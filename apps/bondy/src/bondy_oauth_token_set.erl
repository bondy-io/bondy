%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oauth_token_set).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-type t()   ::  #{
                    type := ?MODULE,
                    data := data(),
                    index := index(),
                    size := non_neg_integer()
                }.
-type data()    ::  #{bondy_auth_scope:t() => bondy_oauth_token:t()}.
-type index()   ::  #{bondy_oauth_token:token_id() => bondy_auth_scope:t()}.

-export_type([t/0]).


-export([add/2]).
-export([cleanup/1]).
-export([cleanup/2]).
-export([cleanup_and_truncate/2]).
-export([cleanup_and_truncate/3]).
-export([find/2]).
-export([find/3]).
-export([merge/2]).
-export([new/0]).
-export([remove/2]).
-export([remove/3]).
-export([size/1]).
-export([take/2]).
-export([take/3]).
-export([to_list/1]).
-export([truncate/2]).



%% =============================================================================
%% API
%% =============================================================================



-doc "Create a new empty token store".
-spec new() -> t().

new() ->
    #{type => ?MODULE, data => #{}, index => #{}, size => 0}.


-doc "Add/replace a token to/in the store according to its `authscope`.".
-spec add(t(), bondy_oauth_token:t()) -> t().

add(#{type := ?MODULE, data := Data0, index := Index0} = T, Token) ->
    Scope = bondy_oauth_token:authscope(Token),
    TokenId = maps:get(id, Token),

    {Index1, Data1} =
        case maps:take(Scope, Data0) of
            {#{id := OldTokenId}, NewData} ->
                {maps:remove(OldTokenId, Index0), NewData};

            error ->
                {Index0, Data0}
        end,

    Index = maps:put(TokenId, Scope, Index1),
    Data = maps:put(Scope, Token, Data1),
    Size = maps:size(Data),
    Size = maps:size(Index),
    T#{data => Data, index => Index, size => Size}.


-doc "Removes a token from the store".
-spec remove(t(), bondy_auth_scope:t()) -> t().

remove(#{type := ?MODULE, data := Data0, index := Index0} = T, Scope)
when is_map(Scope) ->
    case maps:take(Scope, Data0) of
        {#{id := TokenId}, Data} ->
            Index = maps:remove(TokenId, Index0),
            Size = maps:size(Data),
            Size = maps:size(Index),
            T#{data => Data, index => Index, size => Size};

        error ->
            T
    end.


-doc "Removes a token from the store".
-spec remove(t(), bondy_auth_scope:t(), binary()) -> t().

remove(#{type := ?MODULE} = T0, Scope, TokenId)
when is_map(Scope) andalso is_binary(TokenId) ->
    case take(T0, Scope, TokenId) of
        {ok, {_, T}} ->
            T;

        {error, not_found} ->
            T0
    end.

-doc "Removes a token from the store and returns it".
-spec take(t(), bondy_auth_scope:t()) ->
    {ok, {bondy_oauth_token:t(), t()}} | {error, not_found}.

take(#{type := ?MODULE, data := Data0, index := Index0} = T0, Scope)
when is_map(Scope) ->
    case maps:find(Scope, Data0) of
        {ok, #{id := TokenId} = Token} ->
            Data = maps:remove(Scope, Data0),
            Index = maps:remove(TokenId, Index0),
            Size = maps:size(Data),
            Size = maps:size(Index),
            T1 = T0#{data => Data, index => Index, size => Size},
            {ok, {Token, T1}};

        error ->
            {error, not_found}
    end.


-doc "Removes a token from the store and returns it".
-spec take(t(), bondy_auth_scope:t(), binary()) ->
    {ok, {bondy_oauth_token:t(), t()}} | {error, not_found}.

take(#{type := ?MODULE, index := Index0} = T, Scope, TokenId)
when is_map(Scope) andalso is_binary(TokenId) ->
    case maps:find(TokenId, Index0) of
        {ok, S} when S == Scope ->
            take(T, Scope);

        {ok, _} ->
            {error, not_found};

        error ->
            {error, not_found}
    end.


-doc "Merge two token stores".
-spec merge(t(), t()) -> t().

merge(#{type := ?MODULE} = T1, #{type := ?MODULE} = T2) ->
    #{data := D1} = T1,
    #{data := D2} = T2,
    D = maps:merge(D1, D2),
    I = maps:fold(
        fun(Key, #{id := TokenId}, Acc) ->
            maps:put(TokenId, Key, Acc)
        end,
        #{},
        D
    ),
    T1#{data => D, index => I, size => maps:size(D)}.


-doc "Remove all expired tokens from the store".
-spec cleanup(t()) ->
    {[bondy_oauth_token:t()], t()}.

cleanup(T) ->
    cleanup(T, erlang:system_time(second)).


-doc "Remove all expired tokens from the store".
-spec cleanup(t(), Now :: non_neg_integer()) ->
    {[bondy_oauth_token:t()], t()}.

cleanup(#{type := ?MODULE, data := Data0, index := Index0} = T, Now) ->

    {Expired, Data, Index} =
        maps:fold(
            fun(Key, Token, {ExpAcc, DataAcc, IndexAcc}) ->
                case bondy_oauth_token:is_expired(Token, Now) of
                    true ->
                        #{id := TokenId} = Token,
                        {
                            [Token | ExpAcc],
                            maps:remove(Key, DataAcc),
                            maps:remove(TokenId, IndexAcc)
                        };

                    false ->
                        {ExpAcc, DataAcc, IndexAcc}
                end
            end,
            {[], Data0, Index0},
            Data0
        ),

    {Expired, T#{data => Data, index => Index, size => maps:size(Data)}}.


-doc """
Keeps the most recent `MaxSize` tokens on the set, returning those removed
if any.
""".
-spec truncate(t(), MaxSize :: non_neg_integer()) ->
    {[bondy_oauth_token:t()], t()}.

truncate(#{type := ?MODULE, size := Size} = T, MaxSize)
when Size =< MaxSize ->
    {[], T};

truncate(#{type := ?MODULE, size := Size} = T0, MaxSize) ->
    Truncated = lists:sublist(to_list(T0), MaxSize + 1, Size),
    T = lists:foldl(
        fun(#{id := Id, authscope := Scope}, Acc) ->
            remove(Acc, Scope, Id)
        end,
        T0,
        Truncated
    ),
    {Truncated, T}.


-doc """
Util function.
""".
-spec cleanup_and_truncate(t(), MaxSize :: non_neg_integer()) ->
    {[bondy_oauth_token:t()], t()}.

cleanup_and_truncate(#{type := ?MODULE} = T, MaxSize) ->
    cleanup_and_truncate(T, MaxSize, erlang:system_time(second)).


-doc """
Util function.
""".
-spec cleanup_and_truncate(
    t(), MaxSize :: non_neg_integer(), Now :: non_neg_integer()) ->
    {[bondy_oauth_token:t()], t()}.

cleanup_and_truncate(#{type := ?MODULE} = T0, MaxSize, Now) ->
    {Removed, T1} = cleanup(T0, Now),
    {Truncated, T} = truncate(T1, MaxSize),
    {Removed ++ Truncated, T}.


-doc "Find a token based on scope or TokenId".
-spec find(t(), bondy_auth_scope:t() | bondy_oauth_token:token_id()) ->
    {ok, bondy_oauth_token:t()} | {error, not_found}.

find(#{type := ?MODULE, data := Data}, Scope) when is_map(Scope) ->
    case maps:find(Scope, Data) of
        {ok, _} = OK ->
            OK;

        error ->
            {error, not_found}
    end;

find(#{type := ?MODULE, index := Index} = T, TokenId) when is_binary(TokenId) ->
    case maps:find(TokenId, Index) of
        {ok, Scope} ->
            find(T, Scope);

        error ->
            {error, not_found}
    end.


-doc "Find a token based on scope and TokenId".
-spec find(t(), bondy_auth_scope:t(), binary()) ->
    {ok, bondy_oauth_token:t()} | {error, not_found}.

find(#{type := ?MODULE, index := Index} = T, Scope, TokenId)
when is_map(Scope) andalso is_binary(TokenId) ->
    case maps:find(TokenId, Index) of
        {ok, S} when S == Scope ->
            find(T, Scope);

        {ok, _} ->
            {error, not_found};

        error ->
            {error, not_found}
    end.


-doc "Returns the number of tokens".
-spec size(t()) -> non_neg_integer().

size(#{type := ?MODULE, size := Size}) ->
    Size.


-doc "Convert set to a flat list sorted by `refreshed_at`".
-spec to_list(t()) -> [bondy_oauth_token:t()].

to_list(#{type := ?MODULE, data := Data}) ->
    lists:sort(
        fun(A, B) ->
            bondy_oauth_token:expires_at(A) >= bondy_oauth_token:expires_at(B)
        end,
        maps:values(Data)
    ).




%% =============================================================================
%% TEST
%% =============================================================================


-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").


%% =============================================================================
%% TEST FIXTURES
%% =============================================================================

%% Mock token creation helper
mock_token(Id, Scope, ExpiresAt) ->
    Now = erlang:system_time(second),

    #{
        type => bondy_oauth_token,
        version => ~"1",
        token_type => refresh,
        grant_type => password,
        id => Id,
        authscope => Scope,
        expires_in => ExpiresAt,
        created_at => Now,
        refreshed_at => Now,
        issued_at => Now
    }.

%% Mock scope creation helper
mock_scope(Name) ->
    #{
        name => Name,
        realm => <<"test_realm">>,
        device_id => all,
        client_id => all
    }.

%% Helper to create a token set with multiple tokens for testing
setup_multi_token_set() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope1 = mock_scope(<<"read">>),
    Scope2 = mock_scope(<<"write">>),
    Scope3 = mock_scope(<<"admin">>),

    Token1 = mock_token(<<"token1">>, Scope1, 3600),
    Token2 = mock_token(<<"token2">>, Scope2, 7200),
    Token3 = mock_token(<<"token3">>, Scope3, 1800),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token1),
    TokenSet2 = bondy_oauth_token_set:add(TokenSet1, Token2),
    TokenSet3 = bondy_oauth_token_set:add(TokenSet2, Token3),

    {TokenSet3, [Token1, Token2, Token3], [Scope1, Scope2, Scope3]}.

%% =============================================================================
%% TESTS
%% =============================================================================

%% -----------------------------------------------------------------------------
%% new/0 tests
%% -----------------------------------------------------------------------------

new_test() ->
    TokenSet = bondy_oauth_token_set:new(),
    ?assertEqual(?MODULE, maps:get(type, TokenSet)),
    ?assertEqual(#{}, maps:get(data, TokenSet)),
    ?assertEqual(0, maps:get(size, TokenSet)),
    %% Check that index field is present (new in this version)
    ?assert(maps:is_key(index, TokenSet)),
    ?assertEqual(#{}, maps:get(index, TokenSet)).

%% -----------------------------------------------------------------------------
%% add/2 tests
%% -----------------------------------------------------------------------------

add_single_token_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),

    ?assertEqual(1, bondy_oauth_token_set:size(TokenSet1)),
    ?assertEqual({ok, Token}, bondy_oauth_token_set:find(TokenSet1, Scope, <<"token1">>)),

    %% Check that index is updated
    Index = maps:get(index, TokenSet1),
    ?assertEqual(Scope, maps:get(<<"token1">>, Index)).

add_multiple_tokens_different_scopes_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope1 = mock_scope(<<"read">>),
    Scope2 = mock_scope(<<"write">>),
    Token1 = mock_token(<<"token1">>, Scope1, 3600),
    Token2 = mock_token(<<"token2">>, Scope2, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token1),
    TokenSet2 = bondy_oauth_token_set:add(TokenSet1, Token2),

    ?assertEqual(2, bondy_oauth_token_set:size(TokenSet2)),
    ?assertEqual({ok, Token1}, bondy_oauth_token_set:find(TokenSet2, Scope1, <<"token1">>)),
    ?assertEqual({ok, Token2}, bondy_oauth_token_set:find(TokenSet2, Scope2, <<"token2">>)),

    %% Check index integrity
    Index = maps:get(index, TokenSet2),
    ?assertEqual(Scope1, maps:get(<<"token1">>, Index)),
    ?assertEqual(Scope2, maps:get(<<"token2">>, Index)).

add_replace_token_same_scope_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token1 = mock_token(<<"token1">>, Scope, 3600),
    Token2 = mock_token(<<"token2">>, Scope, 7200),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token1),
    TokenSet2 = bondy_oauth_token_set:add(TokenSet1, Token2),

    %% Size should remain 1 as token was replaced
    ?assertEqual(1, bondy_oauth_token_set:size(TokenSet2)),
    ?assertEqual({error, not_found}, bondy_oauth_token_set:find(TokenSet2, Scope, <<"token1">>)),
    ?assertEqual({ok, Token2}, bondy_oauth_token_set:find(TokenSet2, Scope, <<"token2">>)),

    %% Check index is properly updated
    Index = maps:get(index, TokenSet2),
    ?assertNot(maps:is_key(<<"token1">>, Index)),
    ?assertEqual(Scope, maps:get(<<"token2">>, Index)).

%% -----------------------------------------------------------------------------
%% remove/2 tests
%% -----------------------------------------------------------------------------

remove_existing_scope_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    TokenSet2 = bondy_oauth_token_set:remove(TokenSet1, Scope),

    ?assertEqual(0, bondy_oauth_token_set:size(TokenSet2)),
    ?assertEqual({error, not_found}, bondy_oauth_token_set:find(TokenSet2, Scope, <<"token1">>)),

    %% Check index is cleaned up
    Index = maps:get(index, TokenSet2),
    ?assertNot(maps:is_key(<<"token1">>, Index)).

remove_non_existing_scope_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope1 = mock_scope(<<"read">>),
    Scope2 = mock_scope(<<"write">>),
    Token = mock_token(<<"token1">>, Scope1, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    TokenSet2 = bondy_oauth_token_set:remove(TokenSet1, Scope2),

    %% Should remain unchanged
    ?assertEqual(1, bondy_oauth_token_set:size(TokenSet2)),
    ?assertEqual({ok, Token}, bondy_oauth_token_set:find(TokenSet2, Scope1, <<"token1">>)).

%% -----------------------------------------------------------------------------
%% remove/3 tests
%% -----------------------------------------------------------------------------

remove_with_matching_token_id_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    TokenSet2 = bondy_oauth_token_set:remove(TokenSet1, Scope, <<"token1">>),

    ?assertEqual(0, bondy_oauth_token_set:size(TokenSet2)),
    ?assertEqual({error, not_found}, bondy_oauth_token_set:find(TokenSet2, Scope, <<"token1">>)).

remove_with_non_matching_token_id_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    TokenSet2 = bondy_oauth_token_set:remove(TokenSet1, Scope, <<"wrong_token">>),

    %% Should remain unchanged
    ?assertEqual(1, bondy_oauth_token_set:size(TokenSet2)),
    ?assertEqual({ok, Token}, bondy_oauth_token_set:find(TokenSet2, Scope, <<"token1">>)).

%% -----------------------------------------------------------------------------
%% take/3 tests
%% -----------------------------------------------------------------------------

take_existing_token_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    Result = bondy_oauth_token_set:take(TokenSet1, Scope, <<"token1">>),

    ?assertMatch({ok, {Token, _}}, Result),
    {ok, {ReturnedToken, TokenSet2}} = Result,
    ?assertEqual(Token, ReturnedToken),
    ?assertEqual(0, bondy_oauth_token_set:size(TokenSet2)),
    ?assertEqual({error, not_found}, bondy_oauth_token_set:find(TokenSet2, Scope, <<"token1">>)),

    %% Check index is cleaned up
    Index = maps:get(index, TokenSet2),
    ?assertNot(maps:is_key(<<"token1">>, Index)).

take_non_existing_token_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    Result = bondy_oauth_token_set:take(TokenSet1, Scope, <<"wrong_token">>),

    ?assertEqual({error, not_found}, Result).

%% -----------------------------------------------------------------------------
%% merge/2 tests
%% -----------------------------------------------------------------------------

merge_empty_sets_test() ->
    TokenSet1 = bondy_oauth_token_set:new(),
    TokenSet2 = bondy_oauth_token_set:new(),

    Merged = bondy_oauth_token_set:merge(TokenSet1, TokenSet2),

    ?assertEqual(0, bondy_oauth_token_set:size(Merged)).

merge_non_overlapping_sets_test() ->
    TokenSet1 = bondy_oauth_token_set:new(),
    TokenSet2 = bondy_oauth_token_set:new(),
    Scope1 = mock_scope(<<"read">>),
    Scope2 = mock_scope(<<"write">>),
    Token1 = mock_token(<<"token1">>, Scope1, 3600),
    Token2 = mock_token(<<"token2">>, Scope2, 3600),

    TokenSet1Updated = bondy_oauth_token_set:add(TokenSet1, Token1),
    TokenSet2Updated = bondy_oauth_token_set:add(TokenSet2, Token2),
    Merged = bondy_oauth_token_set:merge(TokenSet1Updated, TokenSet2Updated),

    ?assertEqual(2, bondy_oauth_token_set:size(Merged)),
    ?assertEqual({ok, Token1}, bondy_oauth_token_set:find(Merged, Scope1, <<"token1">>)),
    ?assertEqual({ok, Token2}, bondy_oauth_token_set:find(Merged, Scope2, <<"token2">>)),

    %% Check index integrity
    Index = maps:get(index, Merged),
    ?assertEqual(Scope1, maps:get(<<"token1">>, Index)),
    ?assertEqual(Scope2, maps:get(<<"token2">>, Index)).

merge_overlapping_sets_test() ->
    TokenSet1 = bondy_oauth_token_set:new(),
    TokenSet2 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token1 = mock_token(<<"token1">>, Scope, 3600),
    Token2 = mock_token(<<"token2">>, Scope, 7200),

    TokenSet1Updated = bondy_oauth_token_set:add(TokenSet1, Token1),
    TokenSet2Updated = bondy_oauth_token_set:add(TokenSet2, Token2),
    Merged = bondy_oauth_token_set:merge(TokenSet1Updated, TokenSet2Updated),

    %% Token2 should overwrite Token1 due to maps:merge behavior
    ?assertEqual(1, bondy_oauth_token_set:size(Merged)),
    ?assertEqual({ok, Token2}, bondy_oauth_token_set:find(Merged, Scope, <<"token2">>)),

    %% Check index shows the correct mapping
    Index = maps:get(index, Merged),
    ?assertEqual(Scope, maps:get(<<"token2">>, Index)).

%% -----------------------------------------------------------------------------
%% cleanup/1 and cleanup/2 tests
%% -----------------------------------------------------------------------------

cleanup_no_args_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    %% Token expired
    Token = mock_token(<<"token1">>, Scope, 0),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    {Expired, TokenSet2} = bondy_oauth_token_set:cleanup(TokenSet1),

    ?assertEqual([Token], Expired),
    ?assertEqual(0, bondy_oauth_token_set:size(TokenSet2)).

cleanup_no_expired_tokens_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    %% Token expires in 1 hour
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    {Expired, TokenSet2} = bondy_oauth_token_set:cleanup(TokenSet1, erlang:system_time(second)),

    ?assertEqual([], Expired),
    ?assertEqual(1, bondy_oauth_token_set:size(TokenSet2)),
    ?assertEqual({ok, Token}, bondy_oauth_token_set:find(TokenSet2, Scope, <<"token1">>)).

cleanup_expired_tokens_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    %% Token expired
    Token = mock_token(<<"token1">>, Scope, 0),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    {Expired, TokenSet2} = bondy_oauth_token_set:cleanup(TokenSet1, erlang:system_time(second)),

    ?assertEqual([Token], Expired),
    ?assertEqual(0, bondy_oauth_token_set:size(TokenSet2)),
    ?assertEqual({error, not_found}, bondy_oauth_token_set:find(TokenSet2, Scope, <<"token1">>)).

cleanup_mixed_tokens_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope1 = mock_scope(<<"read">>),
    Scope2 = mock_scope(<<"write">>),
    %% One expired, one valid
    ExpiredToken = mock_token(<<"expired">>, Scope1, 0),
    ValidToken = mock_token(<<"valid">>, Scope2, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, ExpiredToken),
    TokenSet2 = bondy_oauth_token_set:add(TokenSet1, ValidToken),
    {Expired, TokenSet3} = bondy_oauth_token_set:cleanup(TokenSet2, erlang:system_time(second)),

    ?assertEqual([ExpiredToken], Expired),
    ?assertEqual(1, bondy_oauth_token_set:size(TokenSet3)),
    ?assertEqual({error, not_found}, bondy_oauth_token_set:find(TokenSet3, Scope1, <<"expired">>)),
    ?assertEqual({ok, ValidToken}, bondy_oauth_token_set:find(TokenSet3, Scope2, <<"valid">>)).

%% -----------------------------------------------------------------------------
%% truncate/2 tests
%% -----------------------------------------------------------------------------

truncate_no_truncation_needed_test() ->
    {TokenSet, _Tokens, _Scopes} = setup_multi_token_set(),

    %% Request to keep 5 tokens when we only have 3
    {Removed, TokenSet2} = bondy_oauth_token_set:truncate(TokenSet, 5),

    ?assertEqual([], Removed),
    ?assertEqual(3, bondy_oauth_token_set:size(TokenSet2)),
    ?assertEqual(TokenSet, TokenSet2).

truncate_keep_zero_test() ->
    {TokenSet, _Tokens, _Scopes} = setup_multi_token_set(),

    {Removed, TokenSet2} = bondy_oauth_token_set:truncate(TokenSet, 0),

    ?assertEqual(3, length(Removed)),
    ?assertEqual(0, bondy_oauth_token_set:size(TokenSet2)).

truncate_keep_one_test() ->
    {TokenSet, _Tokens, _Scopes} = setup_multi_token_set(),

    {Removed, TokenSet2} = bondy_oauth_token_set:truncate(TokenSet, 1),

    ?assertEqual(2, length(Removed)),
    ?assertEqual(1, bondy_oauth_token_set:size(TokenSet2)).

truncate_keep_two_test() ->
    {TokenSet, _Tokens, _Scopes} = setup_multi_token_set(),

    {Removed, TokenSet2} = bondy_oauth_token_set:truncate(TokenSet, 2),

    ?assertEqual(1, length(Removed)),
    ?assertEqual(2, bondy_oauth_token_set:size(TokenSet2)).

truncate_empty_set_test() ->
    TokenSet = bondy_oauth_token_set:new(),

    {Removed, TokenSet2} = bondy_oauth_token_set:truncate(TokenSet, 5),

    ?assertEqual([], Removed),
    ?assertEqual(0, bondy_oauth_token_set:size(TokenSet2)).

%% -----------------------------------------------------------------------------
%% cleanup_and_truncate/2 and cleanup_and_truncate/3 tests
%% -----------------------------------------------------------------------------

cleanup_and_truncate_two_args_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope1 = mock_scope(<<"read">>),
    Scope2 = mock_scope(<<"write">>),
    Scope3 = mock_scope(<<"admin">>),

    %% Create one expired and two valid tokens
    ExpiredToken = mock_token(<<"expired">>, Scope1, 0),
    ValidToken1 = mock_token(<<"valid1">>, Scope2, 3600),
    ValidToken2 = mock_token(<<"valid2">>, Scope3, 7200),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, ExpiredToken),
    TokenSet2 = bondy_oauth_token_set:add(TokenSet1, ValidToken1),
    TokenSet3 = bondy_oauth_token_set:add(TokenSet2, ValidToken2),

    %% Cleanup and keep only 1 token
    {Removed, TokenSet4} = bondy_oauth_token_set:cleanup_and_truncate(TokenSet3, 1),

    %% Should remove expired token + 1 valid token due to truncation
    ?assertEqual(2, length(Removed)),
    ?assertEqual(1, bondy_oauth_token_set:size(TokenSet4)),

    %% The expired token should be in the removed list
    ExpiredIds = [maps:get(id, T) || T <- Removed],
    ?assert(lists:member(<<"expired">>, ExpiredIds)).

cleanup_and_truncate_three_args_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope1 = mock_scope(<<"read">>),
    Scope2 = mock_scope(<<"write">>),

    ExpiredToken = mock_token(<<"expired">>, Scope1, 0),
    ValidToken = mock_token(<<"valid">>, Scope2, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, ExpiredToken),
    TokenSet2 = bondy_oauth_token_set:add(TokenSet1, ValidToken),

    {Removed, TokenSet3} = bondy_oauth_token_set:cleanup_and_truncate(TokenSet2, 1, erlang:system_time(second)),

    %% Should remove only the expired token
    ?assertEqual([ExpiredToken], Removed),
    ?assertEqual(1, bondy_oauth_token_set:size(TokenSet3)),
    ?assertEqual({ok, ValidToken}, bondy_oauth_token_set:find(TokenSet3, Scope2, <<"valid">>)).

%% -----------------------------------------------------------------------------
%% find/2 tests (new function)
%% -----------------------------------------------------------------------------

find_by_scope_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    Result = bondy_oauth_token_set:find(TokenSet1, Scope),

    ?assertEqual({ok, Token}, Result).

find_by_token_id_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    Result = bondy_oauth_token_set:find(TokenSet1, <<"token1">>),

    ?assertEqual({ok, Token}, Result).

find_by_non_existing_token_id_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    Result = bondy_oauth_token_set:find(TokenSet1, <<"non_existing">>),

    ?assertEqual({error, not_found}, Result).

find_by_non_existing_scope_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope1 = mock_scope(<<"read">>),
    Scope2 = mock_scope(<<"write">>),
    Token = mock_token(<<"token1">>, Scope1, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    Result = bondy_oauth_token_set:find(TokenSet1, Scope2),

    ?assertEqual({error, not_found}, Result).

%% -----------------------------------------------------------------------------
%% find/3 tests
%% -----------------------------------------------------------------------------

find_existing_token_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    Result = bondy_oauth_token_set:find(TokenSet1, Scope, <<"token1">>),

    ?assertEqual({ok, Token}, Result).

find_non_existing_token_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    Result = bondy_oauth_token_set:find(TokenSet1, Scope, <<"wrong_token">>),

    ?assertEqual({error, not_found}, Result).

%% -----------------------------------------------------------------------------
%% size/1 tests
%% -----------------------------------------------------------------------------

size_empty_set_test() ->
    TokenSet = bondy_oauth_token_set:new(),
    ?assertEqual(0, bondy_oauth_token_set:size(TokenSet)).

size_with_tokens_test() ->
    {TokenSet, _Tokens, _Scopes} = setup_multi_token_set(),
    ?assertEqual(3, bondy_oauth_token_set:size(TokenSet)).

%% -----------------------------------------------------------------------------
%% to_list/1 tests
%% -----------------------------------------------------------------------------

to_list_empty_set_test() ->
    TokenSet = bondy_oauth_token_set:new(),
    Result = bondy_oauth_token_set:to_list(TokenSet),
    ?assertEqual([], Result).

to_list_single_token_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    Result = bondy_oauth_token_set:to_list(TokenSet1),

    ?assertEqual([Token], Result).

to_list_multiple_tokens_sorted_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope1 = mock_scope(<<"read">>),
    Scope2 = mock_scope(<<"write">>),
    %% Token1 expires later than Token2
    Token1 = mock_token(<<"token1">>, Scope1, 7200),
    Token2 = mock_token(<<"token2">>, Scope2, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token1),
    TokenSet2 = bondy_oauth_token_set:add(TokenSet1, Token2),
    Result = bondy_oauth_token_set:to_list(TokenSet2),

    %% Should be sorted by expires_at in descending order (latest first)
    ?assertEqual([Token1, Token2], Result).

%% -----------------------------------------------------------------------------
%% Index consistency tests
%% -----------------------------------------------------------------------------

index_consistency_after_operations_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope1 = mock_scope(<<"read">>),
    Scope2 = mock_scope(<<"write">>),
    Token1 = mock_token(<<"token1">>, Scope1, 3600),
    Token2 = mock_token(<<"token2">>, Scope2, 3600),

    %% Add tokens
    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token1),
    TokenSet2 = bondy_oauth_token_set:add(TokenSet1, Token2),

    %% Verify index integrity
    Index = maps:get(index, TokenSet2),
    Data = maps:get(data, TokenSet2),

    %% Check that every token ID in index maps to a scope that exists in data
    maps:fold(
        fun(TokenId, Scope, _) ->
            ?assert(maps:is_key(Scope, Data)),
            Token = maps:get(Scope, Data),
            ?assertEqual(TokenId, maps:get(id, Token))
        end,
        ok,
        Index
    ),

    %% Check that every token in data has its ID in the index
    maps:fold(
        fun(Scope, Token, _) ->
            TokenId = maps:get(id, Token),
            ?assert(maps:is_key(TokenId, Index)),
            ?assertEqual(Scope, maps:get(TokenId, Index))
        end,
        ok,
        Data
    ).

index_consistency_after_removal_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),
    TokenSet2 = bondy_oauth_token_set:remove(TokenSet1, Scope),

    Index = maps:get(index, TokenSet2),
    Data = maps:get(data, TokenSet2),

    ?assertEqual(0, maps:size(Index)),
    ?assertEqual(0, maps:size(Data)).

%% -----------------------------------------------------------------------------
%% Error handling tests
%% -----------------------------------------------------------------------------

find_with_invalid_scope_type_test() ->
    TokenSet = bondy_oauth_token_set:new(),
    %% Test with invalid scope type (should be a map)
    Result = bondy_oauth_token_set:find(TokenSet, <<"not_a_scope_map">>),
    ?assertEqual({ok, {error, not_found}}, {ok, Result}).

find_with_invalid_token_id_type_test() ->
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope = mock_scope(<<"read">>),
    Token = mock_token(<<"token1">>, Scope, 3600),
    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token),

    %% Test with non-binary token ID
    ?assertError(
        function_clause,
        bondy_oauth_token_set:find(TokenSet1, Scope, 123)
    ).

%% -----------------------------------------------------------------------------
%% Integration tests
%% -----------------------------------------------------------------------------

full_lifecycle_test() ->
    %% Test a complete token lifecycle: add, find, cleanup, truncate, remove
    TokenSet0 = bondy_oauth_token_set:new(),
    Scope1 = mock_scope(<<"read">>),
    Scope2 = mock_scope(<<"write">>),
    Scope3 = mock_scope(<<"admin">>),

    %% Create tokens: one expired, two valid
    ExpiredToken = mock_token(<<"expired">>, Scope1, 0),
    ValidToken1 = mock_token(<<"valid1">>, Scope2, 3600),
    ValidToken2 = mock_token(<<"valid2">>, Scope3, 7200),

    %% Add all tokens
    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, ExpiredToken),
    TokenSet2 = bondy_oauth_token_set:add(TokenSet1, ValidToken1),
    TokenSet3 = bondy_oauth_token_set:add(TokenSet2, ValidToken2),

    ?assertEqual(3, bondy_oauth_token_set:size(TokenSet3)),

    %% Verify we can find tokens by ID and scope
    ?assertEqual({ok, ExpiredToken}, bondy_oauth_token_set:find(TokenSet3, <<"expired">>)),
    ?assertEqual({ok, ValidToken1}, bondy_oauth_token_set:find(TokenSet3, Scope2)),

    %% Cleanup expired tokens
    {Expired, TokenSet4} = bondy_oauth_token_set:cleanup(TokenSet3, erlang:system_time(second)),
    ?assertEqual([ExpiredToken], Expired),
    ?assertEqual(2, bondy_oauth_token_set:size(TokenSet4)),

    %% Truncate to keep only 1 token
    {Truncated, TokenSet5} = bondy_oauth_token_set:truncate(TokenSet4, 1),
    ?assertEqual(1, length(Truncated)),
    ?assertEqual(1, bondy_oauth_token_set:size(TokenSet5)),

    %% Remove the last token
    [LastToken] = bondy_oauth_token_set:to_list(TokenSet5),
    LastScope = maps:get(authscope, LastToken),
    TokenSet6 = bondy_oauth_token_set:remove(TokenSet5, LastScope),

    ?assertEqual(0, bondy_oauth_token_set:size(TokenSet6)),
    ?assertEqual([], bondy_oauth_token_set:to_list(TokenSet6)).

combined_cleanup_and_truncate_test() ->
    %% Test cleanup_and_truncate with various scenarios
    TokenSet0 = bondy_oauth_token_set:new(),

    %% Create 5 tokens: 2 expired, 3 valid
    Tokens = [
        mock_token(<<"exp1">>, mock_scope(<<"s1">>), 0),  %% Expired
        mock_token(<<"exp2">>, mock_scope(<<"s2">>), 0),  %% Expired
        mock_token(<<"val1">>, mock_scope(<<"s3">>), 1800),  %% Valid
        mock_token(<<"val2">>, mock_scope(<<"s4">>), 3600),  %% Valid
        mock_token(<<"val3">>, mock_scope(<<"s5">>), 7200)   %% Valid
    ],

    %% Add all tokens
    TokenSet = lists:foldl(
        fun(Token, Acc) ->
            bondy_oauth_token_set:add(Acc, Token)
        end,
        TokenSet0,
        Tokens
    ),

    ?assertEqual(5, bondy_oauth_token_set:size(TokenSet)),

    %% Cleanup and truncate to keep 2 tokens
    {Removed, FinalSet} = bondy_oauth_token_set:cleanup_and_truncate(TokenSet, 2, erlang:system_time(second)),

    %% Should remove 2 expired + 1 valid token (3 total)
    ?assertEqual(3, length(Removed)),
    ?assertEqual(2, bondy_oauth_token_set:size(FinalSet)),

    %% Verify that expired tokens are in the removed list
    RemovedIds = [maps:get(id, T) || T <- Removed],
    ?assert(lists:member(<<"exp1">>, RemovedIds)),
    ?assert(lists:member(<<"exp2">>, RemovedIds)),

    %% Verify no expired tokens remain
    RemainingTokens = bondy_oauth_token_set:to_list(FinalSet),
    lists:foreach(
        fun(Token) ->
            ExpiresAt = bondy_oauth_token:expires_at(Token),
            ?assert(ExpiresAt > erlang:system_time(second))
        end,
        RemainingTokens
    ).

index_and_data_consistency_test() ->
    %% Comprehensive test to ensure index and data remain consistent
    %% through various operations
    TokenSet0 = bondy_oauth_token_set:new(),

    %% Helper function to verify consistency
    VerifyConsistency = fun(TS) ->
        #{data := Data, index := Index, size := Size} = TS,

        %% Size should match data size
        ?assertEqual(Size, maps:size(Data)),

        %% Index should have same number of entries as data
        ?assertEqual(maps:size(Data), maps:size(Index)),

        %% Every index entry should point to existing data
        maps:fold(
            fun(TokenId, Scope, _) ->
                ?assert(maps:is_key(Scope, Data)),
                Token = maps:get(Scope, Data),
                ?assertEqual(TokenId, maps:get(id, Token))
            end,
            ok,
            Index
        ),

        %% Every data entry should have corresponding index entry
        maps:fold(
            fun(Scope, Token, _) ->
                TokenId = maps:get(id, Token),
                ?assert(maps:is_key(TokenId, Index)),
                ?assertEqual(Scope, maps:get(TokenId, Index))
            end,
            ok,
            Data
        )
    end,

    %% Start with empty set
    VerifyConsistency(TokenSet0),

    %% Add tokens
    Scope1 = mock_scope(<<"read">>),
    Scope2 = mock_scope(<<"write">>),
    Token1 = mock_token(<<"token1">>, Scope1, 3600),
    Token2 = mock_token(<<"token2">>, Scope2, 3600),

    TokenSet1 = bondy_oauth_token_set:add(TokenSet0, Token1),
    VerifyConsistency(TokenSet1),

    TokenSet2 = bondy_oauth_token_set:add(TokenSet1, Token2),
    VerifyConsistency(TokenSet2),

    %% Replace token (same scope, different token)
    Token3 = mock_token(<<"token3">>, Scope1, erlang:system_time(second) + 7200),
    TokenSet3 = bondy_oauth_token_set:add(TokenSet2, Token3),
    VerifyConsistency(TokenSet3),

    %% Remove by scope
    TokenSet4 = bondy_oauth_token_set:remove(TokenSet3, Scope1),
    VerifyConsistency(TokenSet4),

    %% Take remaining token
    {ok, {_TakenToken, TokenSet5}} = bondy_oauth_token_set:take(TokenSet4, Scope2, <<"token2">>),
    VerifyConsistency(TokenSet5),

    %% Should be empty now
    ?assertEqual(0, bondy_oauth_token_set:size(TokenSet5)).

performance_simulation_test() ->
    %% Simulate a realistic usage pattern with many operations
    TokenSet0 = bondy_oauth_token_set:new(),

    %% Add 100 tokens
    TokenSet1 = lists:foldl(
        fun(N, Acc) ->
            Scope = mock_scope(list_to_binary("scope_" ++ integer_to_list(N))),
            TokenId = list_to_binary("token_" ++ integer_to_list(N)),
            %% Mix of expired and valid tokens
            ExpiresAt = case N rem 3 of
                0 -> 0;  %% Expired
                _ -> 3600   %% Valid
            end,
            Token = mock_token(TokenId, Scope, ExpiresAt),
            bondy_oauth_token_set:add(Acc, Token)
        end,
        TokenSet0,
        lists:seq(1, 100)
    ),

    ?assertEqual(100, bondy_oauth_token_set:size(TokenSet1)),

    %% Cleanup expired tokens (should remove ~33 tokens)
    {Expired, TokenSet2} = bondy_oauth_token_set:cleanup(TokenSet1, erlang:system_time(second)),
    ExpiredCount = length(Expired),
    ?assert(ExpiredCount >= 30 andalso ExpiredCount =< 40),  %% Approximately 1/3

    %% Truncate to 20 tokens
    {_Truncated, TokenSet3} = bondy_oauth_token_set:truncate(TokenSet2, 20),
    ?assertEqual(20, bondy_oauth_token_set:size(TokenSet3)),

    %% Verify we can still find tokens by ID
    RemainingTokens = bondy_oauth_token_set:to_list(TokenSet3),
    [FirstToken | _] = RemainingTokens,
    TokenId = maps:get(id, FirstToken),
    ?assertEqual(
        {ok, FirstToken},
        bondy_oauth_token_set:find(TokenSet3, TokenId)
    ),

    %% Final consistency check
    #{data := Data, index := Index} = TokenSet3,
    ?assertEqual(
        maps:size(Data),
        maps:size(Index),
        io:format("Got ~p but ~p", [
            {maps:size(Data), maps:size(Index)},
            bondy_oauth_token_set:size(TokenSet3)
        ])
    ),
    ?assertEqual(20, maps:size(Data), TokenSet3).

edge_cases_test() ->
    %% Test various edge cases
    TokenSet0 = bondy_oauth_token_set:new(),

    %% Cleanup empty set
    {Expired1, TokenSet1} = bondy_oauth_token_set:cleanup(TokenSet0),
    ?assertEqual([], Expired1),
    ?assertEqual(TokenSet0, TokenSet1),

    %% Truncate empty set
    {Truncated1, TokenSet2} = bondy_oauth_token_set:truncate(TokenSet0, 5),
    ?assertEqual([], Truncated1),
    ?assertEqual(TokenSet0, TokenSet2),

    %% Cleanup and truncate empty set
    {Removed1, TokenSet3} = bondy_oauth_token_set:cleanup_and_truncate(TokenSet0, 5),
    ?assertEqual([], Removed1),
    ?assertEqual(TokenSet0, TokenSet3),

    %% Remove from empty set
    Scope = mock_scope(<<"read">>),
    TokenSet4 = bondy_oauth_token_set:remove(TokenSet0, Scope),
    ?assertEqual(TokenSet0, TokenSet4),

    %% Take from empty set
    Result = bondy_oauth_token_set:take(TokenSet0, Scope, <<"token1">>),
    ?assertEqual({error, not_found}, Result),

    %% Find in empty set
    ?assertEqual({error, not_found}, bondy_oauth_token_set:find(TokenSet0, Scope)),
    ?assertEqual({error, not_found}, bondy_oauth_token_set:find(TokenSet0, <<"token1">>)),
    ?assertEqual({error, not_found}, bondy_oauth_token_set:find(TokenSet0, Scope, <<"token1">>)).

%% -----------------------------------------------------------------------------
%% Property-based testing helpers
%% -----------------------------------------------------------------------------

%% Test that size is always consistent with data size
size_consistency_property_test() ->
    %% Generate random operations and verify size consistency
    TokenSet0 = bondy_oauth_token_set:new(),

    %% Add some tokens
    Tokens = [
        mock_token(<<"t1">>, mock_scope(<<"s1">>), 3600),
        mock_token(<<"t2">>, mock_scope(<<"s2">>), 3600),
        mock_token(<<"t3">>, mock_scope(<<"s3">>), 3600)
    ],

    TokenSet1 = lists:foldl(
        fun(Token, Acc) -> bondy_oauth_token_set:add(Acc, Token) end,
        TokenSet0,
        Tokens
    ),

    %% Property: size should always equal maps:size(data)
    CheckSizeConsistency = fun(TS) ->
        #{data := Data, size := Size} = TS,
        ?assertEqual(Size, maps:size(Data))
    end,

    CheckSizeConsistency(TokenSet1),

    %% After cleanup
    {_, TokenSet2} = bondy_oauth_token_set:cleanup(TokenSet1),
    CheckSizeConsistency(TokenSet2),

    %% After truncate
    {_, TokenSet3} = bondy_oauth_token_set:truncate(TokenSet2, 2),
    CheckSizeConsistency(TokenSet3),

    %% After remove
    [Token | _] = bondy_oauth_token_set:to_list(TokenSet3),
    Scope = maps:get(authscope, Token),
    TokenSet4 = bondy_oauth_token_set:remove(TokenSet3, Scope),
    CheckSizeConsistency(TokenSet4).

-endif.



