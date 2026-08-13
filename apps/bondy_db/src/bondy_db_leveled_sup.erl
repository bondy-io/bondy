%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_leveled_sup).
-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
`one_for_one` supervisor for leveled Bookies under a `bondy_db`
topology.

The supervisor itself is a regular OTP supervisor; topology modules
(`bondy_db_topology_single_bookie`, `bondy_db_topology_per_entity`,
`bondy_db_topology_shared_shards`) provision Bookies under it and own
their lifecycle. The supervisor is started lazily by the topology's
`init/2` rather than wired under `bondy_mst_sup` — the lifetime of
leveled Bookies is bounded by the lifetime of the topology that owns
them.

## Two provisioning modes

- `start_bookie/2` — start a **fresh** Bookie under a private,
  unique child id. Used by topologies that own one Bookie per logical
  unit (`single_bookie`, `per_entity`): they keep the returned pid in
  their own state and never need to look it up by a stable key.

- `get_or_start_bookie/3` — **idempotent** start keyed by a caller
  chosen `Key`. The first call for `Key` starts the Bookie; every
  later call for the same `Key` returns the same pid. This makes the
  supervisor the shared Bookie registry that
  `bondy_db_topology_shared_shards` needs: its N Bookies are shared
  across every table in the DB, and each table's `open_table/4`
  re-derives the same pool by `get_or_start_bookie(Sup, {shard, K},
  _)` — without threading any topology state between `open_table`
  calls.

## Crash recovery (keyed Bookies)

A **keyed** Bookie is `permanent`: leveled acks a put only after the
journal write, so a reopen replays the journal and recovers every acked
write — restarting in place is safe and strictly better than leaving the
shard dead. The restarted Bookie has a NEW pid, so keyed children are
started through `start_registered/3`, which publishes the pid under the
`persistent_term` key `{bondy_db_bookie, Sup, Key}` on every (re)start.
Routing handles carry `{pt, PTKey}` instead of the raw pid
(`bookie_ref/2`) and `bondy_db_projection_leveled` resolves it per call,
so readers and the applier follow a restart with no handle rewiring.
This is the plum_db partition-store model; Riak's lazy vnode-proxy
restart was rejected (it fits dynamic ownership this design lacks).

A crash-LOOP (e.g. a corrupted store that dies on every reopen) exhausts
the supervisor's restart intensity — sized to tolerate a few slow leveled
reopens, not a tight loop — and fells the supervisor. The owner
(`bondy_namespace_catalog` for the main DB) links it and stops on its
EXIT, escalating the failure up the OTP tree instead of serving a
silently dead shard.

**Anonymous** Bookies (`start_bookie/2`; the `single_bookie` /
`per_entity` topologies, which stash the raw pid in their own state)
remain `temporary` — a restarted pid would be unreachable through their
state, so their crash policy stays with the owning topology.

## Lifecycle

`start_link/0` spawns an unnamed supervisor. The caller (the topology
module's `init/2`) gets the supervisor pid back and stashes it inside
its own state. Topology `shutdown/1` calls `stop/1` here, which
terminates every child Bookie (so leveled flushes), erases the
registered `persistent_term` handles, and then brings the supervisor
down.
""").

-export([start_link/0]).
-export([stop/1]).
-export([start_bookie/2]).
-export([get_or_start_bookie/3]).
-export([stop_bookie/2]).
-export([bookie_ref/2]).
-export([bookie_count/1]).

%% Child start callback (keyed Bookies) — not part of the public API.
-export([start_registered/3]).
-export([book_start/1]).

-export([init/1]).

%% The persistent_term key a keyed Bookie's pid is published under. Keyed by
%% the supervisor pid so two DBs' pools (each with its own supervisor) never
%% collide on the same `{shard, K}` key.
-define(PT_KEY(Sup, Key), {bondy_db_bookie, Sup, Key}).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    supervisor:start_link(?MODULE, []).

-doc """
Stop the supervisor and every Bookie it owns. Returns `ok` once every
child has terminated.

Children are terminated via `supervisor:terminate_child/2` so leveled's
`terminate/2` runs and flushes the inker. After every child is gone,
the supervisor itself is unlinked and killed — supervisors do not
expose a clean self-stop API and `exit(Sup, shutdown)` is not honoured
by an arbitrary caller.
""".
-spec stop(Sup :: pid()) -> ok.

stop(Sup) when is_pid(Sup) ->
    %% Terminate children first (by child id) so leveled flushes cleanly.
    Ids = [
        Id
     || {Id, Pid, _Type, _Mods} <- supervisor:which_children(Sup),
        is_pid(Pid)
    ],
    lists:foreach(
        fun(Id) ->
            _ = catch supervisor:terminate_child(Sup, Id),
            %% Erase the keyed handle registration (no-op for the
            %% never-registered anonymous ids).
            _ = persistent_term:erase(?PT_KEY(Sup, Id))
        end,
        Ids
    ),
    %% Now bring the supervisor itself down. We may be the linking
    %% parent (start_link/0) or just a holder of the pid — `kill`
    %% works either way and we have already flushed the children.
    Ref = erlang:monitor(process, Sup),
    _ = catch unlink(Sup),
    exit(Sup, kill),
    receive
        {'DOWN', Ref, process, Sup, _} -> ok
    after 5_000 ->
        true = erlang:demonitor(Ref, [flush]),
        ok
    end.

-doc """
Provision a **fresh** leveled Bookie under the supervisor with `Opts`,
under a private unique child id.

`Opts` is the proplist passed straight to `leveled_bookie:book_start/1`.
At minimum it must include the keys leveled requires (typically
`root_path`); see leveled's documentation for the full list. This
module does not validate `Opts` — that is leveled's job.

Returns the Bookie pid on success.
""".
-spec start_bookie(
    Sup :: pid(),
    Opts :: proplists:proplist()
) -> {ok, pid()} | {error, term()}.

start_bookie(Sup, Opts) when is_pid(Sup), is_list(Opts) ->
    Id = {anon, erlang:unique_integer([positive, monotonic])},
    supervisor:start_child(Sup, child_spec(Id, Opts)).

-doc """
Terminate AND forget the keyed Bookie `Key` (child delete + registered
handle erase). Used by a topology rolling back a partially-started pool:
a plain `book_close` would leave a `permanent` child behind for the
supervisor to immediately restart.
""".
-spec stop_bookie(Sup :: pid(), Key :: term()) -> ok.

stop_bookie(Sup, Key) when is_pid(Sup) ->
    _ = catch supervisor:terminate_child(Sup, Key),
    _ = catch supervisor:delete_child(Sup, Key),
    _ = persistent_term:erase(?PT_KEY(Sup, Key)),
    ok.

-doc """
The routing REFERENCE for the keyed Bookie `Key`: the `{pt, PTKey}` form a
projection handle carries instead of the raw pid, resolved per call by
`bondy_db_projection_leveled` so a supervisor restart of the Bookie is
transparently followed.
""".
-spec bookie_ref(Sup :: pid(), Key :: term()) -> {pt, term()}.

bookie_ref(Sup, Key) when is_pid(Sup) ->
    {pt, ?PT_KEY(Sup, Key)}.

-doc """
Idempotently provision the leveled Bookie identified by `Key`.

The first call for `Key` starts a Bookie with `Opts`; every later call
for the same `Key` returns the already-running pid (ignoring `Opts`,
which the first call fixed). This is how
`bondy_db_topology_shared_shards` shares one Bookie pool across every
table in the DB: the supervisor — itself shared via `topology_opts.sup`
— is the registry, so no topology state needs threading between
`open_table/4` calls.
""".
-spec get_or_start_bookie(
    Sup :: pid(),
    Key :: term(),
    Opts :: proplists:proplist()
) -> {ok, pid()} | {error, term()}.

get_or_start_bookie(Sup, Key, Opts) when is_pid(Sup), is_list(Opts) ->
    case supervisor:start_child(Sup, keyed_child_spec(Sup, Key, Opts)) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, _} = Err -> Err
    end.

-doc """
Child start callback for a keyed Bookie: start leveled, then publish the
pid under the `persistent_term` routing key. Runs on the FIRST start and
on every supervisor restart, which is exactly what keeps `{pt, _}`
handles current across a crash.
""".
-spec start_registered(
    Sup :: pid(), Key :: term(), Opts :: proplists:proplist()
) -> {ok, pid()} | {error, term()}.

start_registered(Sup, Key, Opts) ->
    case book_start(Opts) of
        {ok, Pid} ->
            ok = persistent_term:put(?PT_KEY(Sup, Key), Pid),
            {ok, Pid};
        {error, _} = Err ->
            Err
    end.

-doc """
Starts a Bookie and sweeps the archived files its startup just produced.

Both halves of leveled archive on open rather than delete: the inker
renames journal files absent from its manifest, and the penciller renames
SST files not used to rebuild the ledger, each to `.bak`. Neither is ever
reopened — leveled's own words are "removable waste not of backup", and
"to make it easier for an admin to garbage collect these files". Bondy is
that admin, and start is the moment to act: the renames have just
happened and the store is not yet serving.

Sweep failures are not start failures. A file we cannot unlink costs disk,
not correctness, and the next start tries again.
""".
-spec book_start(Opts :: proplists:proplist()) ->
    {ok, pid()} | {error, term()}.

book_start(Opts) ->
    case leveled_bookie:book_start(Opts) of
        {ok, Pid} ->
            _ = sweep_archived(proplists:get_value(root_path, Opts)),
            {ok, Pid};
        Other ->
            Other
    end.

-doc """
Number of live Bookies currently owned by the supervisor. Used by
`bondy_db_topology_shared_shards` to detect a `shard_count` mismatch
between tables sharing the pool.
""".
-spec bookie_count(Sup :: pid()) -> non_neg_integer().

bookie_count(Sup) when is_pid(Sup) ->
    %% Filter by module: this supervisor also owns a `journal_trimmer`
    %% child, which is not a Bookie.
    length([
        Pid
     || {_Id, Pid, _Type, Mods} <- supervisor:which_children(Sup),
        is_pid(Pid),
        Mods =:= [leveled_bookie]
    ]).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

init([]) ->
    %% `one_for_one` (not `simple_one_for_one`) so children carry stable,
    %% caller-chosen ids — the precondition for `get_or_start_bookie/3`'s
    %% idempotent keying. Intensity is sized for leveled REOPENS, not tight
    %% loops: a restart replays the journal (seconds on a large store), so 5
    %% restarts in 60s already indicates a store that cannot stay up — the
    %% supervisor then dies and the owner escalates (see moduledoc).
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 60
    },
    %% The journal trimmer is this supervisor's own child, started here
    %% rather than by each topology, so every Bookie pool gets exactly one
    %% without threading anything through the three topology modules. It
    %% enumerates its siblings via `which_children/1` — `init/1` runs in
    %% the supervisor process, so `self()` is the pid it needs. Bookies are
    %% `head_only`, where nothing in leveled reclaims journal disk on its
    %% own; see `bondy_db_journal_trimmer`.
    Trimmer = #{
        id => journal_trimmer,
        start => {bondy_db_journal_trimmer, start_link, [self()]},
        restart => permanent,
        shutdown => 5_000,
        type => worker,
        modules => [bondy_db_journal_trimmer]
    },
    {ok, {SupFlags, [Trimmer]}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Anonymous child: temporary (crash policy owned by the topology, see
%% moduledoc).
child_spec(Id, Opts) ->
    #{
        id => Id,
        %% `book_start/1` here, not `leveled_bookie:book_start/1` — it is
        %% the same start plus the archived-file sweep. `modules` stays
        %% `[leveled_bookie]`: it declares the callback module for code
        %% change, and is also what identifies Bookies among this
        %% supervisor's children (see `bookie_count/1`).
        start => {?MODULE, book_start, [Opts]},
        restart => temporary,
        shutdown => 30_000,
        type => worker,
        modules => [leveled_bookie]
    }.

%% @private
%% Deletes the `.bak` files leveled leaves behind on open, under both
%% `<root>/journal/journal_files` and `<root>/ledger/ledger_files`. The
%% middle segment is wildcarded rather than spelled out so the sweep does
%% not encode leveled's directory names twice.
sweep_archived(undefined) ->
    0;
sweep_archived(RootPath) ->
    Files = filelib:wildcard(
        filename:join([RootPath, "*", "*", "*.bak"])
    ),
    Deleted = lists:foldl(
        fun(F, Acc) ->
            case file:delete(F) of
                ok ->
                    Acc + 1;
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        description =>
                            "Could not delete an archived leveled file; "
                            "it holds disk until the next start retries.",
                        file => F,
                        reason => Reason
                    }),
                    Acc
            end
        end,
        0,
        Files
    ),
    Deleted > 0 andalso
        ?LOG_INFO(#{
            description => "Swept archived leveled files on Bookie start",
            root_path => RootPath,
            deleted => Deleted
        }),
    Deleted.

%% @private
%% Keyed child: permanent, started through `start_registered/3` so every
%% (re)start publishes the current pid under the `{pt, _}` routing key.
keyed_child_spec(Sup, Key, Opts) ->
    #{
        id => Key,
        start => {?MODULE, start_registered, [Sup, Key, Opts]},
        restart => permanent,
        shutdown => 30_000,
        type => worker,
        modules => [leveled_bookie]
    }.
