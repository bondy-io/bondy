%% =============================================================================
%%  bondy_config.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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

%% We renamed the default plum_db data channel
-define(PLUM_DB_DATA_CHANNEL, data).
-define(WAMP_RELAY_CHANNEL, wamp_relay).

-include_lib("kernel/include/logger.hrl").
-include("bondy_plum_db.hrl").
-include("bondy.hrl").

-if(?OTP_RELEASE >= 25).
    -define(VALIDATE_MQ_DATA(X),
        case X of
            off_heap -> off_heap;
            _ -> on_heap
        end
    ).
-else.
    -define(VALIDATE_MQ_DATA(_), on_heap).
-endif.


-define(WAMP_EXT_OPTIONS, [
    {call, [
        '_routing_key'
    ]},
    {cancel, [
        '_routing_key'
    ]},
    {interrupt, [
        'x_session_info', '_session_info'
    ]},
    {register, [
        'x_disclose_session_info', '_disclose_session_info',
        '_prefer_local', '_prefer_local',
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
        '_routing_key'
    ]},
    {subscribe, [
        'x_disclose_session_info', '_disclose_session_info'
    ]},
    {yield, [
    ]}
]).
-define(WAMP_EXT_DETAILS, [
    {abort, [
    ]},
    {hello, [
        'x_authroles', '_authroles'
    ]},
    {welcome, [
        'x_authroles', '_authroles'
    ]},
    {goodbye, [
    ]},
    {error, [
    ]},
    {event, [
        'x_session_info', '_session_info'
    ]},
    {call, [
    ]},
    {invocation, [
        'x_session_info', '_session_info'
    ]},
    {result, [
    ]}
]).

-define(CONFIG, [
    %% The following are configured via bondy.conf:
    %% - exchange_tick_period <- cluster.exchange_tick_period
    %% - lazy_tick_period <- cluster.lazy_tick_period
    %% - peer_port <- cluster.peer_port
    %% - parallelism <- cluster.parallelism
    %% - peer_service_manager <- cluster.overlay.topology
    %% - partisan.tls <- cluster.tls.enabled
    %% - partisan.tls_server_options.* <- cluster.tls.server.*
    %% - partisan.tls_client_options.* <- cluster.tls.client.*
    {partisan, [
        %% Overlay topology
        %% Required for peer_service_manager ==
        %% partisan_pluggable_peer_service_manager
        {membership_strategy, partisan_full_membership_strategy},
        {connect_disterl, false},
        {broadcast_mods, [
            plum_db,
            partisan_plumtree_backend
        ]},
        %% Remote refs
        {remote_ref_format, improper_list},
        {remote_ref_binary_padding, false},
        {pid_encoding, false},
        {ref_encoding, false},
        {register_pid_for_encoding, false},
        {binary_padding, false},
        %% Fwd options
        {disable_fast_forward, false},
        %% Broadcast options
        {broadcast, false},
        {tree_refresh, 1000},
        {relay_ttl, 5}
    ]},
    {bondy_wamp, [
        {json, [
            {decode_opts, [{decoders, #{null => undefined}}]}
        ]}
    ]},
    %% Local in-memory storage
    {tuplespace, [
        %% Ring size is determined based on number of Erlang schedulers
        %% which are based on number of CPU Cores.
        {ring_size, min(16, erlang:system_info(schedulers))},
        {static_tables, [
            %% Used by bondy_session.erl
            {bondy_session, [
                set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true},
                {decentralized_counters, true}
            ]},
            %% Used by bondy_session_counter.erl
            {bondy_session_counter, [
                set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true},
                {decentralized_counters, true}
            ]},
            {bondy_registration_index, [
                bag,
                {keypos, 1},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true},
                {decentralized_counters, true}
            ]},
            {bondy_rpc_promise,  [
                ordered_set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true},
                {decentralized_counters, true}
            ]},
            %% Holds information required to implement the different invocation
            %% strategies like round_robin
            {bondy_rpc_state,  [
                set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true},
                {decentralized_counters, true}
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
-export([listener_transport_opts/1]).
-export([listener_protocol_opts/1]).


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

    ok = setup_partisan_channels(),

    ok = setup_partisan(),

    ok = apply_private_config(prepare_private_config()),


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
            Nodestring = atom_to_binary(partisan_config:get(name), utf8),
            ok = set(nodestring, Nodestring),
            Nodestring;
        Nodestring ->
            Nodestring
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec node_spec() -> partisan:node_spec().

node_spec() ->
    partisan:node_spec().



-spec listener_transport_opts(ListenerName :: atom()) -> map().

listener_transport_opts(Name) ->
    Opts = key_value:to_map(get([Name, transport_opts])),
    NumAcceptors = key_value:get(num_acceptors, Opts),
    SocketOpts = normalise_socket_opts(key_value:get(socket_opts, Opts, [])),

    Opts#{
        %% connection_type => worker,
        num_conns_sups => NumAcceptors, % the default, made explicit
        socket_opts => SocketOpts
    }.


-spec listener_protocol_opts(ListenerName :: atom()) -> map().

listener_protocol_opts(Name) ->
    key_value:to_map(get([Name, protocol_opts])).


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
    ok = jose:json_module(bondy_wamp_json),
    ok = configure_registry(),
    ok = configure_jobs_pool().


setup_partisan_channels() ->
    DefaultChannels = #{
        ?PLUM_DB_DATA_CHANNEL => #{parallelism => 2, compression => false},
        ?WAMP_RELAY_CHANNEL => #{parallelism => 2, compression => false}
    },
    Channels =
        case application:get_env(bondy, channels, []) of
            [] ->
                DefaultChannels;
            Channels0 ->
                Channels1 = lists:foldl(
                    fun
                        ({Channel, PList}, Acc) ->
                            maps:put(Channel, maps:from_list(PList), Acc)
                    end,
                    maps:new(),
                    Channels0
                ),
                maps:merge(DefaultChannels, Channels1)
        end,

    %% There is some redundancy as plum_db_config also configures channels, so
    %% we make sure they coincide.
    DataChannelOpts = maps:get(?PLUM_DB_DATA_CHANNEL, Channels),
    application:set_env(plum_db, data_channel_opts, DataChannelOpts),
    application:set_env(partisan, channels, maps:to_list(Channels)).


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

    %% We add the wamp_relay channel
    ok = bondy_config:set(wamp_peer_channel, wamp_relay).


%% @private
setup_wamp() ->
    %% We override all those parameters which the user should not be able to
    %% set and also set other parameters which are required for Bondy to
    %% operate i.e. all dependencies, and are private.

    %% ROUTER
    %% Dynamic Buffer just for HTTP and WS (not RAW TCP sockets)
    Keys = [
        [api_gateway_http, dynamic_buffer],
        [api_gateway_https, dynamic_buffer],
        [admin_api_http, dynamic_buffer],
        [admin_api_https, dynamic_buffer],
        %% At the moment WS goes on top of api_gateway_http/s listener
        %% but this config should override it
        [wamp_websocket, dynamic_buffer]
    ],
    ok = lists:foreach(
        fun(Key) -> bondy_config:set(Key, dynamic_buffer(Key)) end,
        Keys
    ),

    %% WAMP PROTOCOL LIB
    ok = bondy_wamp_config:set(extended_details, ?WAMP_EXT_DETAILS),
    ok = bondy_wamp_config:set(extended_options, ?WAMP_EXT_OPTIONS).


%% @private
dynamic_buffer(Key) ->
    Low = memory:kibibytes(1),
    Top = memory:kibibytes(128),

    case bondy_config:get(Key, []) of
        [] ->
            false;

        [{min, 0}, _] ->
            false;

        [_, {max, 0}] ->
            false;

        [{min, Min}, {max, Max}] when Min >= Low, Max =< Top ->
            {Min, Max};

        [{max, Max}, {min, Min}] when Min >= Low, Max =< Top ->
            {Min, Max};

        Other ->
             ?LOG_ERROR(#{
                description => "Error while preparing configuration",
                reason => "invalid value for configuration option",
                key => Key,
                value => Other
            }),
            exit(invalid_configuration)
    end.

%% @private
prepare_private_config() ->
    Config0 = configure_plum_db(?CONFIG),
    configure_message_retention(Config0).


%% @private
configure_plum_db(Config) ->
    PDBConfig = [
        {data_channel, ?PLUM_DB_DATA_CHANNEL},
        {prefixes, ?PLUM_DB_PREFIXES},
        {data_dir, get(platform_data_dir)}
    ],
    key_value:set(plum_db, PDBConfig, Config).


%% @private
configure_message_retention(Config0) ->
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
configure_registry() ->
    %% Configure partition count
    KeyPath = [registry, partitions],

    ok = case bondy_config:get(KeyPath, undefined) of
        undefined ->
            N = min(16, erlang:system_info(schedulers)),
            bondy_config:set(KeyPath, N),
            ok;
        _ ->
            ok
    end,

    %% Configure partition spawn_opts
    Opts0 = bondy_config:get([registry, partition_spawn_opts], []),
    Value = ?VALIDATE_MQ_DATA(
        key_value:get(message_queue_data, Opts0, off_heap)
    ),
    Opts = key_value:put(message_queue_data, Value, Opts0),
    bondy_config:set([registry, partition_spawn_opts], Opts).


configure_jobs_pool() ->
    %% Configure partition count
    KeyPath = [jobs_pool, size],

    case bondy_config:get(KeyPath, undefined) of
        undefined ->
            N = min(16, erlang:system_info(schedulers)),
            bondy_config:set(KeyPath, N),
            ok;
        _ ->
            ok
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



%% @private
-spec normalise_socket_opts(SocketOpts :: [{atom(), any()}]) ->
    SocketOpts :: [atom() | {atom(), any()}].

normalise_socket_opts(SocketOpts0) ->
    %% We normlise the buffer option
    SocketOpts1 = normalise_socket_buffer(SocketOpts0),

    %% We default to listen on any i.e. 0.0.0.0 or ::1 depending on IPVer
    IP0 = key_value:get(ip, SocketOpts1, any),
    {Family0, SocketOpts2} = take(ip_version, SocketOpts1, any),
    {IP, Family} = bondy_utils:get_ipaddr_family(IP0, Family0),
    SocketOpts3 = key_value:put(ip, IP, SocketOpts2),

    %% This is for non-HTTP listeners. For HTTP we have the linger_timeout
    %% option at the ProtoOpts
    SocketOpts =
        case take(linger_timeout, SocketOpts3, -1) of
            {-1, SocketOpts4} ->
                Linger = {false, 0},
                key_value:put(linger, Linger, SocketOpts4);

            {Timeout, SocketOpts4} ->
                Linger = {true, Timeout},
                key_value:put(linger, Linger, SocketOpts4)
    end,

    [Family | SocketOpts].


%% @private
-spec normalise_socket_buffer([{atom(), any()}]) -> [{atom(), any()}].

normalise_socket_buffer([]) ->
    [];

normalise_socket_buffer(Opts) when is_list(Opts) ->
    Sndbuf = key_value:get(sndbuf, Opts, 0),
    Recbuf = key_value:get(recbuf, Opts, 0),

    case Sndbuf > 0 andalso Recbuf > 0 of
        true ->
            Buffer0 = key_value:get(buffer, Opts, 0),
            Buffer1 = max(Buffer0, max(Sndbuf, Recbuf)),
            key_value:put(buffer, Buffer1, Opts);

        false ->
            Opts
    end.



take(Key, KV0, Default) ->
    case key_value:take(Key, KV0) of
        error ->
            {Default, KV0};
        {_, _} = Result ->
            Result
    end.