%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_jepsen_audit).

%% Observability shim used to investigate the Jepsen combined-nemesis
%% flake (PR-J4). Three jobs:
%%
%%   1. `log_post_ack/5`: structured notice emitted from the HTTP set
%%      handler on every 200 OK, recording `{value, hlc, origin, seq,
%%      table}` so a lost Jepsen value can be mapped onto an HLC.
%%
%%   2. `attach/0`: installs a telemetry handler that mirrors selected
%%      applier events (`applied`, `replay_cell_events`,
%%      `batch_install_cast`) as notice logs so the lost HLC's path
%%      through the applier is recoverable from the scraped log file.
%%
%%   3. `dump_all/0`: dumps, per registered oplog instance, the full
%%      WAL event list (read via `wal_reader`) and the full MST
%%      contents (via `bondy_mst:to_list/1`) to
%%      `/opt/bondy_mst_jepsen/log/audit-dump-<node>.etf`. Called via
%%      `release eval` from the Jepsen `db/teardown!` hook just before
%%      the daemon is stopped.

-include_lib("kernel/include/logger.hrl").

-export([attach/0]).
-export([log_post_ack/5]).
-export([dump_all/0]).
-export([handle_telemetry/4]).

-define(HANDLER_ID, <<"bondy_mst_jepsen_audit">>).

%% =============================================================================
%% Telemetry attach
%% =============================================================================

-spec attach() -> ok | {error, term()}.

attach() ->
    Events = [
        [bondy_oplog, applier, applied],
        [bondy_oplog, applier, replay_cell_events],
        [bondy_oplog, applier, batch_install_cast],
        [bondy_oplog, instance, append]
    ],
    telemetry:attach_many(?HANDLER_ID, Events,
                          fun ?MODULE:handle_telemetry/4, undefined).

%% `handle_telemetry/4` is exported above so the `?MODULE:...` MFA
%% survives code-load (telemetry stores the MFA and re-resolves on
%% each event).
handle_telemetry([bondy_oplog, applier, applied], M, Md, _) ->
    Count = maps:get(count, M, 0),
    Rejected = maps:get(rejected, M, 0),
    case Count + Rejected of
        0 -> ok;
        _ ->
            ?LOG_NOTICE(#{
                audit       => applier_applied,
                count       => Count,
                rejected    => Rejected,
                instance_id => maps:get(instance_id, Md, undefined),
                node        => node()
            })
    end;
handle_telemetry([bondy_oplog, applier, replay_cell_events], M, Md, _) ->
    ?LOG_NOTICE(#{
        audit         => applier_replay,
        cells_applied => maps:get(cells_applied, M, 0),
        pairs         => maps:get(pairs, M, 0),
        outcome       => maps:get(outcome, Md, unknown),
        incremental   => maps:get(incremental, Md, undefined),
        instance_id   => maps:get(instance_id, Md, undefined),
        node          => node()
    });
handle_telemetry([bondy_oplog, applier, batch_install_cast], M, Md, _) ->
    case maps:get(count, M, 0) of
        0 -> ok;
        Count ->
            ?LOG_NOTICE(#{
                audit       => install_cast,
                count       => Count,
                instance_id => maps:get(instance_id, Md, undefined),
                node        => node()
            })
    end;
handle_telemetry([bondy_oplog, instance, append], M, Md, _) ->
    case maps:get(count, M, 0) of
        0 -> ok;
        Count ->
            ?LOG_NOTICE(#{
                audit       => wal_append,
                count       => Count,
                instance_id => maps:get(instance_id, Md, undefined),
                node        => node()
            })
    end;
handle_telemetry(_Event, _M, _Md, _) ->
    ok.

%% =============================================================================
%% POST ack log (called from HTTP set handler)
%% =============================================================================

-spec log_post_ack(
    Value  :: binary(),
    Hlc    :: integer(),
    Origin :: term(),
    Seq    :: integer(),
    Table  :: atom() | binary()
) -> ok.

log_post_ack(Value, Hlc, Origin, Seq, Table) ->
    ?LOG_NOTICE(#{
        audit  => post_ack,
        value  => Value,
        hlc    => Hlc,
        origin => Origin,
        seq    => Seq,
        table  => Table,
        node   => node()
    }).

%% =============================================================================
%% Full state dump
%% =============================================================================

-spec dump_all() -> ok | {error, term()}.

dump_all() ->
    Dir = "/opt/bondy_mst_jepsen/log",
    Path = filename:join(Dir, "audit-dump-" ++ atom_to_list(node()) ++ ".etf"),
    Instances = list_instance_ids(),
    PerInstance = [{Iid, dump_instance(Iid)} || Iid <- Instances],
    Term = {audit_dump_v1, #{
        node      => node(),
        ts_ms     => erlang:system_time(millisecond),
        instances => PerInstance
    }},
    Bin = term_to_binary(Term, [{minor_version, 2}, deterministic]),
    case file:write_file(Path, Bin) of
        ok ->
            ?LOG_NOTICE(#{
                audit         => dump_all_ok,
                path          => Path,
                instance_count => length(Instances)
            }),
            ok;
        {error, Reason} = Err ->
            ?LOG_ERROR(#{
                audit  => dump_all_failed,
                path   => Path,
                reason => Reason
            }),
            Err
    end.

%% @private
%% Enumerates every registered oplog instance via the well-known
%% registry ETS table. Returns a list of instance ids (binaries).
%% `ets:foldl/3` (not `tab2list`) — robust to entry-record field
%% count changes and the instance_id is at element 2 by convention
%% (record tag is element 1).
list_instance_ids() ->
    Tab = bondy_oplog_registry_tab,
    try
        ets:foldl(
            fun(Row, Acc) -> [element(2, Row) | Acc] end,
            [], Tab
        )
    catch error:badarg -> []
    end.

%% @private
%% Per-instance dump. Captures:
%%   - origin
%%   - mst_root
%%   - mst_pairs: full {Key, Value} list (Key carries HLC/Origin/Seq)
%%   - wal_events: list of #{key => Key, op_kind => OpKind} from the
%%     WAL, read from `beginning` (so a kill-9 + restart's recovered
%%     WAL contents are visible).
%%   - {ok, _} | {error, _} for each section
dump_instance(Iid) ->
    Result0 = #{instance_id => Iid},
    Result1 = Result0#{origin => safe(fun() ->
        bondy_oplog_registry:origin(Iid)
    end)},
    Result2 = Result1#{mst => safe(fun() ->
        case bondy_oplog_registry:mst(Iid) of
            undefined -> {error, no_mst};
            MST ->
                #{
                    root  => bondy_mst:root(MST),
                    pairs => bondy_mst:to_list(MST)
                }
        end
    end)},
    Result3 = Result2#{wal_info => safe(fun() -> dump_wal_info(Iid) end)},
    Result4 = Result3#{wal => safe(fun() -> dump_wal(Iid) end)},
    Result4.

%% @private
%% Dump writer-side state via `bondy_oplog_wal:info/1` so we can compare
%% what the writer thinks its head/durable/last_hlc are against what the
%% reader can see.
dump_wal_info(Iid) ->
    case bondy_oplog_registry:wal_pid(Iid) of
        undefined -> {error, no_wal};
        WalPid -> bondy_oplog_wal:info(WalPid)
    end.

%% @private
dump_wal(Iid) ->
    case bondy_oplog_registry:wal_pid(Iid) of
        undefined ->
            {error, no_wal};
        WalPid ->
            %% Try `beginning` first; if it returns zero frames despite
            %% the writer reporting a non-empty head, retry from
            %% `{offset, 0, 48}` to bypass any `beginning`-resolution
            %% issue we don't yet understand (PR-J4 investigation).
            R1 = read_wal(WalPid, beginning),
            case R1 of
                #{event_count := 0} ->
                    R2 = read_wal(WalPid, {offset, 0, 48}),
                    #{primary => R1, retry_offset0_48 => R2};
                _ ->
                    #{primary => R1}
            end
    end.

%% @private
read_wal(WalPid, Start) ->
    case bondy_oplog_wal_reader:open(WalPid, Start, [{follow, false}]) of
        {ok, Iter} ->
            Events = drain_wal(Iter, []),
            bondy_oplog_wal_reader:close(Iter),
            #{event_count => length(Events),
              events => Events,
              start => Start};
        {error, _} = Err ->
            #{event_count => 0, events => [], start => Start, open_error => Err}
    end.

%% @private
drain_wal(Iter, Acc) ->
    case bondy_oplog_wal_reader:next(Iter) of
        {ok, Batch, _Hlcs, _Pos, NewIter} ->
            Acc1 = lists:foldl(fun add_wal_event/2, Acc, Batch),
            drain_wal(NewIter, Acc1);
        end_of_log ->
            lists:reverse(Acc);
        {error, Reason} ->
            lists:reverse([{error, Reason} | Acc])
    end.

%% @private
%% Extract the {Hlc, Origin, Seq} key + the op kind so the dump stays
%% small (the op body can be huge for some folds). The full op body is
%% reachable via the MST pairs if needed.
add_wal_event(Event, Acc) ->
    Key = bondy_oplog_event:key(Event),
    Op  = bondy_oplog_event:op(Event),
    OpKind =
        case Op of
            {cell_apply, _Bucket, _Key, FoldEvent} when is_tuple(FoldEvent) ->
                {cell_apply, element(1, FoldEvent)};
            {cell_apply, _Bucket, _Key, FoldEvent} ->
                {cell_apply, FoldEvent};
            T when is_tuple(T) ->
                element(1, T);
            Other ->
                Other
        end,
    [#{key => Key, op_kind => OpKind, op => Op} | Acc].

%% @private
safe(F) ->
    try F() of
        Result -> {ok, Result}
    catch
        C:R:S ->
            {error, #{class => C, reason => R, stacktrace => S}}
    end.
