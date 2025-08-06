-module(bondy_message_id).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(TAB, bondy_session_counter).



-export([init/0]).
-export([init_session/2]).
-export([session/2]).
-export([purge_session/2]).
-export([global/0]).
-export([router/1]).


%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Initialises the ets table to support session-scoped identifiers.
%% This function has to be called during application startup.
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
    {ok, ?TAB} = bondy_table_manager:add(?TAB, Opts),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init_session(
    RealmUri :: uri(),
    SessionOrId :: bondy_session:t() | bondy_session_id:t()) -> ok.

init_session(RealmUri, SessionId)
when is_binary(RealmUri) andalso is_binary(SessionId) ->
    Key = {RealmUri, SessionId},
    _ = ets:insert_new(?TAB, {Key, 0}),
    ok;

init_session(RealmUri, Session) ->
    session(RealmUri, bondy_session:id(Session)).


%% -----------------------------------------------------------------------------
%% @doc Generates a WAMP message id in the global scope.
%% IDs in the global scope MUST be drawn _randomly_ from a uniform
%% distribution over the complete range [0, 2^53].
%% @end
%% -----------------------------------------------------------------------------
-spec global() -> id().

global() ->
    bondy_wamp_utils:rand_uniform().


%% -----------------------------------------------------------------------------
%% @doc Generates a WAMP message id in the router scope.
%% IDs in the router scope CAN be chosen freely by the specific router
%% implementation.
%% @end
%% -----------------------------------------------------------------------------
-spec router(RealmUri :: uri()) -> id().

router(_) ->
    global().


%% -----------------------------------------------------------------------------
%% @doc Generates a WAMP message id in the session scope.
%% IDs in the session scope MUST be incremented by 1 beginning with 1 and
%% wrapping to 1 after it reached 2^53 (for each direction -
%% Client-to-Router and Router-to-Client)
%% This is the Router-to-Client direction.
%%
%% If the counter hasn't been previously initialised using `init_session/2',
%% the function will return a random ID by calling `router/1'.
%%
%% @end
%% -----------------------------------------------------------------------------
-spec session(
    RealmUri :: uri(),
    SessionOrId :: bondy_session:t() | bondy_session_id:t()) -> id().

session(RealmUri, SessionId)
when is_binary(RealmUri) andalso is_binary(SessionId) ->
    try
        incr_session_counter(RealmUri, SessionId)
    catch
        error:badarg ->
            router(RealmUri)
    end;

session(RealmUri, Session) ->
    session(RealmUri, bondy_session:id(Session)).


%% -----------------------------------------------------------------------------
%% @doc Removes all counters associated with session identifier `SessionId'.
%% @end
%% -----------------------------------------------------------------------------
-spec purge_session(
    RealmUri :: uri(),
    SessionOrId :: bondy_session:t() | bondy_session_id:t()) -> ok.

purge_session(RealmUri, SessionId)
when is_binary(RealmUri) andalso is_binary(SessionId) ->
    true = ets:match_delete(?TAB, {{RealmUri, SessionId}, '_'}),
    ok;

purge_session(RealmUri, Session) when is_binary(RealmUri) ->
    purge_session(RealmUri, bondy_session:id(Session)).




%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
-spec incr_session_counter(uri(), bondy_session_id:t()) ->
    integer() | no_return().

%% TODO do not use default but use another function to set up once we store the session.
%% This way the update_counter will fail for non persistent sessions and we can fallback to a random numnber
incr_session_counter(RealmUri, SessionId) when is_binary(SessionId) ->
    %% IDs in the session scope MUST be incremented by 1 beginning with 1 and
    %% wrapping to 1 after it reached 2^53 (for each direction -
    %% Client-to-Router and Router-to-Client)
    %% This is the Router-to-Client direction
    Key = {RealmUri, SessionId},
    UpdateOp = {2, 1, ?MAX_ID, 0},
    Default = {Key, 0},
    ets:update_counter(?TAB, Key, UpdateOp, Default).


