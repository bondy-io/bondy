%% =============================================================================
%%  bondy_stats.erl -
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

-module(bondy_stats).

-export([update/1]).
-export([update/2]).
-export([get_stats/0]).
-export([create_metrics/0]).
-export([otp_release/0]).
-export([sys_driver_version/0]).
-export([system_version/0]).
-export([system_architecture/0]).
-export([sys_monitor_count/0]).


%% =============================================================================
%% API
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% Borrowed from https://github.com/basho/riak_kv/src/riak_kv_stat_bc.erl
%% -----------------------------------------------------------------------------
otp_release() ->
    list_to_binary(erlang:system_info(otp_release)).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% Borrowed from https://github.com/basho/riak_kv/src/riak_kv_stat_bc.erl
%% -----------------------------------------------------------------------------
sys_driver_version() ->
    list_to_binary(erlang:system_info(driver_version)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% Borrowed from https://github.com/basho/riak_kv/src/riak_kv_stat_bc.erl
%% -----------------------------------------------------------------------------
system_version() ->
    list_to_binary(
        string:strip(erlang:system_info(system_version), right, $\n)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% Borrowed from https://github.com/basho/riak_kv/src/riak_kv_stat_bc.erl
%% -----------------------------------------------------------------------------
system_architecture() ->
    list_to_binary(erlang:system_info(system_architecture)).


%% -----------------------------------------------------------------------------
%% @doc
%% Count up all monitors, unfortunately has to obtain process_info
%% from all processes to work it out.
%% @end
%% Borrowed from https://github.com/basho/riak_kv/src/riak_kv_stat_bc.erl
%% -----------------------------------------------------------------------------
sys_monitor_count() ->
    lists:foldl(
        fun(Pid, Count) ->
            case erlang:process_info(Pid, monitors) of
                {monitors, Mons} ->
                    Count + length(Mons);
                _ ->
                    Count
            end
        end, 0, processes()).




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec create_metrics() -> ok.

create_metrics() ->
    % create_metrics(system_specs()),
    create_metrics(bc_specs()),
    create_metrics(static_specs()).





%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_stats() -> list().

get_stats() ->
    exometer:get_values([bondy]) ++ expand_disk_stats(disk_stats()).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(tuple()) -> ok.

update(Event) ->
    do_update(Event).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(wamp_message:message(), bondy_context:context()) -> ok.

update(M, #{peer := {IP, _}} = Ctxt) ->
    Type = element(1, M),
    Size = erts_debug:flat_size(M) * 8,
    case Ctxt of
        #{realm_uri := Uri, session := S} ->
            Id = bondy_session:id(S),
            do_update({message, Id, Uri, IP, Type, Size});
        #{realm_uri := Uri} ->
            do_update({message, Uri, IP, Type, Size});
        _ ->
            do_update({message, IP, Type, Size})
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
baddress(T) when is_tuple(T), (tuple_size(T) == 4 orelse tuple_size(T) == 8) ->
  list_to_binary(inet_parse:ntoa(T));
baddress(T) when is_list(T) ->
  list_to_binary(T);
baddress(T) when is_binary(T) ->
  T.

%% @private
do_update({session_opened, Realm, _SessionId, IP}) ->
    BIP = baddress(IP),
    _ = exometer:update([bondy, node, sessions], 1),
    _ = exometer:update([bondy, node, sessions, active], 1),

    _ = exometer:update_or_create(
        [bondy, node, realm, sessions, Realm], 1, spiral, []),
    _ = exometer:update_or_create(
        [bondy, node, realm, sessions, active, Realm], 1, counter, []),
    
    _ = exometer:update_or_create(
        [bondy, node, ip, sessions, BIP], 1, spiral, []),
    _ = exometer:update_or_create(
        [bondy, node, ip, sessions, active, BIP], 1, counter, []);

do_update({session_closed, SessionId, Realm, IP, Secs}) ->
    BIP = baddress(IP),
    _ = exometer:update([bondy, node, sessions, active], -1),
    _ = exometer:update([bondy, node, sessions, duration], Secs),

    _ = exometer:update_or_create(
        [bondy, node, realm, sessions, active, Realm], -1, counter, []),
    _ = exometer:update_or_create(
        [bondy, node, realm, sessions, duration, Realm], Secs, histogram, []),
    
    _ = exometer:update_or_create(
        [bondy, node, ip, sessions, active, BIP], -1, counter, []),
    _ = exometer:update_or_create(
        [bondy, node, ip, sessions, duration, BIP], Secs, histogram, []),
    
    %% Cleanup
    _ = exometer:delete([bondy, node, session, messages, SessionId]),
    lists:foreach(
        fun({Name, _, _}) ->
            _ = exometer:delete(Name)
        end,
        exometer:find_entries([bondy, node, session, messages, '_', SessionId])
    ), 
    ok;

do_update({message, IP, Type, Sz}) ->
    BIP = baddress(IP),
    _ = exometer:update([bondy, node, messages], 1),
    _ = exometer:update([bondy, node, messages, size], Sz),
    _ = exometer:update_or_create([bondy, node, messages, Type], 1, spiral, []),

    _ = exometer:update_or_create(
        [bondy, node, ip, messages, BIP], 1, counter, []),
    _ = exometer:update_or_create(
        [bondy, node, ip, messages, size, BIP], Sz, histogram, []),
    _ = exometer:update_or_create(
        [bondy, node, ip, messages, Type, BIP], 1, spiral, []);


do_update({message, Realm, IP, Type, Sz}) ->
    BIP = baddress(IP),
    _ = exometer:update([bondy, node, messages], 1),
    _ = exometer:update([bondy, node, messages, size], Sz),
    _ = exometer:update_or_create([bondy, node, messages, Type], 1, spiral, []),

    _ = exometer:update_or_create(
        [bondy, node, ip, messages, BIP], 1, counter, []),
    _ = exometer:update_or_create(
        [bondy, node, ip, messages, size, BIP], Sz, histogram, []),
    _ = exometer:update_or_create(
        [bondy, node, ip, messages, Type, BIP], 1, spiral, []),

    _ = exometer:update_or_create(
        [bondy, node, realm, messages, Realm], 1, counter, []),
    _ = exometer:update_or_create(
        [bondy, node, realm, messages, size, Realm], Sz, histogram, []),
    _ = exometer:update_or_create(
        [bondy, node, realm, messages, Type, Realm], 1, spiral, []);

do_update({message, Session, Realm, IP, Type, Sz}) ->
    BIP = baddress(IP),
    _ = exometer:update([bondy, node, messages], 1),
    _ = exometer:update([bondy, node, messages, size], Sz),
    _ = exometer:update_or_create([bondy, node, messages, Type], 1, spiral, []),

    _ = exometer:update_or_create(
        [bondy, node, ip, messages, BIP], 1, counter, []),
    _ = exometer:update_or_create(
        [bondy, node, ip, messages, size, BIP], Sz, histogram, []),
    _ = exometer:update_or_create(
        [bondy, node, ip, messages, Type, BIP], 1, spiral, []),

    _ = exometer:update_or_create(
        [bondy, node, realm, messages, Realm], 1, counter, []),
    _ = exometer:update_or_create(
        [bondy, node, realm, messages, size, Realm], Sz, histogram, []),
    _ = exometer:update_or_create(
        [bondy, node, realm, messages, Type, Realm], 1, spiral, []),

    _ = exometer:update_or_create(
        [bondy, node, session, messages, Session], 1, counter, []),
    _ = exometer:update_or_create(
        [bondy, node, session, messages, size, Session], Sz, histogram, []),
    _ = exometer:update_or_create(
        [bondy, node, session, messages, Type, Session], 1, spiral, []).


%% @private
create_metrics(Stats) ->
    %% We are assumming exometer was started by wamp app.
    %% TODO Process aliases
    lists:foreach(
        fun({Name, Type , Opts, Aliases}) ->
            exometer:re_register(Name, Type, Opts),
            lists:foreach(
                fun({DP, Alias}) ->
                    exometer_alias:new(Alias, Name, DP)
                end, 
                Aliases
            )
        end,
        Stats
    ).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
static_specs() ->
    [
        {[bondy, node, sessions], 
            spiral, [], [
                {one, bondy_node_sessions}, 
                {count, bondy_node_sessions_total}]},
        {[bondy, node, messages], 
            spiral, [], [
                {one, bondy_node_messages}, 
                {count, bondy_node_messages_total}]},
        {[bondy, node, sessions, active], 
            counter, [], [
                {value, bondy_node_sessions_active}]},
        {[bondy, node, sessions, duration], 
            histogram, [], [
                {mean, bondy_node_sessions_duration_mean},
                {median, bondy_node_sessions_duration_median},
                {95, bondy_node_sessions_duration_95},
                {99, bondy_node_sessions_duration_99},
                {max, bondy_node_sessions_duration_100}]}
    ].


%% borrowed from Riak Core
% system_specs() ->
%     [
%      {
%          cpu_stats, 
%          cpu, 
%          [{sample_interval, 5000}], 
%          [
%             {nprocs, cpu_nprocs},
%             {avg1  , cpu_avg1},
%             {avg5  , cpu_avg5},
%             {avg15 , cpu_avg15}
%         ]
%     },
%     {
%         mem_stats, 
%         {function, memsup, get_memory_data, [], match, {total, allocated, '_'}},
%         [], 
%         [
%             {total, mem_total},
%             {allocated, mem_allocated}
%         ]
%     },
%     {
%         memory_stats, 
%         {function, erlang, memory, [], proplist, [
%             total, 
%             processes, 
%             processes_used,
%             system, 
%             atom, 
%             atom_used, 
%             binary,
%             code, 
%             ets
%         ]},
%         [], 
%         [
%             {total         , memory_total},
%             {processes     , memory_processes},
%             {processes_used, memory_processes_used},
%             {system        , memory_system},
%             {atom          , memory_atom},
%             {atom_used     , memory_atom_used},
%             {binary        , memory_binary},
%             {code          , memory_code},
%             {ets           , memory_ets}
%         ]
%     }
% ].



bc_specs() ->
    Spec = fun(N, M, F, As) ->
        {[bondy, node, N], {function, M, F, As, match, value}, [], [{value, N}]}
    end,

    [Spec(N, M, F, As) ||
        {N, M, F, As} <- [{nodename, erlang, node, []},
                          {connected_nodes, erlang, nodes, []},
                          {sys_driver_version, ?MODULE, sys_driver_version, []},
                          {sys_heap_type, erlang, system_info, [heap_type]},
                          {sys_logical_processors, erlang, system_info, [logical_processors]},
                          {sys_monitor_count, ?MODULE, sys_monitor_count, []},
                          {sys_otp_release, ?MODULE, otp_release, []},
                          {sys_port_count, erlang, system_info, [port_count]},
                          {sys_process_count, erlang, system_info, [process_count]},
                          {sys_smp_support, erlang, system_info, [smp_support]},
                          {sys_system_version, ?MODULE, system_version, []},
                          {sys_system_architecture, ?MODULE, system_architecture, []},
                          {sys_threads_enabled, erlang, system_info, [threads]},
                          {sys_thread_pool_size, erlang, system_info, [thread_pool_size]},
                          {sys_wordsize, erlang, system_info, [wordsize]}]].


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% Borrowed from https://github.com/basho/riak_kv/src/riak_kv_status.erl
%% -----------------------------------------------------------------------------
expand_disk_stats([{disk, Stats}]) ->
    [{disk, [{struct, [{id, list_to_binary(Id)}, {size, Size}, {used, Used}]}
             || {Id, Size, Used} <- Stats]}].


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% Borrowed from https://github.com/basho/riak_kv/src/riak_kv_status.erl
%% -----------------------------------------------------------------------------
disk_stats() ->
    [{disk, disksup:get_disk_data()}].


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% Borrowed from https://github.com/basho/riak_kv/src/riak_kv_stat_bc.erl
%% -----------------------------------------------------------------------------
% app_stats() ->
%     [{list_to_atom(atom_to_list(A) ++ "_version"), list_to_binary(V)}
%      || {A,_,V} <- application:which_applications()].
    