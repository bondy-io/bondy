-module(bondy_session_manager).
-behaviour(gen_server).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-record(state, {}).

%% API
-export([start_link/0]).
-export([open/4]).
-export([close/1]).


%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc
%% Creates a new session provided the RealmUri exists or can be dynamically
%% created.
%% It calls {@link bondy_session:new/4} which will fail with an exception
%% if the realm does not exist or cannot be created.
%%
%% This function also sets up a monitor for the calling process which is
%% assummed to be the client connection process e.g. WAMP connection. In case
%% the connection crashes it performs the cleanup of any session data that
%% should not be retained.
%% -----------------------------------------------------------------------------
-spec open(
    bondy_session:id(),
    bondy_session:peer(),
    uri() | bondy_realm:t(),
    bondy_session:session_opts()) ->
    bondy_session:t() | no_return().

open(Id, Peer, RealmOrUri, Opts) ->
    Session = bondy_session:open(Id, Peer, RealmOrUri, Opts),
    case gen_server:call(?MODULE, {monitor, Session}, 5000) of
        ok ->
            Session;
        Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec close(bondy_session:t()) -> ok.

close(Session) ->

    ok = bondy_session:close(Session),
    gen_server:cast(?MODULE, {demonitor, Session}).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    {ok, #state{}}.


handle_call({monitor, Session}, _From, State) ->
    Id = bondy_session:id(Session),
    Uri = bondy_session:realm_uri(Session),
    ok = gproc_monitor:subscribe({n, l, {session, Uri, Id}}),
    {reply, ok, State};

handle_call(Event, From, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p, from=~p", [Event, From]
    ),
    {reply, {error, {unsupported_call, Event}}, State}.

handle_cast({demonitor, Session}, State) ->
    Id = bondy_session:id(Session),
    Uri = bondy_session:realm_uri(Session),
    ok = gproc_monitor:unsubscribe({n, l, {session, Uri, Id}}),
    _ = lager:debug(
        "Demonitoring session connection; realm=~p, session_id=~p",
        [Uri, Id]
    ),
    {noreply, State};

handle_cast(Event, State) ->
    _ = lager:error(
        "Error handling cast, reason=unsupported_event, event=~p", [Event]
    ),
    {noreply, State}.


handle_info({gproc_monitor, {n, l, {session, Uri, Id}}, undefined}, State) ->
    %% The connection process has died or closed
    _ = lager:debug(
        "Connection process for session terminated, cleaning up; "
        "realm=~p, session_id=~p",
        [Uri, Id]
    ),
    case bondy_session:lookup(Id) of
        {error, not_found} ->
            ok;
        Session ->
            cleanup(Session)
    end,
    {noreply, State};

handle_info({gproc_monitor, {n, l, {session, Uri, Id}}, Pid}, State) ->
    _ = lager:debug(
        "Monitoring session connection; realm=~p, session_id=~p, pid=~p",
        [Uri, Id, Pid]
    ),
    {noreply, State};

handle_info(Info, State) ->
    _ = lager:debug("Unexpected message, message=~p", [Info]),
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



cleanup(Session) ->
    %% TODO We need a new API to be the underlying cleanup function behind
    %% bondy_context:close/1. In the meantime we create a fakce context,
    %% knowing what it should contain for the close/2 call to work.
    FakeCtxt = #{
        id => bondy_session:id(Session),
        realm_uri => bondy_session:realm_uri(Session),
        node => bondy_session:node(Session),
        peer_id => bondy_session:peer_id(Session),
        session => Session
    },
    %% We close the session too
    bondy_context:close(FakeCtxt, crash).