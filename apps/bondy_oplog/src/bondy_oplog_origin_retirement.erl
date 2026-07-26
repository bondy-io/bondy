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
Origin retirement — the auto-reacting cleanup that follows a deliberate
Partisan membership removal (`BONDY_DB_RECLAMATION_PLAN.md` Step 7).

## The division of labour

**Partisan membership is the replicated authority.** A node leaves the
stability set the moment it is removed from the membership — a deliberate
join/leave act, never a timeout — and `bondy_oplog_instance:
reclamation_members/0` observes that directly. Nothing here decides WHO is
retired; this module only reacts to a membership the cluster has already
agreed on.

**This module owns the node-local cleanup** that should follow: forgetting
departed peers from `bondy_oplog_peer_state`, and reaping dead origins'
causal-context entries from tier_2 cell states (`reap_origins`). Both are
node-local acts driven by the replicated membership signal, so node-local
state is sufficient — no retirement table is replicated.

## Reap-by-complement

An origin is an opaque state-epoch identity with no node attribution, so
survivors cannot attribute a dead node's origins after the fact. Instead of
tracking dead origins, the reaper asks the LIVE members for theirs — the one
mapping each node authoritatively owns — over the sync transport
(`get_origins`), and computes:

    dead = origins in local frontier VVs
           − (own origins ∪ union of every member's advertised origins)

**Fail-closed**: if ANY current member cannot be queried the pass aborts and
retries on the next membership event — the same strictness discipline as
`confirmed_peer_states/2`. A bonus of the complement: origins of nodes that
departed before this subsystem existed (or of pre-wipe incarnations, or of
ephemeral VM boots) are unclaimed by construction and get reaped too.

## What is deliberately NOT done

No automatic bans. Banning a live origin makes this node silently refuse its
remote appends — permanent divergence — and the complement can over-claim if
a member under-advertises (see `local_origins/0`). The membership plane gate
already refuses connections from non-members, which fences a departed node's
late appends; `bondy_oplog_origin_bans` stays an operator tool.

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
-export([local_origins/0]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-record(state, {
    enabled :: boolean(),
    %% Single-flight cleanup worker; a membership event during a run sets
    %% `pending` and the run is repeated once the worker exits.
    worker :: undefined | pid(),
    pending = false :: boolean()
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
   (fail-closed), and reap the frontier origins nobody claims from every
   local instance.

Returns `{ok, Report}` or a named `{error, Reason}` — callers MUST treat
any error as "nothing retired, retry later".
""".
-spec run() ->
    {ok, #{
        forgotten_peers := [term()],
        dead_origins := [bondy_oplog_origin:t()],
        origins_reaped := [bondy_oplog_origin:t()]
    }}
    | {error, term()}.

run() ->
    case bondy_oplog_instance:reclamation_members() of
        error ->
            retirement_skipped(membership_unavailable);
        {ok, Members} ->
            Forgotten = forget_departed(Members),
            case collect_member_origins(Members) of
                {error, Reason} ->
                    retirement_skipped(Reason);
                {ok, MemberOrigins} ->
                    reap_complement(MemberOrigins, Forgotten)
            end
    end.

-doc """
The origins this node currently claims: every running instance's origin.

This is the node's authoritative half of the reap-by-complement contract —
it is what this node advertises to peers via the responder's `get_origins`
verb, and what it subtracts locally. KNOWN LIMITATION: a durable instance
that is STOPPED while a peer runs its complement pass does not advertise its
origin and can have its causal-context entries reaped. The reap is
value-preserving and bans are never issued automatically, so the blast
radius is causal bookkeeping, not data — but keep instances supervised (the
production shape) if origins must never be under-advertised.
""".
-spec local_origins() -> [bondy_oplog_origin:t()].

local_origins() ->
    lists:usort(
        lists:filtermap(
            fun(I) ->
                case bondy_oplog_instance:lookup_origin(I) of
                    {ok, Origin} -> {true, Origin};
                    not_found -> false
                end
            end,
            bondy_oplog:list_instances()
        )
    ).

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
    {Pid, _Ref} = spawn_monitor(fun() -> _ = run() end),
    {noreply, State#state{worker = Pid, pending = false}};
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
handle_info({partisan_membership, _Members}, State) ->
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
%% licenses nothing (proof A4). `[]` members ⇒ solo ⇒ nothing to ask.
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
reap_complement(MemberOrigins, Forgotten) ->
    Live = lists:usort(MemberOrigins ++ local_origins()),
    Dead = [O || O <- frontier_origins(), not lists:member(O, Live)],
    Targets =
        case Dead of
            [] -> [];
            _ -> bondy_oplog:list_instances()
        end,
    Reaped = lists:usort(
        lists:append([reap_instance(I, Dead) || I <- Targets])
    ),
    telemetry:execute(
        [bondy_oplog, retirement, completed],
        #{dead_origins => length(Dead), origins_reaped => length(Reaped)},
        #{forgotten_peers => Forgotten}
    ),
    Dead =/= [] andalso
        ?LOG_NOTICE(#{
            description =>
                "Origin retirement pass reaped dead origins (origins in "
                "the frontier claimed by no current member).",
            dead_origins => length(Dead),
            origins_reaped => length(Reaped),
            forgotten_peers => Forgotten
        }),
    {ok, #{
        forgotten_peers => Forgotten,
        dead_origins => Dead,
        origins_reaped => Reaped
    }}.

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
frontier_origins() ->
    lists:usort(
        lists:append([
            maps:keys(bondy_oplog_instance:frontier(I))
         || I <- bondy_oplog:list_instances()
        ])
    ).

%% @private
retirement_skipped(Reason) ->
    telemetry:execute(
        [bondy_oplog, retirement, skipped],
        #{count => 1},
        #{reason => Reason}
    ),
    {error, Reason}.

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
