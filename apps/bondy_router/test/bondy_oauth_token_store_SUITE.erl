%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Regression guard for the token-storage shape: ONE CELL PER TOKEN, keyed by
%% the subject and the scope (`[UserHash, Realm, ClientId, DeviceId]`, an
%% order-preserving composite whose user column leads), with the per-user bound
%% `oauth2.max_tokens_per_user` enforced over the user's band of cells.
%%
%% This REVERSES the shape this suite used to ratify — one cell per user holding
%% a bounded `bondy_oauth_token_set`. That shape made every write a
%% read-modify-write of the whole set: two concurrent issues of different scopes
%% for one user kept only the last writer's set, and a `revoke_all/2` that
%% interleaved with an issue was overwritten by the issue's stale set, revoked
%% tokens included (`bondy_oauth_token_concurrency_SUITE` demonstrated both).
%% One cell per token makes every write a single cell, so neither can happen.
%%
%% What the bound means now: at most MAX cells per user AFTER an issue returns
%% (the issuer trims its own band) and after `cleanup/0` (the authoritative
%% evictor) — `prop_bondy_oauth_token_bound` holds both. These tests fail loudly
%% if a change ever puts two tokens back in one cell, or lets a user's band grow
%% past the bound.
%% =============================================================================

-module(bondy_oauth_token_store_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bondy_security.hrl").
-include("bondy_db_tables.hrl").

-define(REALM_URI, <<"com.example.test.token_store">>).
-define(USER, <<"alice">>).
-define(USER2, <<"bob">>).
-define(PASS, <<"aWe11KeptSecret">>).
%% A small cap so the test is fast and deterministic.
-define(MAX, 3).

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).

-export([band_is_bounded_after_each_issue/1]).
-export([newest_token_survives_its_own_issue/1]).
-export([one_cell_per_token_not_per_user/1]).
-export([reissue_in_scope_replaces_the_cell/1]).
-export([refresh_rotates_in_place/1]).
-export([revoke_by_string_clears_only_that_cell/1]).
-export([user_delete_revokes_tokens/1]).
-export([refresh_rejects_token_whose_user_is_gone/1]).
-export([refresh_token_of_access_only_grant_raises_badarg/1]).
-export([credential_change_revokes_tokens/1]).

all() ->
    [
        band_is_bounded_after_each_issue,
        newest_token_survives_its_own_issue,
        one_cell_per_token_not_per_user,
        reissue_in_scope_replaces_the_cell,
        refresh_rotates_in_place,
        revoke_by_string_clears_only_that_cell,
        user_delete_revokes_tokens,
        refresh_rejects_token_whose_user_is_gone,
        refresh_token_of_access_only_grant_raises_badarg,
        credential_change_revokes_tokens
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    %% Cap the per-user bound small so we can cross it quickly.
    ok = bondy_config:set([oauth2, max_tokens_per_user], ?MAX),
    _ = bondy_realm:create(#{
        uri => ?REALM_URI,
        authmethods => [?WAMP_OAUTH2_AUTH, ?PASSWORD_AUTH],
        security_enabled => true,
        groups => [#{name => <<"g">>}],
        users => [
            #{username => ?USER, password => ?PASS, groups => [<<"g">>]},
            #{username => ?USER2, password => ?PASS, groups => [<<"g">>]}
        ],
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

%% =============================================================================
%% TESTS
%% =============================================================================

band_is_bounded_after_each_issue(_Config) ->
    %% Issue MAX + 3 refresh tokens for ONE user, each with a distinct
    %% device_id (a distinct scope, so each is its own cell). After every
    %% issue the user's band holds at most MAX cells; at the end exactly MAX,
    %% all of them issued here, and none of them expiring before an evicted
    %% one. Which of the equally-expiring tokens went is
    %% `newest_token_survives_its_own_issue`'s claim, not this one's.
    N = ?MAX + 3,
    Issued = [
        begin
            {ok, T} = issue_token(?USER, device(I)),
            ?assert(length(user_band(?USER)) =< ?MAX),
            T
        end
     || I <- lists:seq(1, N)
    ],
    Live = [T || {_K, T, _H} <- user_band(?USER)],
    ?assertEqual(?MAX, length(Live)),
    LiveIds = lists:sort([bondy_oauth_token:id(T) || T <- Live]),
    IssuedIds = [bondy_oauth_token:id(T) || T <- Issued],
    ?assertEqual([], LiveIds -- IssuedIds),
    Evicted = [
        T
     || T <- Issued, not lists:member(bondy_oauth_token:id(T), LiveIds)
    ],
    ?assertEqual(N - ?MAX, length(Evicted)),
    ?assert(
        lists:min([bondy_oauth_token:expires_at(T) || T <- Live]) >=
            lists:max([bondy_oauth_token:expires_at(T) || T <- Evicted])
    ).

newest_token_survives_its_own_issue(_Config) ->
    %% The bound's promise, stated as a client sees it: an issue past the
    %% bound evicts an OLD token, never the one just handed out, and the
    %% survivors are the last MAX issued. All MAX + 3 tokens here are issued
    %% within one second, so they share `expires_at` and the ordering below
    %% the expiry — the write order — is the only thing deciding who goes.
    User = <<"newest">>,
    ok = add_user(User),
    N = ?MAX + 3,
    Issued = lists:foldl(
        fun(I, Acc) ->
            {ok, T} = issue_token(User, device(I)),
            RT = bondy_oauth_token:to_refresh_token(T),
            ?assertMatch(
                {ok, _},
                bondy_oauth_token:lookup(?REALM_URI, RT),
                "the token just issued must be live"
            ),
            All = Acc ++ [T],
            Expected = lists:sort([
                bondy_oauth_token:id(X)
             || X <- lists:nthtail(max(0, length(All) - ?MAX), All)
            ]),
            ?assertEqual(
                Expected,
                lists:sort([
                    bondy_oauth_token:id(X)
                 || {_, X, _} <- user_band(User)
                ]),
                "the survivors must be the last MAX issued"
            ),
            All
        end,
        [],
        lists:seq(1, N)
    ),
    ?assertEqual(N, length(Issued)),
    T0 = erlang:system_time(second),
    Expiries = lists:usort([bondy_oauth_token:expires_at(T) || T <- Issued]),
    %% The precondition the case rests on: one expiry second for all N.
    %% (If the run straddled a second boundary the case is inconclusive,
    %% not failed; it says so.)
    length(Expiries) =:= 1 orelse
        ct:comment("issues straddled a second boundary at ~p", [T0]).

one_cell_per_token_not_per_user(_Config) ->
    %% Two users, MAX tokens each. The table holds exactly ONE cell PER TOKEN
    %% — 2 * MAX rows for the two of them (other cases' users share the realm,
    %% so the count is taken over these two users' rows) — every key a
    %% composite led by the user's hash, and each user's band holds exactly
    %% that user's tokens.
    _ = [ok = issue(?USER, device(I)) || I <- lists:seq(1, ?MAX)],
    _ = [ok = issue(?USER2, device(I)) || I <- lists:seq(1, ?MAX)],

    {ok, AllRows} = bondy_db:list(token_table(), ?REALM_URI),
    Hashes = [store_key(?USER), store_key(?USER2)],
    Rows = [
        Row
     || {Key, _, _} = Row <- AllRows,
        lists:member(hd(bondy_oplog_index_key:decode_tuple(Key)), Hashes)
    ],
    ?assertEqual(2 * ?MAX, length(Rows)),
    lists:foreach(
        fun({Key, #{type := bondy_oauth_token, authid := AuthId}, _Hlc}) ->
            ?assertMatch(
                [_UserHash, ?REALM_URI, all, _Device],
                bondy_oplog_index_key:decode_tuple(Key)
            ),
            ?assertEqual(
                store_key(AuthId), hd(bondy_oplog_index_key:decode_tuple(Key))
            )
        end,
        Rows
    ),
    ?assertEqual(?MAX, length(user_band(?USER))),
    ?assertEqual(?MAX, length(user_band(?USER2))),
    ?assertEqual(
        [?USER],
        lists:usort([
            bondy_oauth_token:authid(T)
         || {_, T, _} <- user_band(?USER)
        ])
    ).

reissue_in_scope_replaces_the_cell(_Config) ->
    %% Re-issuing for the same device overwrites that device's cell: the band
    %% does not grow, the new id is what the cell holds, and the previous
    %% refresh-token string no longer names a token.
    User = <<"reissue">>,
    ok = add_user(User),
    {ok, T1} = issue_token(User, device(1)),
    {ok, T2} = issue_token(User, device(1)),
    ?assertEqual(1, length(user_band(User))),
    [{_Key, Stored, _Hlc}] = user_band(User),
    ?assertEqual(bondy_oauth_token:id(T2), bondy_oauth_token:id(Stored)),
    ?assertEqual(
        {error, oauth2_invalid_grant},
        bondy_oauth_token:refresh(
            ?REALM_URI, bondy_oauth_token:to_refresh_token(T1)
        )
    ).

refresh_rotates_in_place(_Config) ->
    %% A refresh rewrites the SAME cell with a new id and string. The presented
    %% string stops resolving; the band does not grow.
    User = <<"rotate">>,
    ok = add_user(User),
    {ok, T1} = issue_token(User, device(1)),
    RT1 = bondy_oauth_token:to_refresh_token(T1),
    {ok, T2} = bondy_oauth_token:refresh(?REALM_URI, RT1),
    ?assertNotEqual(bondy_oauth_token:id(T1), bondy_oauth_token:id(T2)),
    ?assertEqual(1, length(user_band(User))),
    [{_Key, Stored, _Hlc}] = user_band(User),
    ?assertEqual(bondy_oauth_token:id(T2), bondy_oauth_token:id(Stored)),
    ?assertEqual(
        {error, oauth2_invalid_grant},
        bondy_oauth_token:refresh(?REALM_URI, RT1)
    ),
    ?assertMatch(
        {ok, _},
        bondy_oauth_token:refresh(
            ?REALM_URI, bondy_oauth_token:to_refresh_token(T2)
        )
    ).

revoke_by_string_clears_only_that_cell(_Config) ->
    %% Revocation is per token: the revoked device's cell is cleared, the
    %% user's other cells are untouched.
    User = <<"revokeone">>,
    ok = add_user(User),
    {ok, T1} = issue_token(User, device(1)),
    {ok, _T2} = issue_token(User, device(2)),
    ?assertEqual(2, length(user_band(User))),
    ?assertEqual(
        ok,
        bondy_oauth_token:revoke(
            ?REALM_URI, bondy_oauth_token:to_refresh_token(T1)
        )
    ),
    ?assertEqual(
        [device(2)],
        [
            bondy_auth_scope:device_id(bondy_oauth_token:authscope(T))
         || {_, T, _} <- user_band(User)
        ]
    ).

user_delete_revokes_tokens(_Config) ->
    %% A user's tokens are cells hanging off the user record, in another
    %% table. Deleting the user must take them with it: a token cell outliving
    %% its user is storage nothing will ever read, and a user re-created under
    %% the same name would adopt the tokens.
    User = <<"tokendel">>,
    ok = add_user(User),
    ok = issue(User, device(1)),
    ok = issue(User, device(2)),
    ?assertEqual(2, length(user_band(User))),

    ok = bondy_rbac_user:remove(?REALM_URI, User),

    ?assertEqual([], user_band(User)).

refresh_rejects_token_whose_user_is_gone(_Config) ->
    %% A token can outlive its user whatever the delete path does — an import,
    %% a peer's merge, a half-applied teardown. Redeeming one must be a clean
    %% refusal, not a crash: `refresh/2` names `oauth2_invalid_grant` as the
    %% answer for a vanished user, and that answer has to be reachable.
    User = <<"tokenorphan">>,
    ok = add_user(User),
    {ok, Token} = issue_token(User, device(1)),
    RefreshToken = bondy_oauth_token:to_refresh_token(Token),

    %% Clear the USER cell only, leaving the token cell in place — the state a
    %% delete path that forgets the tokens leaves behind.
    UserTab = bondy_namespace_catalog:table(?BONDY_DB_USER_TAB),
    ok = bondy_db:apply(UserTab, ?REALM_URI, User, clear),
    ?assertEqual({error, not_found}, bondy_rbac_user:lookup(?REALM_URI, User)),

    ?assertEqual(
        {error, oauth2_invalid_grant},
        bondy_oauth_token:refresh(?REALM_URI, RefreshToken)
    ).

refresh_token_of_access_only_grant_raises_badarg(_Config) ->
    %% A `client_credentials` token is access-only, so asking it for a refresh
    %% token is a caller error. It must be reported as `badarg`, the term a
    %% caller can actually match on.
    User = <<"ccgrant">>,
    ok = add_user(User),
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, ?REALM_URI, User, [<<"g">>], {127, 0, 0, 1}
    ),
    {ok, Token} = bondy_oauth_token:issue(client_credentials, Ctxt, #{}),

    ?assertError(badarg, bondy_oauth_token:to_refresh_token(Token)).

credential_change_revokes_tokens(_Config) ->
    %% A password change fences every token issued before it — the
    %% `token_version` they carry no longer matches the user's, so they cannot
    %% authenticate. They are also removed from storage, off the
    %% credentials-changed event, which is what this pins: reclamation drops
    %% expired tokens and those whose user is gone, never fenced ones, so a
    %% token left behind here would sit in its cell until its refresh lifetime
    %% ran out.
    User = <<"pwchange">>,
    ok = add_user(User),
    {ok, Token} = issue_token(User, device(1)),
    RefreshToken = bondy_oauth_token:to_refresh_token(Token),

    ?assertEqual(1, length(user_band(User))),

    ok = bondy_rbac_user:change_password(
        ?REALM_URI, User, <<"aD1fferentSecret">>, ?PASS
    ),

    %% Revocation runs off the event, so it lands shortly after the call
    %% returns rather than within it.
    ok = wait_until(fun() -> user_band(User) =:= [] end, 5000),
    ?assertEqual(
        {error, oauth2_invalid_grant},
        bondy_oauth_token:refresh(?REALM_URI, RefreshToken)
    ).

wait_until(_Fun, Remaining) when Remaining =< 0 ->
    {error, timeout};
wait_until(Fun, Remaining) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_until(Fun, Remaining - 100)
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

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
%% Issue one refresh token (password grant → refresh type) for `User`, scoped to
%% `DeviceId` so each issue is a distinct authscope.
issue(User, DeviceId) ->
    {ok, _Token} = issue_token(User, DeviceId),
    ok.

%% @private
issue_token(User, DeviceId) ->
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, ?REALM_URI, User, [<<"g">>], {127, 0, 0, 1}
    ),
    bondy_oauth_token:issue(password, Ctxt, #{device_id => DeviceId}).

%% @private
%% Mirrors `bondy_oauth_token:store_key/1` (private): the user column of every
%% cell key is the sha256 of the casefolded authid.
store_key(AuthId) ->
    base16:encode(crypto:hash(sha256, string:casefold(AuthId))).

%% @private
%% The user's band, read the way the module reads it: every cell whose leading
%% column is the user's hash, across every shard (no pin — the test asserts on
%% the whole table's truth, not on placement).
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
token_table() ->
    bondy_namespace_catalog:table(?BONDY_DB_OAUTH_TOKEN_TAB).

%% @private
device(I) ->
    <<"device_", (integer_to_binary(I))/binary>>.
