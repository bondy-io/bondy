%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_upstream).

-moduledoc """
Owner of one declared upstream MCP server (design §13): holds the
upstream MCP session (`bondy_mcp_client`), projects the upstream's tools
into the WAMP registry as callee procedures, and gates every projection
through the pin store.

## Projection

One instance per enabled `mcp.upstreams.$name` declaration, under
`bondy_mcp_upstream_sup`. On startup (and on every retry after a failed
attempt, with `bondy_retry` backoff — the upstream being down at boot
must not be fatal):

1. opens an internal WAMP session, so `bondy_session_manager`'s monitor
   flushes every registration this process made when it dies — the same
   cleanup contract `bondy_http_connector_callee` relies on;
2. runs the MCP initialization phase and lists the upstream's tools;
3. registers `<prefix>.<tool>` per tool that passes the pin gate, with an
   internal callback ref to `handle_wamp_call/2,3` — applied by the
   dealer on THIS node (a non-local callee's CALL is forwarded to the
   node its ref names before the callback is applied), which is what
   makes the gproc lookup below sound.

The projection writes nothing to `bondy_interface`: upstream descriptions
are a prompt-injection channel (§13.3), so surfacing a projected
procedure on Bondy's own served MCP manifest stays a deliberate operator
overlay act, never a side effect.

## Pin gate (§13.3)

The first sighting of a tool pins its definition — trust on first use —
in the durable `mcp_upstream` table: the normative definition fields and
their hash, SHA-256 over a canonical JSON encoding (recursively sorted
object keys). Canonical JSON rather than `term_to_binary`: pins outlive
OTP releases, and the external term format does not (the trap
`bondy_mcp_spec:hash/1` documents for its own ephemeral use). On any
later listing, a changed definition BLOCKS the tool — it is not (or no
longer) registered — until `approve/2` explicitly re-pins it. A
re-initialized upstream session triggers a refresh, so a server that
restarted with changed definitions loses its registrations at that point
rather than at the next boot.

## Calls

The registered callback runs on the dealer's calling process: it reads
the current client connection from this process's gproc value (updated on
re-initialization, so callers never wait on the owner), performs
`tools/call`, and maps the `CallToolResult` back through
`bondy_mcp_wamp:tool_result/1`. A `404` from the upstream — the session
was terminated — asks the owner to re-initialize (single-flight: the
owner compares session ids and reconnects at most once per expiry) and
retries the call once. Every call is audited as an `upstream_call` with
`derivation` naming the shared service account it rode (§13.1).

Positional WAMP arguments are not accepted (the dealer's callback
application splices them into the callback arity): callers pass kwargs,
`@args` included, matching the tool's `inputSchema` — the same bound
`bondy_http_connector`'s callees have.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_router/include/bondy_db_tables.hrl").

%% The normative content of an upstream tool definition: what the pin
%% hash covers. `content`-irrelevant fields (e.g. upstream `_meta`) are
%% outside it deliberately.
-define(NORMATIVE_KEYS, [
    <<"name">>,
    <<"title">>,
    <<"description">>,
    <<"inputSchema">>,
    <<"outputSchema">>,
    <<"annotations">>
]).

-record(state, {
    conf :: map(),
    service :: map() | undefined,
    pool :: atom() | undefined,
    realm_uri :: binary(),
    wamp_session_id :: binary() | undefined,
    conn :: bondy_mcp_client:t() | undefined,
    %% ToolName => {RegId, ProcUri}
    registrations = #{} :: #{binary() => {any(), binary()}},
    %% Drifted definitions awaiting `approve/2`, by tool name.
    blocked = #{} :: #{binary() => map()},
    retry :: bondy_retry:t() | undefined,
    retry_ref :: reference() | undefined
}).

-export([approve/2]).
-export([handle_wamp_call/2]).
-export([handle_wamp_call/3]).
-export([info/1]).
-export([pin_hash/1]).
-export([refresh/1]).
-export([start_link/1]).

%% gen_server callbacks
-export([init/1]).
-export([handle_continue/2]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Starts the owner for one upstream declaration.".
-spec start_link(map()) -> {ok, pid()} | {error, any()}.

start_link(#{name := _} = Conf) ->
    gen_server:start_link(?MODULE, [Conf], []).

-doc """
Re-pins a drift-BLOCKED tool at its current upstream definition and
registers it. The explicit re-approval §13.3 requires; there is no bulk
form on purpose.
""".
-spec approve(binary(), binary()) -> ok | {error, any()}.

approve(Upstream, Tool) ->
    call(Upstream, {approve, Tool}).

-doc """
Re-lists the upstream's tools and reconciles: new tools are pin-gated
and registered, removed tools unregistered, drifted tools unregistered
and blocked.
""".
-spec refresh(binary()) -> ok | {error, any()}.

refresh(Upstream) ->
    call(Upstream, refresh).

-doc "The upstream's projection status.".
-spec info(binary()) -> {ok, map()} | {error, any()}.

info(Upstream) ->
    call(Upstream, info).

-doc """
The pin hash of an upstream tool definition: `<<"sha256:...">>`
(lowercase hex) over the canonical JSON encoding — recursively sorted
object keys — of the definition's normative fields. Canonical JSON keeps
a durable pin's hash stable across OTP releases, which the external term
format does not guarantee.
""".
-spec pin_hash(map()) -> binary().

pin_hash(Def) when is_map(Def) ->
    Normative = maps:with(?NORMATIVE_KEYS, Def),
    Digest = crypto:hash(
        sha256, iolist_to_binary(canonical_json(Normative))
    ),
    <<"sha256:", (binary:encode_hex(Digest, lowercase))/binary>>.

%% =============================================================================
%% WAMP callback
%% =============================================================================

-doc "Kwargs-less form of `handle_wamp_call/3`.".
-spec handle_wamp_call(map(), map()) ->
    {ok, map(), list(), map()} | {error, binary(), map(), list(), map()}.

handle_wamp_call(CBConf, Options) ->
    handle_wamp_call(CBConf, #{}, Options).

-doc """
The projected procedure body, applied by the dealer (arguments per its
internal-callback contract: the registration's `callback_args` map, the
caller's kwargs, the call options).
""".
-spec handle_wamp_call(map(), map(), map()) ->
    {ok, map(), list(), map()} | {error, binary(), map(), list(), map()}.

handle_wamp_call(#{upstream := Upstream} = CBConf, KWArgs, Options) when
    is_map(KWArgs)
->
    T0 = erlang:monotonic_time(microsecond),
    %% The CALL's trace context (§15.4) continues into the upstream
    %% request as `params._meta`, and rides the completion event so an
    %% attached handler can span this leg.
    Trace = bondy_mcp_wamp:trace_meta(Options),
    Result = do_call(CBConf, KWArgs, Trace),
    ok = bondy_mcp_metrics:upstream_call(
        Upstream,
        result_status(Result),
        erlang:monotonic_time(microsecond) - T0,
        Trace
    ),
    ok = audit(CBConf, KWArgs, Result),
    Result.

%% @private
%% The ONE status classification of a projected call's WAMP shape, shared
%% by the audit record and the §15 metric: the fixed tool-error URI is
%% the upstream saying "the tool ran and failed"; every other error URI
%% is a gateway/transport failure.
result_status({ok, _, _, _}) ->
    success;
result_status({error, <<"bondy.error.mcp.upstream_tool_error">>, _, _, _}) ->
    tool_error;
result_status({error, _, _, _, _}) ->
    internal_error.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

-doc false.
init([Conf]) ->
    process_flag(trap_exit, true),

    #{name := Name, realm := RealmUri, identity := Identity} = Conf,

    %% The sup validated the declaration set; this is the per-instance
    %% assertion of the §13.1 contract, for direct (test/console) starts.
    Identity == service orelse error({invalid_identity, Identity}),

    %% Registered up front so `approve/2`, `refresh/1` and the call
    %% handler can address this upstream by name; the value — the current
    %% client connection — stays `undefined` until the session is up, and
    %% the handler answers `bad_gateway` meanwhile.
    true = gproc:reg(gproc_key(Name), undefined),

    Retry = bondy_retry:init({?MODULE, Name}, #{
        deadline => 0,
        max_retries => 1000000,
        backoff_enabled => true,
        backoff_min => 1000,
        backoff_max => 30000,
        backoff_type => jitter
    }),
    State = #state{
        conf = Conf,
        realm_uri = RealmUri,
        retry = Retry
    },
    {ok, State, {continue, setup}}.

-doc false.
handle_continue(setup, State) ->
    {noreply, attempt(State)}.

-doc false.
handle_call({reinitialize, Stale}, _From, State) ->
    reinitialize(Stale, State);
handle_call({approve, Tool}, _From, State) ->
    do_approve(Tool, State);
handle_call(refresh, _From, State0) ->
    case do_refresh(State0) of
        {ok, State} ->
            {reply, ok, State};
        {error, Reason, State} ->
            {reply, {error, Reason}, schedule_retry(State)}
    end;
handle_call(info, _From, State) ->
    #state{
        conn = Conn,
        registrations = Regs,
        blocked = Blocked
    } = State,
    Info = #{
        connected => Conn =/= undefined,
        registered => maps:fold(
            fun(Tool, {_, Uri}, Acc) -> Acc#{Tool => Uri} end, #{}, Regs
        ),
        blocked => maps:keys(Blocked)
    },
    {reply, {ok, Info}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-doc false.
handle_cast(refresh, State0) ->
    case do_refresh(State0) of
        {ok, State} ->
            {noreply, State};
        {error, Reason, State} ->
            ?LOG_WARNING(#{
                description => "Upstream MCP refresh failed, will retry",
                upstream => upstream_name(State),
                reason => Reason
            }),
            {noreply, schedule_retry(State)}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info({timeout, Ref, _}, #state{retry_ref = Ref} = State) ->
    {noreply, attempt(State#state{retry_ref = undefined})};
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, #state{conn = Conn}) ->
    Conn =/= undefined andalso bondy_mcp_client:close(Conn),
    ok.

%% =============================================================================
%% PRIVATE — setup and projection
%% =============================================================================

%% @private
%% One full setup pass: WAMP session, MCP session, projection. Any
%% failure logs and schedules a backoff retry — an upstream or a realm
%% that is not up yet is a condition to outlast, not a crash.
attempt(State0) ->
    case do_refresh(State0) of
        {ok, State} ->
            {_, Retry} = bondy_retry:succeed(State#state.retry),
            State#state{retry = Retry};
        {error, Reason, State} ->
            ?LOG_WARNING(#{
                description =>
                    "Upstream MCP projection attempt failed, will retry",
                upstream => upstream_name(State),
                reason => Reason
            }),
            schedule_retry(State)
    end.

%% @private
%% A refresh is the full setup pass, not just a re-list: it recovers a
%% dropped or stale connection too, with one immediate retry when the
%% listing discovers the session expired mid-pass (the retry pass
%% reconnects; a second expiry is a genuinely unstable upstream and goes
%% to backoff).
do_refresh(State0) ->
    Steps = [
        fun ensure_service/1,
        fun ensure_wamp_session/1,
        fun ensure_conn/1,
        fun do_project/1
    ],
    case run(Steps, State0) of
        {error, session_expired, State} ->
            run(Steps, State);
        Other ->
            Other
    end.

%% @private
run([], State) ->
    {ok, State};
run([Step | Rest], State0) ->
    case Step(State0) of
        {ok, State} ->
            run(Rest, State);
        {error, _, _} = Error ->
            Error
    end.

%% @private
%% Resolved inside the retry loop rather than in `init/1` on purpose:
%% `bondy_app` starts this application BEFORE `bondy_http_connector`, and
%% resolving lazily removes that ordering (and any other: a service
%% configured later is found later) instead of depending on it. The cost
%% is that a misspelled service name retries forever — each attempt
%% logging the name it cannot find — rather than failing the boot.
ensure_service(#state{service = Service} = State) when
    Service =/= undefined
->
    {ok, State};
ensure_service(#state{conf = Conf} = State) ->
    try find_service(Conf) of
        {ok, Service} ->
            Pool = bondy_http_connector_manager:pool_name(
                maps:get(name, Service)
            ),
            {ok, State#state{service = Service, pool = Pool}};
        {error, Reason} ->
            {error, Reason, State}
    catch
        _:_ ->
            {error, connector_not_started, State}
    end.

%% @private
ensure_wamp_session(#state{wamp_session_id = Id} = State) when
    Id =/= undefined
->
    {ok, State};
ensure_wamp_session(#state{realm_uri = RealmUri} = State) ->
    SessionId = bondy_session_id:new(),
    Opts = #{
        type => internal,
        roles => #{callee => #{}},
        agent => <<"bondy_mcp_upstream">>,
        is_anonymous => true
    },
    try bondy_session_manager:open(SessionId, RealmUri, Opts) of
        {ok, _Session} ->
            {ok, State#state{wamp_session_id = SessionId}};
        {error, Reason} ->
            {error, {session_open_failed, Reason}, State}
    catch
        _:Reason ->
            {error, {session_open_failed, Reason}, State}
    end.

%% @private
ensure_conn(#state{conn = Conn} = State) when Conn =/= undefined ->
    {ok, State};
ensure_conn(State) ->
    case bondy_mcp_client:connect(new_conn(State)) of
        {ok, Conn} ->
            true = gproc:set_value(
                gproc_key(upstream_name(State)), Conn
            ),
            {ok, State#state{conn = Conn}};
        {error, Reason} ->
            {error, {connect_failed, Reason}, State}
    end.

%% @private
new_conn(#state{conf = Conf, service = Service, pool = Pool}) ->
    #{name := ServiceName, base_url := BaseUrl} = Service,
    Timeout =
        case maps:get(timeout, Conf, undefined) of
            undefined -> maps:get(timeout, Service, 30000);
            T -> T
        end,
    bondy_mcp_client:new(#{
        url => url(BaseUrl, maps:get(path, Conf, <<>>)),
        pool => Pool,
        service => ServiceName,
        auth => auth(Service, Pool),
        timeout => Timeout
    }).

%% @private
url(BaseUrl, <<>>) ->
    BaseUrl;
url(BaseUrl, Path) ->
    <<BaseUrl/binary, Path/binary>>.

%% @private
%% The service's own auth, exactly as its callees apply it: the pool
%% threaded into the conf so token fetches share the service's TLS and
%% pool config, resolved secret vars merged when the resolver has them
%% (before that, token acquisition fails per call and the projected call
%% answers `bad_gateway` — the connector's own degradation posture).
auth(Service, Pool) ->
    case maps:get(auth_mod, Service, undefined) of
        undefined ->
            none;
        AuthMod ->
            AuthConf0 = maps:get(auth_conf, Service, #{}),
            AuthConf1 = AuthConf0#{pool => Pool},
            ServiceName = maps:get(name, Service),
            AuthConf =
                case
                    bondy_http_connector_manager:service_readiness(
                        ServiceName
                    )
                of
                    {ok, Vars} ->
                        Existing = maps:get(vars, AuthConf1, #{}),
                        AuthConf1#{vars => maps:merge(Existing, Vars)};
                    {error, not_ready} ->
                        AuthConf1
                end,
            {AuthMod, AuthConf}
    end.

%% @private
do_project(State) ->
    case project(State) of
        {ok, State1} ->
            {ok, State1};
        {error, Reason, State1} ->
            {error, Reason, State1}
    end.

%% @private
%% List, pin-gate, reconcile. Registration failures are logged and
%% skipped (the connector callee's posture: the failure modes are
%% permanent and a crash would only cascade); a listing failure aborts
%% the pass so the retry rebuilds the connection state.
project(#state{conn = Conn} = State) ->
    case bondy_mcp_client:list_tools(Conn) of
        {ok, Tools} ->
            {ok, reconcile(Tools, State)};
        {error, session_expired} ->
            %% The next attempt reconnects from scratch.
            {error, session_expired, drop_conn(State)};
        {error, Reason} ->
            {error, Reason, State}
    end.

%% @private
reconcile(Tools, State0) ->
    #state{
        conf = #{name := Upstream, prefix := Prefix},
        realm_uri = RealmUri
    } = State0,

    %% Deterministic order; a mangling collision resolves to the first
    %% original name and the loser is skipped loudly.
    Sorted = lists:usort(
        fun(A, B) -> maps:get(<<"name">>, A) =< maps:get(<<"name">>, B) end,
        [T || T <- Tools, is_map_key(<<"name">>, T)]
    ),

    {Desired, Blocked} = lists:foldl(
        fun(Def, {DAcc, BAcc}) ->
            Name = maps:get(<<"name">>, Def),
            Uri = <<Prefix/binary, ".", (mangle(Name))/binary>>,
            case lists:keymember(Uri, 1, maps:values(DAcc)) of
                true ->
                    ?LOG_ERROR(#{
                        description =>
                            "Upstream MCP tool skipped: its projected "
                            "URI collides with another tool's after "
                            "name mangling",
                        upstream => Upstream,
                        tool => Name,
                        uri => Uri
                    }),
                    {DAcc, BAcc};
                false ->
                    case pin_gate(RealmUri, Upstream, Name, Def) of
                        ok ->
                            {DAcc#{Name => {Uri, Def}}, BAcc};
                        {blocked, Pinned} ->
                            ?LOG_ERROR(#{
                                description =>
                                    "Upstream MCP tool BLOCKED: its "
                                    "definition drifted from the pinned "
                                    "one. Re-approve explicitly with "
                                    "bondy_mcp_upstream:approve/2.",
                                upstream => Upstream,
                                tool => Name,
                                pinned_hash => maps:get(hash, Pinned),
                                current_hash => pin_hash(Def)
                            }),
                            ok = bondy_mcp_metrics:upstream_drift_blocked(
                                Upstream, 1
                            ),
                            {DAcc, BAcc#{Name => Def}}
                    end
            end
        end,
        {#{}, #{}},
        Sorted
    ),

    State1 = unregister_gone(Desired, State0),
    State2 = register_new(Desired, State1),
    State2#state{blocked = Blocked}.

%% @private
unregister_gone(Desired, #state{registrations = Regs0} = State) ->
    Regs = maps:filter(
        fun(Tool, {RegId, Uri}) ->
            case is_map_key(Tool, Desired) of
                true ->
                    true;
                false ->
                    ?LOG_INFO(#{
                        description => "Upstream MCP tool unregistered",
                        upstream => upstream_name(State),
                        tool => Tool,
                        uri => Uri
                    }),
                    _ = bondy_dealer:unregister(
                        RegId, State#state.realm_uri
                    ),
                    false
            end
        end,
        Regs0
    ),
    State#state{registrations = Regs}.

%% @private
register_new(Desired, State) ->
    maps:fold(
        fun
            (Tool, _, #state{registrations = Regs} = Acc) when
                is_map_key(Tool, Regs)
            ->
                Acc;
            (Tool, {Uri, _Def}, Acc) ->
                register_one(Tool, Uri, Acc)
        end,
        State,
        Desired
    ).

%% @private
register_one(Tool, Uri, State) ->
    #state{
        conf = #{name := Upstream} = Conf,
        realm_uri = RealmUri,
        wamp_session_id = SessionId,
        registrations = Regs
    } = State,
    CBConf = #{
        upstream => Upstream,
        tool => Tool,
        procedure => Uri,
        realm => RealmUri,
        service => maps:get(name, State#state.service),
        timeout => maps:get(timeout, Conf, undefined)
    },
    Ref = bondy_ref:new(internal, {?MODULE, handle_wamp_call}, SessionId),
    Opts = #{
        match => <<"exact">>,
        invoke => <<"roundrobin">>,
        callback_args => [CBConf]
    },
    case bondy_dealer:register(Uri, Opts, RealmUri, Ref) of
        {ok, RegId} ->
            ?LOG_INFO(#{
                description => "Upstream MCP tool registered",
                upstream => Upstream,
                tool => Tool,
                uri => Uri
            }),
            State#state{registrations = Regs#{Tool => {RegId, Uri}}};
        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Failed to register upstream MCP tool, skipping",
                upstream => Upstream,
                tool => Tool,
                uri => Uri,
                reason => Reason
            }),
            State
    end.

%% =============================================================================
%% PRIVATE — pins
%% =============================================================================

%% @private
pin_gate(RealmUri, Upstream, Tool, Def) ->
    Hash = pin_hash(Def),
    case pin_read(RealmUri, Upstream, Tool) of
        {ok, #{hash := Hash}} ->
            ok;
        {ok, Pinned} ->
            {blocked, Pinned};
        {error, not_found} ->
            %% Trust on first use.
            ok = pin_write(RealmUri, Upstream, Tool, Def, Hash),
            ok
    end.

%% @private
pin_read(RealmUri, Upstream, Tool) ->
    case bondy_db:read(table(), RealmUri, pin_key(Upstream, Tool)) of
        {ok, {Pin, _}} when is_map(Pin) ->
            {ok, Pin};
        _ ->
            {error, not_found}
    end.

%% @private
pin_write(RealmUri, Upstream, Tool, Def, Hash) ->
    Pin = #{
        hash => Hash,
        definition => maps:with(?NORMATIVE_KEYS, Def),
        pinned_at => erlang:system_time(millisecond)
    },
    bondy_db:apply(
        table(), RealmUri, pin_key(Upstream, Tool), {set, Pin}
    ).

%% @private
%% A deterministic composite key: length-prefixed, so no separator can be
%% forged by a tool name, and byte-stable across OTP releases (which
%% `term_to_binary` is not — these keys are durable).
pin_key(Upstream, Tool) ->
    <<(byte_size(Upstream)):16, Upstream/binary, Tool/binary>>.

%% @private
table() ->
    case bondy_namespace_catalog:table(?BONDY_DB_MCP_UPSTREAM_TAB) of
        undefined -> error(mcp_upstream_table_unavailable);
        Table -> Table
    end.

%% @private
do_approve(Tool, #state{blocked = Blocked} = State) ->
    case maps:take(Tool, Blocked) of
        {Def, Blocked1} ->
            #state{
                conf = #{name := Upstream, prefix := Prefix},
                realm_uri = RealmUri
            } = State,
            ok = pin_write(RealmUri, Upstream, Tool, Def, pin_hash(Def)),
            Uri = <<Prefix/binary, ".", (mangle(Tool))/binary>>,
            State1 = register_one(Tool, Uri, State),
            {reply, ok, State1#state{blocked = Blocked1}};
        error ->
            {reply, {error, not_blocked}, State}
    end.

%% =============================================================================
%% PRIVATE — re-initialization
%% =============================================================================

%% @private
%% Single-flight: a caller re-initializes against the connection it saw
%% fail. If the owner already reconnected past it, the current connection
%% is the answer; otherwise reconnect once and let every queued caller
%% observe the same result. A successful reconnect refreshes the
%% projection (self-cast), because a restarted upstream may have changed
%% definitions and the pin gate must see them now, not at the next boot.
reinitialize(Stale, #state{conn = Conn} = State) when
    Conn =/= undefined,
    map_get(session_id, Conn) =/= map_get(session_id, Stale)
->
    {reply, {ok, Conn}, State};
reinitialize(_Stale, State0) ->
    State = drop_conn(State0),
    case ensure_conn(State) of
        {ok, State1} ->
            gen_server:cast(self(), refresh),
            {reply, {ok, State1#state.conn}, State1};
        {error, Reason, State1} ->
            {reply, {error, Reason}, schedule_retry(State1)}
    end.

%% @private
drop_conn(#state{conn = undefined} = State) ->
    State;
drop_conn(State) ->
    true = gproc:set_value(gproc_key(upstream_name(State)), undefined),
    State#state{conn = undefined}.

%% @private
schedule_retry(#state{retry_ref = Ref} = State) when Ref =/= undefined ->
    %% A retry is already scheduled.
    State;
schedule_retry(#state{retry = Retry0} = State) ->
    case bondy_retry:fail(Retry0) of
        {max_retries, Retry} ->
            {_, FreshRetry} = bondy_retry:succeed(Retry),
            schedule_retry(State#state{retry = FreshRetry});
        {_Delay, Retry} ->
            Ref = bondy_retry:fire(Retry),
            State#state{retry = Retry, retry_ref = Ref}
    end.

%% =============================================================================
%% PRIVATE — the call path (dealer process)
%% =============================================================================

%% @private
do_call(#{upstream := Upstream, tool := Tool} = CBConf, KWArgs, Meta) ->
    Arguments = bondy_mcp_wamp:flatten_payload([], KWArgs),
    case current_conn(Upstream) of
        {ok, Conn} ->
            case bondy_mcp_client:call_tool(Conn, Tool, Arguments, Meta) of
                {error, session_expired} ->
                    retry_call(CBConf, Arguments, Meta, Conn);
                Other ->
                    to_wamp(Other)
            end;
        {error, unavailable} ->
            bad_gateway(<<"Upstream MCP session unavailable">>)
    end.

%% @private
retry_call(#{upstream := Upstream, tool := Tool}, Arguments, Meta, Stale) ->
    case call(Upstream, {reinitialize, Stale}) of
        {ok, Conn} ->
            to_wamp(bondy_mcp_client:call_tool(Conn, Tool, Arguments, Meta));
        {error, _} ->
            bad_gateway(<<"Upstream MCP session unavailable">>)
    end.

%% @private
to_wamp({ok, Result}) ->
    case bondy_mcp_wamp:tool_result(Result) of
        {ok, Args, KWArgs} ->
            {ok, #{}, Args, KWArgs};
        {error, Uri, Args, KWArgs} ->
            {error, Uri, #{}, Args, KWArgs}
    end;
to_wamp({error, {upstream_error, ErrorObj}}) ->
    %% A JSON-RPC-level refusal (e.g. the upstream no longer knows the
    %% tool). The upstream's error object is data for the caller, not a
    %% URI.
    {error, <<"bondy.error.mcp.upstream_error">>, #{}, [], #{
        <<"error">> => ErrorObj
    }};
to_wamp({error, session_expired}) ->
    bad_gateway(<<"Upstream MCP session unavailable">>);
to_wamp({error, Reason}) ->
    ?LOG_ERROR(#{
        description => "Upstream MCP call failed",
        reason => Reason
    }),
    bad_gateway(<<"Upstream MCP server unreachable">>).

%% @private
bad_gateway(Message) ->
    {error, <<"bondy.error.bad_gateway">>, #{}, [], #{
        <<"message">> => Message
    }}.

%% @private
current_conn(Upstream) ->
    try gproc:lookup_value(gproc_key(Upstream)) of
        undefined -> {error, unavailable};
        Conn -> {ok, Conn}
    catch
        error:badarg -> {error, unavailable}
    end.

%% @private
audit(CBConf, KWArgs, Result) ->
    #{
        upstream := Upstream,
        tool := Tool,
        procedure := Procedure,
        realm := RealmUri,
        service := Service
    } = CBConf,
    Status = result_status(Result),
    {ErrorUri, ResultPayload} =
        case Result of
            {ok, _, _, ResKWArgs} -> {undefined, ResKWArgs};
            {error, Uri, _, _, ErrKWArgs} -> {Uri, ErrKWArgs}
        end,
    _ = bondy_mcp_audit:record(upstream_call, #{
        realm => RealmUri,
        listener => undefined,
        transport => http,
        principal => <<"service:", Service/binary>>,
        is_anonymous => false,
        name => Tool,
        procedure => Procedure,
        args_payload => KWArgs,
        result_payload => ResultPayload,
        derivation => #{
            type => service_account,
            service => Service,
            upstream => Upstream
        },
        status => Status,
        error_uri => ErrorUri
    }),
    ok.

%% =============================================================================
%% PRIVATE — misc
%% =============================================================================

%% @private
call(Upstream, Msg) ->
    case gproc:where(gproc_key(Upstream)) of
        undefined ->
            {error, {unknown_upstream, Upstream}};
        Pid ->
            try
                gen_server:call(Pid, Msg, 30000)
            catch
                exit:{Reason, _} ->
                    {error, Reason}
            end
    end.

%% @private
gproc_key(Upstream) ->
    {n, l, {?MODULE, Upstream}}.

%% @private
upstream_name(#state{conf = #{name := Name}}) ->
    Name.

%% @private
find_service(#{service := ServiceName}) ->
    Services = bondy_http_connector_config:get(services, []),
    case
        lists:search(
            fun(#{name := N}) -> N == ServiceName end, Services
        )
    of
        {value, Service} ->
            {ok, Service};
        false ->
            {error, {unknown_service, ServiceName}}
    end.

%% @private
%% A tool name as a WAMP URI component: lowercased, [a-z0-9_] kept,
%% anything else `_`.
mangle(Name) ->
    <<
        <<
            (case C of
                _ when C >= $a, C =< $z -> C;
                _ when C >= $0, C =< $9 -> C;
                $_ -> $_;
                _ -> $_
            end)
        >>
     || <<C>> <= string:lowercase(Name)
    >>.

%% @private
%% Canonical JSON: objects with recursively sorted keys, arrays in
%% order, scalars per OTP `json` (whose shortest-representation number
%% printing is stable). The pin hash's stability rests on this.
canonical_json(Map) when is_map(Map) ->
    Pairs = lists:keysort(1, maps:to_list(Map)),
    [
        $\{,
        lists:join($,, [
            [json:encode(K), $:, canonical_json(V)]
         || {K, V} <- Pairs
        ]),
        $\}
    ];
canonical_json(List) when is_list(List) ->
    [$[, lists:join($,, [canonical_json(V) || V <- List]), $]];
canonical_json(V) ->
    json:encode(V).
