-module(juno_utils).


-export([merge_map_flags/2]).
-export([get_nonce/0]).
-export([get_random_string/2]).




%% =============================================================================
%%  API
%% =============================================================================



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
    get_random_string(
        32, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").



%% -----------------------------------------------------------------------------
%% @doc
%% borrowed from 
%% http://blog.teemu.im/2009/11/07/generating-random-strings-in-erlang/
%% @end
%% -----------------------------------------------------------------------------
get_random_string(Length, AllowedChars) ->
    lists:foldl(
        fun(_, Acc) ->
            [lists:nth(random:uniform(length(AllowedChars)),
            AllowedChars)]
            ++ Acc
        end, 
        [], 
        lists:seq(1, Length)).