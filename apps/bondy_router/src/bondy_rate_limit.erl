%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rate_limit).
-moduledoc """
Inbound rate-limiting policy: turns per-scope configuration into
token-bucket admission decisions over `bondy_rate_limiter`.

Budgets exist at up to three SCOPES, composed as a chain (design:
`_plans/2026-08-29-rate-limit-scopes-design.md`):

- **node** — `[security, rate_limit]` (`security.rate_limit.*` in
  `bondy.conf`): per-source-IP / per-session buckets shared by every
  listener and realm on the node. OFF by default.
- **listener** — `[ListenerName, rate_limit]`
  (`listeners.$name.rate_limit.*`): the same classes, budgeted per
  listener. A class block's presence enables it (per-listener keys are
  default-free); `enabled = false` inside the block parks it.
- **realm** — the realm's own `rate_limit` property (managed through the
  realm admin APIs / `security_config.json`; not `bondy.conf`).

A request is admitted iff EVERY configured scope in its dimensions
admits it, consumed node → listener → realm; the first refusal answers,
and tokens consumed in outer scopes are NOT refunded on an inner refusal
(hierarchical-limiter norm; the unfairness only appears while already
refusing). Composition is therefore monotone — configuration can only
narrow — which is what preserves the node-wide shared budgets (e.g. the
per-IP `auth` credential-guessing bound) whatever else is configured.
Scopes are INDEPENDENTLY enabled: a listener budget works with the node
scope off (falsifier:
`bondy_rate_limit_test:scopes_are_independently_enabled`).

Each class (`handshake`, `auth`, `connection`, `http`, `message`) has
its own buckets keyed by the caller-supplied dimension (a source IP, or
a session id for `message`). `http` is per-source-IP HTTP request
admission — the API Gateway and admin API resources (via the
`cowboy_rest` `rate_limited` hook) and the MCP endpoints; requests, not
connections, so it is a separate class from `connection`. Config `rate`
is tokens/SECOND (operator-friendly); the bucket wants
tokens/millisecond.

The node scope's reader requires the `[security, rate_limit]` config
value to be a MAP — the shape `schema/bondy.schema`'s
`bondy_router.security.rate_limit` translation builds (verified by
generation probe, 2026-08-26; the earlier per-key schema targets
generated nested proplists, which this reader rejected, so conf-file
enablement was a no-op).

It never raises — the underlying limiter fails open — so a limiter
problem degrades to "no limit", never to a wedged inbound path.
""".

-include_lib("kernel/include/logger.hrl").

-type class() :: handshake | auth | connection | http | message.
%% `realm_total` is the realm scope's `total` budget KIND (the tenant
%% quota — ONE shared bucket per realm+class, per-node in v1) given its
%% own scope value so bucket keys and the denial metric distinguish a
%% hot caller (`realm`) from an exhausted quota (`realm_total`). It is
%% consumed AFTER the realm per-caller budget, so a caller over its own
%% cap does not drain the shared quota.
-type scope() :: node | listener | realm | realm_total.
%% The dimensions a seat knows: the listener the request arrived on and,
%% where the request addresses one, the realm. Absent dimensions simply
%% exclude their scope from the chain.
-type dims() :: #{listener => binary(), realm => binary()}.

-export_type([class/0]).
-export_type([scope/0]).
-export_type([dims/0]).

-export([throttle/2]).
-export([throttle/3]).
-export([enabled/1]).
-export([new_session_limiter/0]).
-export([new_session_limiter/1]).
-export([allow_session/1]).
-export([delete_session_limiter/1]).

-ifdef(TEST).
-export([do_throttle/3]).
-endif.

%% One private message bucket per configured scope, resolved once at
%% session open; `undefined` when no scope configures `message`. The
%% realm `total` budget is the exception: it is the realm's SHARED
%% bucket, so its entry holds the shared bucket key + opts (consulted
%% through `bondy_rate_limiter` per message) instead of a private
%% bucket.
-type session_limiter() ::
    [
        {node | listener | realm, bondy_regulator_rate_limit:t()}
        | {realm_total, Key :: term(), Opts :: map()}
    ]
    | undefined.

-export_type([session_limiter/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Equivalent to `throttle(Class, Key, #{})` — the node scope alone.
""".
-spec throttle(Class :: class(), Key :: term()) -> ok | throttled.

throttle(Class, Key) ->
    throttle(Class, Key, #{}).

-doc """
Consume one token from every scope the dimensions name, node first.
Returns `ok` when every configured scope admits (or none is configured)
and `throttled` on the first refusal. `Key` is a source IP (for
`handshake`/`auth`/`connection`/`http`) or a session identifier.
""".
-spec throttle(Class :: class(), Key :: term(), Dims :: dims()) ->
    ok | throttled.

throttle(Class, Key, Dims) ->
    case do_throttle(Class, Key, Dims) of
        ok -> ok;
        {throttled, _Scope} -> throttled
    end.

-doc "Whether the given class is enabled at the NODE scope.".
-spec enabled(class()) -> boolean().

enabled(Class) ->
    node_opts(Class) =/= disabled.

-doc """
Equivalent to `new_session_limiter(#{})` — the node scope alone.
""".
-spec new_session_limiter() -> session_limiter().

new_session_limiter() ->
    new_session_limiter(#{}).

-doc """
Creates the CURRENT session's `message`-class limiter chain — one
dedicated token bucket per scope that configures `message` — or
`undefined` when none does. Held in the session's own state and deleted
on teardown (like `bondy_connect_load`), so the per-message hot path is
a field check + one atomics consume per configured scope — NO
per-message config read. The config is read once here, at session open.
""".
-spec new_session_limiter(Dims :: dims()) -> session_limiter().

new_session_limiter(Dims) ->
    Chain = [
        {Scope, Opts}
     || {Scope, Opts} <- scope_opts(message, Dims), Opts =/= disabled
    ],
    case Chain of
        [] ->
            undefined;
        _ ->
            case make_session_chain(Chain, Dims, []) of
                [] -> undefined;
                Buckets -> Buckets
            end
    end.

-doc """
Consumes one token from each bucket of a limiter chain created by
`new_session_limiter/1`, node scope first, stopping at the first
refusal. `undefined` (message throttling off everywhere) is always
`ok`. Never raises.
""".
-spec allow_session(session_limiter()) -> ok | throttled.

allow_session(undefined) ->
    ok;
allow_session([]) ->
    ok;
allow_session([{realm_total, Key, Opts} | Rest]) ->
    %% The realm's SHARED total bucket — one ETS consume per message,
    %% no per-message config read (Key and Opts were resolved at
    %% session open).
    case bondy_rate_limiter:allow(Key, Opts) of
        true ->
            allow_session(Rest);
        false ->
            ok = count_denial(message, realm_total),
            throttled
    end;
allow_session([{Scope, T} | Rest]) ->
    case bondy_regulator_rate_limit:allow(T, 1) of
        {true, _} ->
            allow_session(Rest);
        {false, _} ->
            ok = count_denial(message, Scope),
            throttled
    end.

-doc "Deletes a session limiter chain (frees its buckets). No-op for `undefined`.".
-spec delete_session_limiter(session_limiter()) -> ok.

delete_session_limiter(undefined) ->
    ok;
delete_session_limiter(Buckets) when is_list(Buckets) ->
    lists:foreach(
        fun
            ({realm_total, _, _}) ->
                %% the realm's shared bucket outlives the session
                ok;
            ({_, T}) ->
                try
                    bondy_regulator_rate_limit:delete(T)
                catch
                    _:_ -> ok
                end
        end,
        Buckets
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The scope chain, exported under TEST so the falsifiers can pin WHICH
%% scope refused (`{throttled, node | listener}` — the observable that
%% proves consumption order and no-refund).
-spec do_throttle(class(), term(), dims()) -> ok | {throttled, scope()}.

do_throttle(Class, Key, Dims) ->
    consume(
        [
            {Scope, Opts}
         || {Scope, Opts} <- scope_opts(Class, Dims), Opts =/= disabled
        ],
        Class,
        Key,
        Dims
    ).

%% @private
consume([], _, _, _) ->
    ok;
consume([{Scope, Opts} | Rest], Class, Key, Dims) ->
    case bondy_rate_limiter:allow(bucket_key(Scope, Class, Key, Dims), Opts) of
        true ->
            consume(Rest, Class, Key, Dims);
        false ->
            ?LOG_INFO(#{
                description => "Inbound request throttled (rate limit)",
                class => Class,
                scope => Scope,
                key => Key,
                listener => maps:get(listener, Dims, undefined),
                realm => maps:get(realm, Dims, undefined)
            }),
            ok = count_denial(Class, Scope),
            {throttled, Scope}
    end.

%% @private
%% The node bucket key keeps its pre-scopes shape so the change is
%% invisible to a node-only configuration. The realm `total` key drops
%% the caller `Key` — ONE bucket per realm+class, shared by every
%% caller (the tenant quota, per-node in v1).
bucket_key(node, Class, Key, _) ->
    {bondy_rate_limit, Class, Key};
bucket_key(listener, Class, Key, #{listener := Name}) ->
    {bondy_rate_limit, listener, Name, Class, Key};
bucket_key(realm, Class, Key, #{realm := Uri}) ->
    {bondy_rate_limit, realm, Uri, Class, Key};
bucket_key(realm_total, Class, _Key, #{realm := Uri}) ->
    {bondy_rate_limit, realm_total, Uri, Class}.

%% @private
%% The budgets the dimensions name, in consumption order: node, then
%% listener, then realm per-caller, then realm total.
scope_opts(Class, Dims) ->
    Node = [{node, node_opts(Class)}],
    Listener =
        case Dims of
            #{listener := Name} when Name =/= undefined ->
                [{listener, listener_opts(Name, Class)}];
            _ ->
                []
        end,
    Realm =
        case Dims of
            #{realm := Uri} when is_binary(Uri) ->
                realm_scope_opts(Uri, Class);
            _ ->
                []
        end,
    Node ++ Listener ++ Realm.

%% @private
%% The realm's budgets for `Class`, from its `rate_limit` property —
%% up to two entries (`realm` = per_caller, `realm_total` = total), only
%% the configured, un-parked ones. Fails open like every other resolver:
%% an unknown realm, or the realm store not being up yet, is "no realm
%% budgets", never a raise.
realm_scope_opts(Uri, Class) ->
    try bondy_realm:lookup(Uri) of
        {ok, Realm} ->
            case realm_class_cfg(bondy_realm:rate_limit(Realm), Class) of
                disabled ->
                    [];
                ClassCfg ->
                    realm_budget(realm, per_caller, Class, ClassCfg) ++
                        realm_budget(realm_total, total, Class, ClassCfg)
            end;
        {error, not_found} ->
            []
    catch
        _:_ ->
            []
    end.

%% @private
realm_class_cfg(RateLimit, Class) when is_map(RateLimit) ->
    case maps:get(Class, RateLimit, undefined) of
        ClassCfg when is_map(ClassCfg) ->
            case on(maps:get(enabled, ClassCfg, true)) of
                true -> ClassCfg;
                false -> disabled
            end;
        _ ->
            disabled
    end;
realm_class_cfg(_, _) ->
    disabled.

%% @private
realm_budget(Scope, Kind, Class, ClassCfg) ->
    case maps:get(Kind, ClassCfg, undefined) of
        Budget when is_map(Budget) -> [{Scope, bucket_opts(Class, Budget)}];
        _ -> []
    end.

%% @private
make_session_chain([], _Dims, Acc) ->
    lists:reverse(Acc);
make_session_chain([{realm_total, Opts} | Rest], Dims, Acc) ->
    %% Shared, not private: keep the bucket key + opts and consult the
    %% shared limiter per message (`allow_session/1`).
    Key = bucket_key(realm_total, message, undefined, Dims),
    make_session_chain(Rest, Dims, [{realm_total, Key, Opts} | Acc]);
make_session_chain([{Scope, Opts} | Rest], Dims, Acc) ->
    Key = {bondy_msg_limiter, self(), erlang:unique_integer([positive])},
    try bondy_regulator_rate_limit:new(token_bucket, Key, Opts) of
        {ok, T} ->
            make_session_chain(Rest, Dims, [{Scope, T} | Acc]);
        {error, Reason} ->
            log_limiter_unavailable(Reason),
            make_session_chain(Rest, Dims, Acc)
    catch
        %% e.g. the regulator's ETS table is not up yet; degrade to "no
        %% message limit for this scope" rather than failing session
        %% open.
        Class:EReason ->
            log_limiter_unavailable({Class, EReason}),
            make_session_chain(Rest, Dims, Acc)
    end.

%% @private
log_limiter_unavailable(Reason) ->
    ?LOG_WARNING(#{
        description =>
            "Could not create per-session message limiter; "
            "message throttling inert for this session",
        reason => Reason
    }).

%% @private
%% The throttling verdict must never depend on the metrics subsystem
%% being up (e.g. before `bondy_prometheus` setup, or in embedded tests).
count_denial(Class, Scope) ->
    _ =
        try
            prometheus_counter:inc(
                bondy_rate_limited_total, [Class, Scope], 1
            )
        catch
            _:_ -> ok
        end,
    ok.

%% @private
%% Resolve the NODE-scope token-bucket opts for `Class`, or `disabled`.
%% Reads the whole `[security, rate_limit]` map once (a 2-level get,
%% never traversing into a non-container) and extracts in-memory.
node_opts(Class) ->
    case bondy_config:get([security, rate_limit], undefined) of
        Cfg when is_map(Cfg) ->
            case node_enabled(Class, Cfg) of
                true -> bucket_opts(Class, sub(Class, Cfg));
                false -> disabled
            end;
        _ ->
            disabled
    end.

%% @private
%% Resolve the LISTENER-scope opts for `Class`, or `disabled`. The
%% listener block is default-free per the listener configuration rules,
%% so a class block's PRESENCE enables it; `enabled => false` inside the
%% block parks it without deleting the numbers.
listener_opts(Name, Class) ->
    %% The published block can be a MAP (an inventory supplied through
    %% app env / `sys.config`) or a nested PROPLIST (the listener splat's
    %% shape for `bondy.conf`-declared blocks) — normalize before
    %% reading, or conf-file budgets would be a silent no-op (the exact
    %% shape bug the NODE scope had until 2026-08-26).
    case as_map(bondy_config:get([Name, rate_limit], undefined)) of
        undefined ->
            disabled;
        Cfg ->
            %% `key_value:to_map/1` is SHALLOW, so the class sub-block
            %% needs its own conversion.
            case as_map(maps:get(Class, Cfg, undefined)) of
                undefined ->
                    disabled;
                ClassCfg ->
                    case on(maps:get(enabled, ClassCfg, true)) of
                        true -> bucket_opts(Class, ClassCfg);
                        false -> disabled
                    end
            end
    end.

%% @private
as_map(M) when is_map(M) -> M;
as_map(L) when is_list(L) -> key_value:to_map(L);
as_map(_) -> undefined.

%% @private
bucket_opts(Class, ClassCfg) ->
    RatePerSec = maps:get(rate, ClassCfg, default_rate_per_sec(Class)),
    #{
        rate => RatePerSec / 1000,
        capacity => maps:get(capacity, ClassCfg, default_capacity(Class))
    }.

%% @private
%% The node feature-wide flag must be on; `message` additionally has its
%% own opt-in flag (it is on the hot per-message path).
node_enabled(Class, Cfg) ->
    on(maps:get(enabled, Cfg, false)) andalso
        case Class of
            message -> on(maps:get(enabled, sub(message, Cfg), false));
            _ -> true
        end.

%% @private
on(true) -> true;
on(on) -> true;
on(_) -> false.

%% @private
sub(Class, Cfg) ->
    case maps:get(Class, Cfg, #{}) of
        M when is_map(M) -> M;
        _ -> #{}
    end.

%% @private
default_rate_per_sec(handshake) -> 10;
default_rate_per_sec(connection) -> 20;
default_rate_per_sec(http) -> 100;
default_rate_per_sec(message) -> 1000;
default_rate_per_sec(_Auth) -> 5.

%% @private
default_capacity(handshake) -> 50;
default_capacity(connection) -> 100;
default_capacity(http) -> 500;
default_capacity(message) -> 2000;
default_capacity(_Auth) -> 20.
