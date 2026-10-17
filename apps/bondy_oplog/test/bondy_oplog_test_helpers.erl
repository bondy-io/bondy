%% =============================================================================
%% Shared test helpers for bondy_oplog eunit suites.
%%
%% Centralises the boilerplate for fabricating projection cell frames
%% (V2 wire format with optional value column) and projecting fold
%% states to the user-facing values that the substrate returns from
%% `bondy_oplog_core:read/3..5`.
%% =============================================================================

-module(bondy_oplog_test_helpers).

-export([frame/3]).
-export([frame/4]).
-export([value_of/2]).
-export([compact_among/2]).
-export([with_cluster/2]).
-export([with_members/2]).
-export([await_subtree_restart/4]).
-export([settle/1]).
-export([open_gate/1]).
-export([install/2]).
-export([install/3]).
-export([applier_install/2]).

%% Build a V2 cell frame for the given fold state. Equivalent to what
%% the applier writes through `bondy_oplog_cell_apply` —
%% state bytes + `term_to_binary(to_value(State))` value bytes.
%%
%% Callers that want to inject an explicit HLC distinct from the
%% state's intrinsic HLC use `frame/4`.
-spec frame(
    Strategy :: atom(),
    State :: term(),
    Hlc :: non_neg_integer()
) -> binary().

frame(Strategy, State, Hlc) ->
    Mod = crdt_mod(Strategy),
    frame(Strategy, State, Hlc, Mod:value_equals_state()).

frame(Strategy, State, Hlc, true) ->
    Mod = crdt_mod(Strategy),
    StateBytes = Mod:encode_state(State),
    bondy_oplog_cell_frame:encode(Hlc, StateBytes, undefined, true);
frame(Strategy, State, Hlc, false) ->
    Mod = crdt_mod(Strategy),
    StateBytes = Mod:encode_state(State),
    ValueBytes = term_to_binary(Mod:to_value(State)),
    bondy_oplog_cell_frame:encode(Hlc, StateBytes, ValueBytes, false).

%% Convenience: the value that `bondy_oplog_core:read/3` is expected to
%% return for `State`.
-spec value_of(Strategy :: atom(), State :: term()) -> term().

value_of(Strategy, State) ->
    (crdt_mod(Strategy)):to_value(State).

%% One compaction cycle of `Id` as a member of `Cluster` (see
%% `with_cluster/2`).
-spec compact_among(binary(), [binary()]) -> term().

compact_among(Id, Cluster) ->
    put({?MODULE, compacting}, Id),
    try
        with_cluster(Cluster, fun() -> bondy_oplog:compact(Id) end)
    after
        erase({?MODULE, compacting})
    end.

%% Runs `Fun` with the instances in `Cluster` as the cluster's members.
%% Instances in one BEAM share a single Partisan membership, so it is mocked:
%% each caller sees `Cluster` minus itself, the instance whose process is
%% calling (the watermark door runs in it) or the one `compact_among/2` names.
%% Over the inline transport a peer is addressed by its instance id, which is
%% what its peer-state rows are keyed by. Any other caller sees every instance
%% as a member, itself included, so it never confirms. A peer that is not an
%% instance id, such as `{peer, Name}`, is never the caller.
-spec with_cluster([term()], fun(() -> T)) -> T.

with_cluster(Cluster, Fun) ->
    case get({?MODULE, cluster}) of
        Cluster ->
            Fun();
        undefined ->
            put({?MODULE, cluster}, Cluster),
            try
                with_members(
                    fun() ->
                        lists:usort([
                            partisan:node() | Cluster -- [caller(Cluster)]
                        ])
                    end,
                    Fun
                )
            after
                erase({?MODULE, cluster})
            end
    end.

%% Runs `Fun` on a node with clustering enabled whose membership is what
%% `Members()` returns, read on every call and from any process.
-spec with_members(fun(() -> [term()]), fun(() -> T)) -> T.

with_members(Members, Fun) ->
    ok = meck:new(bondy_cluster, [passthrough]),
    try
        ok = meck:expect(bondy_cluster, enabled, fun() -> true end),
        ok = meck:expect(bondy_cluster, members, Members),
        Fun()
    after
        meck:unload(bondy_cluster)
    end.

caller(Cluster) ->
    Self = self(),
    case [I || I <- Cluster, is_binary(I), instance_pid(I) =:= Self] of
        [Id] -> Id;
        [] -> get({?MODULE, compacting})
    end.

instance_pid(Id) ->
    try
        bondy_oplog_registry:instance_pid(Id)
    catch
        _:_ -> undefined
    end.

crdt_mod(Strategy) ->
    {crdt, Mod} = bondy_oplog_cell_kernel:from_modules(Strategy, undefined),
    Mod.

%% Polls until the one_for_all restart has produced a new instance AND a
%% new WAL pid, both alive, and a non-fused instance's new applier has
%% finished its `init/1`.
await_subtree_restart(InstId, OldInst, OldWal, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    await_subtree_restart_loop(InstId, OldInst, OldWal, Deadline).

await_subtree_restart_loop(InstId, OldInst, OldWal, Deadline) ->
    Inst = bondy_oplog_instance:whereis(InstId),
    Wal = bondy_oplog_registry:wal_pid(InstId),
    Fresh =
        is_pid(Inst) andalso Inst =/= OldInst andalso
            is_process_alive(Inst) andalso
            is_pid(Wal) andalso Wal =/= OldWal andalso
            is_process_alive(Wal),
    case Fresh andalso applier_ready(InstId) of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> error({subtree_restart_timeout, Inst, Wal});
                false -> timer:sleep(20)
            end,
            await_subtree_restart_loop(InstId, OldInst, OldWal, Deadline)
    end.

%% A call to the applier is served only once its `init/1` has returned.
applier_ready(InstId) ->
    bondy_oplog_registry:fused(InstId) orelse
        case bondy_oplog_registry:applier_pid(InstId) of
            Applier when is_pid(Applier) ->
                try sys:get_state(Applier) of
                    _ -> true
                catch
                    exit:_ -> false
                end;
            undefined ->
                false
        end.

%% Waits until the instance's applier, or its fused writer, has folded
%% everything it has been handed.
settle(Id) ->
    case bondy_oplog_registry:applier_pid(Id) of
        undefined -> bondy_oplog:await_apply(Id);
        Applier -> bondy_oplog_applier:barrier(Applier)
    end.

%% Releases a drain-gated applier and waits for what the release runs. The
%% release is a cast that queues the replay and the drain behind the first
%% settle, so a second one waits for them.
open_gate(Id) ->
    case bondy_oplog_registry:applier_pid(Id) of
        undefined -> ok;
        Applier -> ok = bondy_oplog_applier:open_drain_gate(Applier)
    end,
    ok = settle(Id),
    settle(Id).

%% A whole catalogue install on instance `Id` of a snapshot of the buckets
%% `Cells` carry: begin, stage one batch, then re-derive, which adopts
%% `PeerFrontier` and replies the install's counts.
install(Id, Cells) ->
    install(Id, Cells, #{}).

install(Id, Cells, PeerFrontier) ->
    {ok, Token} = bondy_oplog_instance:begin_install(
        Id, buckets(Cells), PeerFrontier
    ),
    ok = bondy_oplog_instance:install_catalogue_batch(Id, Token, Cells),
    bondy_oplog_instance:rederive_projection(Id, Token).

%% As `install/2`, on a bare applier, without the instance's re-fold mark.
applier_install(Applier, Cells) ->
    {ok, Token} = bondy_oplog_applier:begin_stage(Applier, buckets(Cells), #{}),
    ok = bondy_oplog_applier:install_catalogue_batch(Applier, Token, Cells),
    bondy_oplog_applier:rederive_projection_sync(Applier, Token).

buckets(Cells) ->
    lists:usort([Bucket || {Bucket, _Key, _Frame} <- Cells]).
