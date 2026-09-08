%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_session_cleanup_SUITE).
-moduledoc """
Pins the teardown contract of a WAMP session: every node-local resource a
session acquires while opening must be released when it goes away, on EVERY
close path, not only the graceful one.

The suite is organised by the resource, and each case names the close path it
exercises:

- `owner_down_*` — the connection process dies WITHOUT a GOODBYE (the WAMP
  `terminate/1` path never runs). This is the path a brutally-closed socket
  takes and the one a leak survives longest on.
- `graceful_close_*` — `bondy_session_manager:close/1,2` (the cast a
  connection or `close_all/1` sends).

What this suite does NOT cover: cross-node convergence of the removals (the
RIB summaries ride AAE); the realm-delete path on a node OTHER than the one
that performed the delete — realm deletion is not yet replayed as a local
teardown on peer nodes (see `bondy_realm:delete/2`); and the OIDC re-schedule
after a SUCCESSFUL token refresh, which needs a live IdP. What is covered of
the OIDC path is the property that makes cleanup possible at all — the queue
entry is addressable by the session that owns it — and the drop of an entry
whose session is gone.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

-define(OIDC_TAB, bondy_oidc_refresh_queue).

%% =============================================================================
%% CT CALLBACKS
%% =============================================================================

all() ->
    [
        owner_down_flushes_registrations,
        owner_down_flushes_subscriptions,
        owner_down_removes_session_records,
        graceful_close_removes_session_records,
        node_wildcard_outlives_its_sessions,
        realm_delete_purges_registry,
        oidc_refresh_entry_is_keyed_by_its_session,
        oidc_refresh_entry_dropped_when_session_gone
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Realm = bondy_realm:create(<<"session.cleanup.test">>),
    RealmUri = bondy_realm:uri(Realm),
    ok = bondy_realm:disable_security(Realm),
    [{realm_uri, RealmUri} | Config].

end_per_suite(Config) ->
    Config.

%% =============================================================================
%% TESTS
%% =============================================================================

owner_down_flushes_registrations(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Proc = <<"com.cleanup.test.add">>,

    {Owner, Session} = open_owned_session(RealmUri, Proc, topic(Proc)),
    Id = bondy_session:id(Session),

    ?assertMatch([_], registrations(RealmUri, Id)),

    ok = kill_and_await_close(Owner, RealmUri, Id),

    ?assertEqual([], registrations(RealmUri, Id)),
    ok.

owner_down_flushes_subscriptions(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Proc = <<"com.cleanup.test.sub.add">>,
    Topic = topic(Proc),

    {Owner, Session} = open_owned_session(RealmUri, Proc, Topic),
    Id = bondy_session:id(Session),

    ?assertMatch([_], subscriptions(RealmUri, Id)),

    ok = kill_and_await_close(Owner, RealmUri, Id),

    ?assertEqual([], subscriptions(RealmUri, Id)),
    ok.

owner_down_removes_session_records(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Proc = <<"com.cleanup.test.records.add">>,

    {Owner, Session} = open_owned_session(RealmUri, Proc, topic(Proc)),
    Id = bondy_session:id(Session),
    ExtId = bondy_session:external_id(Session),

    ?assertMatch({ok, _}, bondy_session:lookup(Id)),
    ?assertMatch([_], message_id_counters(RealmUri, Id)),

    ok = kill_and_await_close(Owner, RealmUri, Id),

    %% The session, its external-id index and its message-id counter row.
    ?assertEqual({error, not_found}, bondy_session:lookup(Id)),
    ?assertEqual({error, not_found}, bondy_session:lookup(RealmUri, Id)),
    ?assertEqual({error, not_found}, bondy_session:lookup(RealmUri, ExtId)),
    ?assertEqual([], message_id_counters(RealmUri, Id)),
    ok.

graceful_close_removes_session_records(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Proc = <<"com.cleanup.test.graceful.add">>,

    {Owner, Session} = open_owned_session(RealmUri, Proc, topic(Proc)),
    Id = bondy_session:id(Session),
    ExtId = bondy_session:external_id(Session),

    %% The cast `bondy_wamp_protocol:terminate/1` and `close_all/1` send.
    ok = bondy_session_manager:close(Session),
    ok = await(fun() -> bondy_session:lookup(Id) == {error, not_found} end),

    ?assertEqual({error, not_found}, bondy_session:lookup(RealmUri, ExtId)),
    ?assertEqual([], message_id_counters(RealmUri, Id)),

    %% The registry entries are flushed by the connection process itself
    %% (`bondy_context:close/1`), which `close/1` does not stand in for — the
    %% owner is still alive here, so its entries are still live. Killing it
    %% must still flush them, even though the session record is already gone:
    %% the manager's DOWN handler is not the only thing that can flush.
    Owner ! stop,
    ok = await(fun() -> registrations(RealmUri, Id) == [] end),
    ?assertEqual([], subscriptions(RealmUri, Id)),
    ok.

node_wildcard_outlives_its_sessions(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Proc = <<"com.cleanup.test.wildcard.add">>,

    %% `wamp.session.<NodeHash>..get` is a ROUTER capability, registered once
    %% per realm by `bondy_session_manager` and owned by a session-less
    %% internal callback ref. It is not session state, so a session close must
    %% NOT take it with it — a reader who sees it survive a disconnect is
    %% looking at the intended contract, not a leak. Its release is bound to
    %% the realm (see `realm_delete_purges_registry`).
    {Owner, Session} = open_owned_session(RealmUri, Proc, topic(Proc)),
    Id = bondy_session:id(Session),

    ?assertMatch([_], node_wildcards(RealmUri)),

    ok = kill_and_await_close(Owner, RealmUri, Id),

    ?assertMatch([_], node_wildcards(RealmUri)),

    %% And it stays a single entry however many sessions come and go.
    {Owner2, Session2} = open_owned_session(RealmUri, Proc, topic(Proc)),
    ?assertMatch([_], node_wildcards(RealmUri)),
    ok = kill_and_await_close(
        Owner2, RealmUri, bondy_session:id(Session2)
    ),
    ?assertMatch([_], node_wildcards(RealmUri)),
    ok.

realm_delete_purges_registry(_Config) ->
    %% A realm's registry entries are keyed by the realm, and the router's own
    %% entries (the per-node `wamp.session.<hash>..get` wildcard) have no
    %% session, so nothing in the session close path can reach them. Deleting
    %% the realm must, or every created-and-deleted realm leaves a node-local
    %% entry behind, and with it the RIB summary count that
    %% `bondy_registry_rib:apply_removed/1` would have decremented — a routing
    %% summary this node keeps advertising to its peers until it restarts.
    Uri = <<"session.cleanup.ephemeral.realm">>,
    Realm = bondy_realm:create(Uri),
    ok = bondy_realm:disable_security(Realm),

    Proc = <<"com.cleanup.test.doomed.add">>,
    {Owner, Session} = open_owned_session(Uri, Proc, topic(Proc)),
    Id = bondy_session:id(Session),

    ?assertMatch([_], node_wildcards(Uri)),
    ?assertMatch([_], registrations(Uri, Id)),

    ok = kill_and_await_close(Owner, Uri, Id),
    ok = bondy_realm:delete(Uri, #{force => true}),

    ok = await(fun() -> node_wildcards(Uri) == [] end),
    ?assertEqual([], all_registrations(Uri)),
    ?assertEqual([], all_subscriptions(Uri)),

    %% And the node-local guard must forget the realm too, or a realm that
    %% reclaims this URI would never get its wildcard registered again and
    %% `wamp.session.get` would silently answer no_such_procedure for it.
    Realm2 = bondy_realm:create(Uri),
    ok = bondy_realm:disable_security(Realm2),
    {Owner2, Session2} = open_owned_session(Uri, Proc, topic(Proc)),
    ?assertMatch([_], node_wildcards(Uri)),
    ok = kill_and_await_close(Owner2, Uri, bondy_session:id(Session2)),
    ok = bondy_realm:delete(Uri, #{force => true}),
    ok.

oidc_refresh_entry_is_keyed_by_its_session(Config) ->
    RealmUri = ?config(realm_uri, Config),

    %% The refresh queue entry an `oidcrp` session schedules must be
    %% addressable by that session's id. This is the property the whole
    %% cleanup rests on: with an opaque per-schedule id instead, nothing that
    %% knows only the session can find the entry — not the close path, not the
    %% worker — and a re-schedule silently orphans whatever the session
    %% recorded.
    {Owner, Id} = open_oidc_session(RealmUri),
    ?assertMatch([_], oidc_entries(Id)),
    Owner ! stop,
    ok.

oidc_refresh_entry_dropped_when_session_gone(Config) ->
    RealmUri = ?config(realm_uri, Config),

    %% Nothing on the close path removes the entry, deliberately: a removal
    %% there costs a scan of the whole queue per close. Instead the worker
    %% drops an entry whose session is gone when the entry comes due, so the
    %% refresh can never outlive its session — the leak being pinned here is a
    %% queue row that keeps calling the IdP for a session that no longer
    %% exists.
    {Owner, Id} = open_oidc_session(RealmUri),
    ?assertMatch([_], oidc_entries(Id)),

    true = exit(Owner, kill),
    ok = await(fun() -> bondy_session:lookup(Id) == {error, not_found} end),

    %% Drive the worker's own tick rather than waiting out its 30s timer: the
    %% entry was scheduled due immediately (expires_in 0), so this is the very
    %% batch the timer would have run.
    ok = tick_oidc_workers(),

    ?assertEqual([], oidc_entries(Id)),
    ok.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% Opens a session from a dedicated process and registers a procedure and a
%% subscription owned by it, so that killing the process is exactly a
%% connection dying without a GOODBYE.
open_owned_session(RealmUri, Proc, Topic) ->
    Id = bondy_session_id:new(),
    Owner = spawn_owner(fun() ->
        {ok, Session} = bondy_session_manager:open(
            Id, RealmUri, session_opts()
        ),
        Ref = bondy_session:ref(Session),
        {ok, _} = bondy_dealer:register(Proc, #{}, RealmUri, Ref),
        {ok, _} = bondy_broker:subscribe(RealmUri, #{}, Topic, Ref),
        {ok, Session}
    end),
    {ok, Session} = owner_result(Owner),
    {Owner, Session}.

%% @private
open_oidc_session(RealmUri) ->
    Id = bondy_session_id:new(),
    Owner = spawn_owner(fun() ->
        bondy_session_manager:open(Id, RealmUri, oidc_session_opts())
    end),
    {ok, _Session} = owner_result(Owner),
    {Owner, Id}.

%% @private
spawn_owner(Fun) ->
    Parent = self(),
    spawn(fun() ->
        Parent ! {owner_ready, self(), Fun()},
        receive
            stop -> ok
        end
    end).

%% @private
owner_result(Owner) ->
    receive
        {owner_ready, Owner, Result} -> Result
    after 15000 ->
        error({timeout, waiting_for_owner})
    end.

%% @private
%% Kills the owner outright — no `terminate/1`, no GOODBYE — and waits for the
%% session manager's DOWN handler to finish.
kill_and_await_close(Owner, RealmUri, Id) ->
    MRef = erlang:monitor(process, Owner),
    true = exit(Owner, kill),
    receive
        {'DOWN', MRef, process, Owner, _} -> ok
    after 5000 ->
        error({timeout, waiting_for_owner_death})
    end,
    await(fun() ->
        bondy_session:lookup(Id) == {error, not_found} andalso
            registrations(RealmUri, Id) == []
    end).

%% @private
await(Fun) ->
    await(Fun, 100).

%% @private
await(_Fun, 0) ->
    error(timeout);
await(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            await(Fun, N - 1)
    end.

%% @private
registrations(RealmUri, SessionId) ->
    bondy_registry:entries(registration, RealmUri, SessionId).

%% @private
subscriptions(RealmUri, SessionId) ->
    bondy_registry:entries(subscription, RealmUri, SessionId).

%% @private
all_registrations(RealmUri) ->
    bondy_registry:entries(registration, RealmUri, '_', infinity).

%% @private
all_subscriptions(RealmUri) ->
    bondy_registry:entries(subscription, RealmUri, '_', infinity).

%% @private
%% The router's own per-node `wamp.session.<hash>..get` registrations in the
%% realm, whatever session (none) they belong to.
node_wildcards(RealmUri) ->
    Prefix = <<"wamp.session.">>,
    Size = byte_size(Prefix),
    [
        E
     || E <- all_registrations(RealmUri),
        binary:part(bondy_registry_entry:uri(E), 0, Size) == Prefix
    ].

%% @private
message_id_counters(RealmUri, SessionId) ->
    ets:lookup(bondy_session_counter, {RealmUri, SessionId}).

%% @private
oidc_entries(SessionId) ->
    %% Keyed {NextRefreshAt, SessionId}; the id is the only stable half.
    ets:select(?OIDC_TAB, [
        {{'_', {'_', SessionId}, '_', '_', '_', '_'}, [], [true]}
    ]).

%% @private
tick_oidc_workers() ->
    Workers = [
        Pid
     || {_, Pid, _} <- gproc:select([
            {{{n, l, {bondy_oidc_refresh_worker, '_'}}, '_', '_'}, [], ['$_']}
        ])
    ],
    ?assertNotEqual([], Workers),
    _ = [
        begin
            Pid ! refresh_tick,
            %% Round-trip a call so the tick is known to have been handled.
            _ = sys:get_state(Pid)
        end
     || Pid <- Workers
    ],
    ok.

%% @private
topic(Proc) ->
    <<Proc/binary, ".topic">>.

%% @private
session_opts() ->
    #{
        peer => {{127, 0, 0, 1}, 10000},
        authid => <<"anonymous">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => true,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}, subscriber => #{}}
    }.

%% @private
oidc_session_opts() ->
    Opts = session_opts(),
    Opts#{
        authmethod => ?OIDCRP_AUTH,
        authmethod_details => #{
            oidc_provider => <<"cleanup-test-provider">>,
            oidc_refresh_token => <<"cleanup-test-refresh-token">>,
            %% Due immediately, so the very next batch is the one that must
            %% notice the session is gone.
            oidc_access_token_expires_in => 0
        }
    }.
