-module(juno_utils).


-export([merge_map_flags/2]).


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
    case {maps:get(K, Acc, false), V} of
        {true, true} -> Acc;
        {false, false} -> Acc;
        _ -> maps:update(K, false, Acc)
    end.
