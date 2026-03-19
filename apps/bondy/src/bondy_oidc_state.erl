%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_oidc_state).
-moduledoc """
ETS-based storage for OIDC authorization state during the auth code flow.

Stores nonce, PKCE code_verifier, provider name, realm URI, and redirect URI
keyed by a state token. Entries have a 5-minute TTL and are cleaned up
periodically.

The ETS table is owned by a gen_server that handles periodic cleanup.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(TABLE, ?MODULE).
-define(TTL_MS, 300_000). %% 5 minutes
-define(CLEANUP_INTERVAL_MS, 60_000). %% 1 minute


-record(oidc_state, {
    state_token             ::  binary(),
    nonce                   ::  binary(),
    code_verifier           ::  binary(),
    provider_name           ::  binary(),
    realm_uri               ::  uri(),
    redirect_uri            ::  binary(),
    client_id               ::  binary(),
    device_id               ::  binary(),
    created_at              ::  pos_integer()
}).


%% API
-export([new/8]).
-export([take/1]).
-export([cleanup_expired/0]).

%% GEN_SERVER API
-export([start_link/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).



%% =============================================================================
%% API
%% =============================================================================



-doc """
Stores a new OIDC authorization state entry.

The entry will be automatically cleaned up after 5 minutes.
""".
-spec new(
    StateToken :: binary(),
    Nonce :: binary(),
    CodeVerifier :: binary(),
    ProviderName :: binary(),
    RealmUri :: uri(),
    RedirectUri :: binary(),
    ClientId :: binary(),
    DeviceId :: binary()
) -> ok.

new(StateToken, Nonce, CodeVerifier, ProviderName, RealmUri, RedirectUri,
    ClientId, DeviceId)
when is_binary(StateToken) andalso is_binary(Nonce)
andalso is_binary(CodeVerifier) andalso is_binary(ProviderName)
andalso is_binary(RealmUri) andalso is_binary(RedirectUri)
andalso is_binary(ClientId) andalso is_binary(DeviceId) ->
    Entry = #oidc_state{
        state_token = StateToken,
        nonce = Nonce,
        code_verifier = CodeVerifier,
        provider_name = ProviderName,
        realm_uri = RealmUri,
        redirect_uri = RedirectUri,
        client_id = ClientId,
        device_id = DeviceId,
        created_at = erlang:system_time(millisecond)
    },
    true = ets:insert(?TABLE, Entry),
    ok.


-doc """
Retrieves and deletes an OIDC authorization state entry (single-use).

Returns `{ok, Map}` with the state data or `{error, not_found}` if the token
does not exist or has expired.
""".
-spec take(StateToken :: binary()) ->
    {ok, map()} | {error, not_found | expired}.

take(StateToken) when is_binary(StateToken) ->
    case ets:take(?TABLE, StateToken) of
        [#oidc_state{created_at = CreatedAt} = Entry] ->
            Now = erlang:system_time(millisecond),
            case Now - CreatedAt =< ?TTL_MS of
                true ->
                    {ok, #{
                        nonce => Entry#oidc_state.nonce,
                        code_verifier => Entry#oidc_state.code_verifier,
                        provider_name => Entry#oidc_state.provider_name,
                        realm_uri => Entry#oidc_state.realm_uri,
                        redirect_uri => Entry#oidc_state.redirect_uri,
                        client_id => Entry#oidc_state.client_id,
                        device_id => Entry#oidc_state.device_id
                    }};
                false ->
                    {error, expired}
            end;
        [] ->
            {error, not_found}
    end.


-doc """
Removes all expired entries from the ETS table.
""".
-spec cleanup_expired() -> non_neg_integer().

cleanup_expired() ->
    Cutoff = erlang:system_time(millisecond) - ?TTL_MS,
    MS = [{
        #oidc_state{created_at = '$1', _ = '_'},
        [{'<', '$1', Cutoff}],
        [true]
    }],
    ets:select_delete(?TABLE, MS).



%% =============================================================================
%% GEN_SERVER API
%% =============================================================================



-doc false.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



-doc false.
init([]) ->
    ?TABLE = ets:new(?TABLE, [
        named_table,
        set,
        public,
        {keypos, #oidc_state.state_token},
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    schedule_cleanup(),
    {ok, #{}}.


-doc false.
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.


-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.


-doc false.
handle_info(cleanup, State) ->
    N = cleanup_expired(),
    case N > 0 of
        true ->
            ?LOG_INFO(#{
                description => "Cleaned up expired OIDC state entries",
                count => N
            });
        false ->
            ok
    end,
    schedule_cleanup(),
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
schedule_cleanup() ->
    _ = erlang:send_after(?CLEANUP_INTERVAL_MS, self(), cleanup),
    ok.
