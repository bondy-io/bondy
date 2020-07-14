%% =============================================================================
%%  common.erl -
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
           {join_retry_interval,5000},
           {automatic_join,true},
           {enabled,true},
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
          [{socket_opts,[{backlog,1024},{nodelay,true},{keepalive,true}]},
           {max_connections,100000},
           {acceptors_pool_size,200},
           {port,18082},
           {enabled,true}]},
      {api_gateway_https,
          [{socket_opts,
               [{cacertfile,"./etc/cacert.pem"},
                {keyfile,"./etc/key.pem"},
                {certfile,"./etc/cert.pem"},
                {keepalive,false},
                {backlog,4096},
                {nodelay,true}]},
           {max_connections,500000},
           {acceptors_pool_size,200},
           {port,18083}]},
      {api_gateway_http,
          [{socket_opts,[{backlog,4096},{nodelay,true},{keepalive,false}]},
           {max_connections,500000},
           {acceptors_pool_size,200},
           {port,18080}]},
      {api_gateway,
          [{config_file,
               "./etc/api_gateway_config.json"}]},
      {admin_api_https,
          [{socket_opts,
               [{cacertfile,"./etc/cacert.pem"},
                {keyfile,"./etc/key.pem"},
                {certfile,"./etc/cert.pem"},
                {keepalive,false}]},
           {max_connections,250000},
           {acceptors_pool_size,200},
           {port,18084},
           {enabled,false}]},
      {admin_api_http,
          [{socket_opts,[{backlog,1024},{nodelay,true},{keepalive,false}]},
           {max_connections,250000},
           {acceptors_pool_size,200},
           {port,18081},
           {enabled,true}]},
      {router_pool,[{capacity,10000},{size,8},{type,transient}]},
      {load_regulation_enabled,true},
      {request_timeout,20000},
      {wamp_call_timeout,10000},
      {wamp_connection_lifetime,session},
      {allow_anonymous_user,true},
      {automatically_create_realms,false},
      {security,
          [{config_file,
               "./etc/security_config.json"}]},
      {shutdown_grace_period,5}
]).

-define(CONFIG, [

 {bondy_broker_bridge,
     [{bridges,
          [{bondy_kafka_bridge,
               [{enabled,true},
                {topics,
                    [{<<"account_events">>,<<"foo">>},
                     {<<"agent_events">>,<<"foo">>},
                     {<<"geofence_events">>,<<"foo">>},
                     {<<"notification_events">>,<<"foo">>},
                     {<<"reminder_events">>,<<"foo">>},
                     {<<"task_events">>,<<"foo">>},
                     {<<"thing_events">>,<<"foo">>},
                     {<<"trip_events">>,<<"foo">>},
                     {<<"user_events">>,<<"foo">>}]},
                {clients,
                    [{default,
                         [{extra_sock_opts,[]},
                          {default_producer_config,
                              [{partition_restart_delay_seconds,2},
                               {required_acks,1},
                               {topic_restart_delay_seconds,10}]},
                          {reconnect_cool_down_seconds,10},
                          {auto_start_producers,true},
                          {restart_delay_seconds,10},
                          {allow_topic_auto_creation,false},
                          {max_metadata_sock_retry,5},
                          {endpoints,{"127.0.0.1",9092}}]}]}]}]},
      {config_file,
          "etc/broker_bridge_config.json"}]},
    {lager,
    [{error_logger_hwm,100},
     {crash_log_count,5},
     {crash_log_date,"$D0"},
     {crash_log_size,10485760},
     {crash_log_msg_size,65536},
     {crash_log,"./data/bondy/log/crash.log"},
     {handlers,
         [{lager_file_backend,
              [{file,"./data/bondy/log/console.log"},
               {level,info},
               {size,10485760},
               {date,"$D0"},
               {count,5}]},
          {lager_file_backend,
              [{file,"./data/bondy/log/error.log"},
               {level,error},
               {size,10485760},
               {date,"$D0"},
               {count,5}]},
          {lager_file_backend,
              [{file,"./data/bondy/log/debug.log"},
               {level,debug},
               {size,10485760},
               {date,"$D0"},
               {count,5}]}]},
     {error_logger_redirect,true}]},
    {sasl,[{sasl_error_logger,false}]},
    {os_mon,[{system_memory_high_watermark,0.6}]}
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
            %% dbg:tracer(), dbg:p(all,c),
            %% dbg:tpl(application, '_', []),
            [begin
                application:unload(App),
                application:load(App),
                application:set_env(App, K, V)
            end || {App, L} <- ?CONFIG, {K, V} <- L],

            application:unload(bondy),
            application:load(bondy),
            [application:set_env(bondy, K, V) || {K, V} <- ?BONDY],

            maybe_error(application:ensure_all_started(gproc)),
            maybe_error(application:ensure_all_started(jobs)),
            maybe_error(application:ensure_all_started(wamp)),
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
