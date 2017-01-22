-module(juno_utils).
-include_lib("wamp/include/wamp.hrl").

-export([merge_map_flags/2]).
-export([get_id/1]).
-export([get_nonce/0]).
-export([get_random_string/2]).




%% =============================================================================
%%  API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% IDs in the _global scope_ MUST be drawn _randomly_ from a _uniform
%% distribution_ over the complete range [0, 2^53]
%% @end
%% -----------------------------------------------------------------------------
-spec get_id(Scope :: global | {router, uri()} | {session, id()}) -> id().
get_id(global) ->
    %% IDs in the _global scope_ MUST be drawn _randomly_ from a _uniform
    %% distribution_ over the complete range [0, 2^53]
    wamp_utils:rand_uniform();

get_id({router, _}) ->
    get_id(global);

get_id({session, SessionId}) ->
    %% IDs in the _session scope_ SHOULD be incremented by 1 beginning
    %% with 1 (for each direction - _Client-to-Router_ and _Router-to-
    %% Client_)
    juno_session:incr_seq(SessionId).





%% -----------------------------------------------------------------------------
%% @doc
%% The call will fail with a {badkey, any()} exception is any key found in M1
%% is not present in M2.
%% @end
%% -----------------------------------------------------------------------------
merge_map_flags(M1, M2) when is_map(M1) andalso is_map(M2) ->
    maps:fold(fun merge_fun/3, M2, M1).



%% =============================================================================
%%  PRIVATE
%% =============================================================================


%% @private
merge_fun(K, V, Acc) ->
    case {maps:get(K, Acc, undefined), V} of
        {true, true} -> Acc;
        {false, false} -> Acc;
        _ -> maps:put(K, false, Acc)
    end.


get_nonce() ->
    list_to_binary(
        get_random_string(
            32, 
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")).



%% -----------------------------------------------------------------------------
%% @doc
%% borrowed from 
%% http://blog.teemu.im/2009/11/07/generating-random-strings-in-erlang/
%% @end
%% -----------------------------------------------------------------------------
get_random_string(Length, AllowedChars) ->
    lists:foldl(
        fun(_, Acc) ->
            [lists:nth(rand:uniform(length(AllowedChars)),
            AllowedChars)]
            ++ Acc
        end, 
        [], 
        lists:seq(1, Length)).