-module(ramp_id).
-include("ramp.hrl").

-define(SESSION_ID_TABLE_NAME, session_id).
-define(MAX_ID, 9007199254740993).


-export ([new/1]).
-export ([is_valid/1]).




%% =============================================================================
%% API
%% =============================================================================



-spec new(Scope :: global | tuple()) -> id().
new(global) ->
    %% IDs in the _global scope_ MUST be drawn _randomly_ from a _uniform
    %% distribution_ over the complete range [0, 2^53]
    crypto:rand_uniform(0, ?MAX_ID);

new({router, _}) ->
    new(global);

new({session, SessionId}) ->
    %% IDs in the _session scope_ SHOULD be incremented by 1 beginning
    %% with 1 (for each direction - _Client-to-Router_ and _Router-to-
    %% Client_)
    Tab = get_session_id_table(),
    %% We update the tuple {SessionId, Counter}
    ets:update_counter(Tab, SessionId, {pos, 2}).



is_valid(N) when is_integer(N) andalso N >= 0 andalso N =< ?MAX_ID ->
    true;
validate(_) ->
    false.


%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
get_session_id_table() ->
    %% TODO use betflow_tuplespace as a lib to get sharding and table management
    undefined.
