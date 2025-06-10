%% =============================================================================
%%  bondy_event_wamp_publisher - An event handler to turn bondy events into
%% WAMP events.
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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

%% -----------------------------------------------------------------------------
%% @doc An event handler to generates WAMP Meta Events based on internal
%% Bondy events
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_event_wamp_publisher).
-behaviour(gen_event).
-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").



-record(state, {
    ref :: bondy_ref:t()
}).

-type event() :: [atom()].
-type partition_key() :: any().

%% GEN_EVENT CALLBACKS
-export([init/1]).
-export([handle_event/2]).
-export([handle_call/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).



%% =============================================================================
%% GEN_EVENT CALLBACKS
%% =============================================================================



init([]) ->
    State = #state{ref = bondy_ref:new(internal)},
    {ok, State}.


handle_event(Event, State) ->
    %% handle_event is called by the even manager, so delegate this to jobs
    case async_handle_event(Event, State#state.ref) of
        ok ->
            {ok, State};

        {ok, {Fun, PartitionKey}} ->
            ok = bondy_jobs:enqueue(Fun, PartitionKey),
            {ok, State}
    end.


handle_call(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_info(_Info, State) ->
    {ok, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================


-spec async_handle_event(event(), term()) ->
    ok | {ok, {function(), partition_key()}}.

async_handle_event({[bondy, cluster, connection, Type], Node}, Ref)
when Type == up; Type == down ->
    Fun = fun() ->
        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        MyNode = bondy_config:nodestring(),
        Ctxt = bondy_context:local_context(?MASTER_REALM_URI, Ref),
        Topic =
            case Type of
                up -> ?BONDY_CLUSTER_CONN_UP;
                down -> ?BONDY_CLUSTER_CONN_DOWN
            end,
        bondy_broker:publish(ReqId, #{}, Topic, [MyNode, Node], #{}, Ctxt)
    end,
    {ok, {Fun, undefined}};

async_handle_event({[bondy, realm, created, Type], Uri}, Ref)
when Type == created; Type == updated; Type == deleted ->
    Fun = fun() ->
        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        Ctxt = bondy_context:local_context(?MASTER_REALM_URI, Ref),
        Topic =
            case Type of
                created -> ?BONDY_REALM_CREATED;
                updated -> ?BONDY_REALM_UPDATED;
                deleted -> ?BONDY_REALM_DELETED
            end,
        bondy_broker:publish(ReqId, #{}, Topic, [Uri], #{}, Ctxt)
    end,
    {ok, {Fun, Uri}};


async_handle_event({[bondy, session, opened], Session}, Ref) ->
    SessionId = bondy_session:id(Session),
    Fun = fun() ->
        RealmUri = bondy_session:realm_uri(Session),
        Args = [bondy_session:to_external(Session)],
        KWArgs = #{session_guid => SessionId},

        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        Ctxt = bondy_context:local_context(RealmUri, Ref),
        bondy_broker:publish(
            ReqId, #{}, ?WAMP_SESSION_ON_JOIN, Args, KWArgs, Ctxt
        )
    end,
    {ok, {Fun, SessionId}};

async_handle_event({[bondy, session, closed], Session, _DurationSecs}, Ref) ->
    SessionId = bondy_session:id(Session),
    Fun = fun() ->
        RealmUri = bondy_session:realm_uri(Session),
        Id = bondy_session:external_id(Session),
        Authid = bondy_session:authid(Session),
        Authrole = bondy_session:authrole(Session),
        Args = [Id, Authid, Authrole],
        KWArgs = #{session_guid => bondy_session:id(Session)},

        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        Ctxt = bondy_context:local_context(RealmUri, Ref),

        bondy_broker:publish(
            ReqId, #{}, ?WAMP_SESSION_ON_LEAVE, Args, KWArgs, Ctxt
        )
    end,
    {ok, {Fun, SessionId}};

async_handle_event({[bondy, rbac, group, Type], RealmUri, Name}, Ref)
when Type == added; Type == updated; Type == deleted ->
    case Type =/= deleted orelse bondy_realm:exists(RealmUri) of
        true ->
            Fun = fun() ->
                %% We use a global ID as this is not a publishers request
                ReqId = bondy_message_id:global(),
                Ctxt = bondy_context:local_context(RealmUri, Ref),
                Topic =
                    case Type of
                        added -> ?BONDY_GROUP_ADDED;
                        updated -> ?BONDY_GROUP_UPDATED;
                        deleted -> ?BONDY_GROUP_DELETED
                    end,
                bondy_broker:publish(
                    ReqId, #{}, Topic, [RealmUri, Name], #{}, Ctxt
                )
            end,
            {ok, {Fun, RealmUri}};

        false ->
            %% Realm cascade delete, so we silence the event
            ok
    end;

async_handle_event({[bondy, user, added], RealmUri, Username}, Ref) ->
    Fun = fun() ->
        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        Ctxt = bondy_context:local_context(RealmUri, Ref),

        bondy_broker:publish(
            ReqId, #{}, ?BONDY_USER_ADDED, [Username], #{}, Ctxt
        )
    end,
    {ok, {Fun, RealmUri}};

async_handle_event({[bondy, user, Type], RealmUri, Username}, Ref)
when Type == updated; Type == deleted ->
    case Type =/= deleted orelse bondy_realm:exists(RealmUri) of
        true ->
            Fun = fun() ->
                ok = bondy_ticket:revoke_all(RealmUri, Username),
                ok = bondy_oauth2:revoke_refresh_tokens(RealmUri, Username),

                %% We use a global ID as this is not a publishers request
                ReqId = bondy_message_id:global(),
                Ctxt = bondy_context:local_context(RealmUri, Ref),
                Topic =
                    case Type of
                        updated -> ?BONDY_USER_UPDATED;
                        deleted -> ?BONDY_USER_DELETED
                    end,
                bondy_broker:publish(
                    ReqId, #{}, Topic, [RealmUri, Username], #{}, Ctxt
                )
                %% TODO Refresh any sessions' rbac_ctxt caches this user has in
                %% this node for other realms.
            end,
            {ok, {Fun, RealmUri}};

        false ->
            %% Realm cascade delete, so we silence the event
            ok
    end;

async_handle_event(
    {[bondy, user, credentials, updated], RealmUri, Username}, Ref) ->
    Fun = fun() ->
        ok = bondy_ticket:revoke_all(RealmUri, Username),
        ok = bondy_oauth2:revoke_refresh_tokens(RealmUri, Username),

        Topic = ?BONDY_USER_CREDENTIALS_CHANGED,

        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        Ctxt = bondy_context:local_context(RealmUri, Ref),
        bondy_broker:publish(ReqId, #{}, Topic, [RealmUri, Username], #{}, Ctxt)
    end,
    {ok, {Fun, RealmUri}};

async_handle_event(
    {[bondy, user, logged_in], RealmUri, Username, Meta}, Ref) ->
    Fun = fun() ->
        Topic = ?BONDY_USER_LOGGED_IN,

        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        Ctxt = bondy_context:local_context(RealmUri, Ref),
        bondy_broker:publish(ReqId, #{}, Topic, [Username, Meta], #{}, Ctxt)
    end,
    {ok, {Fun, RealmUri}};

async_handle_event({[bondy, backup, Type], #{filename := File}}, Ref)
when Type == start; Type == stop; Type == exception ->
    Fun = fun() ->
        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        Ctxt = bondy_context:local_context(?MASTER_REALM_URI, Ref),
        Topic =
            case Type of
                start -> ?BONDY_BACKUP_STARTED;
                stop -> ?BONDY_BACKUP_FINISHED;
                exception -> ?BONDY_BACKUP_FAILED
            end,
        bondy_broker:publish(ReqId, #{}, Topic, [File], #{}, Ctxt)
    end,
    {ok, {Fun, undefined}};

async_handle_event({[bondy, backup, restore, Type], #{filename := File}}, Ref)
when Type == start; Type == stop; Type == exception ->
    Fun = fun() ->
        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        Ctxt = bondy_context:local_context(?MASTER_REALM_URI, Ref),
        Topic =
            case Type of
                start -> ?BONDY_BACKUP_RESTORE_STARTED;
                stop -> ?BONDY_BACKUP_RESTORE_FINISHED;
                exception -> ?BONDY_BACKUP_RESTORE_FAILED
            end,
        bondy_broker:publish(ReqId, #{}, Topic, [File], #{}, Ctxt)
    end,
    {ok, {Fun, undefined}};

%% REGISTRATION META API

async_handle_event({[bondy, dealer, registration, Type], Entry}, Ref)
when Type == created; Type == added; Type == deleted; Type == removed ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    SessionId = bondy_registry_entry:session_id(Entry),

    Fun = fun() ->
        ExtSessionId = bondy_utils:external_session_id(SessionId),
        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        RegId = bondy_registry_entry:id(Entry),
        Args =
            case Type == created of
                true ->
                    [ExtSessionId, bondy_registry_entry:to_details_map(Entry)];
                false ->
                    [ExtSessionId, RegId]
        end,
        KWArgs = #{procedure => bondy_registry_entry:uri(Entry)},
        Topic =
            case Type of
                created -> ?WAMP_REG_ON_CREATE;
                added -> ?WAMP_REG_ON_REGISTER;
                deleted -> ?WAMP_REG_ON_DELETE;
                removed -> ?WAMP_REG_ON_UNREGISTER
            end,
        Ctxt = bondy_context:local_context(RealmUri, Ref),

        bondy_broker:publish(ReqId, #{}, Topic, Args, KWArgs, Ctxt)
    end,
    {ok, {Fun, SessionId}};


%% SUBSCRIPTION META API

async_handle_event({[bondy, broker, subscription, Type], Entry}, Ref)
when Type == created; Type == added; Type == deleted; Type == removed ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    SessionId = bondy_registry_entry:session_id(Entry),

    Fun = fun() ->
        ExtSessionId = bondy_utils:external_session_id(SessionId),
        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        RegId = bondy_registry_entry:id(Entry),
        Args =
            case Type == created of
                true ->
                    [ExtSessionId, bondy_registry_entry:to_details_map(Entry)];
                false ->
                    [ExtSessionId, RegId]
        end,
        %% Based on https://github.com/wamp-proto/wamp-proto/issues/349
        KWArgs = #{topic => bondy_registry_entry:uri(Entry)},
        Topic =
            case Type of
                created -> ?WAMP_SUBSCRIPTION_ON_CREATE;
                added -> ?WAMP_SUBSCRIPTION_ON_SUBSCRIBE;
                deleted -> ?WAMP_SUBSCRIPTION_ON_DELETE;
                removed -> ?WAMP_SUBSCRIPTION_ON_UNSUBSCRIBE
            end,
        Ctxt = bondy_context:local_context(RealmUri, Ref),

        bondy_broker:publish(ReqId, #{}, Topic, Args, KWArgs, Ctxt)
    end,
    {ok, {Fun, SessionId}};

async_handle_event(_, _) ->
    ok.



