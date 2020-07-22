%% =============================================================================
%%  bondy_config_manager.erl -
%%
%%  Copyright (c) 2016-2019 Ngineo Limited t/a Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc A server that takes care of initialising the Bondy configuration
%% with a set of statically define (and thus private) configuration options.
%% All the logic is handled by the {@link bondy_config} helper module.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_config_manager).
-behaviour(gen_server).
-include("bondy.hrl").

-define(PRIVATE_CONFIG, "private.config").
-define(WAMP_EXT_OPTIONS, [
    {call, [
        '_auth_claims',
        '_routing_key'
    ]},
    {cancel, [
        '_auth_claims'
    ]},
    {interrupt, [
        '_auth_claims'
    ]},
    {register, [
        '_auth_claims',
        '_force_locality',
        %% number of concurrent, outstanding calls that can exist
        %% for a single endpoint
        '_concurrency',
        {invoke, [
            <<"jump_consistent_hash">>,
            <<"queue_least_loaded">>,
            <<"queue_least_loaded_sample">>
        ]}
    ]},
    {publish, [
        '_auth_claims',
        %% The ttl for retained events
        '_retained_ttl',
        '_routing_key'
    ]},
    {subscribe, [
        '_auth_claims'
    ]},
    {yield, [
        '_auth_claims'
    ]}
]).
-define(WAMP_EXT_DETAILS, [
    {abort, [
        '_auth_claims'
    ]},
    {welcome, [
        '_auth_claims'
    ]},
    {goodbye, [
        '_auth_claims'
    ]},
    {error, [
        '_auth_claims'
    ]},
    {event, [
        '_auth_claims'
    ]},
    {invocation, [
        '_auth_claims'
    ]},
    {result, [
        '_auth_claims'
    ]}
]).

-define(CONFIG, [
    {plum_db, [
        {prefixes, [
            %% ram
            {registry_registrations, ram},
            {registry_subscriptions, ram},
            %% ram_disk
            {security, ram_disk},
            {security_config, ram_disk},
            {security_group_grants, ram_disk},
            {security_groups, ram_disk},
            {security_sources, ram_disk},
            {security_status, ram_disk},
            {security_user_grants, ram_disk},
            {security_users, ram_disk},
            %% disk
            {api_gateway, disk},
            {oauth2_refresh_tokens, disk}
        ]}
    ]},
    {partisan, [
        {partisan_peer_service_manager, partisan_default_peer_service_manager},
        {pid_encoding, false}
    ]},
    {plumtree, [
        {broadcast_mods, [plum_db]}
    ]},
    {tuplespace, [
    %% {ring_size, 32},
        {static_tables, [
            {bondy_session, [
                set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true}
            ]},
            {bondy_registry_state, [
                set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true}
            ]},
            %% Holds information required to implement the different invocation
            %% strategies like round_robin
            {bondy_rpc_state,  [
                set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true}
            ]},
            {bondy_token_cache, [
                set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true}
            ]}
        ]}
    ]}
]).


%% API
-export([start_link/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Starts the config manager process
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    %% We do this here so that other processes in the supervision tree
    %% are not started before we finished with the configuration
    %% This should be fast anyway so no harm is done.
    do_init().


handle_call(Event, From, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p, from=~p", [Event, From]),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast(Event, State) ->
    _ = lager:error(
        "Error handling cast, reason=unsupported_event, event=~p", [Event]),
    {noreply, State}.


handle_info(Info, State) ->
    _ = lager:debug("Unexpected message, message=~p, state=~p", [Info, State]),
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_init() ->
    %% We initialised the Bondy app config
    ok = bondy_config:init(),

    %% Since advanced.config can be provided by the user at the
    %% platform_etd_dir location we need to override all those parameters
    %% which the user should not be able to set and also set
    %% other parameters which are required for Bondy to operate i.e. all
    %% dependencies, and are private.
    State = undefined,
    ok = wamp_config:set(extended_details, ?WAMP_EXT_DETAILS),
    ok = wamp_config:set(extended_options, ?WAMP_EXT_OPTIONS),
    apply_private_config(prepare_private_config(), State).


%% @private
prepare_private_config() ->
    maybe_configure_message_retention(?CONFIG).


%% @private
maybe_configure_message_retention(Config0) ->
    try
        case bondy_config:get([wamp_message_retention, enabled], false) of
            true ->
                Type = bondy_config:get([wamp_message_retention, storage_type]),
                Prefixes0 = key_value:get([plum_db, prefixes], Config0),
                Prefixes1 = [{retained_messages, Type} | Prefixes0],
                Config1 = key_value:set(
                    [plum_db, prefixes], Prefixes1, Config0
                ),
                {ok, Config1};
            false ->
                {ok, Config0}
        end
    catch
        _:Reason:Stacktrace ->
            _ = lager:error(
                "Error while preparing configuration; reason=~p, stacktrace=~p",
                [Reason, Stacktrace]
            ),
            {error, Reason}
    end.


%% @private
apply_private_config({error, Reason}, _State) ->
    {stop, Reason};

apply_private_config({ok, Config}, State) ->
    _ = lager:debug("Bondy private configuration started"),
    try
        _ = [
            ok = application:set_env(App, Param, Val)
            || {App, Params} <- Config, {Param, Val} <- Params
        ],
        _ = lager:info("Bondy private configuration initialised"),
        {ok, State}
    catch
        error:Reason:Stacktrace ->
            _ = lager:error(
                "Error while applying private configuration options; "
                " reason=~p, stacktrace=~p",
                [Reason, Stacktrace]
            ),
            {stop, Reason}
    end.

