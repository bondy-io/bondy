%% =============================================================================
%%  bondy_session_manager.erl -
%%
%%  Copyright (c) 2018-2024 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

-module(bondy_session_manager).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy_uris.hrl").
-include("bondy.hrl").


-record(state, {
    name                :: atom(),
    monitor_refs = #{}  :: #{id() => reference()}
}).

-type close_opts()      ::  #{
                                exclude => [bondy_session_id:t()]
                            }.
-type pool()            :: #{
                                name := term(),
                                size := pos_integer(),
                                algorithm := hash
                            }.

%% API
-export([start_link/2]).
-export([pool/0]).
-export([open/1]).
-export([open/3]).
-export([close/1]).
-export([close/2]).
-export([close_all/1]).
-export([close_all/2]).
-export([close_all/4]).


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
start_link(PoolName, WorkerName) ->
    gen_server:start_link(
        {local, WorkerName}, ?MODULE, [PoolName, WorkerName], []
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec pool() -> pool().

pool() ->
    #{
        name => {?MODULE, pool},
        size =>  bondy_config:get([session_manager_pool, size]),
        %% hash is the only valid algorithm as the worker will monitor the
        %% session owner (connection process) and we need to demonitor on close,
        %% so we need all calls for a given session to be send to the same
        %% worker deterministically.
        algorithm => hash
    }.


%% -----------------------------------------------------------------------------
%% @doc Stores the session `Session' and sets up a monitor for the calling
%% process which is assumed to be the client connection process e.g. WAMP
%% connection. In case the connection crashes it performs the cleanup of any
%% session data that should not be retained.
%% The session manager worker is picked from the pool based on the hash of the
%% calling process' pid.
%% -----------------------------------------------------------------------------
%%
-spec open(Session :: bondy_session:t()) -> ok | no_return().

open(Session) ->
    do_for_worker(
        fun(ServerRef) ->
            {ok, Session} = gen_server:call(ServerRef, {open, Session}, 5000),
            ok
        end,
        bondy_session:id(Session)
    ).


%% -----------------------------------------------------------------------------
%% @doc Creates a new session provided the RealmUri exists or can be dynamically
%% created.
%% It calls {@link bondy_session:new/4} which will fail with an exception
%% if the realm does not exist or cannot be created.
%%
%% This function also sets up a monitor for the calling process which is
%% assumed to be the client connection process e.g. WAMP connection. In case
%% the connection crashes it performs the cleanup of any session data that
%% should not be retained.
%% -----------------------------------------------------------------------------
-spec open(
    bondy_session_id:t(),
    uri() | bondy_realm:t(),
    bondy_session:properties()) ->
    {ok, bondy_session:t()} | no_return().

open(Id, RealmOrUri, Opts) ->
    do_for_worker(
        fun(ServerRef) ->
            Session = bondy_session:new(Id, RealmOrUri, Opts),
            gen_server:call(ServerRef, {open, Session}, 5000)
        end,
        Id
    ).

%% -----------------------------------------------------------------------------
%% @doc Closes the session
%% This function does NOT send a GOODBYE WAMP message to the session owner.
%% @end
%% -----------------------------------------------------------------------------
-spec close(bondy_session:t()) -> ok.

close(Session) ->
    do_for_worker(
        fun(ServerRef) ->
            gen_server:cast(ServerRef, {close, Session, undefined})
        end,
        bondy_session:id(Session)
    ).


%% -----------------------------------------------------------------------------
%% @doc Closes the session.
%% This function sends a GOODBYE WAMP message to the session owner.
%% @end
%% -----------------------------------------------------------------------------
-spec close(bondy_session:t(), uri()) -> ok.

close(Session, ReasonUri) when is_binary(ReasonUri) ->
    do_for_worker(
        fun(ServerRef) ->
            gen_server:cast(ServerRef, {close, Session, ReasonUri})
        end,
        bondy_session:id(Session)
    ).



%% -----------------------------------------------------------------------------
%% @doc Closes all managed sessions in realm with URI `RealmUri'.
%%
%% Notice that `RealmUri' will be used to match the session's`authrealm'
%% property and not `realm_uri'. If the user is an SSO user `authrealm' is the
%% SSO realm and as result all sessions in all associated realms will be closed.
%% @end
%% -----------------------------------------------------------------------------
-spec close_all(RealmUri :: uri()) -> ok.

close_all(RealmUri) ->
    close_all(RealmUri, ?WAMP_CLOSE_NORMAL).


%% -----------------------------------------------------------------------------
%% @doc Closes all managed sessions in realm with URI `RealmUri'.
%%
%% Notice that `RealmUri' will be used to match the session's`authrealm'
%% property and not `realm_uri'. If the user is an SSO user `authrealm' is the
%% SSO realm and as result all sessions in all associated realms will be closed.
%% @end
%% -----------------------------------------------------------------------------
-spec close_all(RealmUri :: uri(), ReasonUri :: uri()) -> ok.

close_all(RealmUri, ReasonUri) when is_binary(ReasonUri) ->
    Bindings = #{realm_uri => RealmUri},
    do_close_all(Bindings, #{}, ReasonUri).


%% -----------------------------------------------------------------------------
%% @doc Closes all sessions for user `Username' on realm `RealmUri' according
%% to the options `Opts'.
%%
%% Notice that `RealmUri' will be used to match the session's`authrealm'
%% property and not `realm_uri'. If the user is an SSO user `authrealm' is the
%% SSO realm and as result all sessions in all associated realms will be closed.
%%
%% @end
%% -----------------------------------------------------------------------------
-spec close_all(
    RealmUri :: uri(),
    Authid :: uri(),
    ReasonUri :: uri(),
    Opts :: close_opts()) -> ok.

close_all(RealmUri, Authid, ReasonUri, Opts) ->
    Bindings = #{authrealm => RealmUri, authid => Authid},
    do_close_all(Bindings, Opts, ReasonUri).




%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([PoolName, WorkerName]) ->
    true = gproc_pool:connect_worker(PoolName, WorkerName),
    {ok, #state{name = WorkerName}}.


handle_call({open, Session0}, _From, State0) ->
    %% We store the session
    {ok, Session} = bondy_session:store(Session0),

    %% We init the session-sceped counters
    RealmUri = bondy_session:realm_uri(Session),
    SessionId = bondy_session:id(Session),
    ok = bondy_message_id:init_session(RealmUri, SessionId),

    Id = bondy_session:id(Session),
    Pid = bondy_session:pid(Session),

    %% We register the session owner (pid) under the session key
    true = bondy_gproc:register({bondy_session, Id}, Pid),

    %% We monitor the session owner (pid) so that we can cleanup when the
    %% process terminates
    Ref = erlang:monitor(process, Pid),

    %% We register WAMP procedures
    ok = register_procedures(Session),

    Refs = State0#state.monitor_refs,

    State = State0#state{
        monitor_refs = Refs#{
            Id => Ref,
            Ref => Id
        }
    },
    {reply, {ok, Session}, State};

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast({close, Session, ReasonUri}, State0) ->
    State = do_close(State0, Session, ReasonUri),
    {noreply, State};

handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.


handle_info({'DOWN', Ref, _, _, _}, State0) ->
    %% The connection process has terminated
    Refs = State0#state.monitor_refs,

    State = case maps:find(Ref, Refs) of
        {ok, Id} ->
            case bondy_session:lookup(Id) of
                {ok, Session} ->
                    ProtocolId = bondy_session:external_id(Session),
                    ?LOG_DEBUG(#{
                        description =>
                            "Connection process for session terminated, "
                            " cleaning up.",
                        protocol_session_id => ProtocolId,
                        session_id => Id
                    }),
                    cleanup(Session);
                {error, not_found} ->
                    ok
            end,
            State0#state{monitor_refs = maps:without([Ref, Id], Refs)};

        error ->
            State0#state{monitor_refs = maps:without([Ref], Refs)}
    end,

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

    %% wamp.session.{ID}.get
    %% -------------------------------------------------------------------------
    %% The wamp.session.get implementation forwards the call to this dynamic
    %% URI. This is required because sessions are not replicated, so we need a
    %% way to located the node where the session lives to route the call to it.
    %% If we have more session methods then we should implement prefix
    %% registration i.e. wamp.session.{ID}.*
    SessionId = bondy_session:id(Session),
    Extid = bondy_session_id:to_external(SessionId),
    Part = bondy_utils:session_id_to_uri_part(Extid),

    ProcUri = <<"wamp.session.", Part/binary, ".get">>,

    %% Notice we are implementing this as callback reference,
    %% this means a different reference per callback. In case we needed to
    %% support many more callbacks we would be better of using the session
    %% manager process as target, having a single reference for all procedures,
    %% reducing memory consumption.
    RealmUri = bondy_session:realm_uri(Session),
    MF = {bondy_session_api, get},
    Ref = bondy_ref:new(internal, MF, SessionId),

    Args = [SessionId],
    Opts = #{match => ?EXACT_MATCH, callback_args => Args},
    {ok, _} = bondy_dealer:register(ProcUri, Opts, RealmUri, Ref),

    ok.


%% @private
cleanup(Session) ->
    %% TODO We need a new API to be the underlying cleanup function behind
    %% bondy_context:close/1. In the meantime we create a fakce context,
    %% knowing what it should contain for the close/2 call to work.
    FakeCtxt = #{
        session => Session,
        realm_uri => bondy_session:realm_uri(Session),
        node => bondy_session:node(Session),
        ref => bondy_session:ref(Session)
    },
    %% We close the session too
    bondy_context:close(FakeCtxt, crash),
    ok.


%% @private
do_for_worker(Fun, Key) ->
    Pid = gproc_pool:pick_worker(maps:get(name, pool()), Key),
    ?LOG_INFO(#{
        description => "Using worker pool",
        pid => Pid
    }),
    Fun(Pid).


do_close(State0, Session, ReasonUri) ->
    Id = bondy_session:id(Session),
    ExtId = bondy_session:external_id(Session),
    RealmUri = bondy_session:realm_uri(Session),
    Refs = State0#state.monitor_refs,

    ?LOG_DEBUG(#{
        description => "Session closing, demonitoring session connection",
        realm => RealmUri,
        session_id => Id,
        protocol_session_id => ExtId
    }),

    State =
        case maps:find(Id, Refs) of
            {ok, Ref} ->
                true = erlang:demonitor(Ref, [flush]),
                State0#state{monitor_refs = maps:without([Id, Ref], Refs)};

            error ->
                State0#state{monitor_refs = maps:without([Id], Refs)}
        end,

    ok = maybe_send_goodbye(Session, ReasonUri),

    %% Close session to cleanup in-memory state
    _ = catch bondy_session:close(Session, ReasonUri),

    State.


%% @private
do_close_all(Bindings, Opts0, ReasonUri) ->
    Opts = #{
        limit => 100,
        return => object,
        exclude => maps:get(exclude, Opts0, undefined)
    },

    Fun = fun
        ({continue, Cont}) ->
            try
                bondy_session:match(Cont)
            catch
                Class:Reason:Stacktrace ->
                    ?LOG_ERROR(#{
                        description => "Error while closing session",
                        class => Class,
                        reason => Reason,
                        stacktrace => Stacktrace
                    }),
                    []
            end;

        (Session) ->
            do_for_worker(
                fun(ServerRef) ->
                    gen_server:cast(ServerRef, {close, Session, ReasonUri})
                end,
                bondy_session:id(Session)
            )
    end,

    Matches = bondy_session:match(Bindings, Opts),
    ok = bondy_utils:foreach(Fun, Matches).


%% @private
maybe_send_goodbye(_, undefined) ->
    ok;

maybe_send_goodbye(Session, ReasonUri) ->
    RealmUri = bondy_session:realm_uri(Session),
    ProcRef = bondy_session:ref(Session),

    Msg = wamp_message:goodbye(
        #{message => <<"The session was closed by the Router.">>},
        ReasonUri
    ),
    _ = catch bondy:send(RealmUri, ProcRef, Msg),
    ok.

