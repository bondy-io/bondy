%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_session_manager).
-moduledoc """
A pooled `gen_server` worker that manages the lifecycle of WAMP sessions. It
stores sessions, monitors their owner (connection) process to clean up on
crashes, registers per-session WAMP procedures, and closes sessions
individually or in bulk.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").
-include("bondy_uris.hrl").
-include("bondy.hrl").

%% Node-local set of realms whose per-node `wamp.session.<hash>..get` wildcard is
%% already registered, so register_procedures/1 registers it once per realm
%% instead of once per session. Owned by bondy_session_manager_sup (stable across
%% worker restarts).
-define(REG_REALMS_TAB, bondy_session_manager_registered_realms).

-record(state, {
    name :: atom(),
    monitor_refs = #{} :: #{id() => reference()}
}).

-type close_opts() :: #{
    exclude => [bondy_session_id:t()]
}.
-type pool() :: #{
    name := term(),
    size := pos_integer(),
    algorithm := hash
}.

%% API
-export([start_link/2]).
-export([ensure_reg_realms_table/0]).
-export([pool/0]).
-export([open/1]).
-export([open/3]).
-export([close/1]).
-export([close/2]).
-export([close_all/1]).
-export([close_all/2]).
-export([close_all/4]).
-export([invalidate_rbac_all/1]).

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

start_link(PoolName, WorkerName) ->
    gen_server:start_link(
        {local, WorkerName}, ?MODULE, [PoolName, WorkerName], []
    ).

-doc """
Creates the node-local table tracking which realms already have their per-node
`wamp.session.<hash>..get` wildcard registered. Called once by
`bondy_session_manager_sup` (its owner) before the worker pool starts.
""".
-spec ensure_reg_realms_table() -> ok.

ensure_reg_realms_table() ->
    Opts = [
        named_table,
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ],
    _ = (catch ets:new(?REG_REALMS_TAB, Opts)),
    ok.

-spec pool() -> pool().

pool() ->
    #{
        name => {?MODULE, pool},
        size => bondy_config:get([session_manager_pool, size]),
        %% hash is the only valid algorithm as the worker will monitor the
        %% session owner (connection process) and we need to demonitor on close,
        %% so we need all calls for a given session to be send to the same
        %% worker deterministically.
        algorithm => hash
    }.

-doc """
Stores the session `Session` and sets up a monitor for the calling process
which is assumed to be the client connection process e.g. WAMP connection. In
case the connection crashes it performs the cleanup of any session data that
should not be retained.

The session manager worker is picked from the pool based on the hash of the
calling process' pid.
""".
-spec open(Session :: bondy_session:t()) -> ok | {error, timeout | any()}.

open(Session) ->
    do_for_worker(
        fun(ServerRef) ->
            try
                gen_server:call(ServerRef, {open, Session}, 15000)
            catch
                exit:{timeout, _} ->
                    {error, timeout}
            end
        end,
        bondy_session:id(Session)
    ).

-doc """
Creates a new session provided the RealmUri exists or can be dynamically
created. It calls `bondy_session:new/4` which will fail with an exception if the
realm does not exist or cannot be created.

This function also sets up a monitor for the calling process which is assumed to
be the client connection process e.g. WAMP connection. In case the connection
crashes it performs the cleanup of any session data that should not be retained.
""".
-spec open(
    bondy_session_id:t(),
    uri() | bondy_realm:t(),
    bondy_session:properties()
) ->
    {ok, bondy_session:t()} | {error, timeout | any()}.

open(Id, RealmOrUri, Opts) ->
    do_for_worker(
        fun(ServerRef) ->
            try
                Session = bondy_session:new(Id, RealmOrUri, Opts),
                gen_server:call(ServerRef, {open, Session}, 15000)
            catch
                exit:{timeout, _} ->
                    {error, timeout}
            end
        end,
        Id
    ).

-doc """
Closes the session.

This function does NOT send a GOODBYE WAMP message to the session owner.
""".
-spec close(bondy_session:t()) -> ok.

close(Session) ->
    do_for_worker(
        fun(ServerRef) ->
            gen_server:cast(ServerRef, {close, Session, undefined})
        end,
        bondy_session:id(Session)
    ).

-doc """
Closes the session.

This function sends a GOODBYE WAMP message to the session owner.
""".
-spec close(bondy_session:t(), uri()) -> ok.

close(Session, ReasonUri) when is_binary(ReasonUri) ->
    do_for_worker(
        fun(ServerRef) ->
            gen_server:cast(ServerRef, {close, Session, ReasonUri})
        end,
        bondy_session:id(Session)
    ).

-doc """
Closes all managed sessions in realm with URI `RealmUri`.

Notice that `RealmUri` will be used to match the session's `authrealm` property
and not `realm_uri`. If the user is an SSO user `authrealm` is the SSO realm and
as result all sessions in all associated realms will be closed.
""".
-spec close_all(RealmUri :: uri()) -> ok.

close_all(RealmUri) ->
    close_all(RealmUri, ?WAMP_CLOSE_NORMAL).

-doc """
Closes all managed sessions in realm with URI `RealmUri`.

Notice that `RealmUri` will be used to match the session's `authrealm` property
and not `realm_uri`. If the user is an SSO user `authrealm` is the SSO realm and
as result all sessions in all associated realms will be closed.
""".
-spec close_all(RealmUri :: uri(), ReasonUri :: uri()) -> ok.

close_all(RealmUri, ReasonUri) when is_binary(ReasonUri) ->
    Bindings = #{realm_uri => RealmUri},
    do_close_all(Bindings, #{}, ReasonUri).

-doc """
Closes all sessions for user `Username` on realm `RealmUri` according to the
options `Opts`.

Notice that `RealmUri` will be used to match the session's `authrealm` property
and not `realm_uri`. If the user is an SSO user `authrealm` is the SSO realm and
as result all sessions in all associated realms will be closed.
""".
-spec close_all(
    RealmUri :: uri(),
    Authid :: uri(),
    ReasonUri :: uri(),
    Opts :: close_opts()
) -> ok.

close_all(RealmUri, Authid, ReasonUri, Opts) ->
    Bindings = #{authrealm => RealmUri, authid => Authid},
    do_close_all(Bindings, Opts, ReasonUri).

-doc """
Invalidates the cached RBAC context of every session on realm `RealmUri`
(`STORAGE_ARCHITECTURE` §9.5). Each session's next authorisation re-reads the
subject's current grants; the sessions themselves are NOT closed.

Used on a local grant/revoke so a permission change re-evaluates active sessions
in place. The scope is the whole realm (rather than a single subject) because a
group grant change affects every member — the over-invalidation of unaffected
sessions costs only a one-time context rebuild on their next op, and grant
changes are rare admin operations.
""".
-spec invalidate_rbac_all(RealmUri :: uri()) -> ok.

invalidate_rbac_all(RealmUri) ->
    do_invalidate_rbac_all(#{realm_uri => RealmUri}).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([PoolName, WorkerName]) ->
    true = gproc_pool:connect_worker(PoolName, WorkerName),
    {ok, #state{name = WorkerName}}.

handle_call({open, Session0}, _From, State0) ->
    %% We store the session
    {ok, Session} = bondy_session:store(Session0),

    %% We init the session-scoped counters
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

    %% This must be safe to avoid crashing the server as this acts as a
    %% session supervisor
    try
        %% We register WAMP procedures
        ok = register_procedures(Session),
        Refs = State0#state.monitor_refs,
        State = State0#state{monitor_refs = Refs#{Id => Ref, Ref => Id}},

        %% Schedule OIDC token refresh if this is an oidcrp session
        ok = maybe_schedule_oidc_refresh(Session),

        {reply, {ok, Session}, State}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description =>
                    "Error while registering session 'get' procedure",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            erlang:demonitor(Ref),
            ok = cleanup(Session),
            {reply, {error, Reason}, State0}
    end;
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

    State =
        case maps:find(Ref, Refs) of
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
    try
        gproc_pool:disconnect_worker(pool(), State#state.name)
    catch
        _:_ ->
            ok
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Ensures this node's `wamp.session.<hash>..get` wildcard is registered for the
%% session's realm — once per realm, not once per session.
%%
%% `wamp.session.get` is served by routing to the node that owns the (non-
%% replicated) session. The client-facing session id is `{NodeHash}.{Rest}`, so
%% the meta API rewrites the call to `wamp.session.{NodeHash}.{Rest}.get`; the
%% wildcard `wamp.session.{NodeHash}..get` registered here matches every such
%% URI for a session owned by this node, letting the dealer forward it with no
%% per-session registration (the old per-session exact registration cost a
%% `bondy_wamp_callback:validate_target/2` on every session open).
register_procedures(Session) ->
    RealmUri = bondy_session:realm_uri(Session),

    %% ets:insert_new is atomic, so exactly one worker registers per realm.
    case ets:insert_new(?REG_REALMS_TAB, {RealmUri}) of
        true ->
            try
                ok = register_node_session_get(RealmUri)
            catch
                Class:Reason:Stacktrace ->
                    %% Undo the guard so a later open retries the registration.
                    true = ets:delete(?REG_REALMS_TAB, RealmUri),
                    erlang:raise(Class, Reason, Stacktrace)
            end;
        false ->
            ok
    end.

%% @private
register_node_session_get(RealmUri) ->
    NodeHash = bondy_session_id:node_hash(),

    %% The empty component between the two dots is the wildcard that matches the
    %% session's `{Rest}` URI segment.
    ProcUri = <<"wamp.session.", NodeHash/binary, "..get">>,

    %% A single node-level callback reference (no owning session). The handler
    %% resolves the session from the guid passed in the call, so the only static
    %% argument is the realm (used for the realm-scoped lookup).
    Ref = bondy_ref:new(internal, {bondy_session_api, get}),
    Opts = #{match => ?WILDCARD_MATCH, callback_args => [RealmUri]},

    case bondy_dealer:register(ProcUri, Opts, RealmUri, Ref) of
        {ok, _} ->
            ok;
        {error, already_exists} ->
            %% The guard and the registry can diverge only across a supervisor
            %% restart; the existing wildcard is exactly what we wanted.
            ok
    end.

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
    ?LOG_DEBUG(#{
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

    try
        Matches = bondy_session:match(Bindings, Opts),
        ok = bondy_utils:foreach(Fun, Matches)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while closing all sessions",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

%% @private
do_invalidate_rbac_all(Bindings) ->
    Opts = #{limit => 100, return => object, exclude => undefined},

    Fun = fun
        ({continue, Cont}) ->
            try
                bondy_session:match(Cont)
            catch
                Class:Reason:Stacktrace ->
                    ?LOG_ERROR(#{
                        description =>
                            "Error while invalidating session RBAC context",
                        class => Class,
                        reason => Reason,
                        stacktrace => Stacktrace
                    }),
                    []
            end;
        (Session) ->
            %% Re-evaluate in place (no teardown): the next authorize rebuilds
            %% the context from the subject's current grants (§9.5).
            ok = bondy_session:invalidate_rbac_context(
                bondy_session:id(Session)
            )
    end,

    try
        Matches = bondy_session:match(Bindings, Opts),
        ok = bondy_utils:foreach(Fun, Matches)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while invalidating all session contexts",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

%% @private
maybe_send_goodbye(_, undefined) ->
    ok;
maybe_send_goodbye(Session, ReasonUri) ->
    RealmUri = bondy_session:realm_uri(Session),
    ProcRef = bondy_session:ref(Session),

    Msg = bondy_wamp_message:goodbye(
        #{message => <<"The session was closed by the Router.">>},
        ReasonUri
    ),
    _ = catch bondy:send(RealmUri, ProcRef, Msg),
    ok.

%% @private
maybe_schedule_oidc_refresh(Session) ->
    case bondy_session:authmethod(Session) of
        ?OIDCRP_AUTH ->
            do_schedule_oidc_refresh(Session);
        _ ->
            ok
    end.

%% @private
do_schedule_oidc_refresh(Session) ->
    case bondy_session:authmethod_details(Session) of
        #{oidc_provider := Provider, oidc_refresh_token := RT} = Details when
            is_binary(Provider) andalso is_binary(RT)
        ->
            RealmUri = bondy_session:realm_uri(Session),
            Authid = bondy_session:authid(Session),
            EntryId = bondy_utils:uuid(),
            AccessExp = maps:get(
                oidc_access_token_expires_in, Details, 0
            ),
            ok = bondy_oidc_refresh_worker:schedule_refresh(
                EntryId,
                RealmUri,
                Authid,
                Provider,
                #{
                    refresh_token => RT,
                    access_token_expires_in => AccessExp
                }
            ),
            %% Store EntryId back for removal at session close
            Updated = Details#{oidc_refresh_entry_id => EntryId},
            SessionId = bondy_session:id(Session),
            ok = bondy_session:update_authmethod_details(
                SessionId, Updated
            ),
            ok;
        _ ->
            ok
    end.
