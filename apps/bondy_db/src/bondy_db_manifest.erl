%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_manifest).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
On-disk **topology manifest** for a durable `bondy_db` database.

The keying configuration of a durable DB — partition strategy, shard count,
realm-prefix depth, hash algorithm, key-encoding version, topology module, and
each table's `aggregate_root` — determines the **physical key
layout** on disk. Changing any of it **re-keys** existing data: a write that
lands on shard 3 under one configuration lands on shard 9 under the next, so
data written before the change is unreadable through the new routing (not lost,
just mis-addressed). That
makes these values **re-key-on-change** and therefore unsafe to silently apply
to a populated data directory.

The manifest **freezes** that keying configuration the first time a durable DB
is provisioned (genesis) and is the authority on every subsequent boot:

```
<bondy_db>/<db>/MANIFEST
```

On boot the catalogue calls `reconcile/3` with the *configured* topology:

- **absent** → genesis: write the manifest from the current config, proceed.
- **match** → boot normally on the (identical) configured topology.
- **differ** → the new configuration is **NOT applied** (applying it would
  mis-route every key and corrupt reads). Emit a loud warning naming the
  diverging keys plus the migration path (export → wipe data dir → reimport via
  `bondy_export`) and keep running on the **on-disk** topology; or, when the
  operator sets `db.main.on_topology_mismatch = stop`, refuse to boot.

Only **keying-relevant** values are frozen. Runtime knobs (AAE, scan
concurrency, the mismatch policy itself, cache, fsync mode) may change freely
and are deliberately absent from the frozen set.

The manifest is a single human-readable Erlang term (a map) with a schema
`version`, an informational `created_at`, a `checksum` over the frozen keying
map (to detect hand-edits / bit-rot), and the `frozen` map itself. It is
written atomically (temp file + rename). Ephemeral databases (the `registry`,
wiped on restart) have no manifest.

Precedent: RocksDB `OPTIONS`, Kafka `meta.properties`, Riak's ring file.
""").

%% The manifest schema version. Bump when the manifest *envelope* shape changes
%% (not when a frozen value changes — that is a topology divergence, not a
%% schema change).
-define(MANIFEST_VERSION, 1).

%% The cell-key encoding version (the `<<Realm, 0, Key>>` realm-fold and the
%% composite-index key encoding). Bump if that wire format ever changes so an
%% incompatible on-disk layout is caught as a divergence.
-define(KEY_ENCODING_VERSION, 1).

%% The shard-placement hash. Recorded so a future change of hash function is
%% caught as a re-key divergence rather than silently mis-routing.
-define(HASH_ALGO, phash2).

-define(FILENAME, "MANIFEST").

-type frozen() :: #{
    db := atom(),
    topology_module := module(),
    partition_strategy := atom(),
    shard_count := pos_integer(),
    realm_prefix_depth := pos_integer(),
    hash_algo := atom(),
    key_encoding_version := pos_integer(),
    %% How tables map onto oplog instances (`bondy_db_topology:instances_strategy/1`):
    %% `per_table_shard` (one instance per table per shard) or `per_shard` (all
    %% tables on a shard share one instance, the one-log-per-shard collapse).
    %% Frozen because switching it re-homes a shard's WAL/MST onto a different
    %% instance id — an on-disk layout change that must be caught, not silently
    %% applied.
    instances_strategy := atom(),
    %% A sample output of the shard-placement hash over a fixed sentinel term.
    %% `hash_algo => phash2` records which function we use; the probe records
    %% what that function actually COMPUTES, so an OTP release that changes
    %% phash2's output (allowed across majors) is caught as a re-key divergence
    %% instead of silently mis-routing every key. Stamped by `finalize/1`;
    %% absent from manifests written before it existed (skipped in `diff/2`).
    hash_probe => non_neg_integer(),
    tables := #{atom() => table_freeze()}
}.

-type table_freeze() :: #{
    aggregate_root := identity | leading_col | second_col
}.

-type manifest() :: #{
    version := pos_integer(),
    created_at := integer(),
    checksum := non_neg_integer(),
    frozen := frozen()
}.

-type divergence() :: {Key :: term(), Configured :: term(), OnDisk :: term()}.

-type decision() :: genesis | match | {mismatch, [divergence()]}.

-type mismatch_policy() :: warn | stop.

-export_type([frozen/0]).
-export_type([manifest/0]).
-export_type([divergence/0]).
-export_type([decision/0]).

%% API
-export([build/1]).
-export([diff/2]).
-export([fingerprint/1]).
-export([path/1]).
-export([read/1]).
-export([reconcile/3]).
-export([write/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Reconcile the `Configured` frozen topology against the manifest on disk under
`Dir`, applying the `OnMismatch` policy (`warn | stop`).

Returns `{ok, Decision, Effective}` where `Effective` is the frozen topology the
caller must actually open the DB with — always the **on-disk** keying once a
manifest exists, since that is how the data is physically laid out:

- `{ok, genesis, Configured}` — no manifest existed; one was written from
  `Configured`, which is therefore the effective topology.
- `{ok, match, Configured}` — the on-disk manifest equals `Configured`.
- `{ok, {mismatch, Divergences}, OnDisk}` — they differ and the policy is
  `warn`; a warning was logged and the **on-disk** topology is returned as
  effective (the new config is NOT applied).

Or an error, in which case the caller must not open the DB:

- `{error, topology_mismatch}` — they differ and the policy is `stop`.
- `{error, Reason}` — the manifest is unreadable / corrupt, or the genesis
  write failed.

This is the single entry point the catalogue uses at provision time; it owns
the logging so callers only branch on the result.
""".
-spec reconcile(
    Dir :: file:filename_all(),
    Configured :: frozen(),
    OnMismatch :: mismatch_policy()
) -> {ok, decision(), frozen()} | {error, term()}.

reconcile(Dir, Configured0, OnMismatch) when
    is_map(Configured0) andalso (OnMismatch == warn orelse OnMismatch == stop)
->
    Configured = finalize(Configured0),
    case read(Dir) of
        {error, not_found} ->
            case write(Dir, build(Configured)) of
                ok ->
                    ?LOG_NOTICE(#{
                        description =>
                            "Topology manifest written (genesis); the keying "
                            "configuration is now frozen for this data dir",
                        path => path(Dir),
                        partition_strategy =>
                            maps:get(partition_strategy, Configured),
                        shard_count => maps:get(shard_count, Configured)
                    }),
                    {ok, genesis, Configured};
                {error, Reason} = Err ->
                    ?LOG_ERROR(#{
                        description => "Failed to write topology manifest",
                        path => path(Dir),
                        reason => Reason
                    }),
                    Err
            end;
        {ok, #{frozen := OnDisk}} ->
            case diff(Configured, OnDisk) of
                [] ->
                    {ok, match, Configured};
                Divergences ->
                    handle_mismatch(Dir, Divergences, OnDisk, OnMismatch)
            end;
        {error, Reason} = Err ->
            ?LOG_ERROR(#{
                description =>
                    "Topology manifest is present but unreadable; refusing to "
                    "guess the on-disk keying layout",
                path => path(Dir),
                reason => Reason
            }),
            Err
    end.

-doc """
Wrap a frozen keying map in a manifest envelope (schema `version`,
informational `created_at`, and a `checksum` over the frozen map).
""".
-spec build(frozen()) -> manifest().

build(Frozen0) when is_map(Frozen0) ->
    Frozen = finalize(Frozen0),
    #{
        version => ?MANIFEST_VERSION,
        created_at => erlang:system_time(second),
        checksum => checksum(Frozen),
        frozen => Frozen
    }.

-doc """
A cross-node–portable digest of the frozen keying topology: a SHA-256 over a
canonical (deterministically encoded) form of the `finalize/1`'d `frozen()` map.

Unlike `checksum/1` (a local `phash2` integrity check), this is stable across
nodes regardless of map iteration order, so two nodes can exchange it during
anti-entropy to decide whether they key data the same way and may therefore
sync at all. Only placement-determining fields contribute — `finalize/1` folds
in the substrate invariants (hash function, key-encoding version, instances
strategy) and the manifest envelope (`version`, `created_at`, `checksum`) is
excluded.

Two manifests with the same `checksum` will produce the same fingerprint; the
SHA-256 simply widens the digest for the cross-node comparison.
""".
-spec fingerprint(frozen()) -> binary().

fingerprint(Frozen0) when is_map(Frozen0) ->
    crypto:hash(sha256, term_to_binary(finalize(Frozen0), [deterministic])).

-doc """
Compare two frozen topologies and return the list of diverging keys. An empty
list means they are identical. Each divergence is
`{Key, ConfiguredValue, OnDiskValue}`, where `Key` is a scalar attribute name
(e.g. `partition_strategy`) or a per-table descriptor
(`{table, Name}` for an added/removed table, `{table, Name, Attr}` for a
changed attribute). `'$absent'` marks a table present on only one side.
""".
-spec diff(Configured :: frozen(), OnDisk :: frozen()) -> [divergence()].

diff(Configured0, OnDisk) when is_map(Configured0) andalso is_map(OnDisk) ->
    Configured = finalize(Configured0),
    Scalars = [
        db,
        topology_module,
        partition_strategy,
        shard_count,
        realm_prefix_depth,
        hash_algo,
        key_encoding_version,
        instances_strategy
    ],
    ScalarDivs = [
        {K, maps:get(K, Configured, undefined), maps:get(K, OnDisk, undefined)}
     || K <- Scalars,
        maps:get(K, Configured, undefined) =/= maps:get(K, OnDisk, undefined)
    ],
    %% The hash probe only diffs against a manifest that recorded one: a
    %% manifest written before the probe existed carries no baseline to compare
    %% (it is adopted at the next genesis, not retrofitted).
    ProbeDivs =
        case OnDisk of
            #{hash_probe := DiskProbe} ->
                case maps:get(hash_probe, Configured) of
                    DiskProbe -> [];
                    OurProbe -> [{hash_probe, OurProbe, DiskProbe}]
                end;
            _ ->
                []
        end,
    ScalarDivs ++ ProbeDivs ++
        diff_tables(
            maps:get(tables, Configured, #{}),
            maps:get(tables, OnDisk, #{})
        ).

-doc "The manifest file path for the data directory `Dir`.".
-spec path(Dir :: file:filename_all()) -> file:filename_all().

path(Dir) ->
    filename:join(Dir, ?FILENAME).

-doc """
Read and validate the manifest under `Dir`.

Returns `{ok, Manifest}`, `{error, not_found}` if no manifest exists, or
`{error, Reason}` if it is unreadable or its checksum does not match its frozen
map (hand-edit / corruption).
""".
-spec read(Dir :: file:filename_all()) ->
    {ok, manifest()} | {error, not_found} | {error, term()}.

read(Dir) ->
    Path = path(Dir),
    case file:consult(Path) of
        {ok, [#{frozen := Frozen, checksum := Sum} = Manifest]} ->
            case checksum(Frozen) of
                Sum ->
                    {ok, Manifest};
                Actual ->
                    {error, {corrupt_manifest, {checksum, Sum, Actual}}}
            end;
        {ok, _Other} ->
            {error, {corrupt_manifest, unexpected_shape}};
        {error, enoent} ->
            {error, not_found};
        {error, Reason} ->
            {error, {unreadable_manifest, Reason}}
    end.

-doc """
Atomically write `Manifest` under `Dir` (temp file + rename), as a single
Erlang term on one line, preceded by a do-not-edit banner.
""".
-spec write(Dir :: file:filename_all(), Manifest :: manifest()) ->
    ok | {error, term()}.

write(Dir, Manifest) when is_map(Manifest) ->
    Path = path(Dir),
    Tmp = unicode:characters_to_list([Path, ".tmp"]),
    %% `bondy_consult:encode/1` owns the byte encoding of the term (UTF-8,
    %% one line), which is what `file:consult/1` in `read/1` decodes. The
    %% frozen map carries caller-supplied atoms (`db`, `topology_module`,
    %% `partition_strategy`), so an atom with a non-ASCII character reaches
    %% the file; pinned through the real write/read pair by
    %% `bondy_db_manifest_test:write_read_survives_non_ascii_atoms_test_`.
    %% The banner is ASCII and is prepended as bytes.
    IOData = [
        "%% bondy_db topology manifest -- DO NOT EDIT.\n"
        "%% Frozen keying configuration; changing it re-keys on-disk data.\n"
        "%% Migration: export -> wipe data dir -> reimport (bondy_export).\n",
        bondy_consult:encode([Manifest])
    ],
    case file:write_file(Tmp, IOData) of
        ok ->
            case file:rename(Tmp, Path) of
                ok ->
                    ok;
                {error, _} = Err ->
                    _ = file:delete(Tmp),
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Stamp the substrate-owned keying invariants onto a caller-supplied frozen
%% map. The catalogue declares only the deployment keying choices
%% (partition_strategy / shard_count / realm_prefix_depth / per-table keys); the
%% hash function and cell-key encoding are properties of the bondy_db code, so
%% they live here as macros. Set unconditionally (idempotent) so a future change
%% to either bumps the recorded value and surfaces as a divergence on the next
%% boot.
finalize(Frozen) when is_map(Frozen) ->
    Frozen#{
        hash_algo => ?HASH_ALGO,
        key_encoding_version => ?KEY_ENCODING_VERSION,
        %% Derived from the topology module — a property of the bondy_db code,
        %% not an independent deployment choice — so it is stamped here next to
        %% the other substrate invariants.
        instances_strategy =>
            bondy_db_topology:instances_strategy(
                maps:get(topology_module, Frozen)
            ),
        %% Probe the placement hash with a fixed sentinel: same OTP behaviour
        %% ⇒ same value. The range bound matches the widest use (2^27 covers
        %% any practical shard_count) without depending on this DB's count.
        hash_probe => erlang:phash2({bondy_db_hash_probe, 42}, 1 bsl 27)
    }.

%% @private
%% phash2 is deterministic for a given term within an OTP major version and the
%% manifest is read by the same node that wrote it, so this is a stable
%% integrity check (not a cross-version-portable digest).
checksum(Frozen) ->
    erlang:phash2(Frozen).

%% @private
diff_tables(Configured, OnDisk) ->
    Names = lists:usort(maps:keys(Configured) ++ maps:keys(OnDisk)),
    lists:flatmap(
        fun(Name) ->
            diff_table(
                Name,
                maps:get(Name, Configured, '$absent'),
                maps:get(Name, OnDisk, '$absent')
            )
        end,
        Names
    ).

%% @private
diff_table(Name, '$absent', OnDisk) ->
    [{{table, Name}, '$absent', OnDisk}];
diff_table(Name, Configured, '$absent') ->
    [{{table, Name}, Configured, '$absent'}];
diff_table(Name, Configured, OnDisk) ->
    lists:filtermap(
        fun(Attr) ->
            case
                {
                    maps:get(Attr, Configured, undefined),
                    maps:get(Attr, OnDisk, undefined)
                }
            of
                {Same, Same} -> false;
                {CVal, DVal} -> {true, {{table, Name, Attr}, CVal, DVal}}
            end
        end,
        [aggregate_root]
    ).

%% @private
handle_mismatch(Dir, Divergences, OnDisk, warn) ->
    log_mismatch(Dir, Divergences, warning),
    {ok, {mismatch, Divergences}, OnDisk};
handle_mismatch(Dir, Divergences, _OnDisk, stop) ->
    log_mismatch(Dir, Divergences, error),
    {error, topology_mismatch}.

%% @private
log_mismatch(Dir, Divergences, Level) ->
    Msg = #{
        description =>
            "Configured bondy_db topology DIFFERS from the on-disk manifest. "
            "The new configuration was NOT applied — on-disk data is keyed "
            "under the manifest's topology and re-routing it would corrupt "
            "reads. To change the topology: export the data, wipe the data "
            "dir, reimport under the new config (see bondy_export). Set "
            "db.main.on_topology_mismatch = stop to fail fast instead.",
        path => path(Dir),
        divergences => [
            #{key => K, configured => C, on_disk => D}
         || {K, C, D} <- Divergences
        ]
    },
    case Level of
        warning -> ?LOG_WARNING(Msg);
        error -> ?LOG_ERROR(Msg)
    end.
