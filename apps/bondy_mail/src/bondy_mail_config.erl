%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_config).

-moduledoc """
Configuration for the `bondy_mail` application.

Implements the `app_config` behaviour, and turns the relay declarations
cuttlefish produced from `bondy.conf` into validated `#bondy_mail_relay{}`
records held in `persistent_term`.

## Dormancy

With no `mail.relay.*` keys configured, `relays/0` answers an empty map, the
supervisor starts no children, and `bondy_mail:send/2` answers
`{error, not_configured}`. The application still starts. A node that does not
send email must not be a node that fails to boot.

## Failing closed

A relay whose credential cannot be resolved is dropped, with an error logged
naming the relay and the resolver's reason. Starting it anyway would mean
attempting delivery unauthenticated, and dropping it is visible in
`bondy.mail.relay.list`. Malformed relays are dropped the same way, so one bad
declaration cannot take the others down with it.
""".

-behaviour(app_config).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mail.hrl").

-define(APP, bondy_mail).

%% Where the validated relays live, kept apart from the raw `relays`
%% declaration cuttlefish produced. See init/0.
-define(RELAYS_BY_NAME, relays_by_name).

%% Overridable via the `master_realm_uri` key so that this application need not
%% include a router-owned header. See master_realm/0.
-define(DEFAULT_MASTER_REALM, ~"com.leapsight.bondy").

%% How long a message's status is remembered, which is also the window in which
%% an idempotency key deduplicates. An hour is long enough to cover a client's
%% retries and short enough that the table stays small.
-define(DEFAULT_STATUS_TTL, 3600000).

%% A backstop, not an operating point: the table is bounded by arrival rate
%% times TTL, and this only decides what happens if that product is larger than
%% expected.
-define(DEFAULT_STATUS_MAX_SIZE, 50000).

%% Cuttlefish applies these too. Validating again means a relay can be built
%% from a plain map in a test without going through a release build, and it is
%% the same belt-and-braces `bondy_bridge_relay_manager` applies to its own
%% cuttlefish output.
-define(RELAY_SPEC, #{
    name => #{
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    host => #{
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    port => #{
        required => true,
        default => 587,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    },
    transport => #{
        required => true,
        default => starttls,
        allow_null => false,
        allow_undefined => false,
        datatype => {in, [plain, starttls, tls]}
    },
    username => #{
        required => true,
        default => undefined,
        allow_null => false,
        allow_undefined => true,
        datatype => binary
    },
    secret => #{
        required => true,
        default => undefined,
        allow_null => false,
        allow_undefined => true,
        datatype => map
    },
    auth => #{
        required => true,
        default => if_available,
        allow_null => false,
        allow_undefined => false,
        datatype => {in, [always, if_available, never]}
    },
    tls_verify => #{
        required => true,
        default => verify_peer,
        allow_null => false,
        allow_undefined => false,
        datatype => {in, [verify_peer, verify_none]}
    },
    tls_cacertfile => #{
        required => true,
        default => undefined,
        allow_null => false,
        allow_undefined => true,
        datatype => binary
    },
    from => #{
        required => true,
        default => undefined,
        allow_null => false,
        allow_undefined => true,
        datatype => binary
    },
    %% `any` is how `*` arrives from the configuration file, so neither of
    %% these can be a plain `{list, binary}` -- that would reject `*` as a bad
    %% datatype and silently disable the relay.
    allowed_from => #{
        required => true,
        default => [],
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (any) -> true;
            (L) when is_list(L) -> true;
            (_) -> {error, ~"Expected a list of domains, or 'any'."}
        end
    },
    realms => #{
        required => true,
        default => [],
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (any) -> true;
            (L) when is_list(L) -> true;
            (_) -> {error, ~"Expected a list of realm URIs, or 'any'."}
        end
    },
    %% Not exposed in the schema: there is one implementation, and the field
    %% exists so the worker dispatches on data rather than naming a module.
    %% A test transport is set here directly; a provider transport would add a
    %% schema mapping and nothing else.
    %%
    %% Checked, because the worker calls `Mod:send/3` on this value: a module
    %% that is absent or does not implement the behaviour would raise `undef`
    %% inside the worker, which is the one thing `bondy_mail_transport` says a
    %% transport must never do -- it would crash the delivery path instead of
    %% classifying a failure on it. Refusing the relay at startup turns that
    %% into one log line naming the relay, before any mail is accepted for it.
    transport_mod => #{
        required => true,
        default => bondy_mail_transport_smtp,
        allow_null => false,
        allow_undefined => false,
        datatype => atom,
        validator => fun is_transport/1
    },
    pool_size => #{
        required => true,
        default => 4,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    },
    queue_max_size => #{
        required => true,
        default => 1000,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    },
    %% 64MB. The message bound is what an operator reasons about; this is the
    %% one that decides how much memory a stalled relay can occupy, and it has
    %% to be set from the size of the messages actually being sent rather than
    %% from their number.
    queue_max_bytes => #{
        required => true,
        default => 67108864,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    },
    queue_ttl => #{
        required => true,
        default => 300000,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    },
    timeout => #{
        required => true,
        default => 30000,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    },
    retry_max_attempts => #{
        required => true,
        default => 3,
        allow_null => false,
        allow_undefined => false,
        datatype => non_neg_integer
    },
    retry_backoff_min => #{
        required => true,
        default => 1000,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    },
    retry_backoff_max => #{
        required => true,
        default => 60000,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    },
    rate_limit_rate => #{
        required => true,
        default => 0,
        allow_null => false,
        allow_undefined => false,
        datatype => number
    },
    rate_limit_burst => #{
        required => true,
        default => 1,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    },
    max_message_size => #{
        required => true,
        default => 26214400,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    },
    %% RFC 5321 obliges a server to accept 100 recipients in one transaction,
    %% so that is the floor a caller can rely on anywhere.
    max_recipients => #{
        required => true,
        default => 100,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    },
    %% Three, because one timeout happens to healthy infrastructure and
    %% marking a relay down for it would raise a page about the weather.
    health_failure_threshold => #{
        required => true,
        default => 3,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    },
    %% One, matching the `bondy_http_connector` precedent: the alarm clears as
    %% soon as anything succeeds unless an operator asks for more evidence.
    health_success_threshold => #{
        required => true,
        default => 1,
        allow_null => false,
        allow_undefined => false,
        datatype => pos_integer
    }
}).

-type relay() :: #bondy_mail_relay{}.

-export_type([relay/0]).

%% API
-export([default_relay/0]).
-export([get/1]).
-export([get/2]).
-export([init/0]).
-export([is_configured/0]).
-export([is_master_realm/1]).
-export([master_realm/0]).
-export([prototype_uri/1]).
-export([relay/1]).
-export([relay_names/0]).
-export([relays/0]).
-export([set/2]).
-export([status_max_size/0]).
-export([status_ttl/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Initialise application config and build the relay table.

Called once from `bondy_mail_app:start/2`, before the supervisor starts, so the
supervisor can decide whether there is anything to supervise.
""".
-spec init() -> ok.

init() ->
    ok = app_config:init(?APP, #{callback_mod => ?MODULE}),
    %% The parsed relays are stored under their own key. `app_config:set/3`
    %% also writes back to the application environment, so parsing `relays`
    %% into `relays` would leave a map where cuttlefish had put a list, and the
    %% next start of this application would silently find no relays at all.
    Relays = build_relays(get(relays, [])),
    ok = set(?RELAYS_BY_NAME, Relays),
    ok = log_summary(Relays),
    ok.

-doc "Get a config value by key.".
-spec get(Key :: list() | atom() | tuple()) -> term().

get(Key) ->
    app_config:get(?APP, Key).

-doc "Get a config value by key, falling back to `Default` when unset.".
-spec get(Key :: list() | atom() | tuple(), Default :: term()) -> term().

get(Key, Default) ->
    app_config:get(?APP, Key, Default).

-doc "Set a config value at runtime.".
-spec set(Key :: key_value:key() | tuple(), Value :: term()) -> ok.

set(Key, Value) ->
    app_config:set(?APP, Key, Value).

-doc """
Return every configured relay, keyed by name.

An empty map means the subsystem is dormant.
""".
-spec relays() -> #{binary() => relay()}.

relays() ->
    get(?RELAYS_BY_NAME, #{}).

-doc "Return the configured relay names, sorted.".
-spec relay_names() -> [binary()].

relay_names() ->
    lists:sort(maps:keys(relays())).

-doc "Return the relay named `Name`.".
-spec relay(Name :: binary()) -> {ok, relay()} | {error, no_such_relay}.

relay(Name) when is_binary(Name) ->
    case maps:find(Name, relays()) of
        {ok, Relay} ->
            {ok, Relay};
        error ->
            {error, no_such_relay}
    end.

-doc """
Return the name of the default relay.

`mail.default_relay` when set, otherwise the only configured relay when there
is exactly one. With several relays and no default, a caller must name one.
""".
-spec default_relay() -> {ok, binary()} | {error, no_such_relay}.

default_relay() ->
    case get(default_relay, undefined) of
        undefined ->
            case maps:keys(relays()) of
                [Name] -> {ok, Name};
                _ -> {error, no_such_relay}
            end;
        Name0 ->
            %% The schema normalises this to a binary, but tolerate a string
            %% so that setting it directly in sys.config does not fail in a
            %% way that looks like a missing relay.
            Name = iolist_to_binary(Name0),
            case maps:is_key(Name, relays()) of
                true -> {ok, Name};
                false -> {error, no_such_relay}
            end
    end.

-doc """
Return how long a message's status is kept, in milliseconds.

This is also the idempotency window: a key is only deduplicated for as long as
the message it named is still remembered.
""".
-spec status_ttl() -> pos_integer().

status_ttl() ->
    %% Tolerant of a key explicitly set to `undefined`, which is how a value is
    %% cleared once `app_config` has cached it -- unsetting the application
    %% environment leaves the cache untouched.
    case get(status_ttl, ?DEFAULT_STATUS_TTL) of
        Ttl when is_integer(Ttl) andalso Ttl > 0 -> Ttl;
        _ -> ?DEFAULT_STATUS_TTL
    end.

-doc """
Return the most status records this node keeps.

Reached only when arrival rate times TTL exceeds it. Beyond this bound the
oldest records are dropped, which degrades status reporting and deduplication
rather than refusing mail.
""".
-spec status_max_size() -> pos_integer().

status_max_size() ->
    case get(status_max_size, ?DEFAULT_STATUS_MAX_SIZE) of
        Max when is_integer(Max) andalso Max > 0 -> Max;
        _ -> ?DEFAULT_STATUS_MAX_SIZE
    end.

-doc "Return `true` when at least one relay is usable.".
-spec is_configured() -> boolean().

is_configured() ->
    maps:size(relays()) > 0.

-doc """
Return the master realm's URI.

Configurable so that this application does not have to include a header owned
by the router: `bondy_mail` sits below `bondy_router` in the dependency graph
and must stay there.
""".
-spec master_realm() -> binary().

master_realm() ->
    get(master_realm_uri, ?DEFAULT_MASTER_REALM).

-doc "Return `true` when `RealmUri` is the master realm.".
-spec is_master_realm(RealmUri :: binary()) -> boolean().

is_master_realm(RealmUri) ->
    RealmUri == master_realm().

-doc """
Return the prototype `RealmUri` inherits from, if any.

Realm inheritance is the router's concept, and this application cannot call
into the router without creating a cycle. So the resolver is named in
configuration -- `bondy_app` sets it to `bondy_realm`, which exports
`prototype_uri/1` -- and looked up dynamically.

With no resolver configured, or a realm the resolver cannot answer for, this
answers `undefined`: no inheritance, so a relay's realm list is taken
literally. That is the fail-closed direction. An unanswerable realm never
inherits its way into a permission it was not granted.
""".
-spec prototype_uri(RealmUri :: binary()) -> optional(binary()).

prototype_uri(RealmUri) ->
    case get(realm_module, undefined) of
        undefined ->
            undefined;
        Mod when is_atom(Mod) ->
            try Mod:prototype_uri(RealmUri) of
                Uri when is_binary(Uri) -> Uri;
                _ -> undefined
            catch
                Class:Reason ->
                    ?LOG_DEBUG(#{
                        description => "Could not resolve realm prototype",
                        realm_uri => RealmUri,
                        module => Mod,
                        class => Class,
                        reason => Reason
                    }),
                    undefined
            end
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
build_relays(L) when is_list(L) ->
    lists:foldl(fun build_relay/2, #{}, L);
build_relays(Other) ->
    ?LOG_ERROR(#{
        description => "Ignoring malformed mail relay configuration",
        reason => not_a_list,
        value => Other
    }),
    #{}.

%% @private
%% One bad relay is dropped rather than allowed to take down the others, or the
%% node. Every drop is logged with the relay name and the reason.
build_relay(Map0, Acc) when is_map(Map0) ->
    Name = maps:get(name, Map0, undefined),
    try maps_utils:validate(Map0, ?RELAY_SPEC) of
        Map ->
            case resolve_secret(Name, Map) of
                {ok, Secret} ->
                    maps:put(Name, to_record(Map, Secret), Acc);
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        description =>
                            "Could not resolve mail relay credential, "
                            "relay disabled",
                        relay => Name,
                        reason => Reason
                    }),
                    Acc
            end
    catch
        _:Reason ->
            ?LOG_ERROR(#{
                description =>
                    "Invalid mail relay configuration, "
                    "relay disabled",
                relay => Name,
                reason => Reason
            }),
            Acc
    end;
build_relay(Other, Acc) ->
    ?LOG_ERROR(#{
        description => "Ignoring malformed mail relay declaration",
        value => Other
    }),
    Acc.

%% @private
resolve_secret(_Name, #{secret := undefined}) ->
    {ok, undefined};
resolve_secret(Name, #{secret := #{provider := none} = Ref}) ->
    %% A credential written into bondy.conf in the clear. Supported so a
    %% development setup does not need an environment variable, but said out
    %% loud at every boot: forbidding it would just relocate the secret to a
    %% variable named `changeme`.
    ?LOG_WARNING(#{
        description =>
            "Mail relay password is set literally in the configuration file. "
            "Use a secret provider (env or aws_sm) outside development.",
        relay => Name
    }),
    bondy_mail_secret:resolve(Ref);
resolve_secret(_Name, #{secret := Ref}) ->
    bondy_mail_secret:resolve(Ref).

%% @private
%% `code:ensure_loaded/1` first, because `function_exported/3` answers about
%% loaded code and a release loads lazily: asking about a perfectly good module
%% that nothing has called yet would disable the relay.
is_transport(Mod) when is_atom(Mod) ->
    _ = code:ensure_loaded(Mod),
    erlang:function_exported(Mod, send, 3) orelse
        {error, ~"Expected a module implementing bondy_mail_transport."};
is_transport(_) ->
    {error, ~"Expected a module implementing bondy_mail_transport."}.

%% @private
to_record(Map, Secret) ->
    PoolSize = maps:get(pool_size, Map),
    #bondy_mail_relay{
        name = maps:get(name, Map),
        host = maps:get(host, Map),
        port = maps:get(port, Map),
        transport = maps:get(transport, Map),
        username = maps:get(username, Map),
        secret = Secret,
        auth = maps:get(auth, Map),
        tls_verify = maps:get(tls_verify, Map),
        tls_cacertfile = maps:get(tls_cacertfile, Map),
        from = maps:get(from, Map),
        allowed_from = maps:get(allowed_from, Map),
        realms = maps:get(realms, Map),
        transport_mod = maps:get(transport_mod, Map),
        pool_size = PoolSize,
        pool_cursor = atomics:new(1, [{signed, false}]),
        %% Two slots per worker -- the messages queued for it and the bytes
        %% they hold -- so that a worker can zero its own pair when it starts
        %% and a stranded reservation cannot outlive the process that stranded
        %% it. See bondy_mail_worker.
        %%
        %% Signed, because a worker draining a queue built up before a
        %% reconfiguration can decrement past what it incremented, and wrapping
        %% an unsigned counter would report a depth of 2^64 on a dashboard.
        queue_counters = atomics:new(2 * PoolSize, [{signed, true}]),
        queue_max_size = maps:get(queue_max_size, Map),
        queue_max_bytes = maps:get(queue_max_bytes, Map),
        queue_ttl = maps:get(queue_ttl, Map),
        timeout = maps:get(timeout, Map),
        retry_max_attempts = maps:get(retry_max_attempts, Map),
        retry_backoff_min = maps:get(retry_backoff_min, Map),
        retry_backoff_max = maps:get(retry_backoff_max, Map),
        rate_limit_rate = maps:get(rate_limit_rate, Map),
        rate_limit_burst = maps:get(rate_limit_burst, Map),
        max_message_size = maps:get(max_message_size, Map),
        max_recipients = maps:get(max_recipients, Map),
        health_failure_threshold = maps:get(health_failure_threshold, Map),
        health_success_threshold = maps:get(health_success_threshold, Map)
    }.

%% @private
log_summary(Relays) when map_size(Relays) == 0 ->
    ?LOG_INFO(#{
        description =>
            "No mail relays configured, bondy_mail is dormant. "
            "Configure mail.relay.$name.* to enable outbound email."
    }),
    ok;
log_summary(Relays) ->
    ?LOG_NOTICE(#{
        description => "Starting bondy_mail",
        relay_count => maps:size(Relays),
        relays => lists:sort(maps:keys(Relays))
    }),
    ok.
