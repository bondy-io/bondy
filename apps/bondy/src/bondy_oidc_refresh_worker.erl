%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_oidc_refresh_worker).
-moduledoc """
A gen_server worker in the OIDC refresh pool.

Periodically scans the `bondy_oidc_refresh_queue` ETS table for sessions
needing token refresh and performs the refresh via `oidcc_token:refresh/3`.

The ETS table is an `ordered_set` keyed by `{NextRefreshAt, EntryId}` for
efficient batch selection of due entries using `ets:select/2` with match
specs.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include_lib("oidcc/include/oidcc_token.hrl").

-define(TABLE, bondy_oidc_refresh_queue).
-define(REFRESH_INTERVAL_MS, 30_000). %% 30 seconds
-define(REFRESH_BUFFER_SECS, 60). %% Refresh 60 seconds before expiry
-define(BATCH_SIZE, 50).

-record(refresh_entry, {
    key                     ::  {pos_integer(), binary()},
    realm_uri               ::  uri(),
    authid                  ::  binary(),
    oidc_provider           ::  binary(),
    refresh_token           ::  binary()
}).


%% API
-export([start_link/1]).
-export([schedule_refresh/5]).
-export([remove_entry/1]).
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
Schedules a token refresh for the given entry.
""".
-spec schedule_refresh(
    EntryId :: binary(),
    RealmUri :: uri(),
    Authid :: binary(),
    OidcProvider :: binary(),
    RefreshInfo :: map()
) -> ok.

schedule_refresh(EntryId, RealmUri, Authid, OidcProvider, RefreshInfo)
when is_binary(EntryId) andalso is_binary(RealmUri)
andalso is_binary(Authid) andalso is_binary(OidcProvider)
andalso is_map(RefreshInfo) ->
    #{refresh_token := RefreshToken} = RefreshInfo,
    AccessExpiresAt = maps:get(access_token_expires_at, RefreshInfo, 0),
    NextRefreshAt = max(0, AccessExpiresAt - ?REFRESH_BUFFER_SECS),

    Entry = #refresh_entry{
        key = {NextRefreshAt, EntryId},
        realm_uri = RealmUri,
        authid = Authid,
        oidc_provider = OidcProvider,
        refresh_token = RefreshToken
    },
    true = ets:insert(?TABLE, Entry),
    ok.


-doc """
Removes all refresh entries for the given entry ID.
""".
-spec remove_entry(EntryId :: binary()) -> ok.

remove_entry(EntryId) when is_binary(EntryId) ->
    MS = [{
        #refresh_entry{key = {'_', EntryId}, _ = '_'},
        [],
        [true]
    }],
    _ = ets:select_delete(?TABLE, MS),
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
    MS = [{
        #refresh_entry{key = {'$1', '_'}, _ = '_'},
        [{'=<', '$1', Now}],
        ['$_']
    }],
    Entries = ets:select(?TABLE, MS, ?BATCH_SIZE),
    do_refresh_entries(Entries).


%% @private
do_refresh_entries('$end_of_table') ->
    ok;

do_refresh_entries({Entries, _Continuation}) ->
    lists:foreach(fun do_refresh_entry/1, Entries).


%% @private
do_refresh_entry(#refresh_entry{
    key = Key,
    realm_uri = RealmUri,
    authid = Authid,
    oidc_provider = Provider,
    refresh_token = RefreshToken
}) ->
    %% Remove the old entry first
    true = ets:delete(?TABLE, Key),

    case bondy_oidc_provider:get_client_context(RealmUri, Provider) of
        {ok, ClientCtx} ->
            ReqOpts = case bondy_oidc_provider:get_provider_config(
                RealmUri, Provider
            ) of
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
                        RealmUri, Authid, Provider,
                        AccessToken, NewRefreshToken
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
    RealmUri, Authid, Provider, AccessToken, NewRefreshToken
) ->
    NewRT = case NewRefreshToken of
        #oidcc_token_refresh{token = T} -> T;
        _ -> undefined
    end,

    NewAccessExpiresAt = case AccessToken of
        #oidcc_token_access{expires = Exp} when is_integer(Exp) -> Exp;
        _ -> 0
    end,

    %% Update claims in PlumDB
    UpdateFun = fun(Claims) ->
        Claims1 = case NewRT of
            undefined -> Claims;
            _ -> Claims#{oidc_refresh_token => NewRT}
        end,
        case NewAccessExpiresAt of
            0 -> Claims1;
            _ -> Claims1#{oidc_access_token_expires_at => NewAccessExpiresAt}
        end
    end,

    case bondy_ticket:update_claims(RealmUri, Authid, UpdateFun) of
        ok ->
            %% Re-schedule if we have a refresh token
            case NewRT of
                undefined ->
                    ok;
                _ ->
                    EntryId = bondy_utils:uuid(),
                    schedule_refresh(
                        EntryId, RealmUri, Authid, Provider,
                        #{
                            refresh_token => NewRT,
                            access_token_expires_at => NewAccessExpiresAt
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
