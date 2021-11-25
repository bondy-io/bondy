%% =============================================================================
%%  common.erl -
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

-module(common).
-include_lib("common_test/include/ct.hrl").

-define(BONDY, [
    {oauth2,
          [{refresh_token_length,40},
           {refresh_token_duration,2592000},
           {code_grant_duration,600},
           {client_credentials_grant_duration,900},
           {password_grant_duration,900},
           {config_file,"./etc/oauth2_config.json"}]},
      {platform_log_dir,"./log"},
      {platform_etc_dir,"./etc"},
      {platform_tmp_dir,"./tmp"},
      {platform_data_dir,"./data"},
      {platform_lib_dir,"./lib"},
      {platform_bin_dir,"./bin"},
      {peer_discovery,
          [{type,bondy_peer_discovery_dns_agent},
           {timeout,5000},
           {polling_interval,10000},
           {initial_delay, 30000},
           {join_retry_interval,5000},
           {automatic_join,true},
           {enabled,false},
           {config,[{<<"service_name">>,<<"bondy">>}]}]},
      {wamp_tls,
          [{socket_opts,
               [{cacertfile,"./etc/cacert.pem"},
                {keyfile,"./etc/key.pem"},
                {certfile,"./etc/cert.pem"},
                {backlog,1024},
                {nodelay,true},
                {keepalive,true}]},
           {max_connections,100000},
           {acceptors_pool_size,200},
           {port,18085},
           {enabled,false}]},
      {wamp_tcp,
          [{socket_opts,[{nodelay,true},{keepalive,true}]},
            {backlog,1024},
           {max_connections,100000},
           {acceptors_pool_size,200},
           {port,18082},
           {enabled,true}]},
      {wamp_websocket,
          [{deflate_opts,
               [{client_context_takeover,takeover},
                {server_context_takeover,takeover},
                {strategy,default},
                {level,5},
                {mem_level,8},
                {server_max_window_bits,11},
                {client_max_window_bits,11}]},
           {compress,false},
           {max_frame_size,infinity},
           {idle_timeout,28800000},
           {ping,[{max_attempts,3},{interval,30000},{enabled,true}]}]},
      {api_gateway_https,
          [{socket_opts,
               [{cacertfile,"./etc/cacert.pem"},
                {keyfile,"./etc/key.pem"},
                {certfile,"./etc/cert.pem"},
                {backlog,4096},
                {nodelay,true},
                {keepalive,false}]},
           {max_connections,500000},
           {acceptors_pool_size,200},
           {port,18083},
           {enabled,false}]},
      {api_gateway_http,
          [{socket_opts,[{nodelay,true},{keepalive,false}]},
          {backlog,4096},
           {max_connections,500000},
           {acceptors_pool_size,200},
           {port,18080},
           {enabled,true}]},
      {api_gateway,[{config_file,"./etc/api_gateway_config.json"}]},
      {admin_api_https,
          [{socket_opts,
               [{cacertfile,"./etc/cacert.pem"},
                {keyfile,"./etc/key.pem"},
                {certfile,"./etc/cert.pem"},
                {backlog,1024},
                {nodelay,true},
                {keepalive,false}]},
           {max_connections,250000},
           {acceptors_pool_size,200},
           {port,18083},
           {enabled,false}]},
      {admin_api_http,
          [{socket_opts,[{nodelay,true},{keepalive,false}]},
          {backlog,1024},
           {max_connections,250000},
           {acceptors_pool_size,200},
           {port,18081},
           {enabled,true}]},
      {router_pool,[{capacity,10000},{size,8},{type,transient}]},
      {load_regulation_enabled,true},
      {request_timeout,20000},
      {wamp_message_retention,
          [{default_ttl,0},
           {max_message_size,65536},
           {max_memory,1073741824},
           {max_messages,1000000},
           {storage_type,ram},
           {enabled,true}]},
      {wamp_call_timeout,10000},
      {wamp_connection_lifetime,session},
      {session_manager_pool, [
          {size, 50}
      ]},
      {security,[
          {ticket, [
              {expiry_time_secs, 300},
              {max_expiry_time_secs, 600},
              {allow_not_found, true},
              {authmethods, [
                <<"cryptosign">>, <<"password">>, <<"ticket">>, <<"tls">>, <<"trust">>,<<"wamp-scram">>, <<"wampcra">>
                ]}
            ]},
          {password,
               [{cra,[{kdf,pbkdf2}]},
                {scram,[{kdf,pbkdf2}]},
                {protocol_upgrade_enabled,false},
                {protocol,cra},
                {min_length,6},
                {max_length,254},
                {pbkdf2,[{iterations,10000}]},
                {argon2id13,[{iterations,moderate},{memory,interactive}]}]},
            {config_file,"./etc/security_config.json"},
            {allow_anonymous_user,true},
            {automatically_create_realms,false}
        ]},
      {shutdown_grace_period,5},
      {wamp_serializers, []}
]).

-define(CONFIG, [
    {bondy_broker_bridge,
        [{bridges,
             [{bondy_kafka_bridge,
                  [{enabled,false},
                   {topics,[{<<"wamp_events">>,<<"com.leapsight.wamp.events">>}]},
                   {clients,
                       [{default,
                            [{endpoints,[{"127.0.0.1",9092}]},
                             {extra_sock_opts,[]},
                             {default_producer_config,
                                 [{partition_restart_delay_seconds,2},
                                  {required_acks,1},
                                  {topic_restart_delay_seconds,10}]},
                             {reconnect_cool_down_seconds,10},
                             {auto_start_producers,true},
                             {restart_delay_seconds,10},
                             {endpoints,"[{\"127.0.0.1\", 9092}]"},
                             {allow_topic_auto_creation,true},
                             {max_metadata_sock_retry,5}]}]}]}]},
         {config_file,"./etc/broker_bridge_config.json"}]},
    {plum_db,
        [{aae_exchange_on_cluster_join,true},
            {hashtree_ttl,604800},
            {hashtree_timer,10000},
            {aae_enabled,true},
            {data_exchange_timeout,60000},
            {data_dir,"./data"},
            {store_open_retries_delay,2000},
            {store_open_retry_limit,30},
            {shard_by,prefix},
            {partitions,16},
            {wait_for_aae_exchange,false},
            {wait_for_hashtrees,true},
            {wait_for_partitions,true}]},
    {plumtree,[{broadcast_exchange_timer,60000}]},
    {partisan,
    [{tls_options,
            [{cacertfile,"./etc/cacert.pem"},
            {keyfile,"./etc/key.pem"},
            {certfile,"./etc/cert.pem"}]},
        {tls,false},
        {parallelism,1},
        {peer_port,18086}]}
]).

-export([
	 all/0,
	 groups/1,
	 suite/0,
     tests/1,
     start_bondy/0,
     stop_bondy/0
	]).

all() ->
    [{group, main}].

groups(Module) ->
    [{main, [parallel], tests(Module)}].

suite() ->
    [{timetrap, {minutes, 5}}].


tests(Module) ->
    [Function || {Function, Arity} <- Module:module_info(exports), Arity == 1, is_a_test(Function)].

is_a_test(is_a_test) ->
    false;
is_a_test(Function) ->
    hd(lists:reverse(string:tokens(atom_to_list(Function), "_"))) == "test".

start_bondy() ->
    case persistent_term:get({?MODULE, bondy_started}, false) of
        false ->
            _ = [
                begin
                    application:unload(App),
                    application:load(App)
                end || {App, _} <- ?CONFIG
            ],

            _ = [
                begin
                    application:set_env(App, K, V)
                end || {App, L} <- ?CONFIG, {K, V} <- L
            ],

            application:unload(bondy),
            application:load(bondy),
            [application:set_env(bondy, K, V) || {K, V} <- ?BONDY],

            length(?BONDY) == length(application:get_all_env(bondy))
            orelse exit(configuration_error),

            maybe_error(application:ensure_all_started(gproc)),
            maybe_error(application:ensure_all_started(jobs)),
            maybe_error(application:ensure_all_started(wamp)),
            maybe_error(application:ensure_all_started(enacl)),
            maybe_error(application:ensure_all_started(pbkdf2)),
            maybe_error(application:ensure_all_started(stringprep)),
            maybe_error(application:ensure_all_started(bondy)),
            persistent_term:put({?MODULE, bondy_started}, true),
            ok;
        true ->
            ok
    end.


stop_bondy() ->
    ok = application:stop(gproc),
    ok = application:stop(jobs),
    persistent_term:put({?MODULE, bondy_started}, false),
    application:stop(bondy).


maybe_error({error, _} = Error) ->
    error(Error);
maybe_error({ok, _}) ->
    ok.
