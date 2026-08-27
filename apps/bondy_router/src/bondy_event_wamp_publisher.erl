%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_event_wamp_publisher).
-moduledoc """
An event handler that generates WAMP Meta Events based on internal
Bondy events.
""".
-behaviour(gen_event).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

%% Minimum seconds between load-shedding warnings; further drops within
%% the window are counted in metrics and logged at debug level only.
-define(SHED_WARN_WINDOW_SECS, 60).

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
        {ok, {Fun, PartitionKey0}} ->
            PartitionKey = bondy_stdlib:lazy_or_else(
                PartitionKey0,
                fun bondy_wamp_utils:rand_uniform/0
            ),

            case bondy_jobs:enqueue(Fun, PartitionKey) of
                ok ->
                    ok;
                {error, full} ->
                    ok = on_shed(Event);
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        description => "Unexpected error while enqueuing job",
                        reason => Reason,
                        event => Event
                    })
            end,
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

%% @private
%% Records a load-shed meta event so operators can see the feature
%% degrading: always bumps `bondy_wamp_dropped_total{reason=shed}` and logs
%% a warning at most once per window (the handler runs in the event
%% manager process, so the process dictionary is a safe window store).
on_shed(Event) ->
    Family = event_family(Event),
    ok = bondy_telemetry:wamp_dropped(shed, Family),
    Now = erlang:monotonic_time(second),
    Key = {?MODULE, last_shed_warning},

    case erlang:get(Key) of
        Last when is_integer(Last), Now - Last < ?SHED_WARN_WINDOW_SECS ->
            ?LOG_DEBUG(#{
                description =>
                    "Dropping WAMP meta event due to load shedding: "
                    "jobs queue at capacity",
                family => Family
            });
        _ ->
            _ = erlang:put(Key, Now),
            ?LOG_WARNING(#{
                description =>
                    "Dropping WAMP meta events due to load shedding: "
                    "jobs queue at capacity. Subscribers to meta topics "
                    "are missing events; further drops in the next "
                    "window are counted in bondy_wamp_dropped_total "
                    "and logged at debug level.",
                family => Family,
                window_secs => ?SHED_WARN_WINDOW_SECS
            })
    end,
    ok.

%% @private
%% Events are tuples of varying arity whose first element is the event
%% path, e.g. `{[bondy, broker, subscription, added], Entry}`.
event_family(Event) when is_tuple(Event) andalso tuple_size(Event) >= 1 ->
    case element(1, Event) of
        [bondy, broker, subscription | _] -> subscription;
        [bondy, dealer, registration | _] -> registration;
        [bondy, session | _] -> session;
        [bondy, realm | _] -> realm;
        [bondy, cluster | _] -> cluster;
        [bondy, rbac | _] -> rbac;
        [bondy, user | _] -> user;
        [bondy, export | _] -> export;
        _ -> other
    end;
event_family(_) ->
    other.

-spec async_handle_event(event(), term()) ->
    ok | {ok, {function(), partition_key()}}.

async_handle_event({[bondy, cluster, connection, Type], Node}, Ref) when
    Type == up; Type == down
->
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
%% NOTE: the emitted event path is `[bondy, realm, Action]` (see
%% bondy_realm on_create/on_update/on_delete). A previous version of
%% this clause matched `[bondy, realm, created, Type]`, which never
%% matched, so the realm meta events were silently never published.
async_handle_event({[bondy, realm, Type], Uri}, Ref) when
    Type == created; Type == updated; Type == deleted
->
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
async_handle_event({[bondy, rbac, group, Type], RealmUri, Name}, Ref) when
    Type == added; Type == updated; Type == deleted
->
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
async_handle_event({[bondy, user, Type], RealmUri, Username}, Ref) when
    Type == updated; Type == deleted
->
    case Type =/= deleted orelse bondy_realm:exists(RealmUri) of
        true ->
            Fun = fun() ->
                ok = bondy_ticket:revoke_all(RealmUri, Username),
                ok = bondy_oauth_token:revoke_all(RealmUri, Username),

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
    {[bondy, user, credentials, updated], RealmUri, Username}, Ref
) ->
    Fun = fun() ->
        ok = bondy_ticket:revoke_all(RealmUri, Username),
        ok = bondy_oauth_token:revoke_all(RealmUri, Username),

        Topic = ?BONDY_USER_CREDENTIALS_CHANGED,

        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        Ctxt = bondy_context:local_context(RealmUri, Ref),
        bondy_broker:publish(ReqId, #{}, Topic, [RealmUri, Username], #{}, Ctxt)
    end,
    {ok, {Fun, RealmUri}};
async_handle_event(
    {[bondy, user, logged_in], RealmUri, Username, Meta}, Ref
) ->
    Fun = fun() ->
        Topic = ?BONDY_USER_LOGGED_IN,

        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        Ctxt = bondy_context:local_context(RealmUri, Ref),
        bondy_broker:publish(ReqId, #{}, Topic, [Username, Meta], #{}, Ctxt)
    end,
    {ok, {Fun, RealmUri}};
async_handle_event({[bondy, export, Type], #{filename := File}}, Ref) when
    Type == start; Type == stop; Type == exception
->
    Fun = fun() ->
        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        Ctxt = bondy_context:local_context(?MASTER_REALM_URI, Ref),
        Topic =
            case Type of
                start -> ?BONDY_EXPORT_STARTED;
                stop -> ?BONDY_EXPORT_FINISHED;
                exception -> ?BONDY_EXPORT_FAILED
            end,
        bondy_broker:publish(ReqId, #{}, Topic, [File], #{}, Ctxt)
    end,
    {ok, {Fun, undefined}};
async_handle_event(
    {[bondy, export, import, Type], #{filename := File}}, Ref
) when
    Type == start; Type == stop; Type == exception
->
    Fun = fun() ->
        %% We use a global ID as this is not a publishers request
        ReqId = bondy_message_id:global(),
        Ctxt = bondy_context:local_context(?MASTER_REALM_URI, Ref),
        Topic =
            case Type of
                start -> ?BONDY_EXPORT_IMPORT_STARTED;
                stop -> ?BONDY_EXPORT_IMPORT_FINISHED;
                exception -> ?BONDY_EXPORT_IMPORT_FAILED
            end,
        bondy_broker:publish(ReqId, #{}, Topic, [File], #{}, Ctxt)
    end,
    {ok, {Fun, undefined}};
%% REGISTRATION META API

%% NOTE: the registration/subscription meta events no longer ride this
%% handler — they are demand-gated and enqueued directly by
%% `bondy_meta_events` at the `bondy_dealer`/`bondy_broker` emission
%% sites (see METRICS_GAP_ANALYSIS.md Part III).
async_handle_event(_, _) ->
    ok.
