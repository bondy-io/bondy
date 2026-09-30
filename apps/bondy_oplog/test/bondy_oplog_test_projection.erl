%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Starts a test instance with the projection `bondy_db` pins on every shard
%% instance: an `applier.cell_apply_target` naming an ETS cache and projection
%% registered in `bondy_oplog_core_registry`. The registration and both tables
%% belong to the calling process and go when it exits. It carries no
%% `instance_id`, which would make the shard one of the instance's AE targets
%% and so a backer of the auth freshness fence
%% (`bondy_oplog_core_registry:instance_ae_targets/2`).
-module(bondy_oplog_test_projection).

-export([start_instance/1]).
-export([start_instance/2]).
-export([start_instance_on/3]).
-export([cell_op/1]).
-export([drain/1]).
-export([cells/1]).

start_instance(InstanceId) ->
    start_instance(InstanceId, #{}).

start_instance(InstanceId, Opts) ->
    bondy_oplog:start_instance(InstanceId, with_projection(InstanceId, Opts)).

%% `start_instance/2` on `Node`, from a process that lives as long as `Node`:
%% an `erpc` worker exits when the call returns, taking the tables with it.
start_instance_on(Node, InstanceId, Opts) ->
    {Mod, Bin, File} = code:get_object_code(?MODULE),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    erpc:call(Node, fun() -> start_instance_owned(InstanceId, Opts) end).

%% An op the projection applies, so the applied frontier witnesses it.
cell_op(N) ->
    Key = integer_to_binary(N),
    {cell_apply, <<>>, Key, {set, N, Key}}.

%% Returns once the applier's projection reflects every local append and every
%% remote event delivered before the call (`bondy_oplog_applier:barrier/1`).
drain(InstanceId) ->
    ok = bondy_oplog:await_apply(InstanceId),
    bondy_oplog_applier:barrier(bondy_oplog_registry:applier_pid(InstanceId)).

%% Every cell of the instance's projection, after `drain/1`.
cells(InstanceId) ->
    ok = drain(InstanceId),
    {ok, Rows} = bondy_oplog_core:range(
        ns(InstanceId), primary, {<<>>, infinity}, #{limit => 1 bsl 20}
    ),
    Rows.

start_instance_owned(InstanceId, Opts) ->
    Caller = self(),
    Ref = make_ref(),
    _ = spawn(fun() ->
        Caller ! {Ref, start_instance(InstanceId, Opts)},
        receive
        after infinity -> ok
        end
    end),
    receive
        {Ref, Result} -> Result
    end.

with_projection(InstanceId, Opts) ->
    NS = ns(InstanceId),
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => lww_register,
        overlay => disabled
    }),
    Applier = maps:get(applier, Opts, #{}),
    Opts#{applier => Applier#{cell_apply_target => {NS, primary, 0}}}.

ns(InstanceId) ->
    list_to_atom(
        "test_projection_" ++ integer_to_list(erlang:phash2(InstanceId))
    ).
