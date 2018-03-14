%% =============================================================================
%%  common.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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

-define(BONDY,[
    {oauth2,
          [{refresh_token_length,40},
           {refresh_token_duration,2592000},
           {code_grant_duration,600},
           {client_credentials_grant_duration,900},
           {password_grant_duration,900}]},
    {platform_log_dir,"./data/bondy/log"},
    {platform_lib_dir,"./lib"},
    %% {platform_etc_dir,"./etc"},
    %% /Volumes/Leapsight/bondy/_build/test/logs/ct_run.nonode@nohost.2017-08-25_11.09.05
    {platform_etc_dir,"../../../../priv/specs"},
    {platform_data_dir, "./data/bondy"}.
    {platform_bin_dir,"./bin"},
    {wamp_tls,
        [{pki_files,
            [{cacertfile,"./etc/cacert.pem"},
            {keyfile,"./etc/key.pem"},
            {certfile,"./etc/cert.pem"}]},
        {max_connections,100000},
        {acceptors_pool_size,200},
        {port,18085},
        {enabled,false}]},
    {wamp_tcp,
        [{max_connections,100000},
        {acceptors_pool_size,200},
        {port,18082},
        {enabled,true}]},
    {api_gateway_https,
        [{pki_files,
            [{cacertfile,"./etc/cacert.pem"},
            {keyfile,"./etc/key.pem"},
            {certfile,"./etc/cert.pem"}]},
        {port,18083},
        {max_connections,500000},
        {acceptors_pool_size,200}]},
    {api_gateway_http,
        [{max_connections,500000},{acceptors_pool_size,200},{port,18080}]},
    {admin_api_https,
        [{pki_files,
            [{cacertfile,"./etc/cacert.pem"},
            {keyfile,"./etc/key.pem"},
            {certfile,"./etc/cert.pem"}]},
        {port,18084},
        {enabled,false}]},
    {admin_api_http,
        [{max_connections,1000},
        {acceptors_pool_size,100},
        {port,18081},
        {enabled,true}]},
    {registry_manager_pool,[{capacity,1000},{size,8},{type,permanent}]},
    {router_pool,[{capacity,10000},{size,8},{type,permanent}]},
    {coordinator_timeout,3000},
    {load_regulation_enabled,true},
    {request_timeout,300000},
    {connection_lifetime,session},
    {automatically_create_realms,false}]
).

-define(CONFIG, [
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
{eleveldb,
    [{cache_object_warming,true},
     {compression,true},
     {fadvise_willneed,false},
     {eleveldb_threads,71},
     {verify_compaction,true},
     {verify_checksums,true},
     {block_size_steps,16},
     {block_restart_interval,16},
     {sst_block_size,4096},
     {block_cache_threshold,33554432},
     {use_bloomfilter,true},
     {write_buffer_size_max,62914560},
     {write_buffer_size_min,31457280},
     {limited_developer_mem,false},
     {sync,false},
     {total_leveldb_mem_percent,70},
     {data_root,"./data/bondy/db/leveldb"},
     {delete_threshold,1000},
     {tiered_slow_level,0}]},
{plumtree,
    [{broadcast_mods,
         [plum_db,bondy_tuplespace_broadcast_handler]}]},
{tuplespace,
    [{static_tables,
         [{bondy_session,
              [set,
               {keypos,2},
               named_table,public,
               {read_concurrency,true},
               {write_concurrency,true}]},
          {bondy_subscription,
              [ordered_set,
               {keypos,2},
               named_table,public,
               {read_concurrency,true},
               {write_concurrency,true}]},
          {bondy_subscription_index,
              [bag,
               {keypos,2},
               named_table,public,
               {read_concurrency,true},
               {write_concurrency,true}]},
          {bondy_registration,
              [ordered_set,
               {keypos,2},
               named_table,public,
               {read_concurrency,true},
               {write_concurrency,true}]},
          {bondy_registration_index,
              [bag,
               {keypos,2},
               named_table,public,
               {read_concurrency,true},
               {write_concurrency,true}]},
          {bondy_rpc_state,
              [set,
               {keypos,2},
               named_table,public,
               {read_concurrency,true},
               {write_concurrency,true}]},
          {bondy_token_cache,
              [set,
               {keypos,2},
               named_table,public,
               {read_concurrency,true},
               {write_concurrency,true}]}]}]}]).

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

    {ok, _} = application:ensure_all_started(bondy),
    ok.

stop_bondy() ->
    application:stop(bondy).


