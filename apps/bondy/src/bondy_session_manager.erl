-module(bondy_session_manager).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(REG_KEY(RealmUri, Id), {n, l, {bondy_session, RealmUri, Id}}).

-record(state, {
    name :: atom()
}).

%% API
-export([start_link/2]).
-export([pool/0]).
-export([pool_size/0]).
-export([open/3]).
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
start_link(Pool, Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [Pool, Name], []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec pool() -> term().

pool() ->
    {?MODULE, pool}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec pool_size() -> integer().

pool_size() ->
    bondy_config:get([session_manager_pool, size]).


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
    uri() | bondy_realm:t(),
    bondy_session:properties()) ->
    bondy_session:t() | no_return().

open(Id, RealmOrUri, Opts) ->
    %% We store the session
    Session = bondy_session:new(Id, RealmOrUri, Opts),
    ok = bondy_session:store(Session),

    %% We register the session
    RealmUri = bondy_session:realm_uri(Session),

    Name = gproc_pool:pick_worker(pool(), RealmUri),

    case gen_server:call(Name, {open, Session}, 5000) of
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
    Uri = bondy_session:realm_uri(Session),
    Name = gproc_pool:pick_worker(pool(), Uri),
    gen_server:cast(Name, {close, Session}).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([Pool, Name]) ->
    true = gproc_pool:connect_worker(Pool, Name),
    {ok, #state{name = Name}}.


handle_call({open, Session}, _From, State) ->
    Id = bondy_session:id(Session),
    RealmUri = bondy_session:realm_uri(Session),
    Pid = bondy_session:pid(Session),
    Key = ?REG_KEY(RealmUri, Id),

    %% We register the session owner (pid) under the realm and session id.
    true = gproc:reg_other(Key, Pid),

    %% We monitor the session owner (pid) so that we can cleanup when the
    %% process terminates
    ok = gproc_monitor:subscribe(Key),

    %% We register WAMP procedures
    ok = register_procedures(Session),

    {reply, ok, State};

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.

handle_cast({close, Session}, State) ->
    Id = bondy_session:id(Session),
    Uri = bondy_session:realm_uri(Session),
    ok = gproc_monitor:unsubscribe(?REG_KEY(Uri, Id)),

    ?LOG_DEBUG(#{
        description => "Session closing, demonitoring session connection",
        realm => bondy_session:realm_uri(Session),
        session_id => Id
    }),

    ok = bondy_session:close(Session),

    {noreply, State};

handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.


handle_info({gproc_monitor, {n, l, {bondy_session, Uri, Id}}, undefined}, State) ->
    %% The connection process has died or closed

    case bondy_session:lookup(Id) of
        {error, not_found} ->
            ok;
        Session ->
            ?LOG_DEBUG(#{
                description => "Connection process for session terminated, cleaning up",
                realm => Uri,
                session_id => Id
            }),
            cleanup(Session)
    end,
    {noreply, State};

handle_info({gproc_monitor, {n, l, {bondy_session, Uri, Id}}, Pid}, State) ->
    ?LOG_DEBUG(#{
        description => "Monitoring session connection",
        session_id => Id,
        realm => Uri,
        pid => Pid
    }),
    {noreply, State};

handle_info(Info, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Info
    }),
    {noreply, State}.


terminate(_Reason, State) ->
    _ = gproc_pool:disconnect_worker(pool(), State#state.name),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
register_procedures(Session) ->
    RealmUri = bondy_session:realm_uri(Session),
    Id = bondy_session:id(Session),
    %% We register wamp.session.{id}.get since we need to route the wamp.
    %% session.get call to the node where the session lives and we use the
    %% Registry to do that.
    Part = bondy_utils:session_id_to_uri_part(Id),
    ProcUri = <<"wamp.session.", Part/binary, ".get">>,
    Opts = #{match => ?PREFIX_MATCH},
    Mod = bondy_wamp_meta_api,
    {ok, _} = bondy_dealer:register(RealmUri, Opts, ProcUri, Mod),
    ok.


%% @private
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
    bondy_context:close(FakeCtxt, crash),
    ok.