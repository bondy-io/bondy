%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Regression guard for the bounded token-storage shape (the plum_db → bondy_db
%% cut MUST preserve it): a user's OAuth tokens live in ONE bondy_db cell holding
%% a `bondy_oauth_token_set` bounded to `oauth2.max_tokens_per_user` and scoped
%% by `authscope` (client/device) — NOT one cell per token.
%%
%% These tests fail loudly if a future change ever explodes the storage to a
%% cell-per-token (which would break the per-user bound and let a user
%% accumulate unbounded tokens).
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

-export([bounded_set_caps_at_max/1]).
-export([one_cell_per_user_not_per_token/1]).
-export([user_delete_revokes_tokens/1]).
-export([refresh_rejects_token_whose_user_is_gone/1]).

all() ->
    [
        bounded_set_caps_at_max,
        one_cell_per_user_not_per_token,
        user_delete_revokes_tokens,
        refresh_rejects_token_whose_user_is_gone
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    %% Cap the per-user token set small so we can cross it quickly.
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

bounded_set_caps_at_max(_Config) ->
    %% Issue MAX + 3 refresh tokens for ONE user, each with a distinct
    %% device_id (a distinct authscope, so they accumulate in the set rather
    %% than replace). The set must be capped at MAX, NOT grow to N.
    N = ?MAX + 3,
    _ = [ok = issue(?USER, device(I)) || I <- lists:seq(1, N)],

    {ok, {Set, _Hlc}} =
        bondy_db:read(token_table(), ?REALM_URI, store_key(?USER)),

    ?assertEqual(?MAX, bondy_oauth_token_set:size(Set)),
    ?assertEqual(?MAX, length(bondy_oauth_token_set:to_list(Set))).

one_cell_per_user_not_per_token(_Config) ->
    %% Two users, many tokens each. The table must hold exactly ONE cell PER
    %% USER (the bounded set), regardless of how many tokens were issued — the
    %% core regression: a cell-per-token shape would yield ~2*(MAX+2) rows.
    _ = [ok = issue(?USER, device(I)) || I <- lists:seq(1, ?MAX + 2)],
    _ = [ok = issue(?USER2, device(I)) || I <- lists:seq(1, ?MAX + 2)],

    {ok, Rows} = bondy_db:list(token_table(), ?REALM_URI),
    Keys = lists:sort([K || {K, _V, _Hlc} <- Rows]),

    ?assertEqual(2, length(Keys)),
    ?assertEqual(
        lists:sort([store_key(?USER), store_key(?USER2)]), Keys
    ),
    %% And each cell still respects the bound.
    lists:foreach(
        fun(User) ->
            {ok, {Set, _}} =
                bondy_db:read(token_table(), ?REALM_URI, store_key(User)),
            ?assert(bondy_oauth_token_set:size(Set) =< ?MAX)
        end,
        [?USER, ?USER2]
    ).

user_delete_revokes_tokens(_Config) ->
    %% A user's tokens are a second cell hanging off the user record, in another
    %% table. Deleting the user must take them with it: a token cell outliving
    %% its user is storage nothing will ever read, and a user re-created under
    %% the same name would adopt the set.
    User = <<"tokendel">>,
    ok = add_user(User),
    ok = issue(User, device(1)),

    ?assertMatch(
        {ok, {_Set, _Hlc}},
        bondy_db:read(token_table(), ?REALM_URI, store_key(User))
    ),

    ok = bondy_rbac_user:remove(?REALM_URI, User),

    ?assertEqual(
        {error, not_found},
        bondy_db:read(token_table(), ?REALM_URI, store_key(User))
    ).

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
%% Mirrors `bondy_oauth_token:store_key/1` (private): the cell key is the sha256
%% of the casefolded authid — one key (one cell) per user.
store_key(AuthId) ->
    base16:encode(crypto:hash(sha256, string:casefold(AuthId))).

%% @private
token_table() ->
    bondy_namespace_catalog:table(?BONDY_DB_OAUTH_TOKEN_TAB).

%% @private
device(I) ->
    <<"device_", (integer_to_binary(I))/binary>>.
