%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_instance_sup).

-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-instance one_for_all supervisor.

Holds the processes that together implement one running instance:

| Order | Child | Role |
|---|---|---|
| 1 | `bondy_oplog_instance`     | MST owner, validator, public API entry point |
| 2 | `bondy_oplog_wal`          | Per-instance write-ahead log writer |
| 3 | `bondy_oplog_applier`      | Reads the WAL and feeds the instance |
| 4 | `bondy_oplog_wal_scrubber` | Periodic CRC integrity check on sealed segments |

`one_for_all` because the first three are interdependent: an instance
with a dead WAL cannot serve writes, and a WAL with no applier
accumulates unconsumed events the retention sweep cannot clear. A
crash anywhere in the subtree restarts the whole subtree, and recovery
on reopen reconciles the on-disk state. The scrubber is a passive
read-only observer; it accepts being restarted along with its peers
in exchange for the simplicity of a single strategy.

Start order matters: the instance creates its registry row before the
WAL writes `wal_pid` and before the applier writes `applier_pid`. The
WAL is up before the applier opens its reader; the applier resolves
the WAL pid and instance pid from the registry at init time. The
scrubber is started last and resolves the WAL pid from the registry
lazily on each scrub run, so it has no init-time dependency on its
peers.
""").

-export([start_link/2]).
-export([init/1]).

-export([wal_pid/1]).
-export([instance_pid/1]).
-export([applier_pid/1]).
-export([scrubber_pid/1]).
-export([warn_default_wal_path/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(instance_id(), bondy_oplog_instance:opts()) ->
    supervisor:startlink_ret().

start_link(InstanceId, Opts) when
    is_binary(InstanceId), byte_size(InstanceId) > 0, is_map(Opts)
->
    supervisor:start_link(?MODULE, {InstanceId, Opts}).

?DOC("""
Returns the pid of the per-instance `bondy_oplog_instance` child for
the given subtree supervisor pid.
""").
-spec instance_pid(pid()) -> pid() | undefined.

instance_pid(SupPid) when is_pid(SupPid) ->
    find_child(SupPid, bondy_oplog_instance).

?DOC("""
Returns the pid of the per-instance `bondy_oplog_wal` child.
""").
-spec wal_pid(pid()) -> pid() | undefined.

wal_pid(SupPid) when is_pid(SupPid) ->
    find_child(SupPid, bondy_oplog_wal).

?DOC("""
Returns the pid of the per-instance `bondy_oplog_applier` child.
""").
-spec applier_pid(pid()) -> pid() | undefined.

applier_pid(SupPid) when is_pid(SupPid) ->
    find_child(SupPid, bondy_oplog_applier).

?DOC("""
Returns the pid of the per-instance `bondy_oplog_wal_scrubber` child.
""").
-spec scrubber_pid(pid()) -> pid() | undefined.

scrubber_pid(SupPid) when is_pid(SupPid) ->
    find_child(SupPid, bondy_oplog_wal_scrubber).

%% =============================================================================
%% supervisor CALLBACKS
%% =============================================================================

init({InstanceId, Opts0}) ->
    %% Resolve origin once and inject it into the opts so every child
    %% (instance gen_server + WAL writer) sees the same value. When
    %% `storage_path` is set and no explicit `origin` was provided, the
    %% origin is loaded from disk (or generated and persisted on first
    %% boot) so kill -9 + restart recovers the WAL instead of crashing
    %% with `{orphan_segment, origin_mismatch}`.
    Opts = resolve_origin_opt(InstanceId, Opts0),
    %% Emit a one-shot warning when the WAL is about to be parked under
    %% the /tmp/<os_pid>/ default — that path changes across BEAM
    %% restarts and silently abandons fsynced frames. The supervisor is
    %% the natural place to surface this: it's the single point where
    %% both the WAL path and the persistence intent are known.
    ok = maybe_warn_default_wal_path(InstanceId, Opts),
    SupFlags = #{
        strategy => one_for_all,
        intensity => 5,
        period => 10
    },
    InstanceSpec = #{
        id => bondy_oplog_instance,
        start => {bondy_oplog_instance, start_link, [InstanceId, Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [bondy_oplog_instance]
    },
    WalOpts = wal_opts(InstanceId, Opts),
    %% Ephemeral ETS WAL (task #50): a fused ephemeral instance may opt into an
    %% in-memory WAL backend (`wal_backend => mem`) that drops the fsync from
    %% the ack path — see `bondy_oplog_wal_mem`. It is gated on `fused` (the mem
    %% reader is only dispatched on the fused drain path) and carries no sealed
    %% segments, so it needs no scrubber. Every other instance keeps the disk
    %% WAL verbatim.
    WalBackend = wal_backend(Opts),
    WalMod =
        case WalBackend of
            mem -> bondy_oplog_wal_mem;
            disk -> bondy_oplog_wal
        end,
    WalSpec = #{
        id => bondy_oplog_wal,
        start => {WalMod, start_link, [InstanceId, WalOpts]},
        restart => permanent,
        shutdown => 30000,
        type => worker,
        modules => [WalMod]
    },
    ApplierOpts = applier_opts(InstanceId, Opts),
    ApplierSpec = #{
        id => bondy_oplog_applier,
        start => {bondy_oplog_applier, start_link, [ApplierOpts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [bondy_oplog_applier]
    },
    ScrubberOpts = scrubber_opts(InstanceId, Opts),
    ScrubberSpec = #{
        id => bondy_oplog_wal_scrubber,
        start => {bondy_oplog_wal_scrubber, start_link, [ScrubberOpts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [bondy_oplog_wal_scrubber]
    },
    %% Ephemeral fused-writer mode (fused-writer rollout, Step 3): the
    %% instance gen_server drains the WAL + installs inline ITSELF, so a
    %% separate applier would double-drain the WAL. Omit it. `fused` is
    %% default-off, so every durable (and non-fused ephemeral) instance
    %% keeps the full applier+instance pipeline verbatim.
    Children =
        case {maps:get(fused, Opts, false), WalBackend} of
            {true, mem} ->
                %% Fused + in-memory WAL: instance drains inline (no applier),
                %% mem WAL has no sealed segments (no scrubber).
                [InstanceSpec, WalSpec];
            {true, disk} ->
                [InstanceSpec, WalSpec, ScrubberSpec];
            {false, _} ->
                [InstanceSpec, WalSpec, ApplierSpec, ScrubberSpec]
        end,
    {ok, {SupFlags, Children}}.

%% @private
%% Resolve the WAL storage backend. The in-memory backend (`mem`) is opt-in via
%% `wal_backend => mem` AND only for fused instances — the mem reader is
%% dispatched on the fused drain path, so a non-fused `mem` request falls back
%% to disk with a warning rather than silently mis-wiring the reader.
wal_backend(Opts) ->
    case maps:get(wal_backend, Opts, disk) of
        mem ->
            case maps:get(fused, Opts, false) of
                true ->
                    mem;
                false ->
                    ?LOG_WARNING(#{
                        description =>
                            "wal_backend => mem requested for a non-fused "
                            "instance; falling back to the disk WAL",
                        instance_id => maps:get(instance_id, Opts, undefined)
                    }),
                    disk
            end;
        disk ->
            disk;
        Other ->
            ?LOG_WARNING(#{
                description =>
                    "unknown wal_backend; falling back to the disk WAL",
                wal_backend => Other
            }),
            disk
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
find_child(SupPid, Id) ->
    try supervisor:which_children(SupPid) of
        Children ->
            case lists:keyfind(Id, 1, Children) of
                {Id, Pid, _Type, _Mods} when is_pid(Pid) -> Pid;
                _ -> undefined
            end
    catch
        exit:_ -> undefined
    end.

%% @private
%% Extract the WAL-relevant options from the instance options map. The
%% caller-facing `bondy_oplog_instance:opts()` is a superset; we filter
%% the keys the WAL recognises so the WAL can validate them itself.
wal_opts(InstanceId, Opts) ->
    Base0 = maps:with(
        [
            max_segment_bytes,
            max_batch_bytes,
            retention,
            idx_interval_bytes,
            fsync_mode,
            batched_fsync_interval,
            batched_fsync_bytes,
            min_live_segments,
            retention_sweep_interval,
            max_total_wal_size,
            max_live_segments
        ],
        Opts
    ),
    %% `origin` is pre-populated by `resolve_origin_opt/2` at supervisor
    %% init so the WAL writer and the instance gen_server see the same
    %% value. The `default/0` fallback here only covers callers that
    %% bypass the supervisor (tests building wal_opts directly).
    Origin = maps:get(origin, Opts, bondy_oplog_origin:default()),
    Dir = wal_base_dir(InstanceId, Opts),
    Base0#{dir => Dir, origin => Origin}.

%% @private
%% The WAL stores its segments under `Dir/<InstanceId>` — the writer's
%% `open/2` appends `InstanceId` to the configured base directory.
%% Resolve a writable base from explicit `wal_dir`, falling back to
%% `storage_path`, and finally to a per-id tmp directory when neither
%% is set. The tmp default mirrors what the instance gen_server already
%% does for its MST backend so a caller with no on-disk configuration
%% still gets a working subtree.
wal_base_dir(InstanceId, Opts) ->
    case maps:find(wal_dir, Opts) of
        {ok, D} ->
            D;
        error ->
            case maps:find(storage_path, Opts) of
                {ok, BaseDir} ->
                    Base = bondy_oplog_path:instance_dir(
                        InstanceId, BaseDir, Opts
                    ),
                    bondy_oplog_path:wal_dir(Base);
                error ->
                    %% Default tmp dir is namespaced by OS pid so a
                    %% fresh BEAM run does not inherit segments from
                    %% a prior run sharing the same `InstanceId`. The
                    %% WAL writer then appends `InstanceId` itself, so
                    %% the final directory is
                    %% `/tmp/bondy_oplog_wal/<os_pid>/<InstanceId>`.
                    Pid = list_to_binary(os:getpid()),
                    Tmp = filename:join(
                        ["/tmp", "bondy_oplog_wal", Pid]
                    ),
                    unicode:characters_to_binary(Tmp)
            end
    end.

%% @private
%% The applier needs the on-disk WAL directory. Pid lookup is deferred
%% to the applier's own `init/1` because the WAL writer (started after
%% the instance, before the applier) only publishes `wal_pid` once its
%% own init has returned — by which time the applier is already being
%% started by the supervisor.
applier_opts(InstanceId, Opts) ->
    Base = wal_base_dir(InstanceId, Opts),
    %% The WAL writer's `open/2` appends `InstanceId` to the configured
    %% base directory; the applier needs the same fully-qualified path
    %% to locate the on-disk `consumer.offset`.
    WalDir = iolist_to_binary(filename:join(Base, InstanceId)),
    Applier0 = maps:get(applier, Opts, #{}),
    %% `ae_targets` is conceptually per-instance (both the applier and
    %% AE rounds bump the same set) so we accept it at the top level
    %% of the instance opts and pass it through to the applier here.
    %% Per-applier override (`Opts.applier.ae_targets`) wins so callers
    %% who set it under the older shipped surface keep working; this
    %% is the only legitimate path for divergent applier-vs-AE target
    %% lists and is not expected in practice.
    AeTargets0 = maps:get(ae_targets, Opts, []),
    AeTargets = maps:get(ae_targets, Applier0, AeTargets0),
    Applier0#{
        instance_id => InstanceId,
        wal_dir => WalDir,
        ae_targets => AeTargets
    }.

%% @private
%% Extract the scrubber-relevant options. `scrubber` is an optional map
%% under the instance opts that can carry `interval_ms`. Default is
%% disabled (`interval_ms = 0`) so untouched configurations do no I/O.
scrubber_opts(InstanceId, Opts) ->
    Scrubber0 = maps:get(scrubber, Opts, #{}),
    Scrubber0#{instance_id => InstanceId}.

%% @private
%% Resolve the `origin` opt and inject it into the opts map so every
%% downstream child (instance gen_server, WAL writer, applier) reads
%% the same value. Precedence:
%%   1. Caller-provided `origin` wins.
%%   2. Otherwise, if `storage_path` is set, load (or create + persist)
%%      the origin under that path so it survives BEAM restarts.
%%   3. Otherwise, fall back to the per-VM ephemeral default — same
%%      behaviour as pre-change for tests and ephemeral instances.
%%
%% The on-disk path is `<storage_path-for-instance>/origin` (i.e.,
%% alongside the `wal/` subdir, not inside it), so the WAL recovery's
%% directory scans don't see it.
resolve_origin_opt(InstanceId, Opts) ->
    case maps:is_key(origin, Opts) of
        true ->
            Opts;
        false ->
            Origin =
                case origin_persist_path(InstanceId, Opts) of
                    undefined ->
                        bondy_oplog_origin:default();
                    Path ->
                        bondy_oplog_origin:load_or_create(Path)
                end,
            Opts#{origin => Origin}
    end.

%% @private
%% Return the on-disk path the origin should be persisted to, or
%% `undefined` when no durable storage is configured. Mirrors the
%% per-instance dir derivation used by `wal_base_dir/2`.
origin_persist_path(InstanceId, Opts) ->
    case maps:find(storage_path, Opts) of
        {ok, BaseDir} ->
            Base = bondy_oplog_path:instance_dir(InstanceId, BaseDir, Opts),
            bondy_oplog_path:origin_dir(Base);
        error ->
            undefined
    end.

%% @private
%% Loud warning when an instance is starting with no durable storage
%% configured for the WAL. The default tmp path is namespaced by
%% `os:getpid()` so a fresh BEAM run never sees prior segments — that
%% is intentional test-isolation behaviour but a footgun under any
%% kill-restart scenario (Jepsen, systemd-restart, OOM-killer).
%%
%% No dedup needed: `bondy_oplog_instance_sup:init/1` runs once per
%% `bondy_oplog:start_instance/2` call (the parent is
%% `simple_one_for_one`, so each instance is a fresh child). The
%% supervisor's own `intensity` governs child restarts within an
%% instance but does not re-invoke init/1. Tests run with
%% `logger_level = error`, so this is silent in the eunit suite.
%%
%% Avoiding `persistent_term` for dedup is deliberate: every
%% `persistent_term:put/2` triggers a global GC scan of every process
%% on the node — fine for write-once-per-VM constants, the wrong
%% substrate for per-instance lifecycle events.
maybe_warn_default_wal_path(InstanceId, Opts) ->
    case warn_default_wal_path(Opts) of
        false ->
            ok;
        true ->
            ?LOG_WARNING(#{
                description =>
                    "WAL falling back to ephemeral tmp path; fsynced "
                    "frames will be abandoned on BEAM restart (the "
                    "path includes os:getpid() for test isolation). "
                    "Configure `storage_path` or `wal_dir` for "
                    "durable instances, or set `durability => ephemeral` "
                    "to acknowledge an intentionally non-durable instance.",
                instance_id => InstanceId
            }),
            ok
    end.

-doc """
Pure predicate: should the no-durable-storage WAL warning fire for these
instance opts?

`false` when a durable WAL location is configured (`wal_dir` or
`storage_path`) **or** when the caller has explicitly declared the
instance ephemeral (`durability => ephemeral`). The latter is the
operator's acknowledgement that the missing `storage_path` is intended —
an ephemeral namespace's full in-memory stack reconverges from peers, so
the kill-restart footgun the warning guards against does not apply and
the message would be pure noise. Exported for unit testing.
""".
-spec warn_default_wal_path(Opts :: map()) -> boolean().

warn_default_wal_path(Opts) ->
    not (maps:is_key(wal_dir, Opts) orelse
        maps:is_key(storage_path, Opts) orelse
        maps:get(durability, Opts, durable) =:= ephemeral).
