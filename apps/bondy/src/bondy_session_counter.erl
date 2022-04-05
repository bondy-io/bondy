-module(bondy_session_counter).

-include_lib("wamp/include/wamp.hrl").

-define(TAB, ?MODULE).

-type key()     ::  message_id.

-export([init/0]).
-export([incr/2]).
-export([delete_all/1]).


%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init() -> ok.

init() ->
    Opts = [
        ordered_set,
        {keypos, 1},
        named_table,
        public,
        {read_concurrency, true},
        {write_concurrency, true},
        {decentralized_counters, true}
    ],
    {ok, ?TAB} = bondy_table_owner:add(?TAB, Opts),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec incr(bondy_session_id:t(), key()) -> integer().

incr(SessionId, message_id) when is_binary(SessionId) ->
    %% IDs in the _session scope_ SHOULD be incremented by 1 beginning
    %% with 1 (for each direction - _Client-to-Router_ and _Router-to-
    %% Client_)
    %% This is the router-to-client direction
    Key = {SessionId, request_id},
    UpdateOp = {2, 1, ?MAX_ID, 0},
    Default = {Key, 0},
    ets:update_counter(?TAB, Key, UpdateOp, Default).


%% -----------------------------------------------------------------------------
%% @doc Removes all counters associated with session identifier `SessionId'.
%% @end
%% -----------------------------------------------------------------------------
-spec delete_all(SessionId :: bondy_session_id:t()) -> ok.

delete_all(SessionId) when is_binary(SessionId) ->
    true = ets:match_delete(?TAB, {{SessionId, '_'}, '_'}),
    ok.