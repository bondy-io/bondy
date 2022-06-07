%% =============================================================================
%%  bondy_session_manager.erl -
%%
%%  Copyright (c) 2018-2022 Leapsight. All rights reserved.
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
-include("bondy_security.hrl").


-record(state, {
    name                :: atom(),
    monitor_refs = #{}  :: #{id() => reference()}
}).

%% API
-export([start_link/2]).
-export([pool/0]).
-export([pool_size/0]).
-export([open/3]).
-export([close/2]).


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
    bondy_session_id:t(),
    uri() | bondy_realm:t(),
    bondy_session:properties()) ->
    bondy_session:t() | no_return().

open(Id, RealmOrUri, Opts) ->
    %% We store the session
    Session0 = bondy_session:new(Id, RealmOrUri, Opts),
    {ok, Session} = bondy_session:store(Session0),

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
-spec close(bondy_session:t(), atom()) -> ok.

close(Session, Reason) ->
    Uri = bondy_session:realm_uri(Session),
    Name = gproc_pool:pick_worker(pool(), Uri),
    gen_server:cast(Name, {close, Session, Reason}).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([Pool, Name]) ->
    true = gproc_pool:connect_worker(Pool, Name),
    {ok, #state{name = Name}}.


handle_call({open, Session}, _From, State0) ->
    Id = bondy_session:id(Session),
    Pid = bondy_session:pid(Session),

    %% We register the session owner (pid) under the session key
    true = bondy:register({bondy_session, Id}, Pid),

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
    {reply, ok, State};

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast({close, Session, Reason}, State0) ->
    Id = bondy_session:id(Session),
    ExtId = bondy_session:external_id(Session),
    Uri = bondy_session:realm_uri(Session),

    ?LOG_DEBUG(#{
        description => "Session closing, demonitoring session connection",
        realm => Uri,
        session_id => Id,
        protocol_session_id => ExtId
    }),
    Refs = State0#state.monitor_refs,

    State = case maps:find(Id, Refs) of
        {ok, Ref} ->
            true = erlang:demonitor(Ref, [flush]),
            State0#state{
                monitor_refs = maps:without([Id, Ref], Refs)
            };
        error ->
            State0#state{
                monitor_refs = maps:without([Id], Refs)
            }
    end,

    ok = maybe_logout(Uri, Session, Reason),

    ok = bondy_session:close(Session),

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
                    ?LOG_DEBUG(#{
                        description => "Connection process for session terminated, cleaning up",
                        protocol_session_id => bondy_session:external_id(Session),
                        session_id => Id
                    }),
                    cleanup(Session);
                {error, not_found} ->
                    ok
            end,
            State0#state{
                monitor_refs = maps:without([Ref, Id], Refs)
            };
        error ->
            State0#state{
                monitor_refs = maps:without([Ref], Refs)
            }
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
    %% URI. This is required becuase sessions are not replicated, so we need a
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
    Opts = #{match => ?PREFIX_MATCH, callback_args => Args},
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
maybe_logout(_Uri, Session, logout) ->

    case bondy_session:authmethod(Session) of
        ?WAMP_TICKET_AUTH ->
            %% TODO remove ticket
            ok;
        ?WAMP_OAUTH2_AUTH ->
            %% TODO remove token for sessionID
            ok
    end;

maybe_logout(_, _, _) ->
    ok.