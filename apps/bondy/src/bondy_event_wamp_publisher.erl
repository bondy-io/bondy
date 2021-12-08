%% =============================================================================
%%  bondy_event_wamp_publisher - An event handler to turn bondy events into
%% WAMP events.
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
    State = #state{},
    {ok, State}.


handle_event({realm_created, Uri}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_REALM_CREATED, [Uri], #{}, ?MASTER_REALM_URI
    ),
    {ok, State};

handle_event({realm_updated, Uri}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_REALM_UPDATED, [Uri], #{}, ?MASTER_REALM_URI
    ),
    {ok, State};

handle_event({realm_deleted, Uri}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_REALM_DELETED, [Uri], #{}, ?MASTER_REALM_URI
    ),
    {ok, State};

handle_event({session_opened, Session}, State) ->
    Uri = bondy_session:realm_uri(Session),
    Args = [bondy_session:to_external(Session)],

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(ReqId, #{}, ?WAMP_SESSION_ON_JOIN, Args, #{}, Uri),
    {ok, State};

handle_event({session_closed, Session, _DurationSecs}, State) ->
    Uri = bondy_session:realm_uri(Session),
    Id = bondy_session:id(Session),
    Authid = bondy_session:authid(Session),
    Authrole = bondy_session:authrole(Session),

    Args = [Id, Authid, Authrole],

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(ReqId, #{}, ?WAMP_SESSION_ON_LEAVE, Args, #{}, Uri),
    {ok, State};

handle_event({group_added, RealmUri, Name}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_GROUP_ADDED, [RealmUri, Name], #{}, RealmUri
    ),
    {ok, State};

handle_event({group_updated, RealmUri, Name}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_GROUP_UPDATED, [RealmUri, Name], #{}, RealmUri
    ),
    {ok, State};

handle_event({group_deleted, RealmUri, Name}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_GROUP_DELETED, [RealmUri, Name], #{}, RealmUri
    ),
    {ok, State};

handle_event({user_added, RealmUri, Username}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_USER_ADDED, [Username], #{}, RealmUri
    ),
    {ok, State};

handle_event({user_updated, RealmUri, Username}, State) ->
    ok = bondy_ticket:revoke_all(RealmUri, Username),
    ok = bondy_oauth2:revoke_refresh_tokens(RealmUri, Username),

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_USER_UPDATED, [RealmUri, Username], #{}, RealmUri
    ),
    %% TODO Refresh any sessions' rbac_ctxt caches this user has in this node
    %% for other realms. This is because
    {ok, State};

handle_event({user_deleted, RealmUri, Username}, State) ->
    %% The effect of revoking tickets and tokens will be replicated through
    %% plum_db
    ok = bondy_ticket:revoke_all(RealmUri, Username),
    ok = bondy_oauth2:revoke_refresh_tokens(RealmUri, Username),

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_USER_DELETED, [RealmUri, Username], #{}, RealmUri
    ),

    {ok, State};

handle_event({user_credentials_updated, RealmUri, Username}, State) ->
    ok = bondy_ticket:revoke_all(RealmUri, Username),
    ok = bondy_oauth2:revoke_refresh_tokens(RealmUri, Username),

    Uri = ?BONDY_USER_CREDENTIALS_CHANGED,

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, Uri, [RealmUri, Username], #{}, RealmUri
    ),

    {ok, State};

handle_event({user_log_in, RealmUri, Username, Meta}, State) ->
    Uri = ?BONDY_USER_LOGGED_IN,

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(ReqId, #{}, Uri, [Username, Meta], #{}, RealmUri),
    {ok, State};

handle_event({backup_started, #{filename := File}}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_BACKUP_STARTED, [File], #{}, ?MASTER_REALM_URI
    ),
    {ok, State};

handle_event({backup_finished, Args}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_BACKUP_FINISHED, Args, #{}, ?MASTER_REALM_URI
    ),
    {ok, State};

handle_event({backup_failed, Args}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_BACKUP_FAILED, Args, #{}, ?MASTER_REALM_URI
    ),
    {ok, State};

handle_event({backup_restore_started, File}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_BACKUP_RESTORE_STARTED, [File], #{}, ?MASTER_REALM_URI
    ),
    {ok, State};

handle_event({backup_restore_finished, Args}, State) ->
    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(
        ReqId, #{}, ?BONDY_BACKUP_RESTORE_FINISHED, [Args], #{}, ?MASTER_REALM_URI
    ),
    {ok, State};

handle_event({backup_restore_failed, Args}, State) ->
    Uri = ?BONDY_BACKUP_RESTORE_FAILED,

    %% We use a global ID as this is not a publishers request
    ReqId = bondy_utils:get_id(global),

    _ = bondy:publish(ReqId, #{}, Uri, Args, #{}, ?MASTER_REALM_URI),
    {ok, State};

%% REGISTRATION META API

handle_event({registration_created, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = ?WAMP_REG_ON_CREATE,
            SessionId = bondy_context:session_id(Ctxt),
            RegId = bondy_registry_entry:id(Entry),
            Map = bondy_registry_entry:to_details_map(Entry),

            %% We use a global ID as this is not a publishers request
            ReqId = bondy_utils:get_id(global),

            {ok, _} = bondy_broker:publish(
                ReqId, #{}, Uri, [SessionId, RegId], Map, Ctxt
            ),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({registration_added, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = ?WAMP_REG_ON_REGISTER,
            SessionId = bondy_context:session_id(Ctxt),
            RegId = bondy_registry_entry:id(Entry),
            Map = bondy_registry_entry:to_details_map(Entry),

            %% We use a global ID as this is not a publishers request
            ReqId = bondy_utils:get_id(global),

            {ok, _} = bondy_broker:publish(
                ReqId, #{}, Uri, [SessionId, RegId], Map, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({registration_deleted, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = ?WAMP_REG_ON_DELETE,
            SessionId = bondy_context:session_id(Ctxt),
            RegId = bondy_registry_entry:id(Entry),
            Map = bondy_registry_entry:to_details_map(Entry),

            %% We use a global ID as this is not a publishers request
            ReqId = bondy_utils:get_id(global),

            {ok, _} = bondy_broker:publish(
                ReqId, #{}, Uri, [SessionId, RegId], Map, Ctxt
            ),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({registration_removed, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = ?WAMP_REG_ON_UNREGISTER,
            SessionId = bondy_context:session_id(Ctxt),
            RegId = bondy_registry_entry:id(Entry),
            Map = bondy_registry_entry:to_details_map(Entry),

            %% We use a global ID as this is not a publishers request
            ReqId = bondy_utils:get_id(global),

            {ok, _} = bondy_broker:publish(
                ReqId, #{}, Uri, [SessionId, RegId], Map, Ctxt
            ),
            {ok, State};
        false ->
            {ok, State}
    end;

%% SUBSCRIPTION META API

handle_event({subscription_created, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = ?WAMP_SUBSCRIPTION_ON_CREATE,
            Opts = #{},
            Args = [
                bondy_registry_entry:session_id(Entry),
                bondy_registry_entry:to_details_map(Entry)
            ],

            %% We use a global ID as this is not a publishers request
            ReqId = bondy_utils:get_id(global),

            KWArgs = #{},
            _ = bondy_broker:publish(ReqId, Opts, Uri, Args, KWArgs, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({subscription_added, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = ?WAMP_SUBSCRIPTION_ON_SUBSCRIBE,
            Opts = #{},
            Args = [
                bondy_registry_entry:session_id(Entry),
                bondy_registry_entry:to_details_map(Entry)
            ],

            %% We use a global ID as this is not a publishers request
            ReqId = bondy_utils:get_id(global),

            KWArgs = #{},
            _ = bondy_broker:publish(ReqId, Opts, Uri, Args, KWArgs, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({subscription_removed, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = ?WAMP_SUBSCRIPTION_ON_UNSUBSCRIBE,
            Opts = #{},
            Args = [
                bondy_registry_entry:session_id(Entry),
                bondy_registry_entry:id(Entry)
            ],

            %% We use a global ID as this is not a publishers request
            ReqId = bondy_utils:get_id(global),

            %% Based on https://github.com/wamp-proto/wamp-proto/issues/349
            KWArgs = #{
                <<"topic">> => bondy_registry_entry:uri(Entry)
            },
            _ = bondy_broker:publish(ReqId, Opts, Uri, Args, KWArgs, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({subscription_deleted, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = ?WAMP_SUBSCRIPTION_ON_DELETE,
            Opts = #{},
            Args = [
                bondy_registry_entry:session_id(Entry),
                bondy_registry_entry:id(Entry)
            ],

            %% We use a global ID as this is not a publishers request
            ReqId = bondy_utils:get_id(global),

            %% Based on https://github.com/wamp-proto/wamp-proto/issues/349
            KWArgs = #{
                <<"topic">> => bondy_registry_entry:uri(Entry)
            },
            _ = bondy_broker:publish(ReqId, Opts, Uri, Args, KWArgs, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

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
