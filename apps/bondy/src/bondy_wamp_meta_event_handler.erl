%% =============================================================================
%%  bondy_wamp_events - An event handler to turn bondy events into WAMP events.
%%
%%  Copyright (c) 2016-2019 Ngineo Limited. All rights reserved.
%%  Copyright (c) 2020 Leapsight Holdings Limited. All rights reserved.
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
-module(bondy_wamp_meta_event_handler).
-behaviour(gen_event).
-include("bondy.hrl").
-include("bondy_meta_api.hrl").
-include("bondy_backup.hrl").
-include_lib("wamp/include/wamp.hrl").

-record(state, {}).

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

handle_event({realm_added, Uri}, State) ->
    _ = bondy:publish(#{}, ?REALM_ADDED, [Uri], #{}, ?BONDY_PRIV_REALM_URI),
    {ok, State};

handle_event({realm_deleted, Uri}, State) ->
    _ = bondy:publish(#{}, ?REALM_DELETED, [Uri], #{}, ?BONDY_PRIV_REALM_URI),
    {ok, State};

handle_event({security_group_added, RealmUri, Name}, State) ->
    _ = [
        _ = bondy:publish(#{}, ?GROUP_ADDED, [RealmUri, Name], #{}, R)
        || R <- [RealmUri, ?BONDY_PRIV_REALM_URI]
    ],
    {ok, State};

handle_event({security_group_updated, RealmUri, Name}, State) ->
    _ = [
        _ = bondy:publish(#{}, ?GROUP_UPDATED, [RealmUri, Name], #{}, R)
        || R <- [RealmUri, ?BONDY_PRIV_REALM_URI]
    ],
    {ok, State};

handle_event({security_group_deleted, RealmUri, Name}, State) ->
    _ = [
        _ = bondy:publish(#{}, ?GROUP_DELETED, [RealmUri, Name], #{}, R)
        || R <- [RealmUri, ?BONDY_PRIV_REALM_URI]
    ],
    {ok, State};

handle_event({security_user_added, RealmUri, Username}, State) ->
    _ = [
        _ = bondy:publish(#{}, ?USER_ADDED, [RealmUri, Username], #{}, R)
        || R <- [RealmUri, ?BONDY_PRIV_REALM_URI]
    ],
    {ok, State};

handle_event({security_user_updated, RealmUri, Username}, State) ->
    _ = [
        _ = bondy:publish(#{}, ?USER_UPDATED, [RealmUri, Username], #{}, R)
        || R <- [RealmUri, ?BONDY_PRIV_REALM_URI]
    ],
    {ok, State};

handle_event({security_user_deleted, RealmUri, Username}, State) ->
    _ = [
        _ = bondy:publish(#{}, ?USER_DELETED, [RealmUri, Username], #{}, R)
        || R <- [RealmUri, ?BONDY_PRIV_REALM_URI]
    ],
    {ok, State};

handle_event({security_password_changed, RealmUri, Username}, State) ->
    _ = bondy:publish(
        #{}, ?PASSWORD_CHANGED, [RealmUri, Username], #{}, ?BONDY_PRIV_REALM_URI
    ),
    {ok, State};

handle_event({security_user_logged_in, RealmUri, Username, Meta}, State) ->
    Uri = <<"bondy.security.user_logged_in">>,
    _ = bondy:publish(#{}, Uri, [Username, Meta], #{}, RealmUri),
    {ok, State};

handle_event({backup_started, File}, State) ->
    _ = bondy:publish(
        #{}, ?BACKUP_STARTED, [File], #{}, ?BONDY_PRIV_REALM_URI
    ),
    {ok, State};

handle_event({backup_finished, Args}, State) ->
    _ = bondy:publish(#{}, ?BACKUP_FINISHED, Args, #{}, ?BONDY_PRIV_REALM_URI),
    {ok, State};

handle_event({backup_error, Args}, State) ->
    _ = bondy:publish(#{}, ?BACKUP_ERROR, Args, #{}, ?BONDY_PRIV_REALM_URI),
    {ok, State};

handle_event({backup_restore_started, File}, State) ->
    _ = bondy:publish(
        #{}, ?RESTORE_STARTED, [File], #{}, ?BONDY_PRIV_REALM_URI
    ),
    {ok, State};

handle_event({backup_restore_finished, Args}, State) ->
    _ = bondy:publish(
        #{}, ?RESTORE_FINISHED, [Args], #{}, ?BONDY_PRIV_REALM_URI
    ),
    {ok, State};

handle_event({backup_restore_error, Args}, State) ->
    _ = bondy:publish(#{}, ?RESTORE_ERROR, Args, #{}, ?BONDY_PRIV_REALM_URI),
    {ok, State};

%% REGISTRATION META API

handle_event({registration_created, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = <<"wamp.registration.on_create">>,
            SessionId = bondy_context:session_id(Ctxt),
            RegId = bondy_registry_entry:id(Entry),
            Map = bondy_registry_entry:to_details_map(Entry),
            {ok, _} = bondy_broker:publish(
                #{}, Uri, [SessionId, RegId], Map, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({registration_added, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = <<"wamp.registration.on_register">>,
            SessionId = bondy_context:session_id(Ctxt),
            RegId = bondy_registry_entry:id(Entry),
            Map = bondy_registry_entry:to_details_map(Entry),
            {ok, _} = bondy_broker:publish(
                #{}, Uri, [SessionId, RegId], Map, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({registration_deleted, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = <<"wamp.registration.on_delete">>,
            SessionId = bondy_context:session_id(Ctxt),
            RegId = bondy_registry_entry:id(Entry),
            Map = bondy_registry_entry:to_details_map(Entry),
            {ok, _} = bondy_broker:publish(
                #{}, Uri, [SessionId, RegId], Map, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({registration_removed, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = <<"wamp.registration.on_unregister">>,
            SessionId = bondy_context:session_id(Ctxt),
            RegId = bondy_registry_entry:id(Entry),
            Map = bondy_registry_entry:to_details_map(Entry),
            {ok, _} = bondy_broker:publish(
                #{}, Uri, [SessionId, RegId], Map, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

%% SUBSCRIPTION META API

handle_event({subscription_created, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = <<"wamp.subscription.on_create">>,
            Opts = #{},
            Args = [
                bondy_registry_entry:session_id(Entry),
                bondy_registry_entry:to_details_map(Entry)
            ],
            KWArgs = #{},
            _ = bondy_broker:publish(Opts, Uri, Args, KWArgs, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({subscription_added, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = <<"wamp.subscription.on_subscribe">>,
            Opts = #{},
            Args = [
                bondy_registry_entry:session_id(Entry),
                bondy_registry_entry:to_details_map(Entry)
            ],
            KWArgs = #{},
            _ = bondy_broker:publish(Opts, Uri, Args, KWArgs, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({subscription_removed, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = <<"wamp.subscription.on_unsubscribe">>,
            Opts = #{},
            Args = [
                bondy_registry_entry:session_id(Entry),
                bondy_registry_entry:id(Entry)
            ],
            %% Based on https://github.com/wamp-proto/wamp-proto/issues/349
            KWArgs = #{
                <<"topic">> => bondy_registry_entry:uri(Entry)
            },
            _ = bondy_broker:publish(Opts, Uri, Args, KWArgs, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({subscription_deleted, Entry, Ctxt}, State) ->
    case bondy_context:has_session(Ctxt) of
        true ->
            Uri = <<"wamp.subscription.on_delete">>,
            Opts = #{},
            Args = [
                bondy_registry_entry:session_id(Entry),
                bondy_registry_entry:id(Entry)
            ],
            %% Based on https://github.com/wamp-proto/wamp-proto/issues/349
            KWArgs = #{
                <<"topic">> => bondy_registry_entry:uri(Entry)
            },
            _ = bondy_broker:publish(Opts, Uri, Args, KWArgs, Ctxt),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event(_, State) ->
    {ok, State}.


handle_call(Event, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p", [Event]
    ),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_info(_Info, State) ->
    {ok, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.