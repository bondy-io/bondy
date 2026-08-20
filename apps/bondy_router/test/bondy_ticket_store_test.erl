%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Focused coverage for `bondy_ticket`'s bulk revocation after its cut-over from
%% plum_db to bondy_db (design §11.4). The point read/write paths are exercised
%% end-to-end by `bondy_auth_ticket_SUITE`; what that suite does NOT cover is
%% `revoke_all/1,2`, which is real production code (realm / user deletion) and —
%% for `revoke_all/2` — the one place the cut changed the ALGORITHM: plum_db's
%% ordered key-prefix range became a realm `bondy_db:list/2` scan that decodes
%% each `term_to_binary/1` store key and filters by its `Authid` (the first
%% element of the composed `{Authid, A, B}` key). This pins that filter.
%%
%% These functions take `RealmUri` directly (no realm resolution), so the test
%% needs only a provisioned catalogue — not a full bondy boot.

-module(bondy_ticket_store_test).

-include_lib("eunit/include/eunit.hrl").

-define(REALM, <<"com.bondy.test.ticket_store">>).

revoke_all_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"revoke_all/2 clears one user's tickets, leaves the others",
                fun revoke_all_user/0},
            {"revoke_all/1 clears the whole realm", fun revoke_all_realm/0}
        ]
    end}.

%% Regression guard for the bounded list-in-one-cell storage shape preserved
%% from plum_db: client-scoped tickets for one (user, client) across many
%% devices live in ONE cell as a per-device list — NOT one cell per ticket.
storage_shape_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"client-scoped tickets are a per-device list in one cell",
                fun client_tickets_list_in_one_cell/0}
        ]
    end}.

%% Lazy reclamation. Re-issuing for device A replaces only A's entry, so
%% without pruning a device that never comes back leaves its expired ticket in
%% the cell forever. `store_ticket/3` must drop the OTHER devices' expired
%% entries while it is already rewriting the cell.
expiry_reclamation_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"storing a ticket prunes other devices' expired entries",
                fun expired_device_tickets_are_pruned/0},
            {"pruning preserves entries it cannot prove expired",
                fun unrecognised_entries_survive_pruning/0}
        ]
    end}.

%% revoke_all/2 must clear exactly the target user's cells. Seed alice (two
%% distinct store keys) and bob (one); revoking alice leaves only bob.
revoke_all_user() ->
    T = table(),
    %% alice: an SSO ticket and a device-scoped SSO ticket (two store keys).
    seed(T, <<"alice">>, {<<"alice">>, <<>>, <<>>}),
    seed(T, <<"alice">>, {<<"alice">>, <<>>, <<"device-1">>}),
    %% bob: one SSO ticket.
    seed(T, <<"bob">>, {<<"bob">>, <<>>, <<>>}),
    ?assertEqual([<<"alice">>, <<"bob">>], live_authids(T)),

    ok = bondy_ticket:revoke_all(?REALM, <<"alice">>),
    ?assertEqual([<<"bob">>], live_authids(T)),

    %% Idempotent: revoking again is a no-op.
    ok = bondy_ticket:revoke_all(?REALM, <<"alice">>),
    ?assertEqual([<<"bob">>], live_authids(T)),

    %% Clean up bob for the next test.
    ok = bondy_ticket:revoke_all(?REALM, <<"bob">>),
    ?assertEqual([], live_authids(T)).

%% revoke_all/1 clears every cell in the realm regardless of user.
revoke_all_realm() ->
    T = table(),
    seed(T, <<"carol">>, {<<"carol">>, <<>>, <<>>}),
    seed(T, <<"dave">>, {<<"dave">>, <<"com.realm">>, <<>>}),
    ?assertEqual([<<"carol">>, <<"dave">>], live_authids(T)),

    ok = bondy_ticket:revoke_all(?REALM),
    ?assertEqual([], live_authids(T)).

%% Drive the real `bondy_ticket:store_ticket/3` (which builds the per-device
%% list via `update_tickets/3`) for one (user, client) across N devices. All N
%% share one composed store key `{Authid, ClientId, <<>>}` (device handled by
%% the in-cell list), so they MUST collapse to a single cell holding a list of
%% N — a cell-per-ticket regression would instead yield N cells.
client_tickets_list_in_one_cell() ->
    T = table(),
    Authid = <<"erin">>,
    Client = <<"app1">>,
    N = 5,

    _ = [
        ok = bondy_ticket:store_ticket(
            ?REALM, Authid, client_claims(Authid, Client, device(I))
        )
     || I <- lists:seq(1, N)
    ],

    %% Exactly ONE cell for (erin, app1), regardless of device count.
    Rows = rows_for(T, Authid),
    ?assertEqual(1, length(Rows)),

    %% And that one cell holds a LIST of N tickets (one per device).
    [{_Key, Value, _Hlc}] = Rows,
    ?assert(is_list(Value)),
    ?assertEqual(N, length(Value)),

    %% Every device — INCLUDING the first — is findable via lookup/3 (regression
    %% guard for the `update_tickets/3` first-device fix: the first ticket used
    %% to be stored as a bare unkeyed map and so was unfindable).
    lists:foreach(
        fun(I) ->
            ?assertMatch(
                {ok, #{scope := #{device_id := _}}},
                bondy_ticket:lookup(?REALM, Authid, scope(Client, device(I)))
            )
        end,
        lists:seq(1, N)
    ),

    %% Re-storing ANY existing device — first included — replaces in place: the
    %% list does NOT grow.
    lists:foreach(
        fun(I) ->
            ok = bondy_ticket:store_ticket(
                ?REALM, Authid, client_claims(Authid, Client, device(I))
            ),
            [{_, V, _}] = rows_for(T, Authid),
            ?assertEqual(N, length(V))
        end,
        [1, N]
    ),

    ok = bondy_ticket:revoke_all(?REALM, Authid),
    ?assertEqual([], rows_for(T, Authid)).

%% One live device and one already-expired device share a cell. Writing any
%% device then reclaims the expired one — but never the entry being written.
expired_device_tickets_are_pruned() ->
    T = table(),
    Authid = <<"frank">>,
    Client = <<"app2">>,

    ok = store(Authid, Client, device(1), live),
    ok = store(Authid, Client, device(2), expired),

    %% Pruning runs BEFORE the keystore, so the entry being written is never a
    %% candidate — it lands in the cell even when it is itself already expired.
    ?assertEqual(2, cell_size(T, Authid)),
    ?assertMatch({ok, _}, lookup(Authid, Client, device(2))),

    %% Writing ANY device now reclaims device 2, and only device 2.
    ok = store(Authid, Client, device(3), live),
    ?assertEqual(2, cell_size(T, Authid)),
    ?assertEqual({error, not_found}, lookup(Authid, Client, device(2))),
    ?assertMatch({ok, _}, lookup(Authid, Client, device(1))),
    ?assertMatch({ok, _}, lookup(Authid, Client, device(3))),

    ok = bondy_ticket:revoke_all(?REALM, Authid).

%% Pruning must drop only what it can positively prove expired. The historical
%% unkeyed form — a bare claims map in the list rather than a
%% `{list_key(), Claims}` pair — is already unreachable by `lookup/3`, but it is
%% not the write path's job to silently delete data it does not recognise.
unrecognised_entries_survive_pruning() ->
    T = table(),
    Authid = <<"grace">>,
    Client = <<"app3">>,

    %% Let store_ticket/3 create the cell so we splice into the real store key
    %% rather than reconstructing its composition here.
    ok = store(Authid, Client, device(1), live),
    [{Key, Value0, _Hlc}] = rows_for(T, Authid),

    Legacy = expired_claims(Authid, Client, device(9)),
    ok = bondy_db:apply(T, ?REALM, Key, {set, [Legacy | Value0]}),
    ?assertEqual(2, cell_size(T, Authid)),

    ok = store(Authid, Client, device(2), live),

    [{_, Value, _}] = rows_for(T, Authid),
    ?assertEqual(3, length(Value)),
    ?assert(lists:member(Legacy, Value)),

    ok = bondy_ticket:revoke_all(?REALM, Authid).

%% =============================================================================
%% Helpers
%% =============================================================================

%% A client-scoped (client_local) scope: client_id =/= all and a concrete
%% device_id, so `store_ticket/3` takes the list-valued cell path.
scope(ClientId, DeviceId) ->
    #{realm => ?REALM, client_id => ClientId, device_id => DeviceId}.

%% A client-scoped claims map for the given client + device.
client_claims(Authid, ClientId, DeviceId) ->
    #{
        authrealm => ?REALM,
        authid => Authid,
        scope => scope(ClientId, DeviceId),
        expires_at => erlang:system_time(second) + 3600
    }.

%% Store one client-scoped ticket, either live or already past `expires_at`.
store(Authid, ClientId, DeviceId, live) ->
    bondy_ticket:store_ticket(
        ?REALM, Authid, client_claims(Authid, ClientId, DeviceId)
    );
store(Authid, ClientId, DeviceId, expired) ->
    bondy_ticket:store_ticket(
        ?REALM, Authid, expired_claims(Authid, ClientId, DeviceId)
    ).

%% Claims whose `expires_at` is unambiguously in the past — well clear of the
%% leeway `bondy_ticket:is_expired/1` applies.
expired_claims(Authid, ClientId, DeviceId) ->
    Claims = client_claims(Authid, ClientId, DeviceId),
    Claims#{expires_at => erlang:system_time(second) - 3600}.

lookup(Authid, ClientId, DeviceId) ->
    bondy_ticket:lookup(?REALM, Authid, scope(ClientId, DeviceId)).

%% The number of per-device entries in the single cell held for `Authid`.
cell_size(Table, Authid) ->
    [{_Key, Value, _Hlc}] = rows_for(Table, Authid),
    length(Value).

%% The cells (rows) in the realm whose decoded store key belongs to `Authid`
%% (its first tuple element), regardless of map- or list-valued.
rows_for(Table, Authid) ->
    {ok, Rows} = bondy_db:list(Table, ?REALM),
    [
        R
     || {Key, _V, _H} = R <- Rows, element(1, binary_to_term(Key)) =:= Authid
    ].

device(I) ->
    <<"device_", (integer_to_binary(I))/binary>>.

%% Seed a ticket cell the way `bondy_ticket:store_ticket/3` does — the composed
%% store key `term_to_binary`-encoded, a claims map value — so the module's own
%% encode/decode resolves it.
seed(Table, Authid, KeyTuple) ->
    Claims = #{
        authrealm => ?REALM,
        authid => Authid,
        scope => #{realm => all, client_id => all, device_id => all},
        expires_at => erlang:system_time(second) + 3600
    },
    ok = bondy_db:apply(Table, ?REALM, term_to_binary(KeyTuple), {set, Claims}).

%% The distinct Authids with a live (map-valued) cell in the realm, sorted.
live_authids(Table) ->
    {ok, Rows} = bondy_db:list(Table, ?REALM),
    lists:usort([
        element(1, binary_to_term(Key))
     || {Key, Value, _Hlc} <- Rows, is_map(Value)
    ]).

table() ->
    bondy_namespace_catalog:table(bondy_ticket).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    Tmp = make_tmpdir(),
    ok = bondy_db_config:set([databases, main, oplog, shard_count], 1),
    application:set_env(bondy_router, platform_data_dir, Tmp),
    {ok, Pid} = bondy_namespace_catalog:start_link(),
    {Pid, Tmp}.

cleanup({Pid, Tmp}) ->
    _ =
        try
            gen_server:stop(Pid, normal, 30000)
        catch
            _:_ -> ok
        end,
    ok = bondy_db_config:set([databases, main, oplog, shard_count], 16),
    application:unset_env(bondy_router, platform_data_dir),
    _ = file:del_dir_r(Tmp),
    ok.

make_tmpdir() ->
    Base = filename:join(
        "/tmp",
        "bondy_ticket_store_test_" ++ os:getpid() ++ "_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_path(Base),
    Base.
