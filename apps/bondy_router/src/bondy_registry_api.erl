%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_api).
-moduledoc """
The `bondy.*` registry introspection procedures — the **paginated** family
(`bondy.registration.list|match`, `bondy.subscription.list|match`,
`bondy.registration.callee.list`).

A thin adapter over `bondy_registry_meta`: it reads the `_limit` / `_cursor`
extension options (bounded by `bondy_registry_meta:{default,max}_page_size/0`),
runs the distributed keyset page, and externalises it with
`bondy_pagination:to_external/1`. The spec-frozen, bounded `wamp.*` equivalents
live in `bondy_wamp_meta_api`.
""".
-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-export([handle_call/3]).

%% =============================================================================
%% API
%% =============================================================================

-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()
) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}.

%% -----------------------------------------------------------------------------
%% bondy.registration.*
%% -----------------------------------------------------------------------------
handle_call(?BONDY_REGISTRATION_LIST, M, Ctxt) ->
    [RealmUri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    reply_page(M, paginated_list(registration, RealmUri, M));
handle_call(?BONDY_REGISTRATION_MATCH, M, Ctxt) ->
    [RealmUri, Uri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    reply_page(M, paginated_match(registration, RealmUri, Uri, M));
handle_call(?BONDY_REGISTRATION_CALLEE_LIST, M, Ctxt) ->
    Args = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1, 2),
    reply_page(M, paginated_callees(Args, M));
%% -----------------------------------------------------------------------------
%% bondy.subscription.*
%% -----------------------------------------------------------------------------
handle_call(?BONDY_SUBSCRIPTION_LIST, M, Ctxt) ->
    [RealmUri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    reply_page(M, paginated_list(subscription, RealmUri, M));
handle_call(?BONDY_SUBSCRIPTION_MATCH, M, Ctxt) ->
    [RealmUri, Uri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    reply_page(M, paginated_match(subscription, RealmUri, Uri, M));
handle_call(_, M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
reply_page(M, {ok, PageMap}) ->
    R = bondy_wamp_message:result(M#call.request_id, #{}, [PageMap]),
    {reply, R};
reply_page(M, {error, Reason}) ->
    E = bondy_wamp_api_utils:error(Reason, M),
    {reply, E}.

%% @private
%% A cluster-wide keyset page of the realm's entries of `Type`, externalised for
%% the wire. Distributed and paginated via `bondy_registry_meta`.
paginated_list(Type, RealmUri, M) ->
    externalise(
        fun() -> bondy_registry_meta:list(Type, RealmUri, page_opts(M)) end
    ).

%% @private
paginated_match(Type, RealmUri, Uri, M) ->
    externalise(
        fun() ->
            bondy_registry_meta:match(Type, RealmUri, Uri, page_opts(M))
        end
    ).

%% @private
%% The callees of a realm (1 arg) or of a procedure (2 args), as
%% `#{node, session_id}`. Paginated and cluster-wide like the four procedures
%% above — it used to be neither: it read `bondy_registry:match/3,4` via
%% `bondy_dealer:callees/1,2`, which under write-only RIB returns the SERVING
%% node's entries only, so the answer silently omitted every callee living
%% elsewhere and grew less complete as the cluster grew.
paginated_callees([RealmUri], M) ->
    paginated_callees(RealmUri, all, M);
paginated_callees([RealmUri, ProcedureUri], M) ->
    paginated_callees(RealmUri, ProcedureUri, M).

%% @private
paginated_callees(RealmUri, Query, M) ->
    externalise(
        fun() ->
            bondy_registry_meta:page_members(
                registration, RealmUri, Query, page_opts(M)
            )
        end
    ).

%% @private
externalise(Fun) ->
    try Fun() of
        {ok, ResultSet} ->
            {ok, bondy_pagination:to_external(ResultSet)};
        {error, _} = Error ->
            Error
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.

%% @private
%% Keyset pagination options from the CALL.Options extension keys `_limit` and
%% `_cursor`. Both are untyped extensions, so read defensively.
page_opts(#call{options = Options}) ->
    #{
        limit => read_limit(Options),
        cursor => maps:get('_cursor', Options, undefined)
    }.

%% @private
%% A non-integer or out-of-range `_limit` falls back to the default rather than
%% erroring — the extension option is untyped, so the reader is deliberately
%% tolerant (unlike `_cursor`, whose malformed value is a hard error, since a
%% junk resume position cannot be guessed). Limits are owned by the engine.
read_limit(Options) ->
    Default = bondy_registry_meta:default_page_size(),
    Max = bondy_registry_meta:max_page_size(),
    case maps:get('_limit', Options, Default) of
        Limit when is_integer(Limit), Limit > 0, Limit =< Max ->
            Limit;
        _ ->
            Default
    end.
