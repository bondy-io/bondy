%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_instance_dyn_sup).

-behaviour(supervisor).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Dynamic supervisor that hosts one `bondy_oplog_instance_sup` subtree
per running instance.

`simple_one_for_one` of *supervisors* — each child is a per-instance
one_for_all subtree (WAL writer + instance gen_server + applier).
The dyn sup keeps the registry's `sup_pid` field in step with
`supervisor:start_child/2` so `start_instance/2` is idempotent and
`stop_instance/1` can locate the subtree by `InstanceId`.
""").

-export([start_link/0]).
-export([start_instance/2]).
-export([stop_instance/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> supervisor:startlink_ret().

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

?DOC("""
Spawns a per-instance subtree. Idempotent: if a subtree for
`InstanceId` is already running, returns its existing supervisor pid
without starting a duplicate.
""").
-spec start_instance(instance_id(), bondy_oplog_instance:opts()) ->
    {ok, pid()} | {error, term()}.

start_instance(InstanceId, Opts) when
    is_binary(InstanceId), is_map(Opts)
->
    case bondy_oplog_registry:sup_pid(InstanceId) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false -> do_start(InstanceId, Opts)
            end;
        undefined ->
            do_start(InstanceId, Opts)
    end.

-spec stop_instance(instance_id() | pid()) -> ok | {error, not_found}.

stop_instance(InstanceId) when is_binary(InstanceId) ->
    case bondy_oplog_registry:sup_pid(InstanceId) of
        undefined ->
            %% No registry row — but the SUBTREE may still be running. A
            %% consumer teardown that failed mid-close can drop the row while
            %% the supervisor child survives. `list_instances/0` enumerates
            %% ROWS, so such an instance is invisible to it and to every
            %% scheduler driven from it — but invisible must not mean
            %% unkillable (`{error, not_found}` forever, a zombie holding its
            %% WAL and storage for the VM's lifetime). Resolve it through the
            %% supervisor instead
            %% (`bondy_oplog_lifecycle_test:stop_survives_missing_registry_row/0`).
            case find_child_by_instance_id(InstanceId) of
                undefined ->
                    {error, not_found};
                SupPid ->
                    supervisor:terminate_child(?SERVER, SupPid)
            end;
        SupPid ->
            case supervisor:terminate_child(?SERVER, SupPid) of
                ok ->
                    %% Drop the registry row only on explicit
                    %% stop_instance — one_for_all subtree restarts
                    %% must leave it in place so the dyn_sup mapping
                    %% (`sup_pid`) survives.
                    _ = bondy_oplog_registry:unregister(InstanceId),
                    ok;
                {error, not_found} ->
                    {error, not_found}
            end
    end;
stop_instance(SupPid) when is_pid(SupPid) ->
    %% Reverse-look-up the instance_id so the registry row is dropped
    %% in step with the supervisor child. The lookup happens *before*
    %% terminate_child because terminating the subtree clears the row's
    %% `sup_pid` indirectly (via the dyn supervisor's child bookkeeping)
    %% on some Erlang versions.
    InstanceId = bondy_oplog_registry:instance_id_by_sup_pid(SupPid),
    case supervisor:terminate_child(?SERVER, SupPid) of
        ok ->
            case InstanceId of
                undefined ->
                    ok;
                Id ->
                    _ = bondy_oplog_registry:unregister(Id),
                    ok
            end;
        {error, not_found} ->
            {error, not_found}
    end.

%% =============================================================================
%% supervisor CALLBACKS
%% =============================================================================

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 10
    },
    ChildSpec = #{
        id => bondy_oplog_instance_sup,
        start => {bondy_oplog_instance_sup, start_link, []},
        restart => transient,
        shutdown => infinity,
        type => supervisor,
        modules => [bondy_oplog_instance_sup]
    },
    {ok, {SupFlags, [ChildSpec]}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Locates a running per-instance subtree by asking each child's instance
%% gen_server for its id — the same enumeration `bondy_oplog:list_instances/0`
%% performs, so anything that function can see, `stop_instance/1` can kill.
%% O(children); only reached on the registry-row-missing path, which is a
%% teardown anomaly, not steady state.
find_child_by_instance_id(InstanceId) ->
    Children = supervisor:which_children(?SERVER),
    Found = [
        SupPid
     || {_Id, SupPid, supervisor, _} <- Children,
        is_pid(SupPid),
        InstancePid <- [bondy_oplog_instance_sup:instance_pid(SupPid)],
        is_pid(InstancePid),
        instance_id_of(InstancePid) =:= InstanceId
    ],
    case Found of
        [SupPid | _] -> SupPid;
        [] -> undefined
    end.

%% @private
%% Total: a child that dies mid-scan reads as a non-match rather than
%% raising out of a cleanup path.
instance_id_of(InstancePid) ->
    try bondy_oplog_instance:info(InstancePid) of
        #{instance_id := Id} -> Id;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

%% @private
do_start(InstanceId, Opts) ->
    case supervisor:start_child(?SERVER, [InstanceId, Opts]) of
        {ok, SupPid} ->
            ok = bondy_oplog_registry:set_sup_pid(InstanceId, SupPid),
            {ok, SupPid};
        {ok, SupPid, _Info} ->
            ok = bondy_oplog_registry:set_sup_pid(InstanceId, SupPid),
            {ok, SupPid};
        {error, _} = E ->
            %% A subtree that dies during start leaves its registry row
            %% behind: the instance registers in its own `init/1`, before a
            %% later child (an applier rejecting its options, a backend
            %% refusing a path) brings the subtree down. Because
            %% `list_instances/0` enumerates the registry, that row is a
            %% phantom instance — every scheduler would dispatch gc and sync
            %% work to something that does not exist, for the lifetime of the
            %% node. Unregistering here cannot take the row from a healthy
            %% instance: `start_instance/2` above reaches `do_start/2` only
            %% when `sup_pid` is `undefined` or its process is dead.
            _ = bondy_oplog_registry:unregister(InstanceId),
            E
    end.
