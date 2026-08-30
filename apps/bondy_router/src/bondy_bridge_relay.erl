%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_bridge_relay).
-moduledoc """
Bridge relays: the configuration of an outbound connection from this node to
another Bondy router.

A bridge relay carries a realm's traffic across a router boundary — the local
node opens a client connection to a remote router and forwards the messages the
bridge's subscriptions and registrations name. This module owns the
configuration record; `bondy_bridge_relay_manager` runs the bridges and
`bondy_bridge_relay_client` is the connection itself.

**A bridge belongs to one node, not to the cluster.** Each configuration names
the node that runs it, and a node starts only its own bridges. Two nodes cannot
run the same bridge, and a bridge whose node is down does not migrate.

## Restart policy

`restart` says when a terminated bridge is started again.

- `permanent` — always restarted, including after a node crash or a manual
  stop and start. A permanent bridge's configuration is persisted here and read
  back at startup.
- `transient` — restarted only after an abnormal termination. It does not
  survive a node restart.

Bridges declared in `bondy.conf` are transient, because that file re-declares
them on every boot; a bridge created through the API defaults to transient for
the same reason.

## Storage

Each bridge is one cell of the durable `bondy_bridge_relay` table, keyed by
bridge name in a single global band — bridge names are cluster-wide, not
per-realm. Deleting a bridge clears its cell, and a later `add/1` under the same
name creates it afresh rather than reviving what was there.
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-define(TYPE, bridge_relay).
-define(VERSION, <<"1.0">>).
%% Permanent bridge configs live in the bondy_db `bondy_bridge_relay` main
%% table. The store is a flat, name-keyed keyspace, so a single fixed bucket is
%% used. The bridge map
%% is stored directly in an `lww_register` cell (the substrate serialises terms;
%% no manual encoding); `clear` deletes (non-terminal, so a later `add`
%% reanimates). The catalogue (`bondy_namespace_catalog`) provisions the table.
-define(BUCKET, <<>>).

-define(BRIDGE_RELAY_SPEC, #{
    name => #{
        alias => <<"name">>,
        required => true,
        datatype => binary
    },
    enabled => #{
        alias => <<"enabled">>,
        required => true,
        default => false,
        datatype => boolean
    },
    restart => #{
        alias => <<"restart">>,
        required => true,
        %% All bondy.conf configured bridges are transient, as they will be
        %% re-configured on restart, so we default all the dynamically created
        %% to transient too.
        default => transient,
        datatype =>
            {in, [
                permanent,
                transient,
                <<"permanent">>,
                <<"transient">>
            ]},
        validator => fun
            (permanent) -> true;
            (transient) -> true;
            (<<"permanent">>) -> {ok, permanent};
            (<<"transient">>) -> {ok, transient};
            (_) -> false
        end
    },
    endpoint => #{
        alias => <<"endpoint">>,
        required => true,
        validator => fun bondy_data_validators:endpoint/1
    },
    transport => #{
        alias => <<"transport">>,
        required => true,
        default => tcp,
        datatype => {in, [tcp, tls, <<"tcp">>, <<"tls">>]},
        validator => fun
            (tcp) -> true;
            (tls) -> true;
            (<<"tcp">>) -> {ok, tcp};
            (<<"tls">>) -> {ok, tls};
            (_) -> false
        end
    },
    connect_timeout => #{
        alias => <<"connect_timeout">>,
        required => true,
        default => timer:seconds(5),
        datatype => [integer, {in, [infinity, <<"infinity">>]}],
        validator => fun
            (X) when is_integer(X) -> X > 0;
            (infinity) -> true;
            (<<"infinity">>) -> {ok, infinity};
            (_) -> false
        end
    },
    network_timeout => #{
        alias => <<"network_timeout">>,
        required => true,
        default => timer:seconds(30),
        datatype => [integer, {in, [infinity, <<"infinity">>]}],
        validator => fun
            (X) when is_integer(X) -> X > 0;
            (infinity) -> true;
            (<<"infinity">>) -> {ok, infinity};
            (_) -> false
        end
    },
    idle_timeout => #{
        alias => <<"idle_timeout">>,
        required => true,
        default => timer:hours(24),
        datatype => [integer, {in, [infinity, <<"infinity">>]}],
        validator => fun
            (X) when is_integer(X) -> X > 0;
            (infinity) -> true;
            (<<"infinity">>) -> {ok, infinity};
            (_) -> false
        end
    },
    hibernate => #{
        alias => <<"hibernate">>,
        required => true,
        default => idle,
        datatype => [atom, binary],
        validator => fun
            (X) when X == never; X == idle; X == always ->
                true;
            (X) when X == <<"never">>; X == <<"idle">>; X == <<"always">> ->
                true;
            (_) ->
                false
        end
    },
    reconnect => #{
        alias => <<"reconnect">>,
        required => true,
        %% Filled from its own spec, for the reason given on `ping' below. This
        %% one did not crash — `bondy_bridge_relay_client:maybe_enable_reconnect/2'
        %% HAS a fall-through clause — it did something quieter: a bridge that
        %% configured no `reconnect' block reached that clause and never
        %% reconnected at all, though this spec has said `enabled => true' with
        %% 100 retries the whole time.
        default => fun() -> maps_utils:validate(#{}, ?RECONNECT_SPEC) end,
        validator => begin
            ?RECONNECT_SPEC
        end
    },
    ping => #{
        alias => <<"ping">>,
        required => true,
        %% The FILLED block, not `#{}'. `maps_utils' returns a key's default as
        %% it is written and does NOT run the key's own `validator' spec over it
        %% (`maps_utils.erl:865' takes the `error' branch straight to
        %% `maybe_get_default/3'), so `#{}' handed the client a ping map with no
        %% `enabled' and no siblings — and
        %% `bondy_bridge_relay_client:maybe_enable_ping/2' matches only
        %% `enabled := true' and `enabled := false', so it died with
        %% `function_clause' in `init/1'. Every bridge is built here
        %% (`bondy_bridge_relay_manager' for the `bondy.conf' ones,
        %% `bondy_bridge_relay_api' for the rest) and every
        %% `bridge.$name.ping.*' mapping is `commented', so a bridge that says
        %% nothing about ping took that path.
        %%
        %% Validating an empty map against the same spec is what makes the four
        %% documented defaults apply, and keeps them written down once. A partial
        %% block was never affected: a PRESENT key does run its spec, so its
        %% siblings were always filled in.
        default => fun() -> maps_utils:validate(#{}, ?PING_SPEC) end,
        validator => begin
            ?PING_SPEC
        end
    },
    %% Client opts!
    %% Deliberately NOT filled from `?TLS_OPTS_SPEC', unlike its three siblings.
    %% That spec defaults `versions' to `['tlsv1.3']' alone, so filling this
    %% block would pin every bridge that states no TLS options to TLS 1.3 and
    %% drop connections to a peer that offers only 1.2 — a narrowing, arriving
    %% through a key nobody wrote. What is written here is what such a bridge has
    %% always been given, and `ssl' decides the versions.
    %%
    %% The cost is that a default added to `?TLS_OPTS_SPEC' will not reach a
    %% bridge that configures no `tls_opts', which is exactly the trap the other
    %% three now avoid. It is accepted here, once, in exchange for not changing
    %% what a TLS bridge negotiates.
    tls_opts => #{
        alias => <<"tls_opts">>,
        required => true,
        default => #{
            verify => verify_none
        },
        validator => begin
            ?TLS_OPTS_SPEC
        end
    },
    %% Filled from its spec. Unlike `tls_opts' this one is value-preserving —
    %% `keepalive' and `nodelay' are the only defaulted keys and both were
    %% already written out here — so it costs nothing and gains the same
    %% property `ping' and `reconnect' now have.
    socket_opts => #{
        alias => <<"socket_opts">>,
        required => true,
        default => fun() -> maps_utils:validate(#{}, ?SOCKET_OPTS_SPEC) end,
        validator => begin
            ?SOCKET_OPTS_SPEC
        end
    },
    parallelism => #{
        alias => <<"parallelism">>,
        required => true,
        default => 1,
        datatype => pos_integer
    },
    max_frame_size => #{
        alias => <<"max_frame_size">>,
        required => true,
        %% Harmonised with the other carriers, all 4194304
        %% (`websocket.max_frame_size`, `mcp.max_body_size`,
        %% `longpoll.max_body_size`, and the RawSocket handshake ceiling).
        %% This was `infinity`, which made a bridged peer the only ingress on
        %% the node with no frame bound at all. A bridge relay is
        %% cryptosign-authenticated, so this is not a pre-auth surface -- but
        %% "authenticated" is not "trusted to size its own frames", and an
        %% operator who genuinely relays larger payloads can raise it per
        %% bridge.
        default => 4194304,
        datatype => [integer, {in, [infinity, <<"infinity">>]}],
        validator => fun
            (X) when is_integer(X) -> X > 0;
            (infinity) -> true;
            (<<"infinity">>) -> {ok, infinity};
            (_) -> false
        end
    },
    realms => #{
        alias => <<"realms">>,
        required => true,
        validator =>
            {list, begin
                ?REALM_SPEC
            end}
    }
}).

-define(TLS_OPTS_SPEC, #{
    cacertfile => #{
        alias => <<"cacertfile">>,
        required => false,
        datatype => list
    },
    certfile => #{
        alias => <<"certfile">>,
        required => false,
        datatype => list
    },
    keyfile => #{
        alias => <<"keyfile">>,
        required => false,
        datatype => list
    },
    verify => #{
        alias => <<"verify">>,
        required => true,
        default => verify_none,
        datatype =>
            {in, [
                verify_peer,
                verify_none,
                <<"verify_peer">>,
                <<"verify_none">>
            ]},
        validator => fun
            (verify_peer) -> true;
            (verify_none) -> true;
            (<<"verify_peer">>) -> {ok, verify_peer};
            (<<"verify_none">>) -> {ok, verify_none};
            (_) -> false
        end
    },
    hostname_verification => #{
        alias => <<"hostname_verification">>,
        %% We rename the prop
        key => customize_hostname_check,
        required => false,
        datatype =>
            {in, [
                wildcard,
                none,
                <<"wildcard">>,
                <<"none">>
            ]},
        validator => fun
            (V) when V == <<"wildcard">>; V == wildcard ->
                %% tls_options will end up having
                %% #{
                %%  ...
                %%  customize_hostname_check => [{match_fun, Match}]
                %% }
                Match = public_key:pkix_verify_hostname_match_fun(https),
                {ok, [{match_fun, Match}]};
            (_) ->
                {ok, []}
        end
    },
    versions => #{
        alias => <<"versions">>,
        required => true,
        default => ['tlsv1.3'],
        datatype =>
            {list,
                {in, [
                    'tlsv1.2',
                    'tlsv1.3',
                    <<"tlsv1.2">>,
                    <<"tlsv1.3">>,
                    <<"1.2">>,
                    <<"1.3">>
                ]}},
        validator => fun bondy_data_validators:tls_versions/1
    }
}).

-define(RECONNECT_SPEC, #{
    enabled => #{
        alias => <<"enabled">>,
        required => true,
        default => true,
        datatype => boolean
    },
    max_retries => #{
        alias => <<"max_retries">>,
        required => true,
        default => 100,
        datatype => pos_integer
    },
    backoff_type => #{
        alias => <<"backoff_type">>,
        required => true,
        default => jitter,
        datatype =>
            {in, [
                'jitter',
                'normal',
                <<"jitter">>,
                <<"normal">>
            ]},
        validator => fun
            (jitter) -> true;
            (normal) -> true;
            (<<"jitter">>) -> {ok, jitter};
            (<<"normal">>) -> {ok, normal};
            (_) -> false
        end
    },
    backoff_min => #{
        alias => <<"backoff_min">>,
        required => true,
        default => timer:seconds(5),
        datatype => pos_integer
    },
    backoff_max => #{
        alias => <<"backoff_max">>,
        required => true,
        default => timer:seconds(60),
        datatype => pos_integer
    }
}).

-define(PING_SPEC, #{
    enabled => #{
        alias => <<"enabled">>,
        required => true,
        default => true,
        datatype => boolean
    },
    idle_timeout => #{
        alias => <<"idle_timeout">>,
        required => true,
        default => timer:seconds(20),
        datatype => [integer, {in, [infinity, <<"infinity">>]}],
        validator => fun
            (X) when is_integer(X) -> X > 0;
            (infinity) -> true;
            (<<"infinity">>) -> {ok, infinity};
            (_) -> false
        end
    },
    timeout => #{
        alias => <<"timeout">>,
        required => true,
        default => timer:seconds(10),
        datatype => pos_integer
    },
    %% 3, matching every listener's `ping.max_attempts'
    %% (`bondy_listener_config:option_defaults/2' for a raw-socket or
    %% bridge-relay listener, `wamp.websocket.ping.max_attempts' for a WebSocket
    %% one). How many unanswered probes mean a dead peer is one judgement, and
    %% this end of a bridge has no reason to make it differently from the end
    %% that accepts the connection. It shipped 2 while the schema's own commented
    %% example showed 3.
    max_attempts => #{
        alias => <<"max_attempts">>,
        required => true,
        default => 3,
        datatype => pos_integer
    }
}).

-define(REALM_SPEC, #{
    uri => #{
        alias => <<"uri">>,
        required => true,
        validator => fun bondy_data_validators:realm_uri/1
    },
    authid => #{
        alias => <<"authid">>,
        required => true,
        validator => fun bondy_data_validators:username/1
    },
    cryptosign => #{
        alias => <<"cryptosign">>,
        required => true,
        validator => #{
            pubkey => #{
                alias => <<"pubkey">>,
                required => true,
                datatype => binary
            },
            procedure => #{
                alias => <<"procedure">>,
                required => false,
                validator => fun
                    (Mod) when is_atom(Mod) ->
                        true;
                    (Mod) when is_binary(Mod) ->
                        try binary_to_existing_atom(Mod) of
                            Val -> {ok, Val}
                        catch
                            _:_ -> false
                        end
                end
            },
            exec => #{
                alias => <<"exec">>,
                required => false,
                validator => fun
                    (Name) when is_list(Name) ->
                        true;
                    (Name) when is_binary(Name) ->
                        {ok, binary_to_list(Name)}
                end
            },
            %% For testing only, this will be removed on 1.0.0
            privkey => #{
                alias => <<"privkey">>,
                required => false,
                datatype => binary
            },
            privkey_env_var => #{
                alias => <<"privkey_env_var">>,
                required => false,
                validator => fun
                    (Name) when is_list(Name) ->
                        true;
                    (Name) when is_binary(Name) ->
                        {ok, binary_to_list(Name)}
                end
            }
        }
    },
    procedures => #{
        alias => <<"procedures">>,
        required => true,
        default => [],
        validator => begin
            {list, ?PROCEDURE_ACTION_SPEC}
        end
    },
    topics => #{
        alias => <<"topics">>,
        required => true,
        default => [],
        validator => begin
            {list, ?TOPIC_ACTION_SPEC}
        end
    }
}).

-define(ACTION_SPEC, #{
    uri => #{
        alias => <<"uri">>,
        required => true,
        datatype => binary
    },
    match => #{
        alias => <<"match">>,
        required => false,
        default => begin
            ?EXACT_MATCH
        end,
        datatype => begin
            {in, ?MATCH_STRATEGIES}
        end
    },
    direction => #{
        alias => <<"direction">>,
        required => true,
        default => out,
        validator => fun
            (in) ->
                true;
            (out) ->
                true;
            (both) ->
                true;
            ("in") ->
                {ok, in};
            ("out") ->
                {ok, out};
            ("both") ->
                {ok, both};
            (<<"in">>) ->
                {ok, in};
            (<<"out">>) ->
                {ok, out};
            (<<"both">>) ->
                {ok, both};
            (_) ->
                false
        end
    }
}).

-define(TOPIC_ACTION_SPEC, begin
    ?ACTION_SPEC
end#{}).

-define(PROCEDURE_ACTION_SPEC, begin
    ?ACTION_SPEC
end#{
    registration => #{
        alias => <<"registration">>,
        required => false,
        validator => fun
            (static) ->
                true;
            (dynamic) ->
                true;
            ("static") ->
                {ok, static};
            ("dynamic") ->
                {ok, dynamic};
            (<<"static">>) ->
                {ok, static};
            (<<"dynamic">>) ->
                {ok, dynamic};
            (_) ->
                false
        end
    }
}).

-type t() :: #{
    name := binary(),
    nodestring := binary(),
    enabled := boolean(),
    restart := restart(),
    endpoint := endpoint(),
    transport := tcp | tls,
    reconnect := reconnect(),
    ping := ping(),
    tls_opts := tls_opts(),
    timeout := timeout(),
    idle_timeout := timeout(),
    parallelism := pos_integer(),
    max_frame_size := pos_integer() | infinity,
    realms := [realm()]
}.

-type endpoint() :: {
    inet:ip_address() | inet:hostname(),
    inet:port_number()
}.
-type restart() :: permanent | transient.
-type realm() :: #{}.
-type reconnect() :: #{}.
-type ping() :: #{}.
-type tls_opts() :: #{
    cacertfile := file:filename_all(),
    certfile := file:filename_all(),
    keyfile := file:filename_all(),
    %% `ssl` exports neither `verify_type/0` nor `tls_version/0` (checked
    %% against OTP 28's own export_type list), so both specs were vacuous.
    verify := verify_none | verify_peer,
    versions := [ssl:protocol_version()]
}.

-export_type([t/0]).

% -export([fetch/1]).
% -export([update/1]).
-export([add/1]).
-export([exists/1]).
-export([forward/2]).
-export([list/0]).
-export([lookup/1]).
-export([new/1]).
-export([remove/1]).
-export([to_external/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Forwards `Msg` over the bridge connections `Ref` names, which may be a single
reference or a list of them.

Delivery is best-effort: the message is handed to each bridge's client process,
and a bridge that is not running silently receives nothing.
""".
-spec forward(Ref :: bondy_ref:t() | [bondy_ref:t()], Msg :: any()) ->
    ok.

forward([], _) ->
    ok;
forward([H | T], Msg) ->
    ok = forward(H, Msg),
    forward(T, Msg);
forward(Ref, Msg) ->
    bondy_bridge_relay_client:forward(Ref, Msg).

-doc """
Returns a validated bridge relay configuration built from `Data`.

`name` and `endpoint` are required; the rest — transport, timeouts, reconnect
policy and `restart` — take defaults. Raises on invalid input. The result is not
persisted; pass it to `add/1`.
""".
-spec new(Data :: map()) -> t() | no_return().

new(Data) ->
    type_and_version(maps_utils:validate(Data, ?BRIDGE_RELAY_SPEC)).

-doc """
Persists bridge `Bridge`, or returns `{error, already_exists}` when a bridge of
that name is already configured.

**The calling node becomes the bridge's owner**: its nodestring is stamped into
the stored configuration, and only that node will run the bridge. Persisting a
configuration does not start it — the owning node's manager reads the table at
startup — so a bridge added to a running node takes effect when that node next
starts.
""".
-spec add(t()) -> ok | {error, already_exists | any()}.

add(#{type := ?TYPE, name := Name} = Bridge0) ->
    case exists(Name) of
        true ->
            {error, already_exists};
        false ->
            Bridge = Bridge0#{nodestring => bondy_config:nodestring()},
            bondy_db:apply(table(), ?BUCKET, Name, {set, Bridge})
    end.

-doc """
Removes the configuration of bridge `Name`, so its owning node no longer starts
it. Removing a bridge that does not exist succeeds.

This is a configuration change, not a disconnect: a bridge already running keeps
running until its node restarts.
""".
-spec remove(Name :: binary()) -> ok.

remove(Name) ->
    ok = bondy_db:apply(table(), ?BUCKET, Name, clear),
    ok.

-doc "Whether a bridge named `Name` is configured, on any node.".
-spec exists(Name :: binary()) -> boolean().

exists(Name) ->
    case lookup(Name) of
        {ok, _} -> true;
        {error, not_found} -> false
    end.

-doc "Returns the configuration of bridge `Name`, or `{error, not_found}`.".
-spec lookup(Name :: binary()) -> {ok, t()} | {error, not_found}.

lookup(Name) ->
    case bondy_db:read(table(), ?BUCKET, Name) of
        {ok, {Value, _Hlc}} when is_map(Value) ->
            {ok, Value};
        {error, not_found} ->
            {error, not_found}
    end.

-doc """
Returns every configured bridge, of every node — the table is a single global
keyspace rather than one per node.
""".
-spec list() -> [t()].

list() ->
    {ok, Rows} = bondy_db:list(table(), ?BUCKET),
    [Value || {_Name, Value, _Hlc} <- Rows, is_map(Value)].

-doc """
Returns `Bridge` in its API representation, with the endpoint rendered as
`host:port` rather than the `{Host, Port}` pair used internally.
""".
-spec to_external(Bridge :: t()) -> map().

to_external(Bridge) ->
    {Host, Port} = maps:get(endpoint, Bridge),
    Endpoint = <<
        (list_to_binary(Host))/binary,
        $:,
        (integer_to_binary(Port))/binary
    >>,

    Bridge#{
        endpoint => Endpoint
    }.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The open bondy_db `bondy_bridge_relay` table handle. Raises if the catalogue
%% has not provisioned it — the table is a hard dependency. The catalogue
%% (a `bondy_sup` child) opens it before `bondy_bridge_relay_manager` (a later
%% child) reads bridge config at boot.
table() ->
    case bondy_namespace_catalog:table(bondy_bridge_relay) of
        undefined -> error(bridge_relay_table_unavailable);
        Table -> Table
    end.

%% @private
type_and_version(Map) ->
    Map#{
        version => ?VERSION,
        type => ?TYPE
    }.
