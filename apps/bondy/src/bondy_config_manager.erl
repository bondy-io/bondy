%% =============================================================================
%%  bondy_config_manager.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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

-include_lib("kernel/include/logger.hrl").
-include("bondy.hrl").
-include("bondy_plum_db.hrl").

-define(WAMP_EXT_OPTIONS, [
    {call, [
        'x_routing_key'
    ]},
    {cancel, [
        'x_routing_key'
    ]},
    {interrupt, [
        'x_session_info'
    ]},
    {register, [
        'x_disclose_session_info',
        'x_force_locality',
        %% number of concurrent, outstanding calls that can exist
        %% for a single endpoint
        'x_concurrency',
        {invoke, [
            <<"jump_consistent_hash">>, <<"jch">>,
            <<"queue_least_loaded">>, <<"qll">>,
            <<"queue_least_loaded_sample">>, <<"qlls">>
        ]}
    ]},
    {publish, [
        %% The ttl for retained events
        '_retained_ttl',
        'x_routing_key'
    ]},
    {subscribe, [
    ]},
    {yield, [
    ]}
]).
-define(WAMP_EXT_DETAILS, [
    {abort, [
    ]},
    {hello, [
        'x_authroles'
    ]},
    {welcome, [
        'x_authroles'
    ]},
    {goodbye, [
    ]},
    {error, [
    ]},
    {event, [
    ]},
    {invocation, [
        'x_session_info',
        %% The following are used internally by Bondy on the edge uplink
        %% communication
        originating_id,
        originating_handler,
        originating_pid,
        originating_node
    ]},
    {result, [
    ]}
]).

-define(CONFIG, [
    %% Distributed globally replicated storage
    {plum_db, [
        {prefixes, ?PLUM_DB_PREFIXES}
    ]},
    {partisan, [
        {partisan_peer_service_manager, partisan_default_peer_service_manager},
        {pid_encoding, false}
    ]},
    {plumtree, [
        {broadcast_mods, [plum_db]}
    ]},
    %% Local in-memory storage
    {tuplespace, [
        %% Ring size is determined based on number of Erlang schedulers
        %% which are based on number of CPU Cores.
        %% {ring_size, 32},
        {static_tables, [
            %% Used by bondy_session.erl
            {bondy_session, [
                set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true}
            ]},
            %% Used by bondy_registry.erl counters
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
    ?LOG_WARNING(#{
        description => "Error handling call",
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        description => "Error handling cast",
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.


handle_info(Info, State) ->
    ?LOG_WARNING(#{
        description => "Error handling info",
        reason => unsupported_event,
        event => Info
    }),
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
    ok = setup_mods(),
    apply_private_config(prepare_private_config(), State).


%% @private
setup_mods() ->
    ok = bondy_json:setup(),
    ok.


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
            ?LOG_ERROR(#{
                description => "Error while preparing configuration",
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.


%% @private
apply_private_config({error, Reason}, _State) ->
    {stop, Reason};

apply_private_config({ok, Config}, State) ->
    ?LOG_DEBUG(#{description => "Bondy private configuration started"}),
    try
        _ = [
            ok = application:set_env(App, Param, Val)
            || {App, Params} <- Config, {Param, Val} <- Params
        ],
        ?LOG_NOTICE("Bondy private configuration initialised"),
        {ok, State}
    catch
        error:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while applying private configuration options",
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {stop, Reason}
    end.

