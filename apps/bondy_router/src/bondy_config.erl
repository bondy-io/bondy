%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_config).
-moduledoc """
An implementation of the `app_config` behaviour.
""".
-behaviour(app_config).

%% The Partisan channel carrying bondy_db replication data.
-define(BONDY_DB_DATA_CHANNEL, data).
-define(WAMP_RELAY_CHANNEL, wamp_relay).
-define(BONDY_AAE_CHANNEL, bondy_aae).

-include_lib("kernel/include/logger.hrl").
-include("bondy_db_tables.hrl").
-include("bondy.hrl").

-if(?OTP_RELEASE >= 25).
-define(VALIDATE_MQ_DATA(X),
    case X of
        off_heap -> off_heap;
        _ -> on_heap
    end
).
-else.
-define(VALIDATE_MQ_DATA(_), on_heap).
-endif.

-define(WAMP_EXT_OPTIONS, [
    {call, [
        '_routing_key',
        %% Total distinct cluster nodes a CALL may be routed to before a
        %% routing failure is final (default 2 — the original candidate
        %% plus one retry). Consulted by the dealer's bounded
        %% pre-invocation retry; retries never extend the call timeout and
        %% never occur once an invocation may have been delivered.
        '_routing_max_candidates',
        %% Absolute time budget for the whole call in milliseconds. For a
        %% progressive call the WAMP `timeout` is an inter-result
        %% inactivity window that each progressive result restarts; the
        %% deadline caps the total duration regardless of progress.
        '_deadline',
        %% Keyset pagination for the `bondy.*` meta list/match procedures:
        %% `_limit` bounds the page size, `_cursor` is the opaque wire cursor
        %% returned as a prior page's `cursor`.
        '_limit',
        '_cursor',
        %% W3C Trace Context (`traceparent`/`tracestate`) and Baggage,
        %% copied verbatim into INVOCATION.Details (see ?WAMP_TRACE_ATTRS).
        '_traceparent',
        '_tracestate',
        '_baggage'
    ]},
    {cancel, [
        '_routing_key'
    ]},
    {interrupt, [
        'x_session_info', '_session_info'
    ]},
    {register, [
        'x_disclose_session_info',
        '_disclose_session_info',
        '_prefer_local',
        '_prefer_local',
        %% number of concurrent, outstanding calls that can exist
        %% for a single endpoint
        'x_concurrency',
        {invoke, [
            <<"jump_consistent_hash">>,
            <<"jch">>,
            <<"queue_least_loaded">>,
            <<"qll">>,
            <<"queue_least_loaded_sample">>,
            <<"qlls">>
        ]}
    ]},
    {publish, [
        %% The ttl for retained events
        '_retained_ttl',
        '_routing_key',
        %% W3C Trace Context (`traceparent`/`tracestate`) and Baggage,
        %% copied verbatim into EVENT.Details (see ?WAMP_TRACE_ATTRS).
        '_traceparent',
        '_tracestate',
        '_baggage'
    ]},
    {subscribe, [
        'x_disclose_session_info', '_disclose_session_info'
    ]},
    {yield, []}
]).
-define(WAMP_EXT_DETAILS, [
    {abort, []},
    {hello, [
        'x_authroles', '_authroles'
    ]},
    {welcome, [
        'x_authroles', '_authroles'
    ]},
    {goodbye, []},
    {error, []},
    {event, [
        'x_session_info',
        '_session_info',
        '_traceparent',
        '_tracestate',
        '_baggage'
    ]},
    {call, []},
    {invocation, [
        'x_session_info',
        '_session_info',
        '_traceparent',
        '_tracestate',
        '_baggage'
    ]},
    {result, []}
]).

-define(CONFIG, [
    %% The following are configured via bondy.conf:
    %% - exchange_tick_period <- cluster.exchange_tick_period
    %% - lazy_tick_period <- cluster.lazy_tick_period
    %% - peer_port <- cluster.peer_port
    %% - parallelism <- cluster.parallelism
    %% - max_message_size <- cluster.max_message_size
    %% - peer_service_manager <- cluster.overlay.topology
    %% - partisan.tls <- cluster.tls.enabled
    %% - partisan.tls_server_options.* <- cluster.tls.server.*
    %% - partisan.tls_client_options.* <- cluster.tls.client.*
    %% - tls_handshake_timeout <- cluster.tls.handshake_timeout
    %% - rpc_max_concurrency <- cluster.rpc_max_concurrency
    %% - connection_high_watermark <- cluster.connection_high_watermark
    {partisan, [
        %% Overlay topology
        %% Required for peer_service_manager ==
        %% partisan_pluggable_peer_service_manager
        {membership_strategy, partisan_full_membership_strategy},
        {connect_disterl, false},
        {broadcast_mods, [
            partisan_plumtree_backend
        ]},
        %% Remote refs
        {remote_ref_format, improper_list},
        {remote_ref_binary_padding, false},
        {pid_encoding, false},
        {ref_encoding, false},
        {register_pid_for_encoding, false},
        {binary_padding, false},
        %% Fwd options
        {disable_fast_forward, false},
        %% Broadcast options
        {broadcast, false},
        {tree_refresh, 1000},
        {relay_ttl, 5}
    ]},
    {bondy_wamp, [
        {json, [
            {decode_opts, [{decoders, #{null => undefined}}]}
        ]}
    ]},
    %% Local in-memory storage
    {tuplespace, [
        %% Ring size is determined based on number of Erlang schedulers
        %% which are based on number of CPU Cores.
        {ring_size, min(16, erlang:system_info(schedulers))},
        {static_tables, [
            %% Used by bondy_session.erl
            {bondy_session, [
                set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true},
                {decentralized_counters, true}
            ]},
            %% Used by bondy_session_counter.erl
            {bondy_session_counter, [
                set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true},
                {decentralized_counters, true}
            ]},
            {bondy_registration_index, [
                bag,
                {keypos, 1},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true},
                {decentralized_counters, true}
            ]},
            {bondy_rpc_promise, [
                ordered_set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true},
                {decentralized_counters, true}
            ]},
            %% Holds information required to implement the different invocation
            %% strategies like round_robin
            {bondy_rpc_state, [
                set,
                {keypos, 2},
                named_table,
                public,
                {read_concurrency, true},
                {write_concurrency, true},
                {decentralized_counters, true}
            ]}
        ]}
    ]}
]).

-define(BONDY, bondy_router).

%% Ranch options for a listener that declares no transport tuning. A listener is
%% fully specified by its inventory entry — transport, protocol and a bind
%% target — so an option block is optional, and the `listeners.$name.*` mappings
%% carry no defaults of their own. Both values are the ones `bondy_wamp_uds` had
%% for the same reason before every listener shared one driver: 10 acceptors and
%% no connection ceiling, rather than ranch's own default of 1024.
%%
%% This is the ONLY place either value is written. `bondy_listener_ranch` reads
%% both without a default, so neither is restated there.
-define(DEFAULT_TRANSPORT_OPTS, #{
    num_acceptors => 10,
    max_connections => infinity
}).

-export([get/1]).
-export([get/2]).
-export([init/1]).
-export([set/2]).

-export([node/0]).
-export([nodestring/0]).
-export([node_hash/0]).
-export([node_spec/0]).
-export([listener_transport_opts/2]).
-export([listener_protocol_opts/1]).
-export([splat_listener_blocks/1]).
-export([code_defined_features/0]).

-compile({no_auto_import, [get/1]}).

-ifdef(TEST).
%% Exposed for deterministic unit testing of the dynamic_buffer
%% normalisation (schema {min,max} property list → Cowboy's
%% {Min, Max} | false), decoupled from the app_config store.
-export([normalize_dynamic_buffer/1]).
-endif.

%% =============================================================================
%% API
%% =============================================================================

init(Args) ->
    %% We initialise the environment with the args
    ok = set_vsn(Args),

    ?LOG_NOTICE(#{
        description => "Initialising Bondy configuration",
        version => get(bondy, vsn)
    }),

    %% We read bondy env and cache the values
    ok = app_config:init(?BONDY, #{callback_mod => ?MODULE}),

    %% Resolve the listener inventory before anything consumes it:
    %% `bondy_cert_manager:init/0` below loads server certificates and client
    %% auth per TLS listener, and `setup_wamp/0` normalises `dynamic_buffer` per
    %% HTTP listener. Both ask the manager which listeners exist.
    %%
    %% Must run after `app_config:init/2` above, the first point at which
    %% configuration is readable at all. It also calls
    %% `splat_listener_blocks/1`, which is what puts a listener's option blocks
    %% where `bondy_cert_manager:init/0` reads `[Name, tls, ...]` from for both
    %% the server certificate and the mTLS policy.
    ok = bondy_listener_manager:init(),

    ok = bondy_cert_manager:init(),

    ok = setup_wamp(),

    ok = setup_mods(),

    ok = setup_partisan_channels(),

    ok = setup_partisan(),

    ok = apply_private_config(prepare_private_config()),

    ?LOG_NOTICE(#{description => "Bondy configuration finished"}),
    ok.

-spec get(Key :: list() | atom() | tuple()) -> term().

get(wamp_call_timeout = Key) ->
    Value = app_config:get(?BONDY, Key),
    Max = app_config:get(?BONDY, wamp_max_call_timeout),
    min(Value, Max);
get(Key) ->
    app_config:get(?BONDY, Key).

-spec get(Key :: list() | atom() | tuple(), Default :: term()) -> term().

get(Key, Default) ->
    app_config:get(?BONDY, Key, Default).

-spec set(Key :: key_value:key() | tuple(), Value :: term()) -> ok.

set(status, Value) ->
    %% Typically we would change status during application_controller
    %% lifecycle so to avoid a loop (resulting in timeout) we avoid
    %% calling application:set_env/3.
    persistent_term:put({?BONDY, status}, Value);
set(Key, Value) ->
    app_config:set(?BONDY, Key, Value).

-spec node() -> atom().

node() ->
    partisan_config:get(name).

-spec nodestring() -> nodestring().

nodestring() ->
    case get(nodestring, undefined) of
        undefined ->
            Nodestring = atom_to_binary(partisan_config:get(name), utf8),
            ok = set(nodestring, Nodestring),
            %% Derive the node routing hash at the same time, cached the same
            %% way (see node_hash/0).
            ok = set(node_hash, compute_node_hash(Nodestring)),
            Nodestring;
        Nodestring ->
            Nodestring
    end.

-doc """
Returns a short, fixed-length, URL-safe hash of this node — the leading 64 bits
of `SHA-256(nodestring)` encoded in base62 (~11 chars, no `.`). It identifies the
node for session routing: the session id embeds it so `wamp.session.get` can be
routed to the owning node without a per-session registration.

Two distinct nodes collide with cryptographically negligible probability
(~`n^2 / 2^65`), independent of nodestring length (so long Kubernetes nodestrings
do not bloat session ids). Cached identically to (and alongside) `nodestring/0`.
""".
-spec node_hash() -> binary().

node_hash() ->
    case get(node_hash, undefined) of
        undefined ->
            %% nodestring/0 populates node_hash alongside itself; this branch
            %% only runs if nodestring was cached before node_hash existed.
            NodeHash = compute_node_hash(nodestring()),
            ok = set(node_hash, NodeHash),
            NodeHash;
        NodeHash ->
            NodeHash
    end.

-spec node_spec() -> partisan:node_spec().

node_spec() ->
    partisan:node_spec().

-doc """
Ranch transport options for `Name`, with `Ip` — the address its listener
resolved to, or `undefined` if none was configured — folded into the socket
options BEFORE they are normalised.

Before, not after, because `normalise_socket_opts/1` is the only place an
address and an `ip_version` are reconciled: it derives the socket's family from
whichever of the two is present and prepends the family atom. An address
written into `socket_opts` after that runs can contradict the atom already
there, and `gen_tcp:listen/2` answers a contradiction with `badarg` rather than
an error tuple.

`undefined` writes nothing, so a listener that configured no address keeps
whatever `socket_opts` already holds — nothing, for a new-style listener, which
`normalise_socket_opts/1` then reads as `any` and resolves to the wildcard of
the configured family.
""".
-spec listener_transport_opts(
    ListenerName :: atom(), Ip :: inet:ip_address() | undefined
) ->
    map().

listener_transport_opts(Name, Ip) ->
    %% `ip` is dropped from the transport options. It is not a ranch transport
    %% option, and `key_value:to_map/1` is shallow, so an `ip` sitting at the top
    %% of a listener's `transport_opts` block survives this merge into the map
    %% handed to `ranch:start_listener/5`.
    %% `ranch:validate_transport_opt/3`'s catch-all answers `false` for an
    %% unknown key, so the bind fails with `{error, {bad_option, ip}}` and
    %% aborts the boot — verified directly by
    %% `top_level_ip_does_not_reach_ranch` in `bondy_listener_SUITE`, which fails
    %% with that exact tuple without this line. The address reaches the socket
    %% options through the `Ip` parameter instead, where it is reconciled with
    %% `ip_version`, so the raw value has no remaining purpose here.
    Opts = maps:remove(
        ip,
        maps:merge(
            ?DEFAULT_TRANSPORT_OPTS,
            key_value:to_map(get([Name, transport_opts], []))
        )
    ),
    NumAcceptors = key_value:get(num_acceptors, Opts),
    SocketOpts0 = normalise_socket_opts(
        with_ip(Ip, key_value:get(socket_opts, Opts, []))
    ),
    %% The per-listener `tls` block is where a certificate is declared; it must
    %% reach the socket options ranch binds with, not just the validation in
    %% `bondy_listener_config:assert_tls_keys/3`.
    SocketOpts1 = with_tls_material(Name, SocketOpts0),
    %% Inject sni_fun for TLS listeners to enable live cert rotation. This runs
    %% AFTER the fold above so a rotating certificate still wins over the
    %% static `tls` block.
    SocketOpts = bondy_cert_manager:maybe_inject_sni_fun(Name, SocketOpts1),

    Opts#{
        %% connection_type => worker,

        % the default, made explicit
        num_conns_sups => NumAcceptors,
        socket_opts => SocketOpts
    }.

-spec listener_protocol_opts(ListenerName :: atom()) -> map().

listener_protocol_opts(Name) ->
    %% Absent block means no overrides, so the handler's own defaults (Cowboy's,
    %% for an HTTP listener) apply. Nothing is invented here.
    key_value:to_map(get([Name, protocol_opts], [])).

%% The eight keys `bondy_listener_config:resolve_one/3' reads directly from a
%% listener's spec: `transport' and `protocol' via `required/2'; `services' via
%% `resolve_services/3' (`maps:find/2' for an HTTP listener, `maps:is_key/2'
%% otherwise); `enabled' and `start_phase' via `maps:get/3' in `resolve_one/3'
%% itself; and `port'/`path'/`ip' via `resolve_bind/3' and `resolve_ip/3'.
%% Everything else in a spec is an option block belonging to a consumer that
%% reads it from `bondy_router.<name>.*'.
-define(SPEC_KEYS, [
    transport, protocol, port, path, ip, services, enabled, start_phase
]).

-doc """
Copies every non-structural key of each `Inventory` entry to
`bondy_router.<name>.<key>`, where its consumer reads it.

Takes the inventory rather than reading `bondy_router.listeners` itself, because
that key holds only what the operator declared. What a node runs is the operator's
inventory with the reserved and internal listeners added and each spec's
transport- and protocol-implied defaults filled in, and every one of those
listeners has consumers reading `[Name, Key]` too. Deciding what that effective
inventory is belongs to `bondy_listener_manager:init/0`, which does it once and
passes the result here.

`bondy_router.listeners` is the only key the `listeners.$name.*` schema block
can render into: a cuttlefish mapping's target is tokenised literally, so it
cannot write a listener's name into one. Every option block a listener's
consumers expect at `[Name, Key]` — `transport_opts`, `protocol_opts`, `tls`,
`cors`, `security_headers`, `proxy_protocol`, `websocket`, `sse`, `longpoll`,
and any key a spec carries at its own top level such as `idle_timeout` —
therefore arrives nested inside that one inventory entry instead. This copies
each one out.

A key absent from an inventory entry stays absent here: only the keys a spec
actually carries are written, so a listener that configured nothing gets no
block at any of these paths and its consumer's own default applies.

A leaf is written through `set/2`'s own path-based semantics rather than
replacing the whole block at `[Name, Key]`, so writing one leaf never touches
its siblings: `acceptors_pool_size` targets `transport_opts.num_acceptors` and
`backlog` targets the nested `transport_opts.socket_opts.backlog`, and a
listener setting both ends up with both. Only a map is descended into; a
list-valued leaf (`tls.versions`, `cors.allowed_origins`) is a value, not a
nested block to merge, and every nested block the `bondy_router.listeners`
translation renders is a map, never a proplist, so this cannot mistake one for
the other.

Nothing here special-cases the atom `undefined`. A caller reads
`get(listeners, undefined)` to tell a node booting on
`bondy_listener_config:default_inventory/0` from a configured one, and resolves
that sentinel to a list before calling — so the atom cannot reach the list
comprehension below and raise `{bad_generator, undefined}`.
""".
-spec splat_listener_blocks(Inventory :: [{atom(), map()}]) -> ok.

splat_listener_blocks(Inventory) ->
    _ = [
        splat(Name, [Key], Value)
     || {Name, Spec} <- Inventory,
        {Key, Value} <- maps:to_list(Spec),
        not lists:member(Key, ?SPEC_KEYS)
    ],
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Descends through a map, writing each leaf at `[Name | Path]` via `set/2`.
%% `set/2` reaches `app_config:do_set/3`, whose own nested-path clause reads
%% whatever is already at each intermediate key (defaulting to `[]`, never
%% discarding it) before re-storing it, so a leaf this writes lands beside its
%% siblings instead of replacing the block that contains them. A value that is
%% not a map — a scalar, a proplist a caller built directly, or a list-valued
%% leaf — is written as-is: only a map is a nested block to descend into.
splat(Name, Path, Value) when is_map(Value) ->
    maps:foreach(fun(K, V) -> splat(Name, Path ++ [K], V) end, Value);
splat(Name, Path, Value) ->
    set([Name | Path], Value).

%% @private
%% Leading 64 bits of SHA-256(nodestring), base62-encoded: fixed-length,
%% URL-safe, dot-free. See node_hash/0 for the collision analysis.
compute_node_hash(Nodestring) when is_binary(Nodestring) ->
    <<H:64, _/binary>> = crypto:hash(sha256, Nodestring),
    %% base62:encode/1 returns a string (iolist); the node hash must be a binary.
    iolist_to_binary(base62:encode(H)).

%% @private
-doc """
A utility function we use to extract the version name that is injected by the
`bondy_router.app.src` configuration file.
""".
set_vsn(Args) ->
    case lists:keyfind(vsn, 1, Args) of
        {vsn, Vsn} ->
            ok = bondy_config:set(status, initialising),
            application:set_env(?BONDY, vsn, Vsn);
        false ->
            ok
    end.

%% @private
setup_mods() ->
    ok = jose:json_module(bondy_wamp_json),
    ok = configure_registry(),
    ok = configure_jobs_pool(),
    ok = configure_http_transport().

setup_partisan_channels() ->
    %% FALLBACK ONLY, for boots that never render cuttlefish (tests,
    %% `rebar3 shell'). `schema/bondy.schema' is authoritative for every
    %% channel it names — `cluster.channels.{default,data,control_plane,
    %% wamp_relay}.*' — and always supplies a value, so the merge below
    %% overrides each of these. Any value here that disagrees with the
    %% schema's default is therefore DEAD in a released node: keep the two
    %% in step, or the disagreement is silent. `bondy_aae' is the one
    %% channel with no schema key, so its value here is the effective one.
    DefaultChannels = #{
        ?BONDY_DB_DATA_CHANNEL => #{parallelism => 2, compression => false},
        %% Matches `cluster.channels.wamp_relay.parallelism'. The channel
        %% carries the WAMP data plane: each connection is one ordered pipe
        %% (flows are pinned by partition_key) with its own sender and
        %% receiver process on each side, so parallelism is the relay's
        %% ingress/egress process parallelism — size it for data-plane
        %% throughput, not like the control-plane channels.
        ?WAMP_RELAY_CHANNEL => #{parallelism => 8, compression => false},
        ?BONDY_AAE_CHANNEL => #{parallelism => 2, compression => false}
    },
    Channels =
        case application:get_env(?BONDY, channels, []) of
            [] ->
                DefaultChannels;
            Channels0 ->
                Channels1 = lists:foldl(
                    fun({Channel, PList}, Acc) ->
                        maps:put(Channel, maps:from_list(PList), Acc)
                    end,
                    maps:new(),
                    Channels0
                ),
                maps:merge(DefaultChannels, Channels1)
        end,

    application:set_env(partisan, channels, maps:to_list(Channels)).

%% @private
setup_partisan() ->
    %% We re-apply partisan config, this reads the partisan env and re-caches
    %% the values. We do this because partisan might have started already.
    ok = partisan_config:init(),

    %% We add the wamp_relay channel
    ok = bondy_config:set(aae_channel, ?BONDY_AAE_CHANNEL),
    ok = bondy_config:set(wamp_peer_channel, ?WAMP_RELAY_CHANNEL).

%% @private
setup_wamp() ->
    %% We override all those parameters which the user should not be able to
    %% set and also set other parameters which are required for Bondy to
    %% operate i.e. all dependencies, and are private.

    %% ROUTER
    %% Dynamic buffer, HTTP listeners only (not RAW TCP sockets). The schema
    %% maps <listener>.buffer.min/max to a {min, max} property list at
    %% [Listener, protocol_opts, dynamic_buffer]; Cowboy requires
    %% `dynamic_buffer => {Min, Max} | false', so normalise the value in
    %% place. When unset the key is left ABSENT and Cowboy's default
    %% ({512, 131072}, adaptive) applies. There is no WebSocket-specific
    %% equivalent to list here: since Cowboy 2.13 a WebSocket connection
    %% INHERITS the listener's dynamic_buffer (cowboy_websocket overrides any
    %% handler-supplied value), so a WS-specific setting cannot take effect,
    %% which is why `?CARRIER_DEFAULTS' has no `dynamic_buffer' entry either.
    Keys = [
        [Name, protocol_opts, dynamic_buffer]
     || Name <- bondy_listener_manager:http_listeners()
    ],
    ok = lists:foreach(fun set_dynamic_buffer/1, Keys),

    %% Every WAMP feature Bondy announces, seated from the code. A feature is a
    %% CAPABILITY, not a setting: it tells a client which parts of the advanced
    %% profile this build implements. A client asks for a subset in HELLO,
    %% `bondy_session:parse_roles/1' intersects that request with these values
    %% (`merge_feature_flags/2'), and from then on every message consults the
    %% resulting SESSION flags. An operator has no say at any point in that
    %% chain, which is why none of these is a `bondy.conf' key.
    %%
    %% `?BROKER_FEATURES' and `?DEALER_FEATURES' are the value tables;
    %% `?BROKER_FEATURES_SPEC' and `?DEALER_FEATURES_SPEC' in `bondy_wamp.hrl'
    %% are the matching name sets, which is what makes the pair an oracle rather
    %% than one more copy of the list.
    %%
    %% Seated as CONFIGURATION rather than returned as literals from
    %% `bondy_dealer:features/0' and `bondy_broker:features/0', because both
    %% modules also answer `is_feature_implemented/1' straight out of
    %% configuration;
    %% one value here is what keeps the two answers from disagreeing, and is what
    %% `bondy_router:roles/0' advertises in WELCOME.
    ok = lists:foreach(
        fun({Role, Features}) ->
            maps:foreach(
                fun(Feature, Supported) ->
                    set([wamp, Role, features, Feature], Supported)
                end,
                Features
            )
        end,
        [{broker, ?BROKER_FEATURES}, {dealer, ?DEALER_FEATURES}]
    ),

    %% WAMP PROTOCOL LIB
    ok = bondy_wamp_config:set(extended_details, ?WAMP_EXT_DETAILS),
    ok = bondy_wamp_config:set(extended_options, ?WAMP_EXT_OPTIONS).

-doc """
Every WAMP feature this build defines a value for, as `{Role, Feature}` pairs.

These are capabilities, not settings: none of them is a `bondy.conf` key, and
`scripts/migrate_conf.escript` reports each one as dropped so an operator
upgrading from a release that mapped them is told why the key is gone.
""".
-spec code_defined_features() -> [{broker | dealer, atom()}].

code_defined_features() ->
    [
        {Role, Feature}
     || {Role, Features} <-
            [{broker, ?BROKER_FEATURES}, {dealer, ?DEALER_FEATURES}],
        Feature <- maps:keys(Features)
    ].

%% @private
set_dynamic_buffer(Key) ->
    Value0 = bondy_config:get(Key, undefined),

    case normalize_dynamic_buffer(Value0) of
        undefined ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Error while preparing configuration",
                reason => Reason,
                key => Key,
                value => Value0
            }),
            exit(invalid_configuration);
        Value ->
            bondy_config:set(Key, Value)
    end.

%% @private
%% Normalises the schema's {min, max} property list into the
%% `{Min, Max} | false' shape Cowboy requires. `undefined' means the option
%% is unset — the caller leaves the key absent so Cowboy's default applies.
%% Setting either bound to 0 disables the dynamic buffer; otherwise BOTH
%% bounds are required, within [1 KiB, 128 KiB] and with Min =< Max.
normalize_dynamic_buffer(undefined) ->
    undefined;
normalize_dynamic_buffer([]) ->
    undefined;
normalize_dynamic_buffer(Props) when is_list(Props) ->
    Low = memory:kibibytes(1),
    Top = memory:kibibytes(128),
    Min = key_value:get(min, Props, undefined),
    Max = key_value:get(max, Props, undefined),

    if
        Min == 0 orelse Max == 0 ->
            false;
        is_integer(Min) andalso is_integer(Max) andalso
            Min >= Low andalso Max =< Top andalso Min =< Max ->
            {Min, Max};
        true ->
            {error,
                "invalid value for configuration option: both min and max "
                "are required, within 1KB..128KB and min =< max "
                "(either may be 0 to disable)"}
    end;
normalize_dynamic_buffer(_) ->
    {error, "invalid value for configuration option"}.

%% @private
prepare_private_config() ->
    {ok, ?CONFIG}.

%% @private
configure_registry() ->
    %% Configure partition count
    KeyPath = [registry, partitions],

    ok =
        case bondy_config:get(KeyPath, undefined) of
            undefined ->
                N = min(16, erlang:system_info(schedulers)),
                bondy_config:set(KeyPath, N),
                ok;
            _ ->
                ok
        end,

    %% Configure partition spawn_opts
    Opts0 = bondy_config:get([registry, partition_spawn_opts], []),
    Value = ?VALIDATE_MQ_DATA(
        key_value:get(message_queue_data, Opts0, off_heap)
    ),
    Opts = key_value:put(message_queue_data, Value, Opts0),
    bondy_config:set([registry, partition_spawn_opts], Opts).

configure_jobs_pool() ->
    %% Configure partition count
    KeyPath = [jobs_pool, size],

    case bondy_config:get(KeyPath, undefined) of
        undefined ->
            N = min(16, erlang:system_info(schedulers)),
            bondy_config:set(KeyPath, N),
            ok;
        _ ->
            ok
    end.

%% @private
%% The HTTP-transport settings the schema cannot default on its own.
%% `partitions' has no `{default, ...}' because its default is the scheduler
%% count, which is not knowable when the schema is written; the rest are seeded
%% here so an embedded caller or a `sys.config' that skips cuttlefish still gets
%% a complete block, and every one of them is read with `bondy_config:get/2'
%% carrying the same value again at the point of use.
%%
%% `overflow_strategy' is NOT here any more. It was seeded and never read: the
%% eviction it named is unconditional in
%% `bondy_http_transport_queue:do_enqueue/3', and its enum admitted one value.
configure_http_transport() ->
    Defaults = [
        {[http_transport, idle_timeout], 3600000},
        {[http_transport, queue, max_messages], 1000},
        {[http_transport, queue, max_bytes], 10485760},
        {[http_transport, queue, message_ttl], 300000},
        {[http_transport, queue, eviction_interval], 5000},
        {[http_transport, queue, partitions], erlang:system_info(schedulers)}
    ],
    lists:foreach(
        fun({KeyPath, Default}) ->
            case bondy_config:get(KeyPath, undefined) of
                undefined -> bondy_config:set(KeyPath, Default);
                _ -> ok
            end
        end,
        Defaults
    ),
    ok.

%% @private
apply_private_config({error, Reason}) ->
    exit(Reason);
apply_private_config({ok, Config}) ->
    ?LOG_DEBUG(#{description => "Bondy private configuration started"}),
    try
        _ = [
            ok = application:set_env(App, Param, Val)
         || {App, Params} <- Config, {Param, Val} <- Params
        ],
        ?LOG_NOTICE("Bondy private configuration initialised"),
        ok
    catch
        error:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description =>
                    "Error while applying private configuration options",
                reason => Reason,
                stacktrace => Stacktrace
            }),
            exit(Reason)
    end.

%% @private
with_ip(undefined, SocketOpts) -> SocketOpts;
with_ip(Ip, SocketOpts) -> key_value:put(ip, Ip, SocketOpts).

%% @private
%% The per-listener `tls` block is where a listener declares its certificate.
%% It has to reach ranch's socket options, not just the validation in
%% `bondy_listener_config:assert_tls_keys/3` — otherwise a listener passes its
%% certificate check and then fails to bind with `no_cert`.
%%
%% The block wins over anything of the same name in `socket_opts`, matching the
%% precedence `bondy_listener_config:tls_material/3` uses, so validation and
%% binding cannot disagree about which certificate is in force. `certfile`,
%% `keyfile`, `cacertfile`, `versions` and `verify` are already the names and
%% value shapes ssl expects, so nothing is translated here.
with_tls_material(Name, SocketOpts) ->
    maps:fold(
        fun(K, V, Acc) -> lists:keystore(K, 1, Acc, {K, V}) end,
        SocketOpts,
        key_value:to_map(get([Name, tls], #{}))
    ).

%% @private
-spec normalise_socket_opts(SocketOpts :: [{atom(), any()}]) ->
    SocketOpts :: [atom() | {atom(), any()}].

normalise_socket_opts(SocketOpts0) ->
    %% We normlise the buffer option
    SocketOpts1 = normalise_socket_buffer(SocketOpts0),

    %% We default to listen on any i.e. 0.0.0.0 or :: depending on IPVer
    IP0 = key_value:get(ip, SocketOpts1, any),
    %% `inet` rather than `any`, because `any` is not a family:
    %% `bondy_utils:get_ipaddr/2` has clauses for `(any, inet)` and
    %% `(any, inet6)` but none for `(any, any)`, so an absent `ip_version` used
    %% to raise `function_clause` here — naming no listener — instead of
    %% listening on 0.0.0.0.
    %%
    %% `listeners.$name.ip_version` carries no default and, being a fuzzy
    %% mapping, cannot — so the key is absent for every listener that did not
    %% state it, which is what this fallback covers.
    %%
    %% Note the precedence this establishes: `get_ipaddr_family/2` below derives
    %% the family from the ARITY of the resolved address, so a configured
    %% address always wins and `ip_version` decides only which wildcard an
    %% address-less listener binds.
    {Family0, SocketOpts2} = take(ip_version, SocketOpts1, inet),
    {IP, Family} = bondy_utils:get_ipaddr_family(IP0, Family0),
    SocketOpts3 = key_value:put(ip, IP, SocketOpts2),

    %% This is for non-HTTP listeners. For HTTP we have the linger_timeout
    %% option at the ProtoOpts
    SocketOpts =
        case take(linger_timeout, SocketOpts3, undefined) of
            {undefined, SocketOpts4} ->
                SocketOpts4;
            {-1, SocketOpts4} ->
                Linger = {false, 0},
                key_value:put(linger, Linger, SocketOpts4);
            {Timeout, SocketOpts4} ->
                Linger = {true, Timeout},
                key_value:put(linger, Linger, SocketOpts4)
        end,

    [Family | SocketOpts].

%% @private
-spec normalise_socket_buffer([{atom(), any()}]) -> [{atom(), any()}].

normalise_socket_buffer([]) ->
    [];
normalise_socket_buffer(Opts) when is_list(Opts) ->
    Sndbuf = key_value:get(sndbuf, Opts, 0),
    Recbuf = key_value:get(recbuf, Opts, 0),

    case Sndbuf > 0 andalso Recbuf > 0 of
        true ->
            Buffer0 = key_value:get(buffer, Opts, 0),
            Buffer1 = max(Buffer0, max(Sndbuf, Recbuf)),
            key_value:put(buffer, Buffer1, Opts);
        false ->
            Opts
    end.

take(Key, KV0, Default) ->
    case key_value:take(Key, KV0) of
        error ->
            {Default, KV0};
        {_, _} = Result ->
            Result
    end.
