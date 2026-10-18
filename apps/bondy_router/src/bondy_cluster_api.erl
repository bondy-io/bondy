%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_cluster_api).
-moduledoc """
`bondy_wamp_api` implementation exposing cluster operations as WAMP
procedures: `bondy.cluster.{members,connections,info,leave}`. On a standalone
node (`bondy_cluster:enabled/0` is `false`) `leave` answers
`bondy.error.cluster_disabled` and changes nothing
(`bondy_cluster_standalone_SUITE`).

## Membership is the reclamation authority

Removing a node from the Partisan membership is not only a routing change. It
is what releases the rest of the cluster from waiting on that node:
`bondy_oplog_instance:reclamation_members/0` is
`bondy_cluster:members/0` minus this node, and
`bondy_oplog_origin_retirement` subscribes to membership and reaps, by
complement, every origin no live member claims. So a departed node that stays
in the membership stalls reclamation, and removing it is what unstalls it.

That direction is worth stating because it is the opposite of what it looks
like. `leave` does not risk stalling reclamation; it is the act reclamation
waits for.

## Why `leave` is graded destructive

The same mechanism is what makes it irreversible. Once a node is out of the
membership, the reaper may reap its origins, and a node returning under the
same name is handed a NEW origin epoch — its former history is then foreign
and its frontier entries are gone. `leave` is therefore not a pause; it is a
decommission, and `bondy_task_catalogue` grades it `destructive` for that
reason rather than because of anything the call itself writes.

## The precondition, and what it does not cover

Reap-by-complement asks every live member which origins it holds and reaps
what nobody claims. It is fail-closed on a member that cannot be asked. The
gap it cannot close by itself is a member that IS reachable but is
under-advertising — one whose oplog instances have not all registered — whose
live origins can then land in the complement and be banned.

So this module surveys every remaining member before removing anyone, and
refuses when a member is unreachable or reports itself not ready. It also
reports each member's registered oplog instance count, because a member with
fewer than its peers is the under-advertising case, and that skew is a
judgement for the operator rather than something this module infers: a cluster
may be heterogeneous by design, and refusing on a count difference would be a
guess. Run the dry run first and read the counts.

## Master realm only

Every procedure here goes through `bondy_wamp_api_utils:admin_call_args/3`.
`bondy.*` is dispatched statically, so without that gate a URI resolves in ANY
realm and only the absence of an RBAC grant stands between a tenant session and
it. `info` needs it most: it answers `node_spec()`, which carries the node's
listen addresses and ports.

The set is pinned by `bondy_cluster_api_SUITE:procedures/0`, which DECLARES
each procedure's authority and is checked against the URIs `handle_call/3`
actually dispatches. A procedure added without an entry fails the suite rather
than shipping ungated.

`bondy.cluster.join` remains unimplemented. Partisan needs a full
`node_spec()` — name, listen addresses and channels — which is more than a
procedure argument conveys well, and the peer-discovery configuration already
covers forming and growing a cluster.
""".
-behaviour(bondy_wamp_api).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

%% Total budget for the pre-leave survey. A member that has not answered by
%% then is treated as unreachable, which refuses the leave — the safe
%% direction, and the same rule the reaper applies to its own fan-out.
-define(SURVEY_TIMEOUT, 5000).

-export([handle_call/3]).

%% The survey's fan-out target, called on every remaining member.
-export([local_readiness/0]).

%% The safety predicate, exported so it can be exercised directly: its
%% interesting outcomes need peers that are silent or not ready, which a
%% single-node suite cannot produce through `handle_call/3`.
-export([survey/1]).
-export([survey/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()
) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}
    | no_return().

handle_call(?BONDY_CLUSTER_JOIN, #call{} = M, _Ctxt) ->
    %% Unimplemented, and stated as such in the moduledoc: joining needs a
    %% full `node_spec()`, and peer discovery already forms clusters.
    R = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, R};
handle_call(?BONDY_CLUSTER_LEAVE, #call{} = M, Ctxt) ->
    %% Arity 1 even for removing THIS node. Naming the target is the point of
    %% the call, and it also sidesteps the meta API's missing-argument
    %% convention, which substitutes the session's realm URI for an omitted
    %% first argument — a value that matches no member and is refused below.
    [Name] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),
    {reply, leave(M, Name)};
handle_call(?BONDY_CLUSTER_CONNECTIONS, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 0),
    Conns = bondy_cluster:connections(),
    Result = #{
        ~"node" => nodestring(partisan:node()),
        ~"connections" => [connection(C) || C <- Conns]
    },
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
    {reply, R};
handle_call(?BONDY_CLUSTER_MEMBERS, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 0),
    R = bondy_wamp_message:result(M#call.request_id, #{}, [
        bondy_cluster:members()
    ]),
    {reply, R};
handle_call(?BONDY_CLUSTER_INFO, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 0),
    Info = #{
        <<"node_spec">> => bondy_wamp_api_utils:node_spec(),
        <<"nodes">> => partisan:nodes()
    },
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Info]),
    {reply, R};
handle_call(_, #call{} = M, _) ->
    R = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, R}.

-doc """
This node's readiness and its registered oplog instance count, tagged with its
name.

The fan-out target of the pre-leave survey. Tagged rather than positional so a
reply carries its own provenance, and so a member that answers with an
unexpected name cannot be mistaken for one that was asked.

It raises when the oplog registry table is gone. The survey then counts the
member as silent, which makes a leave unsafe.
""".
-spec local_readiness() -> {node(), boolean(), non_neg_integer()}.

local_readiness() ->
    Instances = length(bondy_oplog:list_instances()),
    {partisan:node(), bondy_router_app:is_ready(), Instances}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
leave(#call{} = M, Name) when is_binary(Name) ->
    case bondy_cluster:enabled() of
        true -> leave_member(M, Name);
        false -> bondy_wamp_api_utils:error(cluster_disabled, M)
    end;
leave(#call{} = M, _) ->
    bondy_wamp_api_utils:error({invalid_value, ~"node"}, M).

%% @private
leave_member(#call{} = M, Name) ->
    case member(Name) of
        error ->
            bondy_wamp_api_utils:error(
                {not_a_member, Name}, M
            );
        {ok, Node} ->
            Remaining = remaining_members(Name),
            %% The survey is the only wait on this path, so the caller's
            %% `_deadline` bounds it and nothing else. Shortening it cannot
            %% make a leave WRONGLY safe: an unanswered member is silent, and
            %% a silent member is unsafe.
            Budget = bondy_wamp_api_utils:budget(
                bondy_wamp_api_utils:deadline(M#call.options), ?SURVEY_TIMEOUT
            ),
            Survey = survey(Remaining, Budget),
            do_leave(M, Name, Node, Survey)
    end.

%% @private
%% The dry run reports the survey and stops; the real call refuses on an
%% unsafe survey and otherwise performs the Partisan removal.
do_leave(#call{} = M, Name, Node, Survey) ->
    case bondy_wamp_api_utils:dry_run(M) of
        true ->
            bondy_wamp_api_utils:dry_run_result(
                M, would(Name, Survey), render_survey(Name, Survey)
            );
        false ->
            case Survey of
                #{safe := true} ->
                    ok = bondy_cluster:leave(Node),
                    ?LOG_NOTICE(#{
                        description => "Node removed from the cluster",
                        node => Name,
                        survey => render_survey(Name, Survey)
                    }),
                    bondy_wamp_message:result(
                        M#call.request_id, #{}, [render_survey(Name, Survey)]
                    );
                #{} ->
                    bondy_wamp_api_utils:error(
                        {unsafe_to_leave, unsafe_reason(Survey)}, M
                    )
            end
    end.

%% @private
%% Every member that will remain once `Name` is gone. The leaving node is
%% excluded because it is not one of the replicas whose advertisement the
%% reaper will consult afterwards, and this node is excluded because it is
%% answering.
remaining_members(Name) ->
    bondy_cluster:members() -- [partisan:node(), binary_to_atom(Name, utf8)].

-doc """
Asks every remaining member whether it is ready and how many oplog instances
it has registered, and decides whether removing a node is safe.

`safe` is `false` when any member is SILENT (did not answer within the survey
budget) or reports itself NOT READY. Both are the same hazard seen from two
sides: the retirement pass that follows a membership removal reaps origins no
live member claims, is fail-closed on a member it cannot ask, and cannot tell
a member that is up but under-advertising from one that has genuinely
relinquished its origins.

The reply also carries each member's registered oplog instance count. A member
with fewer than its peers is the under-advertising case, and that is reported
rather than enforced: a cluster may be heterogeneous by design, so refusing on
a count difference would be a guess.
""".
-spec survey([node()]) -> map().

%% @private
%% Asks every remaining member whether it is ready and how many oplog
%% instances it has registered. A member that does not answer is `silent`,
%% and any silent or not-ready member makes the leave unsafe: the reaper that
%% runs after the removal is fail-closed on a member it cannot ask, and a
%% member that is up but not fully started is the under-advertising case the
%% moduledoc names.
survey(Peers) ->
    survey(Peers, ?SURVEY_TIMEOUT).

-doc """
The survey, bounded by `Budget` milliseconds rather than by `?SURVEY_TIMEOUT`.

`0` means the caller's `_deadline` is already spent. Nobody is asked, and every
member is reported SILENT — which makes the leave unsafe. That is the only
answer a spent budget can honestly give: the reaper that follows a removal is
fail-closed on a member it could not ask, so a survey that ran out of time and
said `safe` would be asserting exactly what it failed to check.
""".
-spec survey([node()], non_neg_integer()) -> map().

survey([], _Budget) ->
    #{safe => true, answered => [], silent => [], not_ready => []};
survey(Peers, 0) ->
    #{safe => false, answered => [], silent => Peers, not_ready => []};
survey(Peers, Budget) ->
    Replies =
        try
            {R, _BadNodes} = bondy_cluster:multicall(
                Peers, ?MODULE, local_readiness, [], Budget
            ),
            R
        catch
            %% `partisan_erpc:multicall/5` raises this when a request cannot
            %% be sent. Every peer then reads as silent.
            error:{partisan_erpc, badarg} -> []
        end,
    Known = [
        {N, Ready, Count}
     || {N, Ready, Count} <- Replies, lists:member(N, Peers)
    ],
    Answered = [N || {N, _, _} <- Known],
    NotReady = [N || {N, false, _} <- Known],
    #{
        safe => (Peers -- Answered) == [] andalso NotReady == [],
        answered => Known,
        silent => Peers -- Answered,
        not_ready => NotReady
    }.

%% @private
would(Name, #{safe := true}) ->
    <<
        "Remove ",
        Name/binary,
        " from the cluster membership. Its origins become unclaimed, so the "
        "retirement pass may reap them and a node rejoining under this name "
        "is handed a new origin."
    >>;
would(Name, #{}) ->
    <<
        "Refuse to remove ",
        Name/binary,
        ": at least one remaining member is silent or not ready."
    >>.

%% @private
render_survey(Name, #{
    safe := Safe, answered := Answered, silent := Silent, not_ready := NotReady
}) ->
    #{
        ~"node" => Name,
        ~"safe" => Safe,
        ~"members" => [
            #{
                ~"node" => nodestring(N),
                ~"ready" => Ready,
                ~"oplog_instances" => Count
            }
         || {N, Ready, Count} <- Answered
        ],
        ~"silent" => [nodestring(N) || N <- Silent],
        ~"not_ready" => [nodestring(N) || N <- NotReady]
    }.

%% @private
unsafe_reason(#{silent := [_ | _] = Silent}) ->
    {members_silent, [nodestring(N) || N <- Silent]};
unsafe_reason(#{not_ready := [_ | _] = NotReady}) ->
    {members_not_ready, [nodestring(N) || N <- NotReady]}.

%% @private
member(Name) ->
    try binary_to_existing_atom(Name, utf8) of
        Node ->
            case lists:member(Node, bondy_cluster:members()) of
                true -> {ok, Node};
                false -> error
            end
    catch
        %% An atom nobody has ever created cannot be a member, and creating
        %% one from caller input would be a leak.
        error:badarg -> error
    end.

%% @private
connection(#{node := Node, channel := Channel, listen_addr := Addr}) ->
    #{
        ~"node" => nodestring(Node),
        ~"channel" => atom_to_binary(Channel, utf8),
        ~"listen_addr" => listen_addr(Addr)
    }.

%% @private
listen_addr(#{ip := IP, port := Port}) ->
    #{~"ip" => list_to_binary(inet:ntoa(IP)), ~"port" => Port};
listen_addr(undefined) ->
    null.

%% @private
nodestring(Node) when is_atom(Node) ->
    atom_to_binary(Node, utf8).
