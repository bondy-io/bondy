-module(juno_utils).


-export([merge_map_flags/2]).
-export([get_realm/1]).


%% =============================================================================
%%  API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the realm for the provided Uri if the realm exists or if
%% {@link juno_config:automatically_create_realms/0} returns true 
%% (creating a new realm).
%% @end
%% -----------------------------------------------------------------------------
get_realm(Uri) ->
    case juno_config:automatically_create_realms() of
        true ->
            %% We force the creation of a new realm if it does not exist
            wamp_realm:get(Uri);
        false ->
            %% Will throw an exception if it does not exist
            wamp_realm:fetch(Uri)
    end.

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
