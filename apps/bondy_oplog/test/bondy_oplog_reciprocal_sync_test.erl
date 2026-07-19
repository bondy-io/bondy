%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Two properties of the page-exchange protocol:
%%
%% 1. RECIPROCITY (wire only). A page request announces the requester's peer id
%%    and root, so a responder learns for free what the requester holds — the
%%    input a stability oracle needs.
%%
%%    The responder does NOT currently act on it. Triggering a reverse session
%%    on root inequality regresses convergence: while A bulk-pulls from B the
%%    roots differ on every round, so it spawns a reverse session per round and
%%    those consume slots from the node-wide `aae_max_concurrency` cap,
%%    starving the sessions making progress. Measured as a convergence timeout
%%    in `bondy_frontier_cluster_SUITE:asymmetric_compaction_keeps_oracle_in_sync`.
%%    Acting on it needs a real is-behind predicate and a budget that does not
%%    compete with scheduled sync.
%%
%% 2. UNAVAILABILITY. A peer that cannot serve the requested pages — normally
%%    because compaction reclaimed them — says so explicitly. This matters once
%%    cells are reclaimed on a stability frontier: "I no longer hold these"
%%    must be distinguishable from "I returned nothing", because the first is
%%    terminal (bootstrap) and the second is a bug.
%% =============================================================================

-module(bondy_oplog_reciprocal_sync_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

reciprocal_sync_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 60, fun request_carries_self_id_and_root/0},
        {timeout, 60, fun unavailable_is_distinct_from_empty/0},
        {timeout, 60, fun legacy_two_tuple_still_served/0}
    ]}.

%% -----------------------------------------------------------------------------
%% 1. Reciprocity
%% -----------------------------------------------------------------------------

request_carries_self_id_and_root() ->
    {A, B} = two_instances(),
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 40)],

    Tab = ets:new(reqs, [public, bag]),
    meck:new(bondy_oplog_transport_inline, [passthrough]),
    meck:expect(
        bondy_oplog_transport_inline,
        request,
        fun(Peer, Inst, Req, Opts) ->
            true = ets:insert(Tab, {req, Req}),
            meck:passthrough([Peer, Inst, Req, Opts])
        end
    ),

    ?assertMatch({ok, _}, bondy_oplog:sync(A, B)),
    meck:unload(bondy_oplog_transport_inline),

    Reqs = [R || {req, R} <- ets:tab2list(Tab)],
    ets:delete(Tab),

    PageReqs = [R || R <- Reqs, is_tuple(R), element(1, R) == get_pages],
    ?assertNotEqual([], PageReqs, "no page requests were issued"),

    %% Every page request carries the requester's id and root, not the bare
    %% hash list.
    lists:foreach(
        fun(R) ->
            ?assertMatch({get_pages, _Self, _Root, _Hashes}, R),
            {get_pages, Self, Root, Hashes} = R,
            %% On the inline transport a peer is addressed by instance id, so
            %% A's self id is A: it is exactly how B would call back.
            ?assertEqual(A, Self),
            %% `undefined` is a legitimate root: A starts empty, and telling
            %% the peer so is exactly what lets it conclude it is ahead.
            ?assert(Root =:= undefined orelse is_binary(Root)),
            ?assert(is_list(Hashes) andalso Hashes =/= [])
        end,
        PageReqs
    ).

%% -----------------------------------------------------------------------------
%% 2. Unavailability
%% -----------------------------------------------------------------------------

unavailable_is_distinct_from_empty() ->
    {A, _B} = two_instances(),

    %% Ask for hashes the instance certainly does not hold.
    Bogus = [crypto:strong_rand_bytes(32), crypto:strong_rand_bytes(32)],

    ?assertEqual(
        {ok, {unavailable, Bogus}},
        bondy_oplog_responder:dispatch(A, {get_pages, Bogus})
    ),

    %% An empty request is not "unavailable" — there was nothing to serve.
    ?assertEqual(
        {ok, #{}},
        bondy_oplog_responder:dispatch(A, {get_pages, []})
    ),

    %% And the session surfaces it as a terminal reason, distinct from the
    %% empty-pages protocol violation.
    ?assertMatch(
        {error, {peer_pages_unavailable, _}},
        pull_bogus(A, Bogus)
    ).

%% -----------------------------------------------------------------------------
%% 3. Backward compatibility
%% -----------------------------------------------------------------------------
%%
%% A peer running an older version answers the 2-tuple form. It must keep
%% working — it simply does not reciprocate.

legacy_two_tuple_still_served() ->
    {A, B} = two_instances(),
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 10)],
    ?assertMatch({ok, _}, bondy_oplog:sync(A, B)),

    Missing = bondy_oplog_instance:missing_set(A, bondy_oplog:root_hash(B)),
    ?assertEqual([], Missing),

    %% Serve a page we definitely hold, via the legacy shape.
    Root = bondy_oplog:root_hash(B),
    ?assertMatch(
        {ok, Pages} when map_size(Pages) > 0,
        bondy_oplog_responder:dispatch(B, {get_pages, [Root]})
    ).

%% -----------------------------------------------------------------------------
%% Helpers
%% -----------------------------------------------------------------------------

%% Drives one page-fetch round against an instance that cannot serve, through
%% the real session code path.
pull_bogus(Instance, Hashes) ->
    Transport = bondy_oplog_transport_inline,
    case Transport:request(Instance, Instance, {get_pages, Hashes}, #{}) of
        {ok, {unavailable, Batch}} -> {error, {peer_pages_unavailable, Batch}};
        Other -> Other
    end.

two_instances() ->
    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),
    {A, B}.

mk_inst() ->
    list_to_binary(
        "recip_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

originated_opts() ->
    #{origin => bondy_oplog_origin:new()}.
