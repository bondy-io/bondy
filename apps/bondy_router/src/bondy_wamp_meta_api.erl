%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_meta_api).
-moduledoc """
The spec-compliant `wamp.*` registry/subscription meta procedures
(`wamp.registration.*` and `wamp.subscription.*`: `list`, `lookup`, `match`,
`get`, `list_callees`/`list_subscribers`, `count_callees`/`count_subscribers`).

These keep the shapes Crossbar froze for a single-node router (grouped-by-policy
`list`, flat-id `match`), so they are **not** paginated. On a distributed router
the cluster-wide set is unbounded, so each enumeration is **bounded** via
`bondy_registry_meta:max_results/0`: past the ceiling it returns
`{error, too_many_results}` (→ `bondy.error.too_many_results`) and steers the
caller to the paginated `bondy.*` family (`bondy_registry_api`). `get`-by-id is a
cluster-wide broadcast and may return `{error, unavailable}` (→
`bondy.error.unavailable`) rather than a false `no_such_registration` when a node
holding the entry cannot be reached.

`*.count_callees`/`*.count_subscribers` and `*.list_callees`/`*.list_subscribers`
take a registration/subscription id: `bondy_registry_meta` resolves it to its URI
(a cluster-wide broadcast `get`) and then counts (from RIB summaries) or gathers
the member session ids (each owner node contributes its local sessions — the ids
are not replicated under write-only RIB, only summary counts, so they are
collected on demand). Best-effort AP; `{error, unavailable}` when the resolving
`get` cannot confirm the id.
""".
-behaviour(bondy_wamp_callback).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

%% The `wamp.*` enumeration ceiling lives in `bondy_registry_meta:max_results/0`
%% (Crossbar specified these procedures for a single-node router; on a
%% distributed one the cluster-wide set is unbounded, so past the ceiling a
%% `wamp.*` list/match returns `{error, too_many_results}` and the caller is
%% steered to the paginated `bondy.*` family).
%%
%% Sentinel for "list the whole realm" vs a URI to match.
-define(ALL, all).

-export([handle_call/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec handle_call(M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}.

handle_call(#call{procedure_uri = ?WAMP_SESSION_GET} = M0, Ctxt) ->
    [_, Guid] = bondy_wamp_api_utils:validate_call_args(M0, Ctxt, 2),
    %% Sessions are not replicated, so we route the call to the node that owns
    %% the session. The client-facing session id (`Guid`) is `{NodeHash}.{Rest}`;
    %% its own dot aligns with WAMP URI segments, so the routing URI is plain
    %% concatenation `wamp.session.{NodeHash}.{Rest}.get`. Each node registers a
    %% wildcard `wamp.session.{NodeHash}..get` (see bondy_session_manager), so the
    %% dealer forwards to the owning node with no per-session registration.
    case is_binary(Guid) andalso bondy_session_id:is_type(Guid) of
        true ->
            Uri = <<"wamp.session.", Guid/binary, ".get">>,
            Opts = maps:put(x_procedure, ?WAMP_SESSION_GET, M0#call.options),
            M1 = M0#call{procedure_uri = Uri, options = Opts},

            %% As we are rewriting the call, if the session does not exist we
            %% will get either noproc or no_such_procedure and we want to reply
            %% not_found.
            MakeError = fun
                (no_such_procedure) ->
                    no_such_session_error(?CALL, M0#call.request_id);
                (_) ->
                    undefined
            end,

            {continue, M1, MakeError};
        false ->
            E = no_such_session_error(?CALL, M0#call.request_id),
            {reply, E}
    end;
handle_call(#call{procedure_uri = ?WAMP_REG_LIST} = M, Ctxt) ->
    [RealmUri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    case summary(registration, RealmUri) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(#call{procedure_uri = ?WAMP_REG_LOOKUP} = M, Ctxt) ->
    %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Opts]
    L = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2, 3),

    case lookup(registration, L) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(#call{procedure_uri = ?WAMP_REG_MATCH} = M, Ctxt) ->
    %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Opts]
    L = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2, 3),

    case match(registration, L) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(#call{procedure_uri = ?WAMP_REG_GET} = M, Ctxt) ->
    %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Details]
    L = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2, 3),

    case get(registration, L) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(#call{procedure_uri = ?WAMP_LIST_CALLEES} = M, Ctxt) ->
    [RealmUri, RegId] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    case list_registration_callees(RealmUri, RegId) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(#call{procedure_uri = ?WAMP_COUNT_CALLEES} = M, Ctxt) ->
    [RealmUri, RegId] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    case count_callees(RealmUri, RegId) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(#call{procedure_uri = ?WAMP_SUBSCRIPTION_LIST} = M, Ctxt) ->
    [RealmUri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    case summary(subscription, RealmUri) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(#call{procedure_uri = ?WAMP_SUBSCRIPTION_LOOKUP} = M, Ctxt) ->
    %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Opts]
    L0 = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2, 3),
    L = [subscription] ++ L0,
    case lookup(subscription, L) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(#call{procedure_uri = ?WAMP_SUBSCRIPTION_MATCH} = M, Ctxt) ->
    %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Opts]
    L = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2, 3),

    case match(subscription, L) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(#call{procedure_uri = ?WAMP_SUBSCRIPTION_GET} = M, Ctxt) ->
    %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Details]
    L = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2, 3),

    case get(subscription, L) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(
    #call{procedure_uri = ?WAMP_SUBSCRIPTION_LIST_SUBSCRIBERS} = M, Ctxt
) ->
    [RealmUri, RegId] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    case list_subscription_subscribers(RealmUri, RegId) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
handle_call(
    #call{procedure_uri = ?WAMP_SUBSCRIPTION_COUNT_SUBSCRIBERS} = M, Ctxt
) ->
    [RealmUri, RegId] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    case count_subscribers(RealmUri, RegId) of
        {ok, Result} ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:error(Reason, M),
            {reply, E}
    end;
%% Interface Reflection: the read side of `bondy_interface`. A LIST is the
%% RBAC-projected set of described URIs — the specification's own wording is
%% a list of what the peer "is authorized to access or provide" — and a
%% DESCRIBE of an entry the caller may not see answers exactly as an absent
%% one, so the reply is not an existence oracle.
handle_call(#call{procedure_uri = ?WAMP_REFLECTION_PROC_LIST} = M, Ctxt) ->
    reflection_list(procedure, M, Ctxt);
handle_call(#call{procedure_uri = ?WAMP_REFLECTION_PROC_DESCRIBE} = M, Ctxt) ->
    reflection_describe(procedure, M, Ctxt);
handle_call(#call{procedure_uri = ?WAMP_REFLECTION_TOPIC_LIST} = M, Ctxt) ->
    reflection_list(topic, M, Ctxt);
handle_call(#call{procedure_uri = ?WAMP_REFLECTION_TOPIC_DESCRIBE} = M, Ctxt) ->
    reflection_describe(topic, M, Ctxt);
handle_call(#call{procedure_uri = ?WAMP_REFLECTION_ERROR_LIST} = M, Ctxt) ->
    reflection_list(error, M, Ctxt);
handle_call(#call{procedure_uri = ?WAMP_REFLECTION_ERROR_DESCRIBE} = M, Ctxt) ->
    reflection_describe(error, M, Ctxt);
handle_call(#call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
reflection_list(Kind, M, Ctxt) ->
    [RealmUri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    Entries = bondy_interface:list(RealmUri, Kind),
    Uris = visible_uris(Kind, Entries, rbac_filter(RealmUri, Ctxt)),
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Uris]),
    {reply, R}.

%% @private
reflection_describe(Kind, M, Ctxt) ->
    case bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2) of
        [RealmUri, Uri] when is_binary(Uri) ->
            Visible =
                case rbac_filter(RealmUri, Ctxt) of
                    none ->
                        true;
                    {filter, RBACCtxt} ->
                        {V, _} = permitted(Kind, Uri, RBACCtxt),
                        V
                end,
            case
                Visible andalso bondy_interface:describe(RealmUri, Kind, Uri)
            of
                {ok, Entry} ->
                    External = bondy_interface:to_external(Entry),
                    R = bondy_wamp_message:result(
                        M#call.request_id, #{}, [External]
                    ),
                    {reply, R};
                _ ->
                    {reply, bondy_wamp_api_utils:error(not_found, M)}
            end;
        _ ->
            {reply, bondy_wamp_api_utils:error(badarg, M)}
    end.

%% @private
%% Whether — and with which RBAC context — a reflection result must be
%% projected. Mirrors `bondy_rbac:authorize/3`'s own gates: no filter on a
%% security-disabled realm, and none for a master-realm caller operating on
%% another realm (`validate_call_args/3` only admits that caller from the
%% master realm, where they are an administrator).
rbac_filter(RealmUri, Ctxt) ->
    case bondy_context:realm_uri(Ctxt) of
        RealmUri ->
            case bondy_context:is_security_enabled(Ctxt) of
                true ->
                    {filter,
                        bondy_session:rbac_context(
                            bondy_context:session(Ctxt)
                        )};
                false ->
                    none
            end;
        _Master ->
            none
    end.

%% @private
%% The RBAC projection of a list result, threading the refreshed context
%% through the fold (`check_permission/2` returns it precisely so a caller
%% does not rebuild it per entry once the epoch lapses).
visible_uris(_Kind, Entries, none) ->
    lists:usort([maps:get(uri, E) || E <- Entries]);
visible_uris(Kind, Entries, {filter, RBACCtxt0}) ->
    {Uris, _} = lists:foldl(
        fun(E, {Acc, RC0}) ->
            Uri = maps:get(uri, E),
            case permitted(Kind, Uri, RC0) of
                {true, RC} -> {[Uri | Acc], RC};
                {false, RC} -> {Acc, RC}
            end
        end,
        {[], RBACCtxt0},
        Entries
    ),
    lists:usort(Uris).

%% @private
%% "Authorized to access or provide": a procedure is visible to a caller who
%% may call OR register it, a topic to one who may subscribe OR publish.
%% Error URIs have no permission space — they ride on the operations that
%% raise them — so they are always visible.
permitted(error, _Uri, RBACCtxt) ->
    {true, RBACCtxt};
permitted(Kind, Uri, RBACCtxt) ->
    any_permitted(actions(Kind), Uri, RBACCtxt).

%% @private
actions(procedure) -> [<<"wamp.call">>, <<"wamp.register">>];
actions(topic) -> [<<"wamp.subscribe">>, <<"wamp.publish">>].

%% @private
any_permitted([], _Uri, RBACCtxt) ->
    {false, RBACCtxt};
any_permitted([Action | Rest], Uri, RBACCtxt0) ->
    case bondy_rbac:check_permission({Action, Uri}, RBACCtxt0) of
        {true, RBACCtxt} -> {true, RBACCtxt};
        {false, _, RBACCtxt} -> any_permitted(Rest, Uri, RBACCtxt)
    end.

no_such_session_error(Type, ReqId) when Type == ?CALL; Type == ?INVOCATION ->
    bondy_wamp_message:error(
        Type,
        ReqId,
        #{},
        ?WAMP_NO_SUCH_SESSION,
        [
            <<"No session exists for the supplied identifier">>
        ]
    ).

%% @private
-doc """
Retrieves subscription IDs listed according to match policies.

```
Res :=
  {
      "exact": subscription_ids|list,
      "prefix": subscription_ids|list,
      "wildcard": subscription_ids|list
  }
```
""".
summary(Type, RealmUri) ->
    Default = #{
        ?EXACT_MATCH => [],
        ?PREFIX_MATCH => [],
        ?WILDCARD_MATCH => []
    },
    case bounded_ext(Type, RealmUri, ?ALL) of
        {ok, Externals} ->
            Grouped = lists:foldl(
                fun(Ext, Acc) ->
                    Policy = maps:get(match, Ext),
                    Id = maps:get(id, Ext),
                    maps:update_with(Policy, fun(L) -> [Id | L] end, [Id], Acc)
                end,
                Default,
                Externals
            ),
            {ok, Grouped};
        {error, _} = Error ->
            Error
    end.

%% @private
%% Run a bounded `bondy_registry_meta` enumeration at the wamp.* ceiling:
%% `{ok, Externals}` (<= ?WAMP_META_MAX `wamp_meta` maps) or
%% `{error, too_many_results}` when more exist. `?ALL` lists the realm; a URI
%% matches it.
bounded_ext(Type, RealmUri, ?ALL) ->
    bounded_page(bondy_registry_meta:list(Type, RealmUri, page_limit()));
bounded_ext(Type, RealmUri, Uri) ->
    bounded_page(bondy_registry_meta:match(Type, RealmUri, Uri, page_limit())).

%% @private
bounded_page({ok, #{values := Values, has_more := false}}) ->
    {ok, Values};
bounded_page({ok, #{has_more := true}}) ->
    {error, too_many_results};
bounded_page({error, _} = Error) ->
    Error.

%% @private
%% Fetch one past the ceiling so the bounded enumeration can tell "exactly the
%% ceiling" from "more exist" without a count.
page_limit() ->
    #{limit => bondy_registry_meta:max_results() + 1}.

%% @private
%% Cluster-wide get-by-id: ids are node-local and random, so this is a bounded
%% broadcast resolved by the meta engine (see `bondy_registry_meta:get/3`).
get(Type, [_, _] = L) ->
    get(Type, L ++ [#{}]);
get(Type, [RealmUri, RegId, _Details]) ->
    case bondy_registry_meta:get(Type, RealmUri, RegId) of
        {ok, External} ->
            {ok, External};
        {error, not_found} ->
            {error, bondy_wamp_api_utils:no_such_registration_error(RegId)};
        {error, unavailable} = Error ->
            %% A node holding the entry could not be reached — surfaced as
            %% `bondy.error.unavailable`, NOT `no_such_registration`.
            Error
    end.

%% @private
%% The single entry id managing `Uri` (WAMP lookup returns one id or nothing),
%% resolved cluster-wide via the meta engine.
lookup(Type, [_, _] = L) ->
    lookup(Type, L ++ [#{}]);
lookup(Type, [RealmUri, Uri, _Opts]) ->
    case bondy_registry_meta:match(Type, RealmUri, Uri, #{limit => 1}) of
        {ok, #{values := [Ext | _]}} ->
            {ok, maps:get(id, Ext)};
        {ok, #{values := []}} ->
            ok;
        {error, _} = Error ->
            Error
    end.

%% @private
%% All entry ids matching `Uri`, cluster-wide but bounded (spec-shaped flat id
%% list). Overflows to `{error, too_many_results}` past the wamp.* ceiling.
match(Type, [_, _] = L) ->
    match(Type, L ++ [#{}]);
match(Type, [RealmUri, Uri, _Opts]) ->
    case bounded_ext(Type, RealmUri, Uri) of
        {ok, Externals} ->
            {ok, [maps:get(id, Ext) || Ext <- Externals]};
        {error, _} = Error ->
            Error
    end.

%% @private
%% The WAMP session ids of the callees of the registration `RegId`, cluster-wide
%% (`bondy_registry_meta` resolves the id to its URI, then gathers each owner
%% node's local callee sessions — under write-only RIB the ids are not
%% replicated, only summary counts, so they are collected on demand).
list_registration_callees(RealmUri, RegId) ->
    bondy_registry_meta:list_members(registration, RealmUri, RegId).

%% @private
%% The number of callees of the registration `RegId`, cluster-wide (local matches
%% plus the RIB summary counts; best-effort AP).
count_callees(RealmUri, RegId) ->
    bondy_registry_meta:count_members(registration, RealmUri, RegId).

%% @private
list_subscription_subscribers(RealmUri, SubId) ->
    bondy_registry_meta:list_members(subscription, RealmUri, SubId).

%% @private
count_subscribers(RealmUri, SubId) ->
    bondy_registry_meta:count_members(subscription, RealmUri, SubId).
