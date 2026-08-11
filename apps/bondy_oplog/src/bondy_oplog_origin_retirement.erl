%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_origin_retirement).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Origin retirement — the cleanup that follows a deliberate Partisan
membership removal, and the replication of the operator's retirement set.

## The division of labour

**Partisan membership is the replicated authority.** A node leaves the
stability set the moment it is removed from the membership — a deliberate
join/leave act, never a timeout — and `bondy_oplog_instance:
reclamation_members/0` observes that directly. Nothing here decides WHO
has departed; this module only reacts to a membership the cluster has
already agreed on.

**This module owns the node-local cleanup** that should follow: forgetting
departed peers from `bondy_oplog_peer_state`, and reaping dead origins'
causal-context entries from tier_2 cell states (`reap_origins`). Both are
node-local acts driven by the replicated membership signal, so node-local
state is sufficient.

**It also carries the retirement set between nodes.** Each pass pulls every
member's set over the sync transport (`get_retired`) and unions in whatever
came back. The set is grow-only, so the union needs no ordering, cannot
conflict, and converges under repetition — which is why a periodic pull is
the whole of the replication protocol, and why an unreachable member costs
a delay rather than a stall.

## Reap-by-complement

An origin is an opaque state-epoch identity with no node attribution, so
survivors cannot attribute a dead node's origins after the fact. Instead of
tracking dead origins, the reaper asks the LIVE members for theirs — the one
mapping each node authoritatively owns — over the sync transport
(`get_origins`), and computes:

    dead = origins in local frontier VVs
           − (own origins ∪ union of every member's advertised origins)

**Fail-closed**: if ANY current member cannot be queried the pass aborts and
retries on the next membership event. A sample of the membership licenses
nothing — an origin absent from the answers of half the cluster is not
unclaimed, only unasked. A bonus of the complement: origins of nodes that
departed before this subsystem existed (or of pre-wipe incarnations, or of
ephemeral VM boots) are unclaimed by construction and get reaped too.

## Frontier reaping

An origin's frontier entry is a permanent statement — "every event this
origin ever minted, up to seq N, is applied here" — and two consumers read
it: `bondy_oplog_sync_session:frontier_deficit/2` treats a MISSING local
origin as seq 0, and `bondy_oplog_registry:merge_frontier/2` max-merges over
the union of keys, so a peer that still carries the entry re-adds it. Left
alone, a departed node's entries are immortal, one PER DURABLE SHARD, since
`bondy_oplog_instance_sup:resolve_origin_opt/2` persists a separate origin
under each instance's directory — the cost of a departure scales with
`db.main.shard_count`, not with the number of nodes. (Ephemeral instances
contribute nothing: they share one per-VM origin and their frontiers stay
empty.)

Dropping an entry is licensed by exactly one thing: **every member has the
origin in its retirement set**, read fresh over the transport, fail-closed —
a member that did not answer has not agreed
(`bondy_oplog_frontier_reap_test:unreachable_member_reaps_nothing/0`). Note
the asymmetry with learning above, which is deliberate: a union from a
subset is monotone and cannot be wrong, whereas the reap's quantifier ranges
over ALL members (`unreachable_member_still_learns_from_the_rest/0`).

*Retirement, not membership.* Membership is reversible — a departed node
returns with the disk it left with and `bondy_oplog_origin:load_or_create/1`
hands back the same origin, so a reap taken on absence alone makes this
replica silently skip the returned node's new events. Retirement is the
operator asserting the replica is permanently gone; it is monotone,
persisted and replicated, and it bans the origin.

*Universal, not local.* A replica that has retired the origin refuses its
events, so it has no use for a deficit signal about them; a replica that has
NOT yet retired it does. Reaping while any member is still in that state
takes away the only route by which it could still obtain events already
reclaimed from every log — page sync cannot ship them, and only a frontier
deficit flags the catalogue rebootstrap that can.

Requiring instead that every member be LEVEL on the origin is safe but not
live: only a reap lowers a claim and a retired origin's claim never rises
again, so the first replica to reap leaves every other replica permanently
unequal to it, and the entry survives everywhere but one. Checked in
`proofs/tla/OriginRetirementSet.tla` with an inverted invariant, so a
VIOLATION is the good result: `_MeetProbe` HOLDS `NotAllMembersReaped`
(the meet never clears the entry cluster-wide), `_UniversalProbe` violates
it in 10 steps. Do not tighten this back to a meet.

Level-ness is therefore reported, not required — reaping over unequal claims
means the origin was retired before the cluster had converged on its events,
and the ban has frozen the difference permanently.

Solo (`reclamation_members/0` = `{ok, []}`) licenses NOTHING here, unlike
projection-cell reclamation: a frontier entry is a claim compared against
peers, and a one-node cluster that later grows meets a peer still
advertising the entry and reads its own reaped 0 as a deficit
(`bondy_oplog_frontier_reap_test:solo_reaps_no_frontier/0`).

## What is deliberately NOT done

No automatic retirements, and no automatic bans. Retiring a live origin
makes every replica silently refuse its remote appends — permanent
divergence — and the complement can over-claim if a member under-advertises
(see `local_origins/0`). The membership plane gate already refuses
connections from non-members, which fences a departed node's late appends;
retirement stays an operator act.

A node absent when the reap happened is not consulted by it. On its return
it holds no retirement, so for one pass it can still ask for the origin's
events while every surviving replica has stopped reporting them — events
already reclaimed from every log are then unreachable to it. The window
closes as soon as it pulls the retirement set, after which it refuses those
events anyway. This is the ban's cost, not the reap's, and the operator
contract is the same either way: retire an origin only once the cluster has
converged on its events.

## Enablement

Gated by `bondy_oplog` env `origin_retirement` (default `true` — the pass
is idempotent and fail-closed). The transport is taken from the
`sync_session_opts` env (same source as AAE); with the default inline
transport a member query cannot address a remote node and the pass aborts —
fail-closed, never fail-open.
""").

%% Lifecycle
-export([start_link/0]).
-export([child_spec/0]).

%% API
-export([run/0]).
-export([run/1]).
-export([retire_dead/0]).
-export([local_origins/0]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-ifdef(TEST).
%% The reap's licence and the pass that applies it, exposed so a single-VM
%% test can drive them against a member list the local membership cannot
%% produce.
-export([replicate_and_reap/1]).
-export([learn_retirements/1]).
-export([universal/1]).
-endif.

-record(state, {
    enabled :: boolean(),
    %% Single-flight cleanup worker; a membership event during a run sets
    %% `pending` and the run is repeated once the worker exits.
    worker :: undefined | pid(),
    pending = false :: boolean(),
    %% Dead origins already swept out of this node's cell contexts. The
    %% candidate set is drawn from the applied-frontier VVs, which only a
    %% retirement clears, so a departed node stays a candidate until it is
    %% retired — and rescanning every cell of every instance for it, every
    %% interval, is an unbounded background full scan that finds nothing.
    %% Cleared on a real membership event so a topology change always
    %% re-sweeps once.
    swept = [] :: [bondy_oplog_origin:t()]
}).

%% =============================================================================
%% LIFECYCLE
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

%% =============================================================================
%% API
%% =============================================================================

-doc """
Runs one retirement cleanup pass in the CALLER's process:

1. Forget departed peers: every peer recorded in `bondy_oplog_peer_state`
   that is no longer a member is forgotten (node-keyed, local knowledge).
2. Reap-by-complement: query every current member for its origins
   (fail-closed), and reap the causal-context entries of the frontier
   origins nobody claims, from every local instance.
3. Replicate the retirement set: pull every member's set and union it in.
4. Frontier reaping: drop the applied-frontier entry of every origin that
   every member has retired — read fresh at reap time, fail-closed.

Returns `{ok, Report}` or a named `{error, Reason}` — callers MUST treat
any error as "nothing retired, retry later".
""".
-spec run() ->
    {ok, #{
        forgotten_peers := [term()],
        dead_origins := [bondy_oplog_origin:t()],
        origins_reaped := [bondy_oplog_origin:t()],
        retirements_learned := [bondy_oplog_origin:t()],
        frontiers_reaped := [bondy_oplog_origin:t()]
    }}
    | {error, term()}.

run() ->
    run([]).

-doc """
As `run/0`, but skips the cell scan for dead origins listed in `Swept` —
origins a previous pass on this node already reaped out of every cell
context. The returned report carries the updated `swept` set.

The scan is a FULL enumeration of every cell of every instance
(`bondy_oplog_cell_utils:member_cells/4`), and the candidate set is drawn
from the applied-frontier VVs, which only a retirement clears. Without
this, a single departed node makes every subsequent pass rescan the entire
projection, for the life of the node, to find nothing.
""".
-spec run(Swept :: [bondy_oplog_origin:t()]) ->
    {ok, #{
        forgotten_peers := [term()],
        dead_origins := [bondy_oplog_origin:t()],
        origins_reaped := [bondy_oplog_origin:t()],
        retirements_learned := [bondy_oplog_origin:t()],
        frontiers_reaped := [bondy_oplog_origin:t()],
        swept := [bondy_oplog_origin:t()]
    }}
    | {error, term()}.

run(Swept) ->
    case bondy_oplog_instance:reclamation_members() of
        error ->
            retirement_skipped(membership_unavailable);
        {ok, Members} ->
            Forgotten = forget_departed(Members),
            %% Replication runs FIRST and independently of the complement.
            %% The complement is fail-closed on every member answering
            %% `get_origins`; learning a retirement is not, and coupling
            %% them would mean a node that cannot compute the complement
            %% also never learns a retirement it was told about — one
            %% unreachable member stalling propagation across the cluster.
            Replication = replicate_and_reap(Members),
            case collect_member_origins(Members) of
                {error, Reason} ->
                    retirement_skipped(Reason, Replication);
                {ok, MemberOrigins} ->
                    reap_complement(
                        MemberOrigins, Forgotten, Swept, Replication
                    )
            end
    end.

-doc """
Retires every origin no current member claims — the operator act of
decommissioning, expressed once rather than origin by origin.

An origin is an opaque id with no node attribution, and a decommissioned
node is by definition unavailable to be asked which ones were its. This
closes that gap: it runs a pass, takes the complement (`dead_origins` —
origins present in this node's applied-frontier VVs that neither this node
nor any current member claims), and retires all of them. Retirement is
monotone and idempotent, so repeating it is free.

**Call this only after the departed node has been removed from the Partisan
membership, and only once the cluster has converged on that node's events.**
Retiring bans the origin cluster-wide, so any of its events a replica has
not yet applied become permanently unreachable to it. The complement is
computed fail-closed — every current member must answer, or nothing is
retired — but that is a check on WHO was asked, not on whether the data has
settled.

A partitioned node cannot retire the cluster out from under itself: Partisan
membership changes only by a deliberate join/leave, so an unreachable peer is
still a member, and a member that cannot answer aborts the complement.

**Run it with every instance up.** The complement is built from what nodes
advertise, and an instance that was never started — or was stopped by
`bondy_oplog:stop_instance/1`, which drops the registry row — does not
advertise its origin (see `local_origins/0`), so a LIVE origin can land in
the complement. For the automatic cell-context reap that costs causal
bookkeeping; here it would ban a live replica.

A brutally killed instance is not that case — its row survives, so its
origin is still advertised — but the call refuses while any exists
(`bondy_oplog_registry:down/0` non-empty, `{error, {instances_down, Ids}}`),
because an operator taking a permanent, irreversible action wants a node
that is whole. Neither check reaches a PEER that is under-advertising, which
is why the instruction stands as well as the check.

The origins retired are named in a NOTICE log, so a mistaken run is at
least auditable — but retirement cannot be undone.

Returns the origins retired (`[]` when there were none), or a named error
from the pass, which callers MUST treat as "nothing retired, retry later".
""".
-spec retire_dead() ->
    {ok, [bondy_oplog_origin:t()]}
    | {error, {instances_down, [instance_id()]} | term()}.

retire_dead() ->
    case bondy_oplog_registry:down() of
        [_ | _] = Down ->
            %% Refuse rather than warn. Retirement is permanent and bans the
            %% origin cluster-wide, so it is taken against a node that is
            %% whole — not one whose instances are mid-restart and whose
            %% frontier and cell contexts are therefore in motion.
            ?LOG_WARNING(#{
                description =>
                    "Refusing to retire dead origins: instances on this "
                    "node are down. Retirement is permanent and irreversible, "
                    "so it is taken with every instance running. Retry once "
                    "they are.",
                instances_down => Down
            }),
            {error, {instances_down, Down}};
        [] ->
            do_retire_dead()
    end.

%% @private
do_retire_dead() ->
    case run() of
        {error, _} = Error ->
            Error;
        {ok, #{dead_origins := Dead}} ->
            %% Already-retired origins stay in the complement — nothing
            %% claims them, and the frontier entry that made them a
            %% candidate survives until every member has the retirement. So
            %% filter here, and the answer means what it says: the origins
            %% THIS call retired.
            retire_each(
                [O || O <- Dead, not bondy_oplog_origin_bans:is_retired(O)], []
            )
    end.

-doc """
The origins this node claims: every REGISTERED instance's origin.

This is the node's authoritative half of the reap-by-complement contract —
what it advertises to peers via the responder's `get_origins` verb, and what
it subtracts locally.

Registered, not running. `bondy_oplog_registry:origins/0` includes an
instance whose process is momentarily dead, and deliberately so: the two
error directions are not symmetric. Over-advertising delays a peer's reap by
a pass. Under-advertising puts a LIVE origin into that peer's complement,
where `retire_dead/0` bans a running replica permanently, with no way back.
A supervisor restart is ordinary; a permanent ban is not.

KNOWN LIMITATION: an instance that is never started, or one stopped by
`bondy_oplog:stop_instance/1` (which drops the registry row), still does not
advertise its origin. The automatic pass only reaps causal-context entries,
which is value-preserving, but `retire_dead/0` bans — which is why it is an
operator act with an explicit "run it with every instance up" contract, and
why it refuses while `bondy_oplog_registry:down/0` is non-empty.
""".
-spec local_origins() -> [bondy_oplog_origin:t()].

local_origins() ->
    bondy_oplog_registry:origins().

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init([]) ->
    process_flag(trap_exit, true),
    Enabled = bondy_oplog_config:origin_retirement_enabled(),
    Enabled andalso
        begin
            ok = subscribe_membership(),
            %% Boot-time reconcile: a membership removal that happened while
            %% this node was down produces no event, so catch up now.
            gen_server:cast(?MODULE, membership_update),
            %% Periodic pass: origin-epoch turnover WITHOUT a membership
            %% change (e.g. a K8s pod that loses its volume and rejoins under
            %% the same name) fires no event anywhere else in the cluster.
            %% Idempotent + fail-closed, so the tick is safe by construction.
            schedule_periodic()
        end,
    {ok, #state{enabled = Enabled, worker = undefined}}.

handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(membership_update, #state{enabled = false} = State) ->
    {noreply, State};
handle_cast(membership_update, #state{worker = Pid} = State) when
    is_pid(Pid)
->
    %% A run is in flight; run once more when it finishes rather than
    %% stacking workers.
    {noreply, State#state{pending = true}};
handle_cast(membership_update, State) ->
    Owner = self(),
    Swept = State#state.swept,
    {Pid, _Ref} = spawn_monitor(fun() ->
        case run(Swept) of
            {ok, #{swept := S}} -> gen_server:cast(Owner, {swept, S});
            _ -> ok
        end
    end),
    {noreply, State#state{worker = Pid, pending = false}};
handle_cast({swept, Swept}, State) ->
    {noreply, State#state{swept = Swept}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, Reason}, #state{worker = Pid} = State) ->
    Reason =:= normal orelse
        ?LOG_WARNING(#{
            description => "origin retirement worker exited abnormally",
            reason => Reason
        }),
    State#state.pending andalso gen_server:cast(?MODULE, membership_update),
    {noreply, State#state{worker = undefined, pending = false}};
handle_info({partisan_membership, _Members}, State0) ->
    %% A real topology change re-sweeps from scratch: an origin already
    %% swept could have gained a context entry from a late delivery, and a
    %% membership event is rare enough that one full pass is the right
    %% price for not having to reason about that.
    State = State0#state{swept = []},
    %% A membership change pushed by Partisan. The payload is ignored (see
    %% subscribe_membership/0); the single-flight worker re-reads the current
    %% member set itself. The periodic tick is the safety net if a push is ever
    %% missed (e.g. the subscription is dropped without this process dying).
    State#state.enabled andalso gen_server:cast(?MODULE, membership_update),
    {noreply, State};
handle_info(retirement_tick, State) ->
    State#state.enabled andalso
        begin
            gen_server:cast(?MODULE, membership_update),
            schedule_periodic()
        end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Stops at the first failure and reports what was already retired: a
%% partial retirement is sound (the set only grows, and every replica unions
%% it) but the caller must know the rest did not happen.
retire_each([], []) ->
    {ok, []};
retire_each([], Acc) ->
    Retired = lists:reverse(Acc),
    ?LOG_NOTICE(#{
        description =>
            "Retired the origins no current member claims. This is "
            "permanent: these origins are now banned on this node, the "
            "decision replicates to the rest of the cluster, and their "
            "applied-frontier entries are dropped once every member holds "
            "it.",
        origins => Retired
    }),
    {ok, Retired};
retire_each([Origin | Rest], Acc) ->
    case bondy_oplog_origin_bans:retire(Origin, decommissioned) of
        ok ->
            retire_each(Rest, [Origin | Acc]);
        {error, Reason} ->
            {error, {retire_failed, Origin, Reason, lists:reverse(Acc)}}
    end.

%% @private
schedule_periodic() ->
    _ = erlang:send_after(
        bondy_oplog_config:origin_retirement_interval_ms(),
        self(),
        retirement_tick
    ),
    ok.

%% @private
%% Subscribe this process to Partisan membership-change notifications; each
%% change is delivered as a `{partisan_membership, Members}` message (handled in
%% handle_info/2). The payload is ignored on purpose: the worker re-reads the
%% member set from `bondy_oplog_instance:reclamation_members/0` itself, so a
%% stale or representation-specific payload can never drive a cleanup.
subscribe_membership() ->
    partisan_membership:subscribe().

%% @private
%% Forget every recorded peer that is no longer a member. Node-keyed and
%% purely local: `peer_state` only knows peers this node synced with. Only
%% ATOM peers are considered — the Partisan peer namespace — so inline/test
%% transports' instance-id (binary) or tuple peer ids are never judged
%% against a node membership they are not part of.
forget_departed(Members) ->
    Keep = [partisan:node() | Members],
    Known = lists:usort(
        lists:append([
            bondy_oplog_peer_state:get_known_peers(I, 0)
         || I <- bondy_oplog:list_instances()
        ])
    ),
    Departed = [
        P
     || P <- Known, is_atom(P), not lists:member(P, Keep)
    ],
    lists:foreach(
        fun(P) -> bondy_oplog_peer_state:forget_peer(P) end, Departed
    ),
    Departed.

%% @private
%% Every member must answer, or the pass aborts — a sample of the membership
%% licenses nothing: an origin missing from half the cluster's answers is
%% not unclaimed, only unasked. `[]` members ⇒ solo ⇒ nothing to ask.
collect_member_origins([]) ->
    {ok, []};
collect_member_origins(Members) ->
    case bondy_oplog:list_instances() of
        [] ->
            %% No local instances ⇒ no frontiers ⇒ nothing to reap.
            {ok, []};
        [AnyInstance | _] ->
            {Transport, TOpts} = transport_config(),
            collect_member_origins(
                Members, AnyInstance, Transport, TOpts, []
            )
    end.

%% @private
collect_member_origins([], _I, _T, _TOpts, Acc) ->
    {ok, lists:usort(Acc)};
collect_member_origins([M | Rest], I, Transport, TOpts, Acc) ->
    try Transport:request(M, I, get_origins, TOpts) of
        {ok, Origins} when is_list(Origins) ->
            collect_member_origins(Rest, I, Transport, TOpts, Origins ++ Acc);
        Other ->
            {error, {member_unreachable, M, Other}}
    catch
        Class:Reason ->
            {error, {member_unreachable, M, {Class, Reason}}}
    end.

%% @private
reap_complement(MemberOrigins, Forgotten, Swept, Replication) ->
    Live = lists:usort(MemberOrigins ++ local_origins()),
    Dead = [O || O <- frontier_origins(), not lists:member(O, Live)],
    %% Only origins this node has not already swept out of every cell
    %% context drive a scan; the rest are dead candidates whose contexts
    %% are known clean.
    Unswept = [O || O <- Dead, not lists:member(O, Swept)],
    Targets =
        case Unswept of
            [] -> [];
            _ -> bondy_oplog:list_instances()
        end,
    Reaped = lists:usort(
        lists:append([reap_instance(I, Unswept) || I <- Targets])
    ),
    %% Everything scanned this pass is now known clean, whether or not it
    %% had anything to remove — that is precisely what makes the next pass
    %% cheap.
    Swept1 = lists:usort(Swept ++ Unswept),
    #{reaped := FrontiersReaped, learned := Learned} = Replication,
    telemetry:execute(
        [bondy_oplog, retirement, completed],
        #{
            dead_origins => length(Dead),
            origins_reaped => length(Reaped),
            origins_scanned => length(Unswept),
            retirements_learned => length(Learned),
            frontiers_reaped => length(FrontiersReaped)
        },
        #{forgotten_peers => Forgotten}
    ),
    case Reaped of
        [] ->
            %% The steady state, not an anomaly: `Dead` is drawn from the
            %% applied-frontier VVs, which this pass does NOT reap (see
            %% `frontier_origins/0`), so a dead origin remains a candidate
            %% on every pass forever while its cell contexts are already
            %% clean. Reporting that as a reap once per interval, for the
            %% life of the node, is how a quiet steady state gets mistaken
            %% for a leak.
            ?LOG_DEBUG(#{
                description =>
                    "Origin retirement pass found no causal-context "
                    "entries to reap.",
                dead_origins => length(Dead),
                forgotten_peers => Forgotten
            });
        _ ->
            ?LOG_NOTICE(#{
                description =>
                    "Origin retirement pass reaped dead origins (origins "
                    "in the frontier claimed by no current member).",
                dead_origins => length(Dead),
                origins_reaped => length(Reaped),
                forgotten_peers => Forgotten
            })
    end,
    {ok, #{
        forgotten_peers => Forgotten,
        dead_origins => Dead,
        origins_reaped => Reaped,
        retirements_learned => Learned,
        frontiers_reaped => FrontiersReaped,
        swept => Swept1
    }}.

%% @private
%% RETIREMENT REPLICATION + FRONTIER REAPING. One round trip per member
%% serves both, but they consume it differently, and that difference is the
%% whole point:
%%
%% - LEARNING unions whatever came back. The set is grow-only, so a union
%%   from a subset of members is monotone and cannot be wrong — it is the
%%   model's `Propagate(r, p)`, a single-peer union, applied to each member
%%   that answered. Refusing to learn because a THIRD member was unreachable
%%   would stall propagation cluster-wide on one flaky node, and buy nothing.
%% - REAPING requires every member to have answered AND every answer to
%%   contain the origin — the model's `ReapGuard` "universal" branch, where
%%   the quantifier ranges over all members. A member that did not answer
%%   has not agreed; it may still need the deficit signal.
%%
%% Fail-closed applies to the reap alone: no persistence, no local
%% instances, or any member unheard from reaps nothing this pass.
replicate_and_reap([]) ->
    %% Solo. A frontier entry is a CLAIM compared against peers, and
    %% solitude now says nothing about the peers this node will have later:
    %% a one-node cluster that grows again meets a peer still advertising
    %% the entry, and reads its own reaped 0 as a deficit. So solo licenses
    %% nothing here, unlike projection-cell reclamation.
    #{reaped => [], learned => []};
replicate_and_reap(Members) ->
    %% Persistence is a precondition for participating in retirement at
    %% all: a node that would forget the set on restart re-learns the
    %% entries it reaped from a peer and then reads its own absence as a
    %% deficit, and an in-memory ban it forgets flaps the origin's fence.
    case
        {bondy_oplog_origin_bans:is_persistent(), bondy_oplog:list_instances()}
    of
        {false, _} ->
            #{reaped => [], learned => []};
        {true, []} ->
            %% No instances ⇒ no frontier to reap, and no instance id with
            %% which to address a member.
            #{reaped => [], learned => []};
        {true, [Any | _] = Instances} ->
            {Answers, Unheard} = member_retired(Members, Any),
            %% Union BEFORE the gate, and in that order: the reap consults
            %% this node's own set as well as the members' answers, so an
            %% origin the cluster has retired but this node has only just
            %% heard of is reapable in the same pass rather than the next.
            Learned = learn_retirements(Answers),
            Reaped =
                case Unheard of
                    [] ->
                        reap_frontiers(universal(Answers), Instances);
                    _ ->
                        ?LOG_DEBUG(#{
                            description =>
                                "Frontier reap skipped: a member's "
                                "retirement set could not be read. Anything "
                                "the members that DID answer hold has still "
                                "been learned.",
                            unheard => Unheard
                        }),
                        []
                end,
            #{learned => Learned, reaped => Reaped}
    end.

%% @private
%% Asks every member for its retirement set and reports both halves: the
%% answers, and the members that did not give one. Never aborts on the first
%% failure — the answers already collected are exactly what learning needs.
member_retired(Members, InstanceId) ->
    {Transport, TOpts} = transport_config(),
    lists:foldr(
        fun(M, {Answers, Unheard}) ->
            case member_retired(M, InstanceId, Transport, TOpts) of
                {ok, Origins} -> {[Origins | Answers], Unheard};
                {error, Reason} -> {Answers, [{M, Reason} | Unheard]}
            end
        end,
        {[], []},
        Members
    ).

%% @private
member_retired(M, I, Transport, TOpts) ->
    try Transport:request(M, I, get_retired, TOpts) of
        {ok, Origins} when is_list(Origins) ->
            {ok, Origins};
        Other ->
            {error, {member_unreachable, Other}}
    catch
        Class:Reason ->
            {error, {member_unreachable, {Class, Reason}}}
    end.

%% @private
%% The replication half of the grow-only set: union in whatever the members
%% hold. Monotone, so applying peers' sets in any order any number of times
%% converges, and a member that was unreachable this pass costs nothing but
%% a delay.
learn_retirements(PeerSets) ->
    case
        lists:usort(lists:append(PeerSets)) -- bondy_oplog_origin_bans:retired()
    of
        [] ->
            [];
        New ->
            case bondy_oplog_origin_bans:merge_retired(New) of
                ok ->
                    ?LOG_NOTICE(#{
                        description =>
                            "Learned origin retirements from cluster "
                            "members.",
                        origins => New
                    }),
                    New;
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        description =>
                            "Could not record origin retirements learned "
                            "from cluster members; retried next pass.",
                        origins => New,
                        reason => Reason
                    }),
                    []
            end
    end.

%% @private
%% The origins EVERY member holds as retired — the reap's licence. An
%% origin only some members have retired is one the others still expect a
%% deficit signal about. Only ever called with an answer from every member
%% (see `replicate_and_reap/1`); `[]` licenses nothing, which is what makes
%% that precondition safe to state rather than assume.
%% `universal_is_the_intersection_of_member_sets/0` covers the empty list,
%% a member with an empty set, and disjoint answers.
universal([]) ->
    [];
universal([First | Rest]) ->
    lists:foldl(
        fun(Set, Acc) -> ordsets:intersection(Acc, ordsets:from_list(Set)) end,
        ordsets:from_list(First),
        Rest
    ).

%% @private
reap_frontiers([], _Instances) ->
    [];
reap_frontiers(Universal, Instances) ->
    lists:append([
        reap_instance_frontier(I, Universal)
     || I <- Instances
    ]).

%% @private
reap_instance_frontier(InstanceId, Universal) ->
    Local = bondy_oplog_instance:frontier(InstanceId),
    %% The local set is consulted too, so a failed `merge_retired/1` cannot
    %% make this node reap an origin it does not itself refuse events from.
    case
        [
            O
         || O <- Universal,
            is_map_key(O, Local),
            bondy_oplog_origin_bans:is_retired(O)
        ]
    of
        [] ->
            [];
        Candidates ->
            ok = report_unconverged(InstanceId, Candidates, Local),
            bondy_oplog_registry:reap_frontier(InstanceId, Candidates)
    end.

%% @private
%% Level-ness is REPORTED, not required — requiring it would stop the reap
%% after the first replica (see the moduledoc). A peer that still carries the
%% entry at a different sequence means the origin was retired before the
%% cluster converged on its events, and the ban has frozen that difference
%% permanently: this is the operator's one chance to see it.
%%
%% Read from `bondy_oplog_peer_state` — a local ETS lookup of each peer's
%% vector as observed at its last completed round — rather than over the
%% transport. As the reap's GATE that snapshot would be unsound (a dead
%% origin's events keep propagating between rounds), but as a diagnostic it
%% costs nothing, whereas a fresh read would be one drain-barriered
%% `get_frontier` per member per shard on the pass that follows a
%% decommission. Being a snapshot, it can name a divergence a peer has since
%% closed, and can miss one opened after its last round. Unfiltered by
%% recency on purpose: a silent peer is exactly the one likely to be behind.
report_unconverged(InstanceId, Candidates, Local) ->
    Peers = [
        {P, F}
     || #{peer := P, frontier := F} <-
            bondy_oplog_peer_state:get_instance_peer_states(InstanceId, 0),
        is_map(F)
    ],
    Unconverged = [
        #{
            origin => O,
            local => maps:get(O, Local, 0),
            member => M,
            peer => maps:get(O, F, 0)
        }
     || O <- Candidates,
        {M, F} <- Peers,
        is_map_key(O, F),
        maps:get(O, F) =/= maps:get(O, Local, 0)
    ],
    Unconverged =/= [] andalso
        begin
            telemetry:execute(
                [bondy_oplog, retirement, reaped_unconverged],
                #{count => length(Unconverged)},
                #{instance_id => InstanceId}
            ),
            ?LOG_WARNING(#{
                description =>
                    "Reaped the frontier entry of a retired origin whose "
                    "sequence differs across members: the origin was "
                    "retired before the cluster had converged on its "
                    "events, and the ban has frozen that difference "
                    "permanently. Retire an origin only once its events "
                    "have converged.",
                instance_id => InstanceId,
                divergence => Unconverged
            })
        end,
    ok.

%% @private
reap_instance(InstanceId, Dead) ->
    case bondy_oplog_instance:reap_origins(InstanceId, Dead) of
        {ok, #{origins_reaped := Origins}} ->
            Origins;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "origin retirement reap failed for instance; retried "
                    "on the next membership event",
                instance_id => InstanceId,
                reason => Reason
            }),
            []
    end.

%% @private
%% Union of origin ids across every local instance's applied-frontier VV.
%% This is the CANDIDATE population for the CELL-CONTEXT reap, which acts on
%% tier_2 causal contexts and leaves the frontier alone — only a retirement
%% clears a frontier entry. So a candidate whose contexts are already clean
%% is reported dead on every pass and reaped by none of them, until the
%% operator retires it.
frontier_origins() ->
    lists:usort(
        lists:append([
            maps:keys(bondy_oplog_instance:frontier(I))
         || I <- bondy_oplog:list_instances()
        ])
    ).

%% @private
%% The complement half could not run. Retirement replication is reported
%% anyway — it is independent of the complement and may well have succeeded,
%% and silently dropping what it learned is how a "skipped" pass turns into
%% a cluster that never converges on its retirement set.
retirement_skipped(Reason, #{learned := Learned, reaped := Reaped}) ->
    telemetry:execute(
        [bondy_oplog, retirement, skipped],
        #{
            count => 1,
            retirements_learned => length(Learned),
            frontiers_reaped => length(Reaped)
        },
        #{reason => Reason}
    ),
    {error, Reason}.

%% @private
%% Same measurement KEYS as the two-argument form, zeroed: one event name
%% with two shapes is how a dashboard panel ends up intermittently empty.
%% This clause is the pass that aborted before replication could run.
retirement_skipped(Reason) ->
    retirement_skipped(Reason, #{learned => [], reaped => []}).

%% @private
%% Same transport source as AAE (`sync_session_opts`). With the default
%% inline transport a remote member cannot be addressed and the pass aborts
%% — fail-closed by construction.
transport_config() ->
    Opts = application:get_env(bondy_oplog, sync_session_opts, #{}),
    {
        maps:get(transport, Opts, bondy_oplog_transport_inline),
        maps:get(transport_opts, Opts, #{})
    }.
