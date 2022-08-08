%% =============================================================================
%%  bondy_event_wamp_publisher - An event handler to turn bondy events into
%% WAMP events.
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-record(state, {
    ref :: bondy_ref:t()
}).

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
    State = #state{
        ref = bondy_ref:new(internal)
    },
    {ok, State}.


handle_event({cluster_connection_up, Node}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    MyNode = bondy_config:nodestring(),
    Topic = ?BONDY_CLUSTER_CONN_UP,
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, State#state.ref),

    _ = bondy_broker:publish(ReqId, #{}, Topic, [MyNode, Node], #{}, Ctxt),
    {ok, State};

handle_event({cluster_connection_down, Node}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    MyNode = bondy_config:nodestring(),
    Topic = ?BONDY_CLUSTER_CONN_DOWN,
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, State#state.ref),

    _ = bondy_broker:publish(ReqId, #{}, Topic, [MyNode, Node], #{}, Ctxt),
    {ok, State};

handle_event({realm_created, Uri}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?BONDY_REALM_CREATED, [Uri], #{}, Ctxt
    ),
    {ok, State};

handle_event({realm_updated, Uri}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?BONDY_REALM_UPDATED, [Uri], #{}, Ctxt
    ),
    {ok, State};

handle_event({realm_deleted, Uri}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?BONDY_REALM_DELETED, [Uri], #{}, Ctxt
    ),
    {ok, State};

handle_event({session_opened, Session}, State) ->
    RealmUri = bondy_session:realm_uri(Session),
    Args = [bondy_session:to_external(Session)],
    KWArgs = #{
        session_guid => bondy_session:id(Session)
    },
    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),

    _ = bondy_broker:publish(
        ReqId, #{}, ?WAMP_SESSION_ON_JOIN, Args, KWArgs, Ctxt
    ),
    {ok, State};

handle_event({session_closed, Session, _DurationSecs}, State) ->
    RealmUri = bondy_session:realm_uri(Session),
    Id = bondy_session:external_id(Session),
    Authid = bondy_session:authid(Session),
    Authrole = bondy_session:authrole(Session),

    Args = [Id, Authid, Authrole],
    KWArgs = #{
        session_guid => bondy_session:id(Session)
    },

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?WAMP_SESSION_ON_LEAVE, Args, KWArgs, Ctxt
    ),
    {ok, State};

handle_event({group_added, RealmUri, Name}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?BONDY_GROUP_ADDED, [RealmUri, Name], #{}, Ctxt
    ),
    {ok, State};

handle_event({group_updated, RealmUri, Name}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?BONDY_GROUP_UPDATED, [RealmUri, Name], #{}, Ctxt
    ),
    {ok, State};

handle_event({group_deleted, RealmUri, Name}, State) ->
    %% Silence when this is a cascade delete
    case bondy_realm:exists(RealmUri) of
        true ->
            %% We use a global ID as this is not a publishers request
            ReqId = bondy_utils:gen_message_id(global),
            Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

            _ = bondy_broker:publish(
                ReqId, #{}, ?BONDY_GROUP_DELETED, [RealmUri, Name], #{}, Ctxt
            );
        false ->
            ok
    end,
    {ok, State};

handle_event({user_added, RealmUri, Username}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?BONDY_USER_ADDED, [Username], #{}, Ctxt
    ),
    {ok, State};

handle_event({user_updated, RealmUri, Username}, State) ->
    ok = bondy_ticket:revoke_all(RealmUri, Username),
    ok = bondy_oauth2:revoke_refresh_tokens(RealmUri, Username),

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?BONDY_USER_UPDATED, [RealmUri, Username], #{}, Ctxt
    ),
    %% TODO Refresh any sessions' rbac_ctxt caches this user has in this node
    %% for other realms. This is because
    {ok, State};

handle_event({user_deleted, RealmUri, Username}, State) ->
    %% Silence when this is a cascade delete
    case bondy_realm:exists(RealmUri) of
        true ->
            %% The effect of revoking tickets and tokens will be replicated
            %% through plum_db
            ok = bondy_ticket:revoke_all(RealmUri, Username),
            ok = bondy_oauth2:revoke_refresh_tokens(RealmUri, Username),

            %% We use a global ID as this is not a publishers request
            ReqId = bondy_utils:gen_message_id(global),
            Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

            _ = bondy_broker:publish(
                ReqId, #{}, ?BONDY_USER_DELETED, [RealmUri, Username], #{}, Ctxt
            );
        false ->
            ok
    end,
    {ok, State};

handle_event({user_credentials_updated, RealmUri, Username}, State) ->
    ok = bondy_ticket:revoke_all(RealmUri, Username),
    ok = bondy_oauth2:revoke_refresh_tokens(RealmUri, Username),

    Uri = ?BONDY_USER_CREDENTIALS_CHANGED,

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, Uri, [RealmUri, Username], #{}, Ctxt
    ),

    {ok, State};

handle_event({user_log_in, RealmUri, Username, Meta}, State) ->
    Uri = ?BONDY_USER_LOGGED_IN,

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    _ = bondy_broker:publish(ReqId, #{}, Uri, [Username, Meta], #{}, Ctxt),
    {ok, State};

handle_event({backup_started, #{filename := File}}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?BONDY_BACKUP_STARTED, [File], #{}, Ctxt
    ),
    {ok, State};

handle_event({backup_finished, Args}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?BONDY_BACKUP_FINISHED, Args, #{}, Ctxt
    ),
    {ok, State};

handle_event({backup_failed, Args}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?BONDY_BACKUP_FAILED, Args, #{}, Ctxt
    ),
    {ok, State};

handle_event({backup_restore_started, File}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?BONDY_BACKUP_RESTORE_STARTED, [File], #{}, Ctxt
    ),
    {ok, State};

handle_event({backup_restore_finished, Args}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, State#state.ref),

    _ = bondy_broker:publish(
        ReqId, #{}, ?BONDY_BACKUP_RESTORE_FINISHED, [Args], #{}, Ctxt
    ),
    {ok, State};

handle_event({backup_restore_failed, Args}, State) ->
    Uri = ?BONDY_BACKUP_RESTORE_FAILED,

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, State#state.ref),

    _ = bondy_broker:publish(ReqId, #{}, Uri, Args, #{}, Ctxt),
    {ok, State};

%% REGISTRATION META API

handle_event({registration_created, Entry}, State) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    SessionId = bondy_utils:external_session_id(
        bondy_registry_entry:session_id(Entry)
    ),

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    RegId = bondy_registry_entry:id(Entry),
    Uri = ?WAMP_REG_ON_CREATE,
    Args = [SessionId, RegId],
    KWArgs = bondy_registry_entry:to_details_map(Entry),

    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    {ok, _} = bondy_broker:publish(ReqId, #{}, Uri, Args, KWArgs, Ctxt),

    {ok, State};

handle_event({registration_added, Entry}, State) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    SessionId = bondy_utils:external_session_id(
        bondy_registry_entry:session_id(Entry)
    ),

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    RegId = bondy_registry_entry:id(Entry),
    Uri = ?WAMP_REG_ON_REGISTER,
    Args = [SessionId, RegId],
    KWArgs = bondy_registry_entry:to_details_map(Entry),

    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    {ok, _} = bondy_broker:publish(ReqId, #{}, Uri, Args, KWArgs, Ctxt),

    {ok, State};

handle_event({registration_deleted, Entry}, State) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    SessionId = bondy_utils:external_session_id(
        bondy_registry_entry:session_id(Entry)
    ),

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    RegId = bondy_registry_entry:id(Entry),
    Uri = ?WAMP_REG_ON_DELETE,
    Args = [SessionId, RegId],
    KWArgs = bondy_registry_entry:to_details_map(Entry),


    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    {ok, _} = bondy_broker:publish(ReqId, #{}, Uri, Args, KWArgs, Ctxt),

    {ok, State};

handle_event({registration_removed, Entry}, State) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    SessionId = bondy_utils:external_session_id(
        bondy_registry_entry:session_id(Entry)
    ),

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    RegId = bondy_registry_entry:id(Entry),
    Uri = ?WAMP_REG_ON_UNREGISTER,
    Args = [SessionId, RegId],
    KWArgs = bondy_registry_entry:to_details_map(Entry),

    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    {ok, _} = bondy_broker:publish(ReqId, #{}, Uri, Args, KWArgs, Ctxt),

    {ok, State};

%% SUBSCRIPTION META API

handle_event({subscription_created, Entry}, State) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    ExtId = bondy_utils:external_session_id(
        bondy_registry_entry:session_id(Entry)
    ),

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Uri = ?WAMP_SUBSCRIPTION_ON_CREATE,
    Opts = #{},
    Args = [
        ExtId,
        bondy_registry_entry:to_details_map(Entry)
    ],
    KWArgs = #{},

    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    _ = bondy_broker:publish(ReqId, Opts, Uri, Args, KWArgs, Ctxt),

    {ok, State};

handle_event({subscription_added, Entry}, State) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    ExtId = bondy_utils:external_session_id(
        bondy_registry_entry:session_id(Entry)
    ),

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Uri = ?WAMP_SUBSCRIPTION_ON_SUBSCRIBE,
    Opts = #{},
    Args = [
        ExtId,
        bondy_registry_entry:to_details_map(Entry)
    ],
    KWArgs = #{},

    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    _ = bondy_broker:publish(ReqId, Opts, Uri, Args, KWArgs, Ctxt),

    {ok, State};

handle_event({subscription_removed, Entry}, State) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    ExtId = bondy_utils:external_session_id(
        bondy_registry_entry:session_id(Entry)
    ),

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Uri = ?WAMP_SUBSCRIPTION_ON_UNSUBSCRIBE,
    Opts = #{},
    Args = [
        ExtId,
        bondy_registry_entry:id(Entry)
    ],
    %% Based on https://github.com/wamp-proto/wamp-proto/issues/349
    KWArgs = #{
        <<"topic">> => bondy_registry_entry:uri(Entry)
    },

    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    _ = bondy_broker:publish(ReqId, Opts, Uri, Args, KWArgs, Ctxt),

    {ok, State};

handle_event({subscription_deleted, Entry}, State) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    ExtId = bondy_utils:external_session_id(
        bondy_registry_entry:session_id(Entry)
    ),

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:gen_message_id(global),
    Uri = ?WAMP_SUBSCRIPTION_ON_DELETE,
    Opts = #{},
    Args = [
        ExtId,
        bondy_registry_entry:id(Entry)
    ],
    %% Based on https://github.com/wamp-proto/wamp-proto/issues/349
    KWArgs = #{
        <<"topic">> => bondy_registry_entry:uri(Entry)
    },

    Ctxt = bondy_context:local_context(RealmUri, State#state.ref),

    _ = bondy_broker:publish(ReqId, Opts, Uri, Args, KWArgs, Ctxt),

    {ok, State};

handle_event(_, State) ->
    {ok, State}.


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
%% API
%% =============================================================================



