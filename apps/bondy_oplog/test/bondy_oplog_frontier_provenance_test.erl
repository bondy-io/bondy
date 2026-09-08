%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% The provenance stamp on a persisted applied frontier.
%%
%% Releases up to and including `1.0.0-rc.lime` merged a fold of the live MST's
%% `cell_apply` keys into the frontier at every boot. That fold counts RECEIPT,
%% so the value such a build persisted may claim a seq whose cell never folded,
%% and no merge lowers an entry. The stamp is how a later build knows what it
%% inherited; its absence is the signal.
%%
%% `an_inherited_overclaim_is_not_laundered/0` is the falsifier and the reason
%% the stamp describes the VALUE rather than the writer. A stamp meaning "the
%% build that wrote this folds before claiming" passes every other case here
%% and fails that one: the node writes one checkpoint and its still-suspect
%% frontier reads sound forever after.
%% =============================================================================
-module(bondy_oplog_frontier_provenance_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(ALARM, bondy_oplog_frontier_receipt_derived).

%% =============================================================================
%% The classification
%% =============================================================================

classification_test_() ->
    [
        {"a stamped value is taken at its stamp",
            ?_assertEqual(folded, classify(stamped(folded)))},
        {"a value stamped suspect stays suspect",
            ?_assertEqual(receipt_derived, classify(stamped(receipt_derived)))},

        %% Conservative on both unknowns: a stamp slot carrying no
        %% `provenance`, and a payload from before the slot existed.
        {"a stamp map without the key reads suspect",
            ?_assertEqual(receipt_derived, classify(payload(#{})))},
        {"the 4-tuple that predates the stamp is suspect",
            ?_assertEqual(receipt_derived, classify(payload(no_stamp_slot)))},
        {"the 3-tuple that predates the minted slot is suspect",
            ?_assertEqual(receipt_derived, classify(payload(no_minted_slot)))},

        %% Nothing inherited is not the same as something suspect.
        {"no checkpoint at all inherits nothing",
            ?_assertEqual(folded, classify(undefined))},
        {"a payload carrying no frontier inherits nothing",
            ?_assertEqual(folded, classify(ckpt({bare_crdt, <<"x">>})))}
    ].

%% =============================================================================
%% The stamp on a live instance
%% =============================================================================

instance_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) ->
        [
            {timeout, 60, fun() ->
                an_inherited_overclaim_is_not_laundered(Dir)
            end},
            {timeout, 60, fun() -> a_fresh_instance_stamps_folded(Dir) end},
            {timeout, 60, fun() -> an_own_only_frontier_is_silent(Dir) end}
        ]
    end}.

%% THE FALSIFIER. An instance boots on a checkpoint written by a defective
%% build, alarms, and then writes a checkpoint of its own. That checkpoint must
%% carry the suspicion forward: the value in it is the value it inherited, and
%% the sound writer that persisted it changes nothing about where the entries
%% came from.
an_inherited_overclaim_is_not_laundered(Dir) ->
    {Id, NS, Origin, Shard} = fresh(Dir),
    Remote = bondy_oplog_origin:new(),
    try
        _ = append_batch(Id, 3),
        _ = bondy_oplog_instance:await_apply(Id),
        ok = compact_to_empty(Id),
        ok = bondy_oplog:stop_instance(Id),

        %% What an rc.lime node left behind: a 4-tuple payload, no stamp, and
        %% a remote-origin entry its boot fold derived from receipt.
        ok = rewrite_as_pre_stamp(Dir, Id, Remote, 7),

        {ok, _} = open_instance(Id, NS, Dir, Origin),
        ?assertEqual(7, maps:get(Remote, frontier(Id), 0)),
        ?assertEqual(1, alarm_count(Id)),

        %% The laundering step: persist, and read the payload back.
        ok = bondy_oplog_instance:persist_frontier(Id),
        ?assertEqual([receipt_derived], stamps(Dir, Id)),

        %% And it survives the restart, which is what the stamp is for.
        ok = bondy_oplog:stop_instance(Id),
        ?assertEqual(0, alarm_count(Id)),
        {ok, _} = open_instance(Id, NS, Dir, Origin),
        ?assertEqual(1, alarm_count(Id)),
        ?assertEqual([receipt_derived], stamps(Dir, Id))
    after
        cleanup_instance(Id, NS, Shard)
    end.

%% The healthy path pays nothing: an instance with no inherited value stamps
%% `folded` and says nothing, however many checkpoints it writes.
a_fresh_instance_stamps_folded(Dir) ->
    {Id, NS, _Origin, Shard} = fresh(Dir),
    try
        _ = append_batch(Id, 3),
        _ = bondy_oplog_instance:await_apply(Id),
        ok = compact_to_empty(Id),
        ok = bondy_oplog_instance:persist_frontier(Id),
        ?assertEqual([folded], stamps(Dir, Id)),
        ?assertEqual(0, alarm_count(Id))
    after
        cleanup_instance(Id, NS, Shard)
    end.

%% A suspect value holding no REMOTE entry carries no over-claim: for its own
%% origin the oplog-derived claim is sound, because a local write folds before
%% its event is minted
%% (`proofs/isabelle/Frontier_Writers.thy`, `own_origin_oplog_claim_is_sound`).
%% Alarming on it would fire on every single-node deployment.
an_own_only_frontier_is_silent(Dir) ->
    {Id, NS, Origin, Shard} = fresh(Dir),
    try
        _ = append_batch(Id, 3),
        _ = bondy_oplog_instance:await_apply(Id),
        ok = compact_to_empty(Id),
        ok = bondy_oplog:stop_instance(Id),
        %% Same pre-stamp payload as the falsifier, minus the remote entry.
        ok = rewrite_as_pre_stamp(Dir, Id, undefined, 0),

        {ok, _} = open_instance(Id, NS, Dir, Origin),
        %% The value IS classified suspect ...
        ?assertEqual([receipt_derived], stamps_after_persist(Id, Dir)),
        %% ... and still nothing is raised.
        ?assertEqual(0, alarm_count(Id))
    after
        cleanup_instance(Id, NS, Shard)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

classify(Ckpt) ->
    bondy_oplog_instance:checkpoint_provenance(Ckpt).

ckpt(Payload) ->
    {<<"watermark">>, Payload}.

stamped(Provenance) ->
    payload(#{provenance => Provenance}).

payload(no_minted_slot) ->
    ckpt({projection_managed, frontier, #{}});
payload(no_stamp_slot) ->
    ckpt({projection_managed, frontier, #{}, 0});
payload(Meta) when is_map(Meta) ->
    ckpt({projection_managed, frontier, #{}, 0, Meta}).

setup() ->
    {ok, _} = application:ensure_all_started(sasl),
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = filename:join(
        "/tmp/" ++ os:getpid(),
        "provenance_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

cleanup(Dir) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    _ =
        try
            del_tree(Dir)
        catch
            _:_ -> ok
        end,
    ok.

fresh(Dir) ->
    Id = list_to_binary(
        "provenance_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    NS = binary_to_atom(<<"ns_", Id/binary>>, utf8),
    Origin = bondy_oplog_origin:new(),
    Shard = register_shard(NS),
    {ok, _} = open_instance(Id, NS, Dir, Origin),
    {Id, NS, Origin, Shard}.

cleanup_instance(Id, NS, {Cache, Proj}) ->
    _ = alarm_handler:clear_alarm({?ALARM, Id}),
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

register_shard(NS) ->
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
    {Cache, Proj}.

open_instance(Id, NS, Dir, Origin) ->
    bondy_oplog:start_instance(Id, #{
        origin => Origin,
        fold_module => lww_register,
        backend => bondy_mst_pack_store,
        storage_path => unicode:characters_to_binary(Dir),
        seed => true,
        applier => #{cell_apply_target => {NS, primary, 0}}
    }).

append_batch(Id, N) ->
    [
        begin
            Key = <<"k_", (integer_to_binary(J))/binary>>,
            EvKey = bondy_oplog:append(
                Id, {cell_apply, ?B, Key, {set, 1000 + J, Key}}
            ),
            _ = bondy_oplog:projection(Id),
            EvKey
        end
     || J <- lists:seq(1, N)
    ].

compact_to_empty(Id) ->
    Root = bondy_oplog_instance:root_hash(Id),
    {ok, {compacted, _, _}} = bondy_oplog_instance:compact(Id, [Root]),
    0 = bondy_oplog:size(Id),
    ok.

frontier(Id) ->
    bondy_oplog_registry:frontier(Id).

%% Rewrite every checkpoint this instance owns into the shape an rc.lime node
%% left on disk: the 4-tuple, with no stamp slot at all. `Remote =:= undefined`
%% adds no remote entry, leaving an own-origin-only value.
rewrite_as_pre_stamp(Dir, Id, Remote, Seq) ->
    lists:foreach(
        fun(F) ->
            {ok, Bin} = file:read_file(F),
            {checkpoint_v1, W, {projection_managed, frontier, VV0, Minted, _}} =
                erlang:binary_to_term(Bin),
            VV =
                case Remote of
                    undefined -> VV0;
                    _ -> VV0#{Remote => Seq}
                end,
            ok = file:write_file(
                F,
                erlang:term_to_binary(
                    {checkpoint_v1, W,
                        {projection_managed, frontier, VV, Minted}}
                )
            )
        end,
        checkpoint_files(Dir, Id)
    ).

stamps_after_persist(Id, Dir) ->
    ok = bondy_oplog_instance:persist_frontier(Id),
    stamps(Dir, Id).

%% The distinct provenance stamps across this instance's checkpoints. A list
%% rather than a single value so a writer that stamps one file and not another
%% shows up as two elements instead of being hidden by whichever was read.
stamps(Dir, Id) ->
    lists:usort([
        begin
            {ok, Bin} = file:read_file(F),
            {checkpoint_v1, _W, {projection_managed, frontier, _VV, _M, Meta}} =
                erlang:binary_to_term(Bin),
            maps:get(provenance, Meta)
        end
     || F <- checkpoint_files(Dir, Id)
    ]).

checkpoint_files(Dir, Id) ->
    Files = [
        F
     || F <- filelib:wildcard(filename:join(Dir, "**/checkpoint.etf")),
        string:find(F, binary_to_list(Id)) =/= nomatch
    ],
    ?assert(length(Files) >= 1),
    Files.

alarm_count(Id) ->
    AlarmId = {?ALARM, Id},
    length([
        A
     || A <- alarm_handler:get_alarms(),
        is_tuple(A),
        element(1, A) =:= AlarmId
    ]).

del_tree(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            {ok, Names} = file:list_dir(Dir),
            lists:foreach(fun(N) -> del_tree(filename:join(Dir, N)) end, Names),
            file:del_dir(Dir);
        false ->
            file:delete(Dir)
    end.
