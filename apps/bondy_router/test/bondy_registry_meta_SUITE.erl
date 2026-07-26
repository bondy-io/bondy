%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Single-node coverage of the distributed introspection engine
%% `bondy_registry_meta`: the node-walk keyset pagination, cursor round-trip
%% over the wire, `count` from summaries, and stale-cursor rejection. The
%% cross-node leg is exercised by the cluster suite; here `partisan:nodes()` is
%% empty, so the node set is this node alone and the walk reduces to the local
%% keyset — which is exactly the per-node leg every cluster page is built from.
-module(bondy_registry_meta_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").

-compile([export_all, nowarn_export_all]).

-define(N_REGS, 25).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        list_paginates_all_entries,
        list_last_page_has_no_cursor,
        count_exact_match,
        count_agrees_with_match_enumeration,
        members_by_id,
        stale_cursor_rejected,
        wamp_get_maps_engine_outcomes_to_uris,
        get_cancellation_reaps_workers
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Realm = bondy_realm:create(<<"com.meta.test">>),
    RealmUri = bondy_realm:uri(Realm),
    ok = bondy_realm:disable_security(Realm),
    Peer = {{127, 0, 0, 1}, 10000},
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => <<"meta">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => true,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}, callee => #{}}
    }),
    Ctxt = bondy_context:new(Peer, {ws, text, json}, #{session => Session}),
    Ref = bondy_context:ref(Ctxt),

    %% Add N distinct exact registrations (one callee per URI).
    Ids = [
        begin
            Uri = uri(I),
            {ok, {Entry, true}} = bondy_registry:add(
                registration, RealmUri, Uri, #{match => ?EXACT_MATCH}, Ref
            ),
            bondy_registry_entry:id(Entry)
        end
     || I <- lists:seq(1, ?N_REGS)
    ],

    [
        {realm_uri, RealmUri},
        {context, Ctxt},
        {ids, lists:sort(Ids)}
        | Config
    ].

end_per_suite(Config) ->
    Config.

%% =============================================================================
%% CASES
%% =============================================================================

%% Page through the whole realm with a limit that does not divide the total,
%% and assert the union is complete, duplicate-free and strictly ascending.
list_paginates_all_entries(Config) ->
    RealmUri = ?config(realm_uri, Config),
    ExpectedIds = ?config(ids, Config),

    %% Page size does not divide the total, so pages straddle the boundary.
    Collected = drain(RealmUri, 4, undefined, []),

    %% Complete and duplicate-free.
    ?assertEqual(ExpectedIds, lists:usort(Collected)),
    ?assertEqual(length(ExpectedIds), length(Collected)),
    %% The keyset walk yields strictly ascending ids.
    ?assertEqual(lists:sort(Collected), Collected),
    ?assert(is_strictly_ascending(Collected)).

list_last_page_has_no_cursor(Config) ->
    RealmUri = ?config(realm_uri, Config),
    %% A limit >= total returns everything in one page with no continuation.
    {ok, Page} = bondy_registry_meta:list(
        registration, RealmUri, #{limit => ?N_REGS + 10}
    ),
    ?assertEqual(false, maps:get(has_more, Page)),
    ?assertEqual(undefined, maps:get(next, Page)),
    ?assertEqual(?N_REGS, length(maps:get(values, Page))).

count_exact_match(Config) ->
    RealmUri = ?config(realm_uri, Config),
    %% Single-node, exact registration: exactly one match, no remote summaries.
    ?assertEqual(
        {ok, 1}, bondy_registry_meta:count(registration, RealmUri, uri(1))
    ),
    ?assertEqual(
        {ok, 0},
        bondy_registry_meta:count(registration, RealmUri, <<"com.meta.absent">>)
    ).

%% A cursor minted for one (Type, Realm) query must be rejected when replayed
%% against a different one — the fingerprint guards it.
stale_cursor_rejected(Config) ->
    RealmUri = ?config(realm_uri, Config),
    {ok, Page} = bondy_registry_meta:list(registration, RealmUri, #{limit => 5}),
    Wire = bondy_pagination:encode_cursor(maps:get(next, Page)),

    %% Same wire cursor, different entry type => stale.
    ?assertEqual(
        {error, stale},
        bondy_registry_meta:list(
            subscription, RealmUri, #{limit => 5, cursor => Wire}
        )
    ),
    %% Garbage cursor => malformed.
    ?assertEqual(
        {error, malformed},
        bondy_registry_meta:list(
            registration, RealmUri, #{limit => 5, cursor => <<"garbage">>}
        )
    ).

%% count/3 (from RIB summaries) must agree with the length of the enumerated
%% match/4 page for a quiescent set — a regression guard on the two staying
%% consistent. Single node: no remote summaries, so count == local match count.
count_agrees_with_match_enumeration(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Uri = uri(1),
    {ok, Count} = bondy_registry_meta:count(registration, RealmUri, Uri),
    {ok, #{values := Values}} =
        bondy_registry_meta:match(registration, RealmUri, Uri, #{limit => 1000}),
    ?assertEqual(length(Values), Count),
    ?assertEqual(1, Count).

%% count_members/list_members take a registration/subscription id: resolve it to
%% its URI (a broadcast get) and then count (from summaries + local) / gather the
%% member WAMP session ids. Single node: each setup URI has exactly one callee.
members_by_id(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Ctxt = ?config(context, Config),
    Ref = bondy_context:ref(Ctxt),
    [RegId | _] = ?config(ids, Config),

    %% Registration id -> its URI -> one callee.
    ?assertEqual(
        {ok, 1},
        bondy_registry_meta:count_members(registration, RealmUri, RegId)
    ),
    {ok, RegMembers} =
        bondy_registry_meta:list_members(registration, RealmUri, RegId),
    ?assertMatch([SessionId] when is_integer(SessionId), RegMembers),

    %% Same path for a subscription, resolved by its own id.
    Topic = <<"com.meta.topic.members">>,
    {ok, {SubEntry, true}} = bondy_registry:add(
        subscription, RealmUri, Topic, #{match => ?EXACT_MATCH}, Ref
    ),
    SubId = bondy_registry_entry:id(SubEntry),
    ?assertEqual(
        {ok, 1},
        bondy_registry_meta:count_members(subscription, RealmUri, SubId)
    ),
    ?assertMatch(
        {ok, [_]},
        bondy_registry_meta:list_members(subscription, RealmUri, SubId)
    ),

    %% An id that resolves on no node is a definite not_found (not unavailable).
    BogusId = 9999999999,
    ?assertEqual(
        {error, not_found},
        bondy_registry_meta:count_members(registration, RealmUri, BogusId)
    ),
    ?assertEqual(
        {error, not_found},
        bondy_registry_meta:list_members(subscription, RealmUri, BogusId)
    ).

%% Regression guard for the get-by-id process hygiene: when the caller dies
%% mid-flight (client disconnect / cancel), the middleman must reap its linked
%% workers rather than leave them blocked on a query. We block a worker inside a
%% mocked local lookup, kill the caller, and assert the worker terminates.
get_cancellation_reaps_workers(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Tester = self(),
    BlockedId = 987654321,

    ok = meck:new(bondy_registry, [passthrough]),
    try
        ok = meck:expect(bondy_registry, lookup, fun
            (registration, _Realm, Id) when Id =:= BlockedId ->
                Tester ! {worker, self()},
                timer:sleep(60000),
                {error, not_found};
            (Type, Realm, Id) ->
                meck:passthrough([Type, Realm, Id])
        end),

        Caller = spawn(fun() ->
            _ = bondy_registry_meta:get(registration, RealmUri, BlockedId)
        end),

        WorkerPid =
            receive
                {worker, W} -> W
            after 5000 -> ct:fail(worker_never_started)
            end,
        MonRef = erlang:monitor(process, WorkerPid),

        %% Caller cancelled: the middleman (monitoring it) must reap the worker.
        true = exit(Caller, kill),
        receive
            {'DOWN', MonRef, process, WorkerPid, _} -> ok
        after 5000 ->
            ct:fail(worker_not_reaped_on_caller_death)
        end
    after
        ok = meck:unload(bondy_registry)
    end.

%% The WAMP layer must turn each engine outcome of `wamp.registration.get` into
%% the right response: `unavailable` -> a distinct WAMP error URI (NOT a false
%% "no such registration"), `not_found` -> a different (registration) error URI,
%% and `{ok, _}` -> a result, never an error.
wamp_get_maps_engine_outcomes_to_uris(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Ctxt = ?config(context, Config),

    ok = meck:new(bondy_registry_meta, [passthrough]),
    try
        ok = meck:expect(
            bondy_registry_meta, get, fun(_, _, _) -> {error, unavailable} end
        ),
        ?assertEqual(
            <<"bondy.error.unavailable">>, wamp_get_error_uri(RealmUri, Ctxt)
        ),

        ok = meck:expect(
            bondy_registry_meta, get, fun(_, _, _) -> {error, not_found} end
        ),
        NotFoundUri = wamp_get_error_uri(RealmUri, Ctxt),
        ?assertNotEqual(<<"bondy.error.unavailable">>, NotFoundUri),

        ok = meck:expect(
            bondy_registry_meta, get, fun(_, _, _) -> {ok, #{id => 1}} end
        ),
        ?assertMatch({reply, #result{}}, wamp_get(RealmUri, Ctxt))
    after
        ok = meck:unload(bondy_registry_meta)
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% Drain every page, threading the wire cursor, accumulating the ids. Capped so
%% a non-advancing cursor fails loudly (with the per-page id lists) instead of
%% looping until the timetrap.
drain(RealmUri, Limit, Cursor, Acc) ->
    drain(RealmUri, Limit, Cursor, Acc, 0, []).

drain(_RealmUri, _Limit, _Cursor, _Acc, Iter, Pages) when Iter > 20 ->
    ct:fail({pagination_did_not_terminate, {pages, lists:reverse(Pages)}});
drain(RealmUri, Limit, Cursor, Acc, Iter, Pages) ->
    Opts =
        case Cursor of
            undefined -> #{limit => Limit};
            _ -> #{limit => Limit, cursor => Cursor}
        end,
    {ok, #{values := Values, next := Next, has_more := HasMore}} =
        bondy_registry_meta:list(registration, RealmUri, Opts),
    Ids = [maps:get(id, V) || V <- Values],
    Acc1 = Acc ++ Ids,
    case HasMore of
        false ->
            ?assertEqual(undefined, Next),
            Acc1;
        true ->
            drain(
                RealmUri,
                Limit,
                bondy_pagination:encode_cursor(Next),
                Acc1,
                Iter + 1,
                [Ids | Pages]
            )
    end.

is_strictly_ascending([]) -> true;
is_strictly_ascending([_]) -> true;
is_strictly_ascending([A, B | T]) when A < B -> is_strictly_ascending([B | T]);
is_strictly_ascending(_) -> false.

uri(I) ->
    Suffix = list_to_binary(io_lib:format("~4..0b", [I])),
    <<"com.meta.p.", Suffix/binary>>.

%% @private
wamp_get_error_uri(RealmUri, Ctxt) ->
    {reply, #error{error_uri = Uri}} = wamp_get(RealmUri, Ctxt),
    Uri.

%% @private
wamp_get(RealmUri, Ctxt) ->
    M = #call{
        request_id = 1,
        procedure_uri = ?WAMP_REG_GET,
        args = [RealmUri, 12345],
        options = #{}
    },
    bondy_wamp_meta_api:handle_call(M, Ctxt).
