%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_listener_manager).

-moduledoc """
Starts, stops, suspends and resumes every configured listener.

Not a process, just a bare module. `init/0` resolves the
`bondy_router.listeners` inventory once and stores the result in
`persistent_term`; every other function reads it. The one event-driven duty
around listeners — rebuilding dispatch tables when an API Gateway specification
changes — belongs to the `bondy_http_gateway` gen_server, which already owns
specification storage and its own debounce.

Startup is two-phase. Listeners marked `start_phase => early` come up before any
other, so the liveness (`/ping`), readiness (`/ready`) and metrics paths answer
while `bondy_config:get(status)` still reports `initialising`:
`bondy_app` sets the status to `ready` only after starting the normal phase.
Everything else comes up in that later phase.

`ready` therefore means boot finished, not that no client has connected yet:
`start(normal)` binds its listeners synchronously and the status flips after it
returns, and nothing gates connection acceptance on `bondy_config:get(status)`.
The phases order the listeners against each other; they do not fence clients
out.

A configuration error raises. Boot must fail rather than continue with a node
that serves nothing the operator asked for.

One listener is not operator-defined. `admin_local` — a Unix domain socket
carrying the Admin API — is appended to every inventory by `init/0` through
`bondy_listener_config:resolve_internal/4`, and `resolve/2` rejects the name in
a configured inventory, so it cannot be redefined, disabled or removed.
""".

-include_lib("kernel/include/logger.hrl").

-define(KEY, {?MODULE, listeners}).

-type phase() :: early | normal | all.

-export_type([phase/0]).

-export([connections/0]).
-export([connections/1]).
-export([http_listeners/0]).
-export([init/0]).
-export([listener/1]).
-export([listeners/0]).
-export([resume/1]).
-export([start/1]).
-export([stop/1]).
-export([suspend/1]).
-export([tls_listeners/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Resolves and caches the listener inventory, and publishes each listener's option
blocks where their consumers read them. Raises on any configuration error.
""".
-spec init() -> ok | no_return().

init() ->
    %% Read through `bondy_config` rather than `application:get_env/3`: the
    %% per-listener option blocks are only reachable that way (app_config caches
    %% application env into persistent_term and `bondy_config:get/2` reads the
    %% cache), so taking the inventory from the same accessor keeps one source
    %% of truth. `bondy_config:init/1` populates the cache before calling this.
    %%
    %% One path. An absent key means the operator declared no listeners at all --
    %% cuttlefish drops the inventory translation unless some
    %% `listeners.$name.*' mapping is set, and they are all default-free -- so the
    %% built-in defaults apply. There is no second spelling to fall back to:
    %% `listeners.$name.*' is the only listener surface the schemas define.
    {Inventory0, Provenance} =
        case bondy_config:get(listeners, undefined) of
            undefined -> {bondy_listener_config:default_inventory(), default};
            Configured -> {Configured, configured}
        end,
    %% The effective inventory: what the operator declared, plus the reserved
    %% listeners every node gets, with each spec's transport- and
    %% protocol-implied defaults filled in. Everything downstream reads this
    %% rather than `bondy_config:get(listeners, _)`, which holds only the
    %% operator's half — the `default`, `admin` and `admin_local` listeners have
    %% consumers reading `[Name, Key]` exactly as a declared one does, and until
    %% this was the inventory that got splatted they were reading nothing.
    Inventory = [
        {Name, bondy_listener_config:with_option_defaults(Spec)}
     || {Name, Spec} <- with_reserved(Inventory0)
    ],
    InternalSpec = bondy_listener_config:with_option_defaults(
        admin_local_spec()
    ),

    %% Publishes every listener's option blocks at `bondy_router.<name>.<key>'.
    %% Must precede the resolution below — `resolve/2''s `GetFun' reads
    %% `[Name, tls, ...]' for the TLS-material check, and a certificate nested
    %% inside an inventory entry is invisible until it has been copied out.
    ok = bondy_config:splat_listener_blocks([
        {admin_local, InternalSpec} | Inventory
    ]),

    ok = log_provenance(Provenance, Inventory),
    Get = fun bondy_config:get/2,
    Result =
        maybe
            {ok, Configured1} ?=
                bondy_listener_config:resolve(Inventory, Get),
            {ok, Internal} ?=
                bondy_listener_config:resolve_internal(
                    admin_local, InternalSpec, Configured1, Get
                ),
            {ok, Configured1 ++ [Internal]}
        end,
    case Result of
        {ok, Listeners} ->
            _ = persistent_term:put(?KEY, Listeners),
            ok = log_inventory(Listeners);
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Invalid listener configuration",
                reason => Reason
            }),
            error(Reason)
    end.

-doc "Starts the listeners in `Phase` (`early`, `normal`, or `all`).".
-spec start(phase()) -> ok | {error, term()}.

start(Phase) ->
    fold_until_error(fun start_one/1, in_phase(Phase)).

-doc """
Stops the listeners in `Phase`, terminating their connections.

Takes a phase for the same reason `suspend/1` does: `early` is what carries the
liveness, readiness and metrics paths, and shutting those down is a separate
decision from shutting down the listeners that serve clients.
""".
-spec stop(phase()) -> ok.

stop(Phase) ->
    _ = [bondy_listener:stop(L) || L <- in_phase(Phase)],
    ok.

-doc """
Stops accepting new connections on the listeners in `Phase`. Established
connections are unaffected.

Phase-selective rather than global because suspending `early` would take the
liveness (`/ping`) and readiness (`/ready`) paths down with it: those answer on
an `early` listener, so an orchestrator draining the node would read
`econnrefused` as a dead node and hard-kill it instead of letting the drain
finish — the opposite of what a grace period is for. `bondy_app:prep_stop/1`
therefore suspends `normal` only.
""".
-spec suspend(phase()) -> ok.

suspend(Phase) ->
    _ = [bondy_listener:suspend(L) || L <- in_phase(Phase)],
    ok.

-doc """
Resumes accepting new connections on the listeners in `Phase`, undoing
`suspend/1`.

Called by `bondy_listener_wamp_api` for the `bondy.listener.resume` procedure,
which is the pairing this exists for: nothing in Bondy suspends a phase it
intends to resume — `bondy_app:prep_stop/1` suspends `normal` on the way to
stopping it — so taking a phase out of rotation and putting it back is an
operator's action. It takes a phase for the same reason `suspend/1` does.

Idempotent: resuming a phase that is already accepting is not an error, because
`ranch:resume_listener/1` answers `ok` for a listener that was never suspended.
`bondy_listener_api_SUITE:resume_is_idempotent` covers that, and
`suspending_normal_refuses_new_connections` covers the round trip against a real
socket.
""".
-spec resume(phase()) -> ok.

resume(Phase) ->
    _ = [bondy_listener:resume(L) || L <- in_phase(Phase)],
    ok.

-spec listeners() -> [bondy_listener_config:t()].

listeners() ->
    persistent_term:get(?KEY, []).

-spec listener(atom()) -> {ok, bondy_listener_config:t()} | {error, not_found}.

listener(Name) ->
    %% A single match, not the first of several: every entry passes
    %% `bondy_listener_config:assert_unique_name/2`, the injected one included
    %% (`resolve_internal/4` checks it against the resolved inventory), so a
    %% second entry here means that check was bypassed — fail rather than pick
    %% one.
    case [L || #{name := N} = L <- listeners(), N =:= Name] of
        [L] -> {ok, L};
        [] -> {error, not_found}
    end.

-spec connections() -> [pid()].

connections() ->
    lists:append([bondy_listener:connections(L) || L <- listeners()]).

-doc """
Connections of one listener. Distinct from `connections/0` because a caller
that wants the connections of a *named* listener cannot filter the aggregate:
the pids carry no listener identity. Returns `[]` for an unknown name, matching
`bondy_listener:connections/1` on a listener that is not running.
""".
-spec connections(atom()) -> [pid()].

connections(Name) ->
    case listener(Name) of
        {ok, L} -> bondy_listener:connections(L);
        {error, not_found} -> []
    end.

-doc """
Names of the listeners that terminate TLS. Replaces the hardcoded list
`bondy_cert_manager` carried, so a new TLS listener needs no code change.
""".
-spec tls_listeners() -> [atom()].

tls_listeners() ->
    [Name || #{name := Name, transport := tls} <- listeners()].

-doc "Names of the listeners serving HTTP.".
-spec http_listeners() -> [atom()].

http_listeners() ->
    [Name || #{name := Name, protocol := http} <- listeners()].

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The internal listener appended to every inventory.
%%
%% An inventory an operator writes can omit every administrable endpoint, and
%% one that names an endpoint can still fail to bind it: `transport = tls` with
%% an unresolvable `certfile` is accepted by the resolver and then locks the
%% operator out at bind time. A Unix domain socket involves no certificate, no
%% DNS name and no port, so none of the TLS, name-resolution or port-conflict
%% failures that motivate this listener can affect it, and
%% `bondy_listener_config` rejects the name in a configured inventory, so there
%% is no operator block to merge and nothing to override.
%%
%% It is NOT true that no configuration can stop it binding. Its path derives
%% from `platform_tmp_dir`, an ordinary cuttlefish mapping, and two values of
%% that key make the bind fail — both measured on Darwin with a listen on
%% `{ip, {local, Path}}`:
%%
%%   * a directory long enough to push the path past `sun_path` (104 bytes,
%%     measured here; 108 per the Linux headers, not measured) yields
%%     `{error, einval}`
%%   * a directory this process cannot write yields `{error, eacces}`
%%
%% Either aborts boot, because `admin_local` is `early` and `bondy_app`'s
%% `ok ?= start_early_listeners()` propagates the error. That is deliberate: a
%% node that refuses to boot is loud and fixable, whereas one that boots without
%% its administrable endpoint is discovered when someone is already locked out.
%% `start_one/1` reports the diagnosis those two errors need.
%%
%% Built here rather than in the resolver because the socket path comes from
%% configuration and the resolver is pure.
admin_local_spec() ->
    %% `platform_tmp_dir` (`schema/bondy.schema:6160`), not `platform_data_dir`:
    %% a socket file is ephemeral, is recreated on every boot, and must not sit
    %% among the durable stores. It is also where the listener this replaces put
    %% its socket — `bondy_wamp_uds`'s default path was `/tmp/bondy_wamp.sock`.
    %%
    %% Read without a default on purpose: the key carries a `{default, ...}` in
    %% the schema, so an absent value means the release was rendered wrong, and
    %% inventing a directory here would put the node's control socket somewhere
    %% the operator is not looking.
    Dir = bondy_config:get(platform_tmp_dir),
    #{
        transport => uds,
        protocol => http,
        path => filename:join(Dir, "bondy_admin.sock"),
        start_phase => early,
        services => [admin_api, admin, wamp_ws, metrics]
    }.

%% @private
%% `admin_local`'s bind failures are the only ones an operator cannot diagnose
%% from the error alone. `einval` from a listen on `{ip, {local, Path}}` means
%% the path exceeded `sun_path`, and neither the length nor the setting it came
%% from appears anywhere in that atom, so both are reported here. Every other
%% listener names its own bind target in `bondy.conf`; this one does not exist
%% there at all.
%%
%% The error is returned unchanged, so the node still fails to boot.
start_one(#{name := admin_local, bind := {path, Path}} = Listener) ->
    case bondy_listener:start(Listener) of
        ok ->
            ok;
        {error, Reason} = Error ->
            ?LOG_ERROR(#{
                description =>
                    "The internal admin listener could not bind its socket, "
                    "so the node will not start. This socket is the endpoint "
                    "that stays reachable when no other listener binds; its "
                    "path is derived from the platform_tmp_dir setting.",
                listener => admin_local,
                reason => Reason,
                path => Path,
                path_byte_size => path_byte_size(Path),
                sun_path_limit =>
                    "104 bytes on Darwin, 108 on Linux "
                    "(sockaddr_un.sun_path)",
                setting => platform_tmp_dir,
                platform_tmp_dir => bondy_config:get(platform_tmp_dir)
            }),
            Error
    end;
start_one(Listener) ->
    bondy_listener:start(Listener).

%% @private
%% The `sun_path` limit is on BYTES, so a multibyte directory name costs more
%% than its character count suggests.
path_byte_size(Path) ->
    byte_size(unicode:characters_to_binary(Path)).

%% @private
%% Reserved names an operator did not write are added, so declaring an inventory
%% cannot silently remove the administrable endpoint. An operator who DID write
%% one keeps it: reserved means it cannot be removed or disabled, not that it
%% cannot be configured — `bondy_listener_config:assert_reserved/2` enforces that
%% half.
%%
%% Applied to the default inventory as well as a configured one, and that is
%% safe rather than merely harmless: the default inventory names the admin
%% listener `admin` too, so this is a no-op there. It would NOT be if that
%% inventory named it anything else — injecting `admin` beside it would put two
%% listeners on 18081 and `bondy_listener_config:assert_bind_free/2` would refuse
%% the boot. `reserved_spec/1` reads the name out of `default_inventory/0` for
%% exactly that reason.
with_reserved(Inventory) ->
    lists:foldl(
        fun(Name, Acc) ->
            case lists:keymember(Name, 1, Acc) of
                true -> Acc;
                false -> Acc ++ [{Name, reserved_spec(Name)}]
            end
        end,
        Inventory,
        [admin]
    ).

%% @private
%% Read from `default_inventory/0` rather than restated here. The two were
%% identical field for field and a comment said so, which is a duplication
%% waiting to drift; there is now one definition of what the admin listener is.
%%
%% The absent `ip` is deliberate and part of that definition:
%% `bondy_listener_config:resolve_ip/3` defaults a listener carrying `admin` or
%% `metrics` to loopback, which is where the admin API binds.
%%
%% A hard match, so removing `admin` from the default inventory fails loudly here
%% instead of silently skipping the reserved injection.
reserved_spec(Name) ->
    {Name, Spec} = lists:keyfind(
        Name, 1, bondy_listener_config:default_inventory()
    ),
    Spec.

%% @private
in_phase(all) ->
    listeners();
in_phase(Phase) ->
    [L || #{start_phase := P} = L <- listeners(), P =:= Phase].

%% @private
fold_until_error(_Fun, []) ->
    ok;
fold_until_error(Fun, [H | T]) ->
    case Fun(H) of
        ok -> fold_until_error(Fun, T);
        {error, _} = Error -> Error
    end.

%% @private
%% One line per listener at boot. What an operator writes in `bondy.conf` and
%% what this node ends up listening on are separated by cuttlefish rendering,
%% the inventory and this resolution step; printing the resolved set is what
%% makes the outcome of all three visible without attaching to the node.
log_inventory(Listeners) ->
    _ = [
        ?LOG_NOTICE(#{
            description => "Listener configured",
            listener => maps:get(name, L),
            transport => maps:get(transport, L),
            protocol => maps:get(protocol, L),
            bind => maps:get(bind, L),
            services => maps:get(services, L),
            start_phase => maps:get(start_phase, L),
            enabled => maps:get(enabled, L)
        })
     || L <- Listeners
    ],
    ok.

%% @private
%% Which inventory a node booted from. Silence here would make the default case
%% indistinguishable from a declared one, and they behave differently: a declared
%% inventory starts exactly what it names, while the default starts the three
%% built-in listeners. An operator whose `listeners.*' block failed to render sees
%% `default' and knows immediately.
log_provenance(default, Inventory) ->
    ?LOG_NOTICE(#{
        description =>
            "No listeners.* configuration found; using the built-in default "
            "listeners. Declare listeners.<name>.* to define your own.",
        listeners => [N || {N, _} <- Inventory]
    }),
    ok;
log_provenance(configured, Inventory) ->
    ?LOG_INFO(#{
        description => "Listener inventory read from configuration",
        listeners => [N || {N, _} <- Inventory]
    }),
    ok.
