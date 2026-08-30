%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_cluster_api).
-moduledoc """
`bondy_wamp_api` implementation exposing cluster operations as WAMP
procedures: `bondy.cluster.{members,connections,info,leave}`.

## Membership is the reclamation authority

Removing a node from the Partisan membership is not only a routing change. It
is what releases the rest of the cluster from waiting on that node:
`bondy_oplog_instance:reclamation_members/0` is
`partisan_peer_service:members/0` minus this node, and
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
    {ok, Conns} = partisan_peer_service:connections(),
    Result = #{
        ~"node" => nodestring(partisan:node()),
        ~"connections" => [connection(C) || C <- Conns]
    },
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Result]),
    {reply, R};
handle_call(?BONDY_CLUSTER_MEMBERS, #call{} = M, _Ctxt) ->
    {ok, Members} = partisan_peer_service:members(),
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Members]),
    {reply, R};
handle_call(?BONDY_CLUSTER_INFO, #call{} = M, _Ctxt) ->
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
""".
-spec local_readiness() -> {node(), boolean(), non_neg_integer()}.

local_readiness() ->
    Instances =
        try length(bondy_oplog:list_instances()) of
            N -> N
        catch
            _:_ -> 0
        end,
    {partisan:node(), bondy_app:is_ready(), Instances}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
leave(#call{} = M, Name) when is_binary(Name) ->
    case member_spec(Name) of
        error ->
            bondy_wamp_api_utils:error(
                {not_a_member, Name}, M
            );
        {ok, Spec} ->
            Remaining = remaining_members(Name),
            Survey = survey(Remaining),
            do_leave(M, Name, Spec, Survey)
    end;
leave(#call{} = M, _) ->
    bondy_wamp_api_utils:error({invalid_value, ~"node"}, M).

%% @private
%% The dry run reports the survey and stops; the real call refuses on an
%% unsafe survey and otherwise performs the Partisan removal.
do_leave(#call{} = M, Name, Spec, Survey) ->
    case bondy_wamp_api_utils:dry_run(M) of
        true ->
            bondy_wamp_api_utils:dry_run_result(
                M, would(Name, Survey), render_survey(Name, Survey)
            );
        false ->
            case Survey of
                #{safe := true} ->
                    ok = partisan_peer_service:leave(Spec),
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
    Members = partisan_membership:node_names(),
    Members -- [partisan:node(), binary_to_atom(Name, utf8)].

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
survey([]) ->
    #{safe => true, answered => [], silent => [], not_ready => []};
survey(Peers) ->
    Replies =
        try
            {R, _BadNodes} = partisan_rpc:multicall(
                Peers, ?MODULE, local_readiness, [], ?SURVEY_TIMEOUT
            ),
            R
        catch
            _:_ -> []
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
%% The `node_spec()` Partisan needs to remove another node — `members/0`
%% answers names, `members_for_orchestration/0` answers specs.
member_spec(Name) ->
    try binary_to_existing_atom(Name, utf8) of
        Node ->
            {ok, Specs} = partisan_peer_service:members_for_orchestration(),
            case [S || #{name := N} = S <- Specs, N == Node] of
                [Spec | _] -> {ok, Spec};
                [] -> error
            end
    catch
        %% An atom nobody has ever created cannot be a member, and creating
        %% one from caller input would be a leak.
        _:_ -> error
    end.

%% @private
connection(C) ->
    #{
        ~"node" => nodestring(partisan_peer_connections:node(C)),
        ~"channel" => atom_to_binary(
            partisan_peer_connections:channel(C), utf8
        ),
        ~"listen_addr" => listen_addr(C)
    }.

%% @private
listen_addr(C) ->
    try partisan_peer_connections:listen_addr(C) of
        #{ip := IP, port := Port} ->
            #{
                ~"ip" => list_to_binary(inet:ntoa(IP)),
                ~"port" => Port
            }
    catch
        _:_ -> null
    end.

%% @private
nodestring(Node) when is_atom(Node) ->
    atom_to_binary(Node, utf8).
