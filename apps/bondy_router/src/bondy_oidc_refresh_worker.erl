%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oidc_refresh_worker).
-moduledoc """
A gen_server worker in the OIDC refresh pool.

Periodically scans the `bondy_oidc_refresh_queue` ETS table for sessions
needing token refresh and performs the refresh via `oidcc_token:refresh/3`.

The ETS table is an `ordered_set` keyed by `{NextRefreshAt, SessionId}` for
efficient batch selection of due entries using `ets:select/2` with match
specs.

An entry lives exactly as long as the session that scheduled it. Nothing on the
session close path removes it — a removal there would have to scan the whole
queue, since the queue is ordered by time and a closing session knows only its
id. Instead the entry is dropped here, when it comes due, if its session is
gone; that is also why the key's second element is the SESSION id and not an
id minted per schedule. With a per-schedule id, the id a session recorded at
open stopped naming the entry the first time the entry was refreshed and
re-queued, so nothing could ever remove it again and the refresh went on
calling the IdP for a session that had long since disconnected
(`bondy_session_cleanup_SUITE:oidc_refresh_entry_is_keyed_by_its_session`).
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include_lib("oidcc/include/oidcc_token.hrl").

-define(TABLE, bondy_oidc_refresh_queue).
%% 30 seconds
-define(REFRESH_INTERVAL_MS, 30_000).
%% Refresh 60 seconds before expiry
-define(REFRESH_BUFFER_SECS, 60).
-define(BATCH_SIZE, 50).

-record(refresh_entry, {
    key :: {non_neg_integer(), bondy_session_id:t()},
    realm_uri :: uri(),
    authid :: binary(),
    oidc_provider :: binary(),
    refresh_token :: binary()
}).

%% API
-export([start_link/1]).
-export([schedule_refresh/5]).
-export([init_table/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc false.
start_link(Shard) ->
    Name = {via, gproc, {n, l, {?MODULE, Shard}}},
    gen_server:start_link(Name, ?MODULE, [Shard], []).

-doc """
Creates the ETS table for the refresh queue. Called once during supervision
tree init.
""".
-spec init_table() -> ok.

init_table() ->
    case ets:info(?TABLE, name) of
        undefined ->
            ?TABLE = ets:new(?TABLE, [
                named_table,
                ordered_set,
                public,
                {keypos, #refresh_entry.key},
                {write_concurrency, true}
            ]),
            ok;
        _ ->
            ok
    end.

-doc """
Schedules a token refresh for session `SessionId`.

The session id, not a per-schedule identifier, is the entry's identity: it is
what lets the worker ask whether the entry still has a session (see the
moduledoc).
""".
-spec schedule_refresh(
    SessionId :: bondy_session_id:t(),
    RealmUri :: uri(),
    Authid :: binary(),
    OidcProvider :: binary(),
    RefreshInfo :: map()
) -> ok.

schedule_refresh(SessionId, RealmUri, Authid, OidcProvider, RefreshInfo) when
    is_binary(SessionId) andalso is_binary(RealmUri) andalso
        is_binary(Authid) andalso is_binary(OidcProvider) andalso
        is_map(RefreshInfo)
->
    #{refresh_token := RefreshToken} = RefreshInfo,
    AccessExpiresAt = maps:get(access_token_expires_in, RefreshInfo, 0),
    NextRefreshAt = max(0, AccessExpiresAt - ?REFRESH_BUFFER_SECS),

    Entry = #refresh_entry{
        key = {NextRefreshAt, SessionId},
        realm_uri = RealmUri,
        authid = Authid,
        oidc_provider = OidcProvider,
        refresh_token = RefreshToken
    },
    true = ets:insert(?TABLE, Entry),
    ok.

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

-doc false.
init([_Shard]) ->
    schedule_tick(),
    {ok, #{}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(refresh_tick, State) ->
    do_refresh_batch(),
    schedule_tick(),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, _State) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
schedule_tick() ->
    _ = erlang:send_after(?REFRESH_INTERVAL_MS, self(), refresh_tick),
    ok.

%% @private
do_refresh_batch() ->
    Now = erlang:system_time(second),
    MS = [
        {
            #refresh_entry{key = {'$1', '_'}, _ = '_'},
            [{'=<', '$1', Now}],
            ['$_']
        }
    ],
    Entries = ets:select(?TABLE, MS, ?BATCH_SIZE),
    do_refresh_entries(Entries).

%% @private
do_refresh_entries('$end_of_table') ->
    ok;
do_refresh_entries({Entries, _Continuation}) ->
    lists:foreach(fun do_refresh_entry/1, Entries).

%% @private
do_refresh_entry(#refresh_entry{
    key = {_, SessionId} = Key,
    realm_uri = RealmUri,
    authid = Authid,
    oidc_provider = Provider,
    refresh_token = RefreshToken
}) ->
    %% Remove the old entry first
    true = ets:delete(?TABLE, Key),

    case bondy_session:lookup(RealmUri, SessionId) of
        {error, not_found} ->
            %% The session went away. Dropping the entry here — rather than on
            %% the close path — is the whole reason the key carries the session
            %% id, and it is what stops a disconnected session's refresh from
            %% running against the IdP for ever. Returning without
            %% re-scheduling is the removal.
            ok;
        {ok, _} ->
            do_refresh_live_entry(
                SessionId, RealmUri, Authid, Provider, RefreshToken
            )
    end.

%% @private
do_refresh_live_entry(SessionId, RealmUri, Authid, Provider, RefreshToken) ->
    case bondy_oidc_provider:get_client_context(RealmUri, Provider) of
        {ok, ClientCtx} ->
            ReqOpts =
                case
                    bondy_oidc_provider:get_provider_config(
                        RealmUri, Provider
                    )
                of
                    {ok, Cfg} -> bondy_oidc_provider:request_opts(Cfg);
                    {error, _} -> #{}
                end,
            RefreshOpts = #{
                expected_subject => Authid,
                request_opts => ReqOpts
            },
            case oidcc_token:refresh(RefreshToken, ClientCtx, RefreshOpts) of
                {ok, #oidcc_token{
                    access = AccessToken,
                    refresh = NewRefreshToken
                }} ->
                    handle_refresh_success(
                        SessionId,
                        RealmUri,
                        Authid,
                        Provider,
                        AccessToken,
                        NewRefreshToken
                    );
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        description => "OIDC token refresh failed",
                        realm_uri => RealmUri,
                        authid => Authid,
                        provider => Provider,
                        reason => Reason
                    })
            end;
        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Failed to get client context for OIDC refresh",
                realm_uri => RealmUri,
                provider => Provider,
                reason => Reason
            })
    end.

%% @private
handle_refresh_success(
    SessionId, RealmUri, Authid, Provider, AccessToken, NewRefreshToken
) ->
    NewRT =
        case NewRefreshToken of
            #oidcc_token_refresh{token = T} -> T;
            _ -> undefined
        end,

    NewAccessExpiresAt =
        case AccessToken of
            #oidcc_token_access{expires = Exp} when is_integer(Exp) -> Exp;
            _ -> 0
        end,

    %% Update claims in PlumDB
    UpdateFun = fun(Claims) ->
        Claims1 =
            case NewRT of
                undefined -> Claims;
                _ -> Claims#{oidc_refresh_token => NewRT}
            end,
        case NewAccessExpiresAt of
            0 -> Claims1;
            _ -> Claims1#{oidc_access_token_expires_in => NewAccessExpiresAt}
        end
    end,

    case bondy_ticket:update_claims(RealmUri, Authid, UpdateFun) of
        ok ->
            %% Re-schedule if we have a refresh token
            case NewRT of
                undefined ->
                    ok;
                _ ->
                    %% Under the SAME session id, so the entry the session
                    %% scheduled at open is still the entry the queue holds.
                    schedule_refresh(
                        SessionId,
                        RealmUri,
                        Authid,
                        Provider,
                        #{
                            refresh_token => NewRT,
                            access_token_expires_in => NewAccessExpiresAt
                        }
                    )
            end;
        {error, not_found} ->
            ?LOG_WARNING(#{
                description => "Ticket not found during OIDC refresh update",
                realm_uri => RealmUri,
                authid => Authid,
                provider => Provider
            })
    end.
