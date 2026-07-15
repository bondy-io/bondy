%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_bootstrap_lifecycle).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-instance bootstrap lifecycle.

The applier MUST NOT apply WAL events onto the per-cell projection
until the instance has been bootstrapped — either by joining an
existing cluster via `bondy_oplog_sync_session:bootstrap/3`, or by
declaring itself a genesis (`seed: true`) peer at startup. Without
this gate a fresh peer that receives a live event before bootstrap
would apply it to bottom state and converge to wrong values. The
failure is silent and affects *every* fold strategy, not just
counters.

## State machine

```
                bootstrap/3 success / seed: true
    pre_bootstrap ──────────────────────────────► live
```

The transition is **one-shot** and **durable**. Once an instance
reaches `live` on persistent storage it stays `live` across restarts;
no path returns to `pre_bootstrap` without operator intervention
(deleting the flag file by hand).

## Storage

The lifecycle bit lives in `<instance_dir>/lifecycle.live` — an empty
flag file. Presence ⇒ `live`. Absence ⇒ `pre_bootstrap`. The
transition is atomic via `file:rename/2`:

```erlang
ok = file:write_file(".lifecycle.live.tmp", <<>>),
ok = file:rename(".lifecycle.live.tmp", "lifecycle.live").
```

No parsing, no checksum, no version handshake — recovery is "does
the file exist or not."

A boolean mirror is held in `atomics` so the applier's hot loop can
gate without a syscall per tick. The file is the source of truth on
restart; the atomic is the runtime cache.

## Ephemeral instances

Instances configured without `storage_path` (typical for tests using
the ETS backend with no on-disk component) cannot persist a flag
file. For those the lifecycle is in-memory only and defaults to
`live` — there is no persistent state to bootstrap from, and tests
that don't think about lifecycle work unchanged. `seed: true` is
still honoured for symmetry.

## Defaults

| Configuration | Initial state |
|---|---|
| `lifecycle.live` exists on disk | `live` |
| `seed: true` in opts | `live` (writes flag file if persistent) |
| No `storage_path` (ephemeral) | `live` |
| Persistent, no flag file, `seed: false` | `pre_bootstrap` |

A persistent instance whose flag file is absent and that was not
seeded is presumed to be a fresh peer that must call
`bondy_oplog_sync_session:bootstrap/3` against a live peer before it
can serve fold-driven reads.
""").

-define(FLAG_FILENAME, "lifecycle.live").
-define(FLAG_TMPNAME, ".lifecycle.live.tmp").
-define(ATOMIC_SLOT, 1).
-define(ATOMIC_LIVE, 1).
-define(ATOMIC_PRE_BOOTSTRAP, 0).

-record(handle, {
    instance_id :: instance_id(),
    flag_path :: undefined | file:filename_all(),
    atomic :: atomics:atomics_ref()
}).

-opaque handle() :: #handle{}.

-type state() :: pre_bootstrap | live.

-export_type([handle/0]).
-export_type([state/0]).

-export([open/2]).
-export([is_live/1]).
-export([state/1]).
-export([mark_live/1]).
-export([flag_path/1]).
-export([instance_id/1]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Opens a lifecycle handle for `InstanceId`.

`Opts` is the same map passed to `bondy_oplog_instance:init/1`;
recognised keys are `storage_path`, `path_layout`, and `seed`.

The handle is cheap to copy and safe to share between processes: the
atomics ref is shared by reference; the flag-path binary is
immutable.

The function performs at most one filesystem stat (does the flag
file exist?) and at most one `file:write_file`/`file:rename` pair
(when seeding a persistent instance). On error reading the
directory, the instance is considered `pre_bootstrap` and a warning
is logged.
""").
-spec open(instance_id(), map()) -> handle().

open(InstanceId, Opts) when is_binary(InstanceId), is_map(Opts) ->
    FlagPath = compute_flag_path(InstanceId, Opts),
    Atomic = atomics:new(1, [{signed, false}]),
    InitialState = resolve_initial_state(FlagPath, Opts),
    case InitialState of
        live ->
            ok = atomics:put(Atomic, ?ATOMIC_SLOT, ?ATOMIC_LIVE);
        pre_bootstrap ->
            ok = atomics:put(Atomic, ?ATOMIC_SLOT, ?ATOMIC_PRE_BOOTSTRAP)
    end,
    Handle = #handle{
        instance_id = InstanceId,
        flag_path = FlagPath,
        atomic = Atomic
    },
    %% When seeding a persistent instance for the first time, materialise
    %% the flag file so the next restart sees `live` without needing the
    %% seed opt again.
    case {InitialState, FlagPath, maps:get(seed, Opts, false)} of
        {live, P, true} when P =/= undefined ->
            ok = persist_flag_idempotent(P, InstanceId);
        _ ->
            ok
    end,
    Handle.

?DOC("""
Constant-time check used by the applier hot loop. Reads the boolean
mirror from `atomics`; no syscall, no allocation.
""").
-spec is_live(handle()) -> boolean().

is_live(#handle{atomic = Ref}) ->
    atomics:get(Ref, ?ATOMIC_SLOT) =:= ?ATOMIC_LIVE.

?DOC("""
Returns the current lifecycle state as an atom. Equivalent to
`is_live/1` but useful in logs and tests.
""").
-spec state(handle()) -> state().

state(#handle{} = H) ->
    case is_live(H) of
        true -> live;
        false -> pre_bootstrap
    end.

?DOC("""
Flips the lifecycle to `live` durably and idempotently.

Order of effects (matters for crash recovery):

  1. Atomic rename of `.lifecycle.live.tmp` → `lifecycle.live`
     (the durability barrier — until it succeeds, restart still sees
     `pre_bootstrap`).
  2. Boolean mirror set in `atomics`.

Callers MUST invoke this *last* in the bootstrap completion sequence
— after `load_snapshot` has installed the snapshot and after the
watermark has been advanced. A crash between any earlier step and
this call leaves no flag file; on restart the operator re-runs
`bootstrap/3` and the earlier steps idempotently re-succeed.

Re-marking an already-live instance is a no-op (both file:rename and
atomic-set are idempotent).
""").
-spec mark_live(handle()) -> ok.

mark_live(#handle{atomic = Ref} = H) ->
    case H#handle.flag_path of
        undefined ->
            ok;
        Path ->
            ok = persist_flag_idempotent(Path, H#handle.instance_id)
    end,
    ok = atomics:put(Ref, ?ATOMIC_SLOT, ?ATOMIC_LIVE),
    ok.

?DOC("""
Returns the on-disk path of the lifecycle flag file, or `undefined`
for ephemeral instances. Test-facing.
""").
-spec flag_path(handle()) -> undefined | file:filename_all().

flag_path(#handle{flag_path = P}) ->
    P.

?DOC("Returns the instance_id this handle belongs to.").
-spec instance_id(handle()) -> instance_id().

instance_id(#handle{instance_id = Id}) ->
    Id.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Computes `<instance_dir>/lifecycle.live`. Returns `undefined` for
%% instances without a `storage_path` — those are ephemeral and have
%% no place to persist the flag.
compute_flag_path(InstanceId, Opts) ->
    case maps:find(storage_path, Opts) of
        {ok, BaseDir} when is_binary(BaseDir); is_list(BaseDir) ->
            BaseBin = unicode:characters_to_binary(BaseDir),
            InstanceDir = bondy_oplog_path:instance_dir(
                InstanceId, BaseBin, Opts
            ),
            filename:join(
                unicode:characters_to_binary(InstanceDir),
                ?FLAG_FILENAME
            );
        error ->
            undefined
    end.

%% @private
%% Decides the initial state by combining the persistent flag and the
%% startup options. See the "Defaults" table in the moduledoc.
resolve_initial_state(undefined, Opts) ->
    %% Ephemeral instance — nothing to enforce. Default live, with
    %% `seed: false` honoured for symmetry with tests that want to
    %% exercise the gate in-memory.
    case maps:get(seed, Opts, true) of
        true -> live;
        false -> pre_bootstrap
    end;
resolve_initial_state(Path, Opts) ->
    case filelib:is_regular(Path) of
        true ->
            live;
        false ->
            case maps:get(seed, Opts, false) of
                true -> live;
                false -> pre_bootstrap
            end
    end.

%% @private
%% Idempotent flag-file write. Ensures the parent directory exists
%% (the instance directory may not be present yet on the first open of
%% a brand-new instance — `bondy_mst_pack_store` and other backends
%% create their own subtree, but we don't depend on them having run
%% first). Uses tmp+rename so a crash between write and rename leaves
%% no half-flag.
persist_flag_idempotent(Path, InstanceId) ->
    Dir = filename:dirname(Path),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    case filelib:is_regular(Path) of
        true ->
            ok;
        false ->
            TmpPath = filename:join(Dir, ?FLAG_TMPNAME),
            case file:write_file(TmpPath, <<>>) of
                ok ->
                    case file:rename(TmpPath, Path) of
                        ok ->
                            ok;
                        {error, RenameErr} ->
                            ?LOG_ERROR(#{
                                description =>
                                    "failed to durably mark instance "
                                    "lifecycle as live; restart will "
                                    "see pre_bootstrap",
                                instance_id => InstanceId,
                                path => Path,
                                reason => RenameErr
                            }),
                            error({lifecycle_persist_failed, RenameErr})
                    end;
                {error, WriteErr} ->
                    ?LOG_ERROR(#{
                        description =>
                            "failed to write lifecycle.live tmp file",
                        instance_id => InstanceId,
                        path => TmpPath,
                        reason => WriteErr
                    }),
                    error({lifecycle_persist_failed, WriteErr})
            end
    end.
