%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_leveled_sup).
-behaviour(supervisor).

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

## Lifecycle

`start_link/0` spawns an unnamed supervisor. The caller (the topology
module's `init/2`) gets the supervisor pid back and stashes it inside
its own state. Topology `shutdown/1` calls `stop/1` here, which
terminates every child Bookie (so leveled flushes) and then brings the
supervisor down.

Each Bookie is `temporary` — supervisor restart-after-crash would
deliver a fresh Bookie pid that the topology's existing routing map
does not know about. The topology is responsible for any restart
policy it wants.
""").

-export([start_link/0]).
-export([stop/1]).
-export([start_bookie/2]).
-export([get_or_start_bookie/3]).
-export([bookie_count/1]).

-export([init/1]).

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
            _ = catch supervisor:terminate_child(Sup, Id)
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
    case supervisor:start_child(Sup, child_spec(Key, Opts)) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, _} = Err -> Err
    end.

-doc """
Number of live Bookies currently owned by the supervisor. Used by
`bondy_db_topology_shared_shards` to detect a `shard_count` mismatch
between tables sharing the pool.
""".
-spec bookie_count(Sup :: pid()) -> non_neg_integer().

bookie_count(Sup) when is_pid(Sup) ->
    length([
        Pid
     || {_Id, Pid, _Type, _Mods} <- supervisor:which_children(Sup),
        is_pid(Pid)
    ]).

%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================

init([]) ->
    %% `one_for_one` (not `simple_one_for_one`) so children carry stable,
    %% caller-chosen ids — the precondition for `get_or_start_bookie/3`'s
    %% idempotent keying. `intensity => 0` with `temporary` children: a
    %% Bookie crash is never restarted (so it does not count against the
    %% intensity and does not fell the supervisor); the owning topology
    %% drives any restart policy.
    SupFlags = #{
        strategy => one_for_one,
        intensity => 0,
        period => 1
    },
    {ok, {SupFlags, []}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
child_spec(Id, Opts) ->
    #{
        id => Id,
        start => {leveled_bookie, book_start, [Opts]},
        restart => temporary,
        shutdown => 30_000,
        type => worker,
        modules => [leveled_bookie]
    }.
