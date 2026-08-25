%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_stream).

-moduledoc """
The `subscriptions/listen` stream (design §9, §5.3): the one long-lived
thing in the modern era, owned by the request's own Cowboy process — no
extra process exists. `bondy_mcp_http_handler` calls `open/6` from its
dispatch and delegates its `cowboy_loop` `info/3` here for the life of the
SSE response.

## Shape

`open/6` validates the `notifications` filter, opens a STORED session via
`bondy_session_manager:open/3` — which monitors this process, so when the
stream dies (client close, idle timeout, crash) the manager's existing
`DOWN` cleanup closes the session and removes every subscription
registered under its ref; nothing here depends on a terminate callback
running — then issues one WAMP `SUBSCRIBE` per honored
`resourceSubscriptions` entry and answers with the SSE stream, sending
`notifications/subscriptions/acknowledged` as the FIRST message (the spec
requires it before any notification), carrying the subset actually
honored.

## Honoring the filter (§9.1, §9.2)

`toolsListChanged` and `resourcesListChanged` are fed by the manifest
manager's rebuild (`notify_manifest_changed/2`, called by
`bondy_mcp_gateway` when a rebuild CHANGES the manifest), not by any WAMP
subscription. `promptsListChanged` is not supported and is omitted from
the acknowledgment. Each `resourceSubscriptions` URI resolves through the
manifest to a WAMP topic (`bondy_mcp_wamp:resolve_update_topic/2`); an
entry that does not resolve, or whose topic the principal lacks
`wamp.subscribe` on, is SILENTLY omitted — RBAC-hidden and absent answer
identically (§6), and the denial is audited as a §14.1 policy decision,
invisible on the wire.

The server MUST NOT send a notification type the client did not request:
delivery is gated on the stream's own filter state, and a delivered WAMP
`EVENT` whose subscription id this stream does not hold is dropped.
`notifications/resources/updated` carries ONLY the resource URI (§9.2) —
the client re-reads, which keeps RBAC on the read path.

## The three endings (§9.3)

- Client closes the SSE stream / transport drops: nothing is sent; the
  session-manager `DOWN` cleanup runs.
- Server teardown (`close/2`): `notifications/cancelled` naming the
  `subscriptions/listen` request id (the spec's ONLY sanctioned use of
  that notification server-side), then the empty completion response
  (`resultType: "complete"`) correlated by that id, then the stream ends.

Stream lifetime is governed by the listener's CONNECTION idle timer,
seated from the `mcp` carrier's `idle_timeout` with
`reset_idle_timeout_on_send` by `bondy_listener_config:
held_stream_defaults/1` — no per-stream cast (§3.8: HTTP/2 discards it).
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include_lib("bondy_router/include/bondy.hrl").
-include_lib("bondy_json_rpc/include/bondy_json_rpc.hrl").

-define(SUBSCRIPTION_ID_META, <<"io.modelcontextprotocol/subscriptionId">>).

-record(stream, {
    %% The JSON-RPC id of the `subscriptions/listen` request — the
    %% subscription's whole identity (§9.1).
    id :: binary() | integer(),
    realm :: binary(),
    session :: bondy_session:t(),
    %% WAMP subscription id => the resource URI it serves.
    subs :: #{integer() => binary()},
    tools_list :: boolean(),
    resources_list :: boolean()
}).

-opaque t() :: #stream{}.
-export_type([t/0]).

-export([open/6]).
-export([info/3]).
-export([close/2]).
-export([pids/1]).
-export([notify_manifest_changed/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Opens the stream in the calling Cowboy request process: validates the
filter, opens the stored session, subscribes, starts the SSE response and
sends the acknowledgment. Returns the started `Req` and the stream state
for the handler's loop. Validation failures throw the handler's
`{reply2, Status, Body}` — everything that can fail does so BEFORE the
response starts.
""".
-spec open(
    Id :: binary() | integer(),
    Params :: map(),
    RealmUri :: binary(),
    AuthSt :: map(),
    Req :: cowboy_req:req(),
    St :: map()
) -> {stream, cowboy_req:req(), t()}.

open(Id, Params, RealmUri, AuthSt, Req0, St) ->
    Filter = filter(Id, Params),
    {ok, #{entries := Entries}} = bondy_mcp_gateway:manifest(RealmUri),
    Session = open_session(Id, RealmUri, AuthSt, Req0),
    {Honored, Subs} = subscribe_resources(
        maps:get(resource_subscriptions, Filter),
        Entries,
        RealmUri,
        AuthSt,
        Session,
        St
    ),
    true = gproc:reg({p, l, {?MODULE, RealmUri}}),
    Req = cowboy_req:stream_reply(
        200,
        #{
            <<"content-type">> => <<"text/event-stream; charset=utf-8">>,
            <<"cache-control">> => <<"no-cache">>,
            <<"x-accel-buffering">> => <<"no">>
        },
        Req0
    ),
    Stream = #stream{
        id = Id,
        realm = RealmUri,
        session = Session,
        subs = Subs,
        tools_list = maps:get(tools_list, Filter),
        resources_list = maps:get(resources_list, Filter)
    },
    ok = send(Req, ack(Stream, Filter, Honored)),
    {stream, Req, Stream}.

-doc """
Handles one message for the handler's `cowboy_loop` `info/3`.
""".
-spec info(any(), cowboy_req:req(), t()) ->
    {ok, cowboy_req:req(), t()} | {stop, cowboy_req:req(), t()}.

info({?BONDY_REQ, _Pid, _RealmUri, #event{} = Event}, Req, Stream) ->
    #stream{subs = Subs} = Stream,
    case maps:find(Event#event.subscription_id, Subs) of
        {ok, Uri} ->
            ok = send(
                Req,
                notification(Stream, <<"notifications/resources/updated">>, #{
                    <<"uri">> => Uri
                })
            ),
            ok = bondy_mcp_metrics:notification_emitted(
                Stream#stream.realm, resources_updated, 1
            );
        error ->
            %% Not a subscription this stream holds — never forwarded:
            %% the filter is a MUST, not a suggestion (§9.1).
            ok
    end,
    {ok, Req, Stream};
info({mcp_manifest_changed, Realm, Kinds}, Req, #stream{realm = Realm} = S) ->
    S#stream.tools_list andalso lists:member(tools, Kinds) andalso
        begin
            ok = send(
                Req,
                notification(S, <<"notifications/tools/list_changed">>, #{})
            ),
            ok = bondy_mcp_metrics:notification_emitted(
                Realm, tools_list_changed, 1
            ),
            true
        end,
    S#stream.resources_list andalso lists:member(resources, Kinds) andalso
        begin
            ok = send(
                Req,
                notification(S, <<"notifications/resources/list_changed">>, #{})
            ),
            ok = bondy_mcp_metrics:notification_emitted(
                Realm, resources_list_changed, 1
            ),
            true
        end,
    {ok, Req, S};
info({mcp_stream_close, Reason}, Req, #stream{id = Id} = Stream) ->
    %% Server-initiated teardown (§9.3): notifications/cancelled naming
    %% the listen request id, then the graceful completion response —
    %% distinguishable from a transport drop, which sends neither.
    ok = send(
        Req,
        bondy_json_rpc:notification(<<"notifications/cancelled">>, #{
            <<"requestId">> => Id,
            <<"reason">> => reason_text(Reason)
        })
    ),
    ok = bondy_mcp_metrics:notification_emitted(
        Stream#stream.realm, cancelled, 1
    ),
    Final = bondy_json_rpc:result_response(Id, #{
        <<"resultType">> => <<"complete">>,
        <<"_meta">> => #{?SUBSCRIPTION_ID_META => Id}
    }),
    ok = cowboy_req:stream_events(
        #{data => bondy_json_rpc:encode(Final)}, fin, Req
    ),
    {stop, Req, Stream};
info(_Msg, Req, Stream) ->
    {ok, Req, Stream}.

-doc """
Asks the stream at `Pid` to end gracefully — the §9.3 server-initiated
teardown. Asynchronous; the caller does not learn when the stream closed.
""".
-spec close(pid(), any()) -> ok.

close(Pid, Reason) when is_pid(Pid) ->
    Pid ! {mcp_stream_close, Reason},
    ok.

-doc "The live `subscriptions/listen` stream processes serving `RealmUri`.".
-spec pids(binary()) -> [pid()].

pids(RealmUri) ->
    gproc:lookup_pids({p, l, {?MODULE, RealmUri}}).

-doc """
Tells every stream serving `RealmUri` that the realm's manifest changed —
called by `bondy_mcp_gateway` after a rebuild whose result differs from
the previous manifest. `Kinds` names what changed (`tools`, `resources`);
each stream forwards only the types its own filter requested.
""".
-spec notify_manifest_changed(binary(), [tools | resources]) -> ok.

notify_manifest_changed(_, []) ->
    ok;
notify_manifest_changed(RealmUri, Kinds) ->
    Msg = {mcp_manifest_changed, RealmUri, Kinds},
    _ = [Pid ! Msg || Pid <- pids(RealmUri)],
    ok.

%% =============================================================================
%% PRIVATE — opening
%% =============================================================================

%% @private
%% The §9.1 notifications filter, validated. Booleans and a list of
%% binaries; anything else is -32602. `promptsListChanged` is accepted in
%% the request but never honored — Bondy has no prompts (§8).
filter(Id, Params) ->
    F = maps:get(<<"notifications">>, Params, #{}),
    is_map(F) orelse invalid_params(Id, <<"notifications must be an object">>),
    Bool = fun(Key) ->
        case maps:get(Key, F, false) of
            B when is_boolean(B) ->
                B;
            _ ->
                invalid_params(Id, <<Key/binary, " must be a boolean">>)
        end
    end,
    Subs =
        case maps:get(<<"resourceSubscriptions">>, F, []) of
            L when is_list(L) ->
                lists:all(fun is_binary/1, L) orelse
                    invalid_params(
                        Id, <<"resourceSubscriptions must be a list of URIs">>
                    ),
                lists:uniq(L);
            _ ->
                invalid_params(
                    Id, <<"resourceSubscriptions must be a list of URIs">>
                )
        end,
    #{
        tools_list => Bool(<<"toolsListChanged">>),
        resources_list => Bool(<<"resourcesListChanged">>),
        prompts_requested => Bool(<<"promptsListChanged">>),
        resource_subscriptions => Subs
    }.

%% @private
%% The stored session (§5.3): `bondy_session_manager:open/3` runs
%% `bondy_session:new/3` in THIS process — the session's ref targets the
%% stream — and monitors it, which is the whole cleanup story. Role:
%% subscriber only (§5.5 is an upper bound; a stream never calls).
open_session(Id, RealmUri, AuthSt, Req) ->
    Result = bondy_session_manager:open(
        bondy_session_id:new(),
        RealmUri,
        #{
            peer => cowboy_req:peer(Req),
            is_anonymous => maps:get(is_anonymous, AuthSt),
            authid => maps:get(authid, AuthSt),
            authroles => maps:get(authroles, AuthSt),
            roles => #{subscriber => #{features => #{}}}
        }
    ),
    case Result of
        {ok, Session} ->
            Session;
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Failed to open an MCP stream session",
                realm => RealmUri,
                reason => Reason
            }),
            throw(
                {reply2, 500,
                    bondy_json_rpc:error_response(
                        Id, ?JSONRPC_INTERNAL_ERROR, <<"Internal error">>
                    )}
            )
    end.

%% @private
%% Resolves and subscribes the honored subset: each URI must resolve
%% through the manifest to an update topic AND pass `wamp.subscribe` on
%% that topic. Unresolvable and denied are the same silence on the wire;
%% only the denial leaves an audit record.
subscribe_resources([], _, _, _, _, _) ->
    {[], #{}};
subscribe_resources(Uris, Entries, RealmUri, AuthSt, Session, St) ->
    RbacCtxt0 =
        case bondy_realm:is_security_enabled(RealmUri) of
            true -> bondy_session:rbac_context(Session);
            false -> none
        end,
    Ref = bondy_session:ref(Session),
    {Honored, Subs, _} = lists:foldl(
        fun(Uri, {HonoredAcc, SubsAcc, Ctxt0}) ->
            case resolve(maps:values(Entries), Uri) of
                {ok, Entry, Topic} ->
                    case allowed(Topic, Ctxt0) of
                        {true, Ctxt} ->
                            {ok, SubId} = bondy_broker:subscribe(
                                RealmUri, #{}, Topic, Ref
                            ),
                            ok = bondy_mcp_metrics:resource_subscribed(
                                RealmUri, maps:get(name, Entry)
                            ),
                            {
                                [Uri | HonoredAcc],
                                SubsAcc#{SubId => Uri},
                                Ctxt
                            };
                        {false, Ctxt} ->
                            ok = audit_denied(
                                Uri, Entry, RealmUri, AuthSt, St
                            ),
                            ok = bondy_mcp_metrics:rbac_denied(
                                RealmUri, subscribe_authz, 1
                            ),
                            {HonoredAcc, SubsAcc, Ctxt}
                    end;
                nomatch ->
                    {HonoredAcc, SubsAcc, Ctxt0}
            end
        end,
        {[], #{}, RbacCtxt0},
        Uris
    ),
    {lists:reverse(Honored), Subs}.

%% @private
%% The first manifest entry whose update stream serves `Uri` (§9.2).
resolve([], _) ->
    nomatch;
resolve([Entry | Rest], Uri) ->
    case bondy_mcp_wamp:resolve_update_topic(Entry, Uri) of
        {ok, Topic} -> {ok, Entry, Topic};
        _ -> resolve(Rest, Uri)
    end.

%% @private
allowed(_, none) ->
    {true, none};
allowed(Topic, Ctxt0) ->
    case bondy_rbac:check_permission({<<"wamp.subscribe">>, Topic}, Ctxt0) of
        {true, Ctxt} -> {true, Ctxt};
        {false, _, Ctxt} -> {false, Ctxt}
    end.

%% @private
%% A denied subscription attempt is a §14.1 policy decision. Denial only
%% arises on a security-enabled realm, so the source is `rbac`.
audit_denied(Uri, Entry, RealmUri, AuthSt, St) ->
    _ = bondy_mcp_audit:record(policy_decision, #{
        realm => RealmUri,
        listener => maps:get(listener, St),
        transport => maps:get(transport, St),
        principal => maps:get(authid, AuthSt),
        is_anonymous => maps:get(is_anonymous, AuthSt),
        name => maps:get(name, Entry),
        uri => Uri,
        procedure => maps:get(procedure, Entry, undefined),
        entry_hash => maps:get(hash, Entry),
        redaction => maps:get(redaction, Entry, none),
        decision => #{verdict => deny, rule => undefined, source => rbac},
        status => denied
    }),
    ok.

%% @private
%% The spec-required first message: the subset this server agreed to
%% honor. `promptsListChanged` is omitted — unsupported types are, by the
%% specification, absent rather than false. A requested key the server
%% honors echoes back; `resourceSubscriptions` echoes the honored URIs
%% (possibly fewer than requested, and an unauthorized one is
%% indistinguishable from an unknown one).
ack(#stream{id = Id}, Filter, Honored) ->
    N0 = #{},
    N1 =
        case maps:get(tools_list, Filter) of
            true -> N0#{<<"toolsListChanged">> => true};
            false -> N0
        end,
    N2 =
        case maps:get(resources_list, Filter) of
            true -> N1#{<<"resourcesListChanged">> => true};
            false -> N1
        end,
    N3 =
        case maps:get(resource_subscriptions, Filter) of
            [] -> N2;
            _ -> N2#{<<"resourceSubscriptions">> => Honored}
        end,
    bondy_json_rpc:notification(
        <<"notifications/subscriptions/acknowledged">>, #{
            <<"_meta">> => #{?SUBSCRIPTION_ID_META => Id},
            <<"notifications">> => N3
        }
    ).

%% =============================================================================
%% PRIVATE — delivery
%% =============================================================================

%% @private
notification(#stream{id = Id}, Method, Params) ->
    bondy_json_rpc:notification(Method, Params#{
        <<"_meta">> => #{?SUBSCRIPTION_ID_META => Id}
    }).

%% @private
send(Req, Msg) ->
    cowboy_req:stream_events(
        #{data => bondy_json_rpc:encode(Msg)}, nofin, Req
    ).

%% @private
reason_text(Reason) when is_binary(Reason) ->
    Reason;
reason_text(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
reason_text(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

%% @private
invalid_params(Id, Message) ->
    throw(
        {reply2, 400,
            bondy_json_rpc:error_response(
                Id, ?JSONRPC_INVALID_PARAMS, Message
            )}
    ).
