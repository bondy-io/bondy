%% =============================================================================
%%  bondy_config.erl -
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
%% @doc An implementation of app_config behaviour.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_config).
-behaviour(app_config).

-include_lib("kernel/include/logger.hrl").
-include_lib("partisan/include/partisan.hrl").
-include("bondy_plum_db.hrl").
-include("bondy.hrl").


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
        %% Use by bondy relays
        'x_call_id'
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
        {connect_disterl, false},
        {channels, [wamp_peer_relay, data, rpc, membership]},
        {partisan_peer_service_manager, partisan_pluggable_peer_service_manager},
        {pid_encoding, false},
        {ref_encoding, false},
        {broadcast_mods, [plum_db, partisan_plumtree_backend]}
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


-define(BONDY, bondy).

-export([get/1]).
-export([get/2]).
-export([init/1]).
-export([set/2]).

-export([node/0]).
-export([nodestring/0]).
-export([node_spec/0]).

-compile({no_auto_import, [get/1]}).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
init(Args) ->
    %% We initialise the environment with the args
    ok = set_vsn(Args),

    ?LOG_NOTICE(#{
        description => "Initialising Bondy configuration",
        version => get(bondy, vsn)
    }),

    %% We read bondy env and cache the values
    ok = app_config:init(?BONDY, #{callback_mod => ?MODULE}),

    ok = setup_wamp(),

    ok = setup_mods(),

    ok = apply_private_config(prepare_private_config()),

    ok = setup_partisan(),

    ?LOG_NOTICE(#{description => "Bondy configuration finished"}),
    ok.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Key :: list() | atom() | tuple()) -> term().

get(wamp_call_timeout = Key) ->
    Value = app_config:get(?BONDY, Key),
    Max = app_config:get(?BONDY, wamp_max_call_timeout),
    min(Value, Max);

get(Key) ->
    app_config:get(?BONDY, Key).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Key :: list() | atom() | tuple(), Default :: term()) -> term().

get(Key, Default) ->
    app_config:get(?BONDY, Key, Default).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec set(Key :: key_value:key() | tuple(), Value :: term()) -> ok.

set(status, Value) ->
    %% Typically we would change status during application_controller
    %% lifecycle so to avoid a loop (resulting in timeout) we avoid
    %% calling application:set_env/3.
    persistent_term:put({?BONDY, status}, Value);

set(Key, Value) ->
    app_config:set(?BONDY, Key, Value).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec node() -> atom().

node() ->
    partisan_config:get(name).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec nodestring() -> nodestring().

nodestring() ->
    case get(nodestring, undefined) of
        undefined ->
            Node = partisan_config:get(name),
            set(nodestring, atom_to_binary(Node, utf8));
        Nodestring ->
            Nodestring
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec node_spec() -> node_spec().

node_spec() ->
    bondy_peer_service:myself().



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc A utility function we use to extract the version name that is
%% injected by the bondy.app.src configuration file.
%% @end
%% -----------------------------------------------------------------------------
set_vsn(Args) ->
    case lists:keyfind(vsn, 1, Args) of
        {vsn, Vsn} ->
            ok = bondy_config:set(status, initialising),
            application:set_env(bondy, vsn, Vsn);
        false ->
            ok
    end.


%% @private
setup_mods() ->
    ok = bondy_json:setup().


%% @private
setup_partisan() ->
    %% We re-apply partisan config, this reads the partisan env and re-caches
    %% the values.
    %% We do this because partisan might have started already. Before we were
    %% adding plum_db included application and we were synchronising using
    %% application start phases but that so we could control when plum_db and
    %% partisan were being load, but that complicates embedding plum_db in
    %% other applications.
    ok = partisan_config:init(),

    %% We add the wamp_peer_relay channel
    ok = bondy_config:set(wamp_peer_channel, wamp_peer_relay).


%% @private
setup_wamp() ->
    %% We override all those parameters which the user should not be able to
    %% set and also set other parameters which are required for Bondy to
    %% operate i.e. all dependencies, and are private.
    ok = wamp_config:set(extended_details, ?WAMP_EXT_DETAILS),
    ok = wamp_config:set(extended_options, ?WAMP_EXT_OPTIONS).


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
apply_private_config({error, Reason}) ->
    exit(Reason);

apply_private_config({ok, Config}) ->
    ?LOG_DEBUG(#{description => "Bondy private configuration started"}),
    try
        _ = [
            ok = application:set_env(App, Param, Val)
            || {App, Params} <- Config, {Param, Val} <- Params
        ],
        ?LOG_NOTICE("Bondy private configuration initialised"),
        ok
    catch
        error:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while applying private configuration options",
                reason => Reason,
                stacktrace => Stacktrace
            }),
            exit(Reason)
    end.

