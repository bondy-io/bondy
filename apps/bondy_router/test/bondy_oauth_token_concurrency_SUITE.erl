%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% The token store under concurrent writers for ONE user.
%%
%% Written first as the falsification probe for the one-set-per-user layout,
%% where every write was a read-modify-write of the user's whole set: two
%% writers issuing DIFFERENT scopes could both read the same set and the
%% later-applied write dropped the earlier token (20 concurrent issues left 1
%% token), and a `revoke_all/2` interleaved with an issue was overwritten by
%% the issue's stale set, revoked tokens included. The store is now one cell
%% per token; these cases are the gate that keeps it so.
%%
%% `two_scopes_sequential` is the control. `two_scopes_concurrent` forces two
%% issuers' writes into flight together (both rendezvous at their store write).
%% `many_scopes_concurrent` runs N issuers with no help. In
%% `revoke_all_concurrent_with_issue` the issuer is held before its write while
%% `revoke_all/2` runs, then released: what the store holds afterwards is at
%% most that one token, never a revoked one.
%% =============================================================================

-module(bondy_oauth_token_concurrency_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").
-include("bondy_db_tables.hrl").

-define(REALM_URI, <<"com.example.test.token_concurrency">>).
-define(PASS, <<"aWe11KeptSecret">>).
-define(N_CONCURRENT, 20).

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([two_scopes_sequential/1]).
-export([two_scopes_concurrent/1]).
-export([many_scopes_concurrent/1]).
-export([revoke_all_concurrent_with_issue/1]).

all() ->
    [
        two_scopes_sequential,
        two_scopes_concurrent,
        many_scopes_concurrent,
        revoke_all_concurrent_with_issue
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    %% Larger than any number of scopes issued here, so the per-user bound
    %% never explains a missing token.
    ok = bondy_config:set([oauth2, max_tokens_per_user], 100),
    _ = bondy_realm:create(#{
        uri => ?REALM_URI,
        authmethods => [?WAMP_OAUTH2_AUTH, ?PASSWORD_AUTH],
        security_enabled => true,
        groups => [#{name => <<"g">>}],
        users => [],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => <<"all">>
            }
        ]
    }),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    try
        meck:unload(bondy_db)
    catch
        _:_ -> ok
    end,
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

two_scopes_sequential(_Config) ->
    %% Control: two scopes issued one after the other both survive.
    User = <<"seq_user">>,
    ok = add_user(User),
    {ok, _} = issue_token(User, device(1)),
    {ok, _} = issue_token(User, device(2)),
    ?assertEqual(2, user_band_size(User)).

two_scopes_concurrent(_Config) ->
    %% Two writers, two scopes, one user, their store writes released
    %% together: neither may lose the other's token.
    User = <<"race_user">>,
    ok = add_user(User),
    Coord = spawn_link(fun() -> rendezvous(2, []) end),
    ok = hold_at_write(Coord),

    Parent = self(),
    Pids = [
        spawn_link(fun() ->
            Parent ! {self(), issue_token(User, device(I))}
        end)
     || I <- [1, 2]
    ],
    Results = [
        receive
            {Pid, R} -> R
        after 10000 -> exit({timeout_waiting_for, Pid})
        end
     || Pid <- Pids
    ],
    ?assertMatch([{ok, _}, {ok, _}], Results),

    ?assertEqual(2, user_band_size(User)).

many_scopes_concurrent(_Config) ->
    %% Unaided: N concurrent issues, N distinct scopes, one user. No meck, no
    %% rendezvous — whatever interleaving the scheduler and the store produce.
    User = <<"storm_user">>,
    ok = add_user(User),
    Parent = self(),
    Pids = [
        spawn_link(fun() ->
            Parent ! {self(), issue_token(User, device(I))}
        end)
     || I <- lists:seq(1, ?N_CONCURRENT)
    ],
    Results = [
        receive
            {Pid, R} -> R
        after 30000 -> exit({timeout_waiting_for, Pid})
        end
     || Pid <- Pids
    ],
    Oks = [R || {ok, _} = R <- Results],
    Errors = [R || {error, _} = R <- Results],
    Size = user_band_size(User),
    ct:pal(
        "~p concurrent issues: ~p ok, ~p error(s) ~p -> ~p tokens in the band",
        [?N_CONCURRENT, length(Oks), length(Errors), Errors, Size]
    ),
    %% Every accepted issue must be in the band; a rejected one must not.
    ?assertEqual(length(Oks), Size),
    ?assertEqual([], Errors).

revoke_all_concurrent_with_issue(_Config) ->
    %% A user holds three tokens. An issue for a FOURTH scope is held right
    %% before its store write. Meanwhile `revoke_all/2` clears the user's
    %% band. The issuer is then released and writes its cell.
    %%
    %% Expected: revocation is final — afterwards the store holds at most the
    %% concurrently issued token, never the three revoked ones.
    User = <<"revoke_user">>,
    ok = add_user(User),
    Old = [issue_token(User, device(I)) || I <- [1, 2, 3]],
    ?assertMatch([{ok, _}, {ok, _}, {ok, _}], Old),
    ?assertEqual(3, user_band_size(User)),
    OldIds = lists:sort([bondy_oauth_token:id(T) || {ok, T} <- Old]),

    %% Rendezvous of ONE issuer: it parks before its write; the test process
    %% is the coordinator and releases it after the revoke.
    Coord = self(),
    ok = hold_at_write(Coord),
    Parent = self(),
    Issuer = spawn_link(fun() ->
        Parent ! {self(), issue_token(User, device(4))}
    end),
    receive
        {arrived, Issuer} -> ok
    after 5000 -> exit(issuer_never_reached_the_store)
    end,

    ok = bondy_oauth_token:revoke_all(?REALM_URI, User),
    ?assertEqual(0, user_band_size(User)),

    Issuer ! go,
    NewResult =
        receive
            {Issuer, R} -> R
        after 10000 -> exit(timeout_waiting_for_issuer)
        end,
    ?assertMatch({ok, _}, NewResult),
    {ok, NewT} = NewResult,

    Ids = lists:sort([bondy_oauth_token:id(T) || {_K, T, _H} <- user_band(User)]),
    Resurrected = [Id || Id <- Ids, lists:member(Id, OldIds)],
    ct:pal(
        "after revoke_all || issue: ~p tokens in the band, ~p of them revoked",
        [length(Ids), length(Resurrected)]
    ),
    ?assertEqual([], Resurrected),
    ?assertEqual([bondy_oauth_token:id(NewT)], Ids).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% Rendezvous at the token table's store write: `bondy_db:apply/4` with a
%% `{set, Token}` op on the token table parks the caller until the coordinator
%% says `go`, then passes through — the write itself is the real one. Clears
%% (revocation, the bound's trims) and every other table pass straight
%% through.
hold_at_write(Coord) ->
    TokenType = maps:get(entity_type, token_table()),
    ok = meck:new(bondy_db, [passthrough, no_link]),
    ok = meck:expect(bondy_db, apply, fun(Table, Realm, Key, Op) ->
        case {maps:get(entity_type, Table), Op} of
            {TokenType, {set, _}} ->
                Coord ! {arrived, self()},
                receive
                    go -> ok
                after 5000 -> exit(rendezvous_timeout)
                end;
            _ ->
                ok
        end,
        meck:passthrough([Table, Realm, Key, Op])
    end),
    ok.

%% @private
rendezvous(0, Waiting) ->
    _ = [Pid ! go || Pid <- Waiting],
    ok;
rendezvous(N, Waiting) ->
    receive
        {arrived, Pid} -> rendezvous(N - 1, [Pid | Waiting])
    end.

%% @private
add_user(Username) ->
    User = bondy_rbac_user:new(#{
        username => Username,
        password => ?PASS,
        groups => [<<"g">>]
    }),
    {ok, _} = bondy_rbac_user:add(?REALM_URI, User),
    ok.

%% @private
issue_token(User, DeviceId) ->
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, ?REALM_URI, User, [<<"g">>], {127, 0, 0, 1}
    ),
    bondy_oauth_token:issue(password, Ctxt, #{device_id => DeviceId}).

%% @private
user_band_size(User) ->
    length(user_band(User)).

%% @private
%% The user's band: every cell whose leading column is the user's hash, across
%% every shard.
user_band(User) ->
    {Lo, Hi} = bondy_oplog_index_key:col_bounds(store_key(User)),
    {ok, Rows} = bondy_db:fold(
        token_table(),
        ?REALM_URI,
        Lo,
        Hi,
        fun(Row, Acc) -> [Row | Acc] end,
        []
    ),
    lists:reverse(Rows).

%% @private
%% Mirrors `bondy_oauth_token:store_key/1` (private): the user column.
store_key(AuthId) ->
    base16:encode(crypto:hash(sha256, string:casefold(AuthId))).

%% @private
token_table() ->
    bondy_namespace_catalog:table(?BONDY_DB_OAUTH_TOKEN_TAB).

%% @private
device(I) ->
    <<"device_", (integer_to_binary(I))/binary>>.
