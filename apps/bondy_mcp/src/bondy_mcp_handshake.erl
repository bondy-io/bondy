%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_handshake).

-moduledoc """
Session mechanics for the handshake protocol era (design §12: revisions
`2025-06-18` and `2025-11-25` over Streamable HTTP). The HTTP orchestration
— era selection, method dispatch, status codes — stays in
`bondy_mcp_http_handler`; this module owns what a handshake SESSION is,
including reaching one owned by another cluster node.

## The session (§12.1)

An MCP handshake session is a `bondy_http_transport_session` process plus a
STORED WAMP session (subscriber role) whose ref targets that process. The
`Mcp-Session-Id` is `<nodestring>.<transport-id>` — node-prefixed because
gproc registration is node-local, so only the owning node can resolve the
transport id. Both halves are visible-ASCII, satisfying the transport
specification's session-id character rule.

The stored session is opened with `transport_id` set, which makes
`bondy:send/3` deliver everything addressed to it — broker `EVENT`s — into
the session's transport queue instead of its mailbox (`bondy.erl`'s
`maybe_enqueue/3`). That queue IS the §12.2 notification backlog: a
disconnected `GET` stream loses nothing, and reconnecting drains it.
The open runs INSIDE the transport session process (via
`bondy_http_transport_session:with_state/2`) because
`bondy_session:new/3` targets the calling process and
`bondy_session_manager:open/3` monitors it — that monitor is the cleanup
for the stored session and its subscriptions however the process dies.

## Cross-node requests: the door

The WAMP data plane is already cluster-transparent — calls route through
the dealer to callees anywhere, and events reach the owner's queue from
any node via the relay. What is NOT is the session's control plane: a
plain gen_server plus node-local gproc and a node-local queue, which no
partisan primitive can request/reply against by pid. So every node
serving handshake traffic runs one registered, STATELESS
`partisan_gen_server` (this module, the "door", started on demand), the
same shape as `bondy_registry_meta`: peers address `{?MODULE, Node}` and
each request is served spawn-and-go so no session's slow moment blocks
another's.

Callers hold a `handle()` — `{local, Pid}` or `{remote, Node, Tid}` —
and every operation routes on it. The owning node executes the operation
against the session exactly as a local request would; the REQUESTING
node keeps authentication and the WAMP dispatch (the dealer already
makes the call itself location-transparent). What crosses the door is
the principal TERM and operation arguments, never credentials.

A node name parsed out of a wire session id is attacker-controlled and
is validated against partisan MEMBERSHIP before any use — it is compared
against the members' existing atoms, never converted with
`binary_to_atom/2`, so a client cannot mint atoms or address arbitrary
nodes; unknown and departed owners uniformly answer `not_found` and the
client re-initializes (the transport spec's recovery).

## The cross-node GET stream

A `GET` landing on a non-owner attaches through a PROXY process on the
owner: the proxy is what registers as the session's exclusive SSE
consumer (so the one-stream rule holds cluster-wide), drains and
translates the queue locally — where the subscription maps live — and
pushes finished frames door-to-door to the consumer node, which hands
them to the waiting Cowboy process. Registrations live in gproc on each
side (`{proxy, Tid}` on the owner, `{consumer, Ref}` on the consumer
node), so process death cleans them automatically; a stale proxy whose
consumer died uncleanly is detected on the NEXT attach attempt by a
liveness probe to the consumer node's door and detached, so a conflict
self-heals instead of pinning `409` until the session dies. Frame
delivery between healthy nodes rides partisan's ordered channel; on a
partition the stream goes quiet and the client's reconnect answers
`404` → re-initialize, which is the §12.2 loss model already accepted
(`Last-Event-Id` resumability is deferred).

## Authentication is per request, the session never is

The specification's security best practices are normative here: servers
"MUST verify all inbound requests" and "MUST NOT use sessions for
authentication", and SHOULD bind session IDs to the principal. Every
POST/GET/DELETE re-authenticates at the HTTP layer exactly like the modern
era, and the session is BOUND to the principal that initialized it
(`anonymous` as a class on anonymous principals, whose authids are minted
per request): a different principal presenting the session id gets the
same `404` an unknown session gets — holding a session id grants nothing.

## Deviations from §12.1 as originally designed, and why

The designed bootstrap (synthesize a WAMP `HELLO`, authenticate via
stored claims) forces the realm to permit `cookie` as a WAMP auth
method — read from `bondy_wamp_protocol:maybe_auth_challenge/4`, which
hard-selects `?WAMP_COOKIE_AUTH` whenever claims are present. A realm
authenticating MCP clients by password or OAuth JWT would refuse its
own sessions. The session is instead opened directly from the
HTTP-authenticated identity — the mechanism §21 increment 6's stream
proved — and no WAMP protocol state exists in the session process.
An unreachable or unknown owner answers `404`, not the designed `410`:
the transport specification obliges the client to re-initialize on `404`
and says nothing about `410`.
""".

-behaviour(partisan_gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include_lib("bondy_router/include/bondy.hrl").

-define(DRAIN_BATCH, 100).
%% Door calls: a partisan call always returns or times out.
-define(DOOR_TIMEOUT, 5000).
%% Attach spawns and awaits a proxy on the owner.
-define(ATTACH_TIMEOUT, 10000).

%% Handler state kept inside the transport session process. `with_state/2`
%% serializes every update, which is what orders concurrent POSTs'
%% subscribes and unsubscribes (§12.3).
-type hs() :: #{
    realm := binary(),
    principal := anonymous | binary(),
    version := binary(),
    session := bondy_session:t(),
    %% WAMP subscription id => the resource URI it serves, and its inverse.
    subs := #{integer() => binary()},
    uris := #{binary() => integer()},
    %% JSON-RPC id => the in-flight call (§12.5).
    inflight := #{any() => inflight()}
}.
-type inflight() :: #{
    req_id := id(),
    ctxt := bondy_context:t(),
    mode := binary(),
    %% The node whose dealer holds the call promise — where the CANCEL
    %% must execute (promise stores are caller-node-local).
    node := node()
}.
%% What a request needs to know about a session it dispatches under.
-type meta() :: #{session_id := binary(), version := binary()}.
%% How a request addresses the session for every subsequent operation.
-type handle() :: {local, pid()} | {remote, node(), binary()}.
%% The handler's held GET stream state.
-type stream() ::
    #{mode := local, pid := pid(), tid := binary(), mref := reference()}
    | #{mode := remote, ref := reference(), owner := node(), tid := binary()}.
-export_type([hs/0]).
-export_type([handle/0]).
-export_type([meta/0]).
-export_type([stream/0]).

-export([attach_stream/2]).
-export([bootstrap/5]).
-export([cancel_inflight/2]).
-export([close/1]).
-export([detach_stream/1]).
-export([drain/2]).
-export([fetch/3]).
-export([mint_session_id/1]).
-export([notify_manifest_changed/2]).
-export([parse_session_id/1]).
-export([principal/1]).
-export([register_inflight/3]).
-export([start_link/0]).
-export([subscribe/3]).
-export([take_inflight/2]).
-export([touch/1]).
-export([unregister_inflight/2]).
-export([unsubscribe/2]).

%% PARTISAN_GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% =============================================================================
%% API — session identity
%% =============================================================================

-doc "The wire `Mcp-Session-Id` for a local transport id.".
-spec mint_session_id(TransportId :: binary()) -> binary().

mint_session_id(TransportId) ->
    <<(bondy_config:nodestring())/binary, ".", TransportId/binary>>.

-doc """
Splits a wire session id into its owning node and transport id. The node
name itself contains dots (`bondy@10.0.0.1`), so the split is on the LAST
dot — transport ids are UUIDs and never contain one.
""".
-spec parse_session_id(binary()) ->
    {ok, Node :: binary(), TransportId :: binary()} | error.

parse_session_id(Bin) when is_binary(Bin) ->
    case string:split(Bin, <<".">>, trailing) of
        [Node, TransportId] when Node =/= <<>>, TransportId =/= <<>> ->
            {ok, Node, TransportId};
        _ ->
            error
    end;
parse_session_id(_) ->
    error.

-doc """
The identity a session is bound to: the `anonymous` class for anonymous
principals — their authids are minted per request, so the class is the
strongest binding an anonymous realm admits — and the authid otherwise.
""".
-spec principal(AuthSt :: map()) -> anonymous | binary().

principal(#{is_anonymous := true}) -> anonymous;
principal(#{authid := Authid}) -> Authid.

%% =============================================================================
%% API — lifecycle
%% =============================================================================

-doc """
Creates the session for a successful `initialize`: starts the transport
session (its held `GET` stream deliberately NOT counting as activity —
§12.8: only POSTs reset the idle timer) and, inside it, opens the stored
WAMP session bound to the authenticated principal. Also ensures this
node's door is running, so peers can reach the session from the first
moment its id is on the wire. Returns the minted `Mcp-Session-Id`.

`Listener` is the serving listener's name, carried — with the realm —
as the session's lifecycle telemetry metadata, so the transport
session's `closed` event reaches `bondy_mcp_metrics` with the labels
the close series needs (§15.1). The metadata is registered only AFTER
the stored session opened: a bootstrap that fails part-way closes a
transport that was never announced as an MCP session, and its stop
event must not be accounted as one.
""".
-spec bootstrap(
    RealmUri :: binary(),
    Version :: binary(),
    AuthSt :: map(),
    Peer :: {inet:ip_address(), non_neg_integer()},
    Listener :: atom()
) -> {ok, binary()} | {error, any()}.

bootstrap(RealmUri, Version, AuthSt, Peer, Listener) ->
    ok = ensure_door(),
    TransportId = bondy_utils:uuid(),
    SessionId = bondy_session_id:new(),
    case
        bondy_http_transport_session_sup:start_child(
            TransportId, RealmUri, SessionId, #{
                sse_counts_as_activity => false
            }
        )
    of
        {ok, Pid} ->
            Result = safe_with_state(
                Pid,
                open_fun(
                    TransportId, SessionId, RealmUri, Version, AuthSt, Peer
                )
            ),
            case Result of
                {ok, ok} ->
                    Metadata = #{
                        mcp => #{realm => RealmUri, listener => Listener}
                    },
                    try
                        ok = bondy_http_transport_session:set_telemetry_metadata(
                            Pid, Metadata
                        ),
                        {ok, mint_session_id(TransportId)}
                    catch
                        exit:_ ->
                            %% The session died between the open and the
                            %% registration; close is a no-op on a dead
                            %% pid.
                            ok = bondy_http_transport_session:close(
                                Pid, init_failed
                            ),
                            {error, session_terminated}
                    end;
                Other ->
                    ok = bondy_http_transport_session:close(Pid, init_failed),
                    {error, Other}
            end;
        {error, _} = Error ->
            Error
    end.

-doc """
Resolves a wire session id presented against `RealmUri` by the
authenticated principal, returning the handle every subsequent operation
routes on plus the session facts a dispatch needs. Every failure —
malformed id, unknown or non-member node, unreachable owner, unknown
transport, realm mismatch, principal mismatch, stored session gone — is
the same `{error, not_found}`, so the answer is not an oracle for which
check failed and holding a session id proves nothing; the client
re-initializes, which is the transport specification's own recovery.
""".
-spec fetch(SessionId :: binary(), RealmUri :: binary(), AuthSt :: map()) ->
    {ok, handle(), meta()} | {error, not_found}.

fetch(WireId, RealmUri, AuthSt) ->
    ok = ensure_door(),
    case parse_session_id(WireId) of
        {ok, NodeBin, TransportId} ->
            case NodeBin == bondy_config:nodestring() of
                true ->
                    local_fetch(TransportId, RealmUri, principal(AuthSt));
                false ->
                    case member_node(NodeBin) of
                        {ok, Node} ->
                            remote_fetch(
                                Node, TransportId, RealmUri, principal(AuthSt)
                            );
                        error ->
                            {error, not_found}
                    end
            end;
        error ->
            {error, not_found}
    end.

-doc "Marks POST activity on the session (§12.8: only POSTs do).".
-spec touch(handle()) -> ok.

touch({local, Pid}) ->
    bondy_http_transport_session:touch(Pid);
touch({remote, Node, TransportId}) ->
    door_cast(Node, {touch, TransportId}).

-doc """
Closes the session: cancels every in-flight call (each on the node whose
dealer holds its promise; the blocked POST processes answer with the
cancellation error), then stops the transport session — whose
termination deletes the queue and whose monitor-driven cleanup closes
the stored session and removes its subscriptions.
""".
-spec close(handle()) -> ok.

close({local, Pid}) ->
    local_close(Pid, client_close);
close({remote, Node, TransportId}) ->
    _ = door_call(Node, {close, TransportId}),
    ok.

%% =============================================================================
%% API — subscriptions (§12.4)
%% =============================================================================

-doc """
Subscribes the session's stored WAMP session to `Topic`, serving resource
`Uri`. Executes inside the owning session process, so concurrent POSTs'
subscribes and unsubscribes are ordered by construction — from any node.
Idempotent per URI.
""".
-spec subscribe(handle(), Uri :: binary(), Topic :: binary()) ->
    ok | {error, any()}.

subscribe({local, Pid}, Uri, Topic) ->
    local_subscribe(Pid, Uri, Topic);
subscribe({remote, Node, TransportId}, Uri, Topic) ->
    door_call(Node, {subscribe, TransportId, Uri, Topic}).

-doc """
Removes the session's subscription serving `Uri`. Unknown URIs answer
`{error, not_found}` — the specification treats unsubscribing a
non-subscribed resource as an error the client can see.
""".
-spec unsubscribe(handle(), Uri :: binary()) ->
    ok | {error, not_found | any()}.

unsubscribe({local, Pid}, Uri) ->
    local_unsubscribe(Pid, Uri);
unsubscribe({remote, Node, TransportId}, Uri) ->
    door_call(Node, {unsubscribe, TransportId, Uri}).

%% =============================================================================
%% API — in-flight requests and cancellation (§12.5)
%% =============================================================================

-doc """
Registers an in-flight call under its JSON-RPC id. The entry is stamped
with THIS node — the caller's node, whose dealer holds the call promise
and therefore the only node a CANCEL for it can execute on.
""".
-spec register_inflight(handle(), Id :: any(), map()) -> ok.

register_inflight(Handle, Id, Entry0) ->
    Entry = Entry0#{node => partisan:node()},
    case Handle of
        {local, Pid} ->
            local_register_inflight(Pid, Id, Entry);
        {remote, Node, TransportId} ->
            _ = door_call(Node, {register_inflight, TransportId, Id, Entry}),
            ok
    end.

-doc "Removes an in-flight call once its response was produced.".
-spec unregister_inflight(handle(), Id :: any()) -> ok.

unregister_inflight({local, Pid}, Id) ->
    local_unregister_inflight(Pid, Id);
unregister_inflight({remote, Node, TransportId}, Id) ->
    door_cast(Node, {unregister_inflight, TransportId, Id}).

-doc "Atomically takes an in-flight entry, if it is still in flight.".
-spec take_inflight(handle(), Id :: any()) -> {ok, inflight()} | error.

take_inflight({local, Pid}, Id) ->
    local_take_inflight(Pid, Id);
take_inflight({remote, Node, TransportId}, Id) ->
    case door_call(Node, {take_inflight, TransportId, Id}) of
        {ok, Entry} -> {ok, Entry};
        _ -> error
    end.

-doc """
`notifications/cancelled` (§12.5): cancels the in-flight call registered
under the JSON-RPC id, with the WAMP cancel mode recorded at call time
(the manifest entry's `cancel_mode` WAMP option, `killnowait` by
default). The entry is taken from the OWNER and the cancel executes on
the entry's ORIGIN node — where the promise lives — so the notification
may arrive at any node in the cluster. The blocked POST process is
answered by the dealer with the cancellation error and produces the
response. Arriving after the response was sent — the entry is gone — is
a no-op by construction.
""".
-spec cancel_inflight(handle(), Id :: any()) -> ok.

cancel_inflight(Handle, Id) ->
    case take_inflight(Handle, Id) of
        {ok, Entry} ->
            route_cancel(Entry);
        error ->
            ok
    end.

%% =============================================================================
%% API — server-to-client notifications
%% =============================================================================

-doc """
Enqueues `notifications/*/list_changed` into every handshake session on
`RealmUri` — called by `bondy_mcp_gateway` after a rebuild that changed
the manifest. Pre-encoded here: the queue's `{encoded, Bin}` shape means
"send verbatim" to the `GET` stream, and a session with no stream
connected keeps it as backlog (§12.2).
""".
-spec notify_manifest_changed(binary(), [tools | resources]) -> ok.

notify_manifest_changed(_, []) ->
    ok;
notify_manifest_changed(RealmUri, Kinds) ->
    Encoded = [
        bondy_json_rpc:encode(
            bondy_json_rpc:notification(
                <<"notifications/", (atom_to_binary(Kind))/binary,
                    "/list_changed">>,
                #{}
            )
        )
     || Kind <- Kinds
    ],
    Sessions = gproc:lookup_values({p, l, {?MODULE, RealmUri}}),
    lists:foreach(
        fun({_Pid, TransportId}) ->
            lists:foreach(
                fun(Bin) ->
                    _ = bondy_http_transport_queue:enqueue(
                        TransportId, {encoded, Bin}, #{}
                    )
                end,
                Encoded
            ),
            bondy_http_transport_session:notify_enqueue(TransportId)
        end,
        Sessions
    ),
    Sessions == [] orelse
        lists:foreach(
            fun(Kind) ->
                ok = bondy_mcp_metrics:notification_emitted(
                    RealmUri, list_changed_type(Kind), length(Sessions)
                )
            end,
            Kinds
        ),
    ok.

%% @private
list_changed_type(tools) -> tools_list_changed;
list_changed_type(resources) -> resources_list_changed.

%% =============================================================================
%% API — the held GET stream (§12.2)
%% =============================================================================

-doc """
Attaches the calling process as the session's ONE held `GET` stream —
cluster-wide: locally by registering as the session's exclusive SSE
consumer, remotely through an owner-side proxy. `{error,
already_registered}` is `409 Conflict` on the wire; on the remote path a
conflicting registration is first probed for liveness on ITS consumer
node and a dead one is detached and replaced, so an uncleanly dropped
stream cannot pin the conflict.
""".
-spec attach_stream(handle(), TransportId :: binary()) ->
    {ok, stream()} | {error, already_registered | not_found}.

attach_stream({local, Pid}, TransportId) ->
    try
        bondy_http_transport_session:register_sse_stream(
            Pid, self(), #{mode => exclusive}
        )
    of
        ok ->
            MRef = erlang:monitor(process, Pid),
            {ok, #{mode => local, pid => Pid, tid => TransportId, mref => MRef}};
        {error, already_registered} ->
            {error, already_registered}
    catch
        %% The session died since it was resolved; the request answers
        %% the same 404 an unknown session gets.
        exit:{noproc, _} -> {error, not_found};
        exit:{normal, _} -> {error, not_found};
        exit:{shutdown, _} -> {error, not_found}
    end;
attach_stream({remote, Node, TransportId}, TransportId) ->
    ok = ensure_door(),
    remote_attach(Node, TransportId, 2).

-doc """
Best-effort detach of a REMOTE stream on its way out — the proxy on the
owner is told to exit, freeing the one-stream slot promptly. Not the
cleanup path of record: an uncleanly dead consumer is detected by the
next attach's liveness probe.
""".
-spec detach_stream(stream()) -> ok.

detach_stream(#{mode := remote, owner := Node, tid := Tid, ref := Ref}) ->
    _ = door_call(Node, {detach_stream, Tid, Ref}),
    try
        gproc:unreg({n, l, {?MODULE, consumer, Ref}})
    catch
        error:badarg -> ok
    end,
    ok;
detach_stream(_) ->
    ok.

-doc """
Drains up to one batch of the session's queue for the `GET` stream,
translating above the queue (§12.3): `{encoded, Bin}` entries are MCP
JSON-RPC sent verbatim; raw `EVENT` records become
`notifications/resources/updated` carrying only the resource URI their
subscription serves (§12.4) — an event whose subscription this session
no longer holds is dropped. Returns the SSE data frames in queue order,
and whether a further batch may remain. Owner-local: the local GET
stream and the remote stream's proxy both call it there.
""".
-spec drain(pid(), TransportId :: binary()) ->
    {Frames :: [binary()], More :: boolean()}.

drain(Pid, TransportId) ->
    case bondy_http_transport_queue:dequeue_batch(TransportId, ?DRAIN_BATCH) of
        [] ->
            {[], false};
        Items ->
            Subs = subscription_uris(Pid),
            Frames = lists:filtermap(
                fun(Item) -> translate(Item, Subs) end, Items
            ),
            {Frames, length(Items) == ?DRAIN_BATCH}
    end.

%% =============================================================================
%% THE DOOR — lifecycle and callbacks
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, any()}.

start_link() ->
    partisan_gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #{}}.

%% Session operations are served spawn-and-go (`bondy_registry_meta`'s
%% pattern): the worker calls into the session and answers via
%% `partisan_gen_server:reply/2`, so one slow session never serializes
%% the node's whole cross-node handshake traffic behind it.
handle_call({fetch, Tid, RealmUri, Principal}, From, State) ->
    _ = spawn(fun() ->
        Reply =
            case local_fetch(Tid, RealmUri, Principal) of
                {ok, _Handle, Meta} -> {ok, Meta};
                {error, _} = Error -> Error
            end,
        partisan_gen_server:reply(From, Reply)
    end),
    {noreply, State};
handle_call({subscribe, Tid, Uri, Topic}, From, State) ->
    spawn_reply(From, fun(Pid) -> local_subscribe(Pid, Uri, Topic) end, Tid),
    {noreply, State};
handle_call({unsubscribe, Tid, Uri}, From, State) ->
    spawn_reply(From, fun(Pid) -> local_unsubscribe(Pid, Uri) end, Tid),
    {noreply, State};
handle_call({register_inflight, Tid, Id, Entry}, From, State) ->
    spawn_reply(
        From, fun(Pid) -> local_register_inflight(Pid, Id, Entry) end, Tid
    ),
    {noreply, State};
handle_call({take_inflight, Tid, Id}, From, State) ->
    spawn_reply(From, fun(Pid) -> local_take_inflight(Pid, Id) end, Tid),
    {noreply, State};
handle_call({close, Tid}, From, State) ->
    spawn_reply(From, fun(Pid) -> local_close(Pid, client_close) end, Tid),
    {noreply, State};
handle_call({attach_stream, Tid, Ref, ConsumerNode}, From, State) ->
    _ = spawn(fun() ->
        partisan_gen_server:reply(
            From, start_proxy(Tid, Ref, ConsumerNode)
        )
    end),
    {noreply, State};
handle_call({detach_stream, Tid, Ref}, _From, State) ->
    %% Only the proxy serving exactly `Ref` is detached — a newer proxy
    %% that replaced it must not be killed by a late detach.
    case gproc_lookup({?MODULE, proxy, Tid}) of
        {Proxy, {Ref, _}} -> Proxy ! detach;
        _ -> ok
    end,
    {reply, ok, State};
handle_call({stream_alive, Ref}, _From, State) ->
    Alive =
        case gproc_lookup({?MODULE, consumer, Ref}) of
            {Pid, _} -> is_process_alive(Pid);
            _ -> false
        end,
    {reply, Alive, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({touch, Tid}, State) ->
    case bondy_http_transport_session:whereis(Tid) of
        undefined -> ok;
        Pid -> bondy_http_transport_session:touch(Pid)
    end,
    {noreply, State};
handle_cast({unregister_inflight, Tid, Id}, State) ->
    _ = spawn(fun() ->
        case bondy_http_transport_session:whereis(Tid) of
            undefined -> ok;
            Pid -> local_unregister_inflight(Pid, Id)
        end
    end),
    {noreply, State};
handle_cast({do_cancel, Entry}, State) ->
    %% This node's dealer holds the promise (the entry's origin).
    _ = spawn(fun() -> do_cancel(Entry) end),
    {noreply, State};
handle_cast({frames, Ref, Frames}, State) ->
    case gproc_lookup({?MODULE, consumer, Ref}) of
        {Pid, _} -> Pid ! {mcp_hs_frames, Frames};
        _ -> ok
    end,
    {noreply, State};
handle_cast({stream_down, Ref}, State) ->
    case gproc_lookup({?MODULE, consumer, Ref}) of
        {Pid, _} -> Pid ! mcp_hs_stream_down;
        _ -> ok
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE — routing
%% =============================================================================

%% @private
%% The door is started on demand, mirroring the gateway and audit
%% servers: nothing runs on a node that serves no handshake traffic.
%% `fetch/3` and `bootstrap/5` ensure it, which guarantees every node
%% that dispatched a request (and may therefore be a cancel target or a
%% stream consumer) answers its name.
ensure_door() ->
    case erlang:whereis(?MODULE) of
        undefined ->
            case bondy_mcp_sup:start_door() of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok;
                %% A concurrent starter won the restart_child race.
                {error, running} -> ok;
                {error, _} = Error -> error(Error)
            end;
        _ ->
            ok
    end.

%% @private
%% The owner named in a wire session id, validated against partisan
%% MEMBERSHIP by comparing the members' EXISTING atoms — never
%% `binary_to_atom/2` on client input, which would let clients mint
%% atoms. A non-member (unknown, typoed, or genuinely departed) owner is
%% `error` and the request answers `not_found`.
member_node(NodeBin) ->
    Members = [partisan:node() | partisan:nodes()],
    case
        lists:search(
            fun(N) -> atom_to_binary(N, utf8) == NodeBin end, Members
        )
    of
        {value, Node} -> {ok, Node};
        false -> error
    end.

%% @private
door_call(Node, Msg) ->
    door_call(Node, Msg, ?DOOR_TIMEOUT).

%% @private
door_call(Node, Msg, Timeout) ->
    try
        partisan_gen_server:call(
            {?MODULE, Node}, Msg, [{timeout, Timeout}]
        )
    catch
        Class:Reason ->
            ?LOG_INFO(#{
                description => "MCP handshake door call failed",
                node => Node,
                class => Class,
                reason => Reason
            }),
            {error, unreachable}
    end.

%% @private
door_cast(Node, Msg) ->
    try
        partisan_gen_server:cast({?MODULE, Node}, Msg)
    catch
        _:_ -> ok
    end,
    ok.

%% @private
remote_fetch(Node, Tid, RealmUri, Principal) ->
    case door_call(Node, {fetch, Tid, RealmUri, Principal}) of
        {ok, Meta} ->
            {ok, {remote, Node, Tid}, Meta};
        _ ->
            {error, not_found}
    end.

%% @private
route_cancel(#{node := Node} = Entry) ->
    case Node == partisan:node() of
        true -> do_cancel(Entry);
        false -> door_cast(Node, {do_cancel, Entry})
    end;
route_cancel(Entry) ->
    do_cancel(Entry).

%% @private
%% One door worker shape: resolve the transport, run the op, reply.
spawn_reply(From, Fun, Tid) ->
    _ = spawn(fun() ->
        Reply =
            case bondy_http_transport_session:whereis(Tid) of
                undefined -> {error, not_found};
                Pid -> Fun(Pid)
            end,
        partisan_gen_server:reply(From, Reply)
    end),
    ok.

%% @private
gproc_lookup(Key) ->
    try
        {gproc:lookup_pid({n, l, Key}), gproc:lookup_value({n, l, Key})}
    catch
        error:badarg -> undefined
    end.

%% =============================================================================
%% PRIVATE — local session operations
%% =============================================================================

%% @private
%% Runs inside the transport session process: the gproc property targets
%% it (auto-cleaned on death) and the stored session's ref and the
%% session manager's monitor both target the calling process.
open_fun(TransportId, SessionId, RealmUri, Version, AuthSt, Peer) ->
    fun(undefined) ->
        true = gproc:reg({p, l, {?MODULE, RealmUri}}, TransportId),
        Result = bondy_session_manager:open(SessionId, RealmUri, #{
            peer => Peer,
            is_anonymous => maps:get(is_anonymous, AuthSt),
            authid => maps:get(authid, AuthSt),
            authroles => maps:get(authroles, AuthSt),
            roles => #{subscriber => #{features => #{}}},
            transport_id => TransportId
        }),
        case Result of
            {ok, Session} ->
                {ok, #{
                    realm => RealmUri,
                    principal => principal(AuthSt),
                    version => Version,
                    session => Session,
                    subs => #{},
                    uris => #{},
                    inflight => #{}
                }};
            {error, Reason} ->
                {{error, Reason}, undefined}
        end
    end.

%% @private
local_fetch(TransportId, RealmUri, Principal) ->
    case bondy_http_transport_session:whereis(TransportId) of
        undefined ->
            {error, not_found};
        Pid ->
            check(Pid, RealmUri, Principal)
    end.

%% @private
%% The binding checks, uniformly `not_found`. The stored-session liveness
%% check covers the admin-kill and realm-deletion rows of §12.8: a session
%% whose WAMP session was closed underneath it is dead — the transport
%% process is closed here and the client re-initializes.
check(Pid, RealmUri, Principal) ->
    Result = safe_with_state(Pid, fun(HS) -> {HS, HS} end),
    case Result of
        {ok, #{realm := RealmUri, principal := Principal, session := S} = HS} ->
            case bondy_session:lookup(bondy_session:id(S)) of
                {ok, _} ->
                    Meta = #{
                        session_id => bondy_session:id(S),
                        version => maps:get(version, HS)
                    },
                    {ok, {local, Pid}, Meta};
                {error, not_found} ->
                    %% The stored WAMP session was closed underneath the
                    %% transport (§12.8: the admin-kill and realm-deletion
                    %% rows both land here — this seat cannot tell which,
                    %% so one honest reason covers both).
                    ok = local_close(Pid, stored_session_closed),
                    {error, not_found}
            end;
        _ ->
            {error, not_found}
    end.

%% @private
local_close(Pid, Reason) ->
    case
        safe_with_state(
            Pid, fun(HS) -> {maps:values(maps:get(inflight, HS, #{})), HS} end
        )
    of
        {ok, Inflight} when is_list(Inflight) ->
            lists:foreach(fun route_cancel/1, Inflight);
        _ ->
            ok
    end,
    bondy_http_transport_session:close(Pid, Reason).

%% @private
local_subscribe(Pid, Uri, Topic) ->
    Result = safe_with_state(Pid, fun(HS) ->
        #{realm := RealmUri, session := Session, subs := Subs, uris := Uris} =
            HS,
        case maps:is_key(Uri, Uris) of
            true ->
                {ok, HS};
            false ->
                Ref = bondy_session:ref(Session),
                case bondy_broker:subscribe(RealmUri, #{}, Topic, Ref) of
                    {ok, SubId} ->
                        {ok, HS#{
                            subs := Subs#{SubId => Uri},
                            uris := Uris#{Uri => SubId}
                        }};
                    {error, _} = Error ->
                        {Error, HS}
                end
        end
    end),
    flatten(Result).

%% @private
local_unsubscribe(Pid, Uri) ->
    Result = safe_with_state(Pid, fun(HS) ->
        #{realm := RealmUri, subs := Subs, uris := Uris} = HS,
        case maps:take(Uri, Uris) of
            {SubId, Uris1} ->
                _ = bondy_broker:unsubscribe(SubId, RealmUri),
                {ok, HS#{subs := maps:remove(SubId, Subs), uris := Uris1}};
            error ->
                {{error, not_found}, HS}
        end
    end),
    flatten(Result).

%% @private
subscription_uris(Pid) ->
    case
        safe_with_state(
            Pid, fun(HS) -> {maps:get(subs, HS, #{}), HS} end
        )
    of
        {ok, Subs} when is_map(Subs) -> Subs;
        _ -> #{}
    end.

%% @private
local_register_inflight(Pid, Id, Entry) ->
    _ = safe_with_state(Pid, fun(HS) ->
        Inflight = maps:get(inflight, HS),
        {ok, HS#{inflight := Inflight#{Id => Entry}}}
    end),
    ok.

%% @private
local_unregister_inflight(Pid, Id) ->
    _ = safe_with_state(Pid, fun(HS) ->
        Inflight = maps:get(inflight, HS),
        {ok, HS#{inflight := maps:remove(Id, Inflight)}}
    end),
    ok.

%% @private
local_take_inflight(Pid, Id) ->
    Result = safe_with_state(Pid, fun(HS) ->
        Inflight = maps:get(inflight, HS),
        case maps:take(Id, Inflight) of
            {Entry, Inflight1} ->
                {{ok, Entry}, HS#{inflight := Inflight1}};
            error ->
                {error, HS}
        end
    end),
    case Result of
        {ok, Inner} -> Inner;
        _ -> error
    end.

%% @private
do_cancel(#{req_id := ReqId, ctxt := Ctxt, mode := Mode}) ->
    M = bondy_wamp_message:cancel(ReqId, #{mode => Mode}),
    try
        _ = bondy_router:forward(M, Ctxt),
        ok
    catch
        Class:Reason ->
            ?LOG_WARNING(#{
                description => "Failed to cancel an in-flight MCP call",
                class => Class,
                reason => Reason
            }),
            ok
    end.

%% =============================================================================
%% PRIVATE — the remote stream (consumer side)
%% =============================================================================

%% @private
%% The consumer registers ITSELF in gproc before asking the owner to
%% attach, so no frame can arrive before it is addressable; gproc
%% auto-cleans on death. A conflicting registration is probed on its own
%% consumer node — alive answers 409, dead (or unreachable, in which
%% case frames could not flow to it anyway) is detached and the attach
%% retried.
remote_attach(_, _, 0) ->
    {error, already_registered};
remote_attach(Node, Tid, Attempts) ->
    Ref = make_ref(),
    true = gproc:reg({n, l, {?MODULE, consumer, Ref}}, Tid),
    case
        door_call(
            Node, {attach_stream, Tid, Ref, partisan:node()}, ?ATTACH_TIMEOUT
        )
    of
        ok ->
            {ok, #{mode => remote, ref => Ref, owner => Node, tid => Tid}};
        {error, {already_registered, OldConsumerNode, OldRef}} ->
            true = gproc:unreg({n, l, {?MODULE, consumer, Ref}}),
            case probe_stream(OldConsumerNode, OldRef) of
                true ->
                    {error, already_registered};
                false ->
                    _ = door_call(Node, {detach_stream, Tid, OldRef}),
                    %% The proxy's death and the session's DOWN handling
                    %% are asynchronous; the retry allows them to land.
                    timer:sleep(200),
                    remote_attach(Node, Tid, Attempts - 1)
            end;
        {error, already_registered} ->
            %% An owner-LOCAL stream holds the slot; its liveness was
            %% checked by the exclusive registration itself.
            true = gproc:unreg({n, l, {?MODULE, consumer, Ref}}),
            {error, already_registered};
        {error, _} ->
            true = gproc:unreg({n, l, {?MODULE, consumer, Ref}}),
            {error, not_found}
    end.

%% @private
probe_stream(ConsumerNode, Ref) ->
    case door_call(ConsumerNode, {stream_alive, Ref}) of
        true -> true;
        %% false, and unreachable: a consumer frames cannot reach is
        %% dead for the stream's purposes.
        _ -> false
    end.

%% =============================================================================
%% PRIVATE — the remote stream (owner-side proxy)
%% =============================================================================

%% @private
%% Spawns the proxy and waits for its registration outcome. The proxy is
%% what holds the session's exclusive SSE slot, so the one-stream rule
%% is enforced by the same mechanism as a local stream.
start_proxy(Tid, Ref, ConsumerNode) ->
    case bondy_http_transport_session:whereis(Tid) of
        undefined ->
            {error, not_found};
        Pid ->
            Caller = self(),
            Proxy = spawn(fun() ->
                proxy_init(Caller, Pid, Tid, Ref, ConsumerNode)
            end),
            receive
                {proxy_up, Proxy, Result} -> Result
            after ?DOOR_TIMEOUT ->
                exit(Proxy, kill),
                {error, not_found}
            end
    end.

%% @private
proxy_init(Caller, Pid, Tid, Ref, ConsumerNode) ->
    try gproc:reg({n, l, {?MODULE, proxy, Tid}}, {Ref, ConsumerNode}) of
        true ->
            try
                bondy_http_transport_session:register_sse_stream(
                    Pid, self(), #{mode => exclusive}
                )
            of
                ok ->
                    MRef = erlang:monitor(process, Pid),
                    Caller ! {proxy_up, self(), ok},
                    proxy_loop(Pid, Tid, Ref, ConsumerNode, MRef);
                {error, already_registered} ->
                    %% An owner-local stream holds the slot.
                    Caller ! {proxy_up, self(), {error, already_registered}}
            catch
                exit:_ ->
                    Caller ! {proxy_up, self(), {error, not_found}}
            end
    catch
        error:badarg ->
            %% Another proxy already serves this session: report whose,
            %% so the requester can probe it.
            case gproc_lookup({?MODULE, proxy, Tid}) of
                {_, {OldRef, OldConsumerNode}} ->
                    Caller !
                        {proxy_up, self(),
                            {error,
                                {already_registered, OldConsumerNode, OldRef}}};
                undefined ->
                    Caller ! {proxy_up, self(), {error, already_registered}}
            end
    end.

%% @private
proxy_loop(Pid, Tid, Ref, ConsumerNode, MRef) ->
    receive
        drain_queue ->
            {Frames, More} = drain(Pid, Tid),
            Frames == [] orelse
                door_cast(ConsumerNode, {frames, Ref, Frames}),
            More andalso (self() ! drain_queue),
            proxy_loop(Pid, Tid, Ref, ConsumerNode, MRef);
        {stop_stream, _} ->
            door_cast(ConsumerNode, {stream_down, Ref});
        {'DOWN', MRef, process, Pid, _} ->
            door_cast(ConsumerNode, {stream_down, Ref});
        detach ->
            %% The consumer went away; nothing to tell it.
            ok;
        _ ->
            proxy_loop(Pid, Tid, Ref, ConsumerNode, MRef)
    end.

%% =============================================================================
%% PRIVATE — shared helpers
%% =============================================================================

%% @private
translate({encoded, Bin}, _) when is_binary(Bin) ->
    {true, Bin};
translate(#event{subscription_id = SubId}, Subs) ->
    case maps:find(SubId, Subs) of
        {ok, Uri} ->
            {true,
                bondy_json_rpc:encode(
                    bondy_json_rpc:notification(
                        <<"notifications/resources/updated">>,
                        #{<<"uri">> => Uri}
                    )
                )};
        error ->
            false
    end;
translate(Other, _) ->
    ?LOG_DEBUG(#{
        description => "Dropping untranslatable MCP handshake queue item",
        item => Other
    }),
    false.

%% @private
%% `with_state/2` wraps the closure's own reply in `{ok, _}`; collapse the
%% two layers so callers see the closure's result, and a session that died
%% mid-call as an error.
flatten({ok, Inner}) -> Inner;
flatten({error, _} = Error) -> Error.

%% @private
%% A session can die between resolving its pid and calling into it — a
%% race no caller can close — so the raise a gen_server call makes on a
%% dead server is folded into the error range every caller already
%% handles (the request answers 404 and the client re-initializes).
safe_with_state(Pid, Fun) ->
    try
        bondy_http_transport_session:with_state(Pid, Fun)
    catch
        exit:{noproc, _} -> {error, noproc};
        exit:{normal, _} -> {error, noproc};
        exit:{shutdown, _} -> {error, noproc};
        exit:{timeout, _} -> {error, timeout}
    end.
