%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_config).

-moduledoc """
Validates and normalises a connection spec into the internal config map
consumed by `bondy_connect_protocol` (and, later, the transport/connection
layers).

This phase validates the **protocol-relevant** fields strictly — `realm`
(a valid WAMP URI), `roles`, `agent`, and `auth` — and supplies defaults for
the transport-related fields (`transport`, `serializers`, `reconnect`, `ping`,
`max_message_length`, `handler`, `tls`) which are exercised in later phases. TLS
defaults are secure-by-default (`verify_peer`).
""".

-include("bondy_connect.hrl").

%% The advanced-profile features the client actually implements. The rule
%% is **advertise == handle**: we only claim a feature whose behaviour the
%% client honours. `progressive_call_results` is advertised for both RPC
%% roles: as caller via `call_async/5` with `receive_progress => true`
%% ({progress, Payload} deliveries before the terminal reply), as callee
%% via the `progress` fun injected into the handler details. Note the WAMP
%% spec pairs it with `call_canceling`, which both roles announce.
%% `progressive_calls` (caller-side argument streaming) is likewise advertised
%% for both roles: as caller via `call_stream/5` + `send_input`/`finish_input`,
%% as callee via the `input` fun injected into the handler details.
-define(DEFAULT_ROLES, #{
    caller => #{
        features => #{
            call_timeout => true,
            call_canceling => true,
            caller_identification => true,
            call_retries => true,
            progressive_call_results => true,
            progressive_calls => true
        }
    },
    callee => #{
        features => #{
            call_canceling => true,
            caller_identification => true,
            pattern_based_registration => true,
            shared_registration => true,
            registration_revocation => true,
            progressive_call_results => true,
            progressive_calls => true
        }
    },
    publisher => #{
        features => #{
            publisher_identification => true,
            publisher_exclusion => true,
            subscriber_blackwhite_listing => true
        }
    },
    subscriber => #{
        features => #{
            pattern_based_subscription => true,
            publisher_identification => true
        }
    }
}).

-define(DEFAULT_SERIALIZERS, [json]).
%% 16 MB
-define(DEFAULT_MAX_MESSAGE_LENGTH, 16777216).

%% Resilient by default: a dropped session is re-established with a
%% bounded, backed-off retry budget. `retry_initial_connect` (default `false`)
%% keeps `connect/1` fail-fast on the *first* attempt — backoff/replay only kick
%% in once a session has established at least once. Set it `true` to also retry
%% the initial connect.
-define(DEFAULT_RECONNECT, #{
    enabled => true,
    retry_initial_connect => false,
    max_retries => 10,
    interval => 3000,
    deadline => 60000,
    backoff_enabled => true,
    backoff_min => 1000,
    backoff_max => 60000
}).

%% Idle keepalive (raw-socket ping/pong). After `idle_timeout` ms of silence the
%% client pings; `max_attempts` unanswered pings (each waiting `timeout` ms)
%% tears the link down and triggers reconnect.
-define(DEFAULT_PING, #{
    enabled => true,
    idle_timeout => 30000,
    timeout => 10000,
    max_attempts => 3
}).

%% How long to wait in `waiting_for_network` for the network to recover before
%% giving up (only used when partisan network monitoring is available).
-define(DEFAULT_NETWORK_TIMEOUT, 60000).

-export([validate/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Validate and normalise a connection `Spec`. Returns the normalised config map
on success.
""".
-spec validate(Spec :: map()) -> {ok, map()} | {error, term()}.

validate(Spec) when is_map(Spec) ->
    try
        Realm = validate_realm(Spec),
        Auth = validate_auth(Spec),
        Config = #{
            realm => Realm,
            roles => maps:get(roles, Spec, ?DEFAULT_ROLES),
            agent => validate_agent(Spec),
            auth => Auth,
            serializers => maps:get(serializers, Spec, ?DEFAULT_SERIALIZERS),
            transport => maps:get(transport, Spec, tcp),
            endpoint => maps:get(endpoint, Spec, undefined),
            ws_path => maps:get(ws_path, Spec, <<"/ws">>),
            %% `validate/1' builds a CLOSED map, so a key absent from here
            %% never reaches the transport at all — silently, with the
            %% transport's own default applying instead. That is how
            %% `longpoll_path` was ignored while a case believed it was
            %% dialling a bad path, and the connection established normally
            %% against the real endpoint.
            longpoll_path =>
                maps:get(longpoll_path, Spec, <<"/wamp/longpoll">>),
            longpoll_poll_timeout =>
                maps:get(longpoll_poll_timeout, Spec, 60000),
            sse_path => maps:get(sse_path, Spec, <<"/wamp/sse">>),
            max_message_length =>
                maps:get(max_message_length, Spec, ?DEFAULT_MAX_MESSAGE_LENGTH),
            handler => validate_handler(Spec),
            reconnect => validate_reconnect(Spec),
            ping => validate_ping(Spec),
            network_timeout => validate_network_timeout(Spec),
            tls => validate_tls(Spec)
        },
        {ok, Config}
    catch
        throw:Reason ->
            {error, Reason}
    end;
validate(_) ->
    {error, invalid_spec}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
validate_realm(#{realm := Realm}) when is_binary(Realm) ->
    try
        bondy_wamp_uri:validate(Realm)
    catch
        _:_ ->
            throw({invalid_realm, Realm})
    end;
validate_realm(_) ->
    throw(missing_realm).

%% @private
validate_agent(#{agent := Agent}) when is_binary(Agent) ->
    Agent;
validate_agent(#{agent := _}) ->
    throw({invalid_agent, not_a_binary});
validate_agent(_) ->
    ?BONDY_CONNECT_AGENT.

%% @private
%% Default to anonymous when no auth is configured.
validate_auth(#{auth := #{method := Method} = Auth}) when is_binary(Method) ->
    case lists:member(Method, methods()) of
        true ->
            Auth;
        false ->
            throw({unsupported_authmethod, Method})
    end;
validate_auth(#{auth := #{}}) ->
    throw(missing_authmethod);
validate_auth(#{auth := _}) ->
    throw(invalid_auth);
validate_auth(_) ->
    #{method => ?WAMP_ANON_AUTH}.

%% @private
%% Merge the user's reconnect map over the bounded defaults and validate.
validate_reconnect(Spec) ->
    merge_validate(reconnect, Spec, ?DEFAULT_RECONNECT, fun(K, V) ->
        case K of
            enabled -> is_boolean(V) orelse bad(reconnect, K, V);
            retry_initial_connect -> is_boolean(V) orelse bad(reconnect, K, V);
            backoff_enabled -> is_boolean(V) orelse bad(reconnect, K, V);
            _ -> is_non_neg_int(V) orelse bad(reconnect, K, V)
        end
    end).

%% @private
validate_ping(Spec) ->
    merge_validate(ping, Spec, ?DEFAULT_PING, fun(K, V) ->
        case K of
            enabled -> is_boolean(V) orelse bad(ping, K, V);
            _ -> is_pos_int(V) orelse bad(ping, K, V)
        end
    end).

%% @private Validate the optional `handler' load-regulation config,
%% consumed by `bondy_connect_load:new/1'. Recognised keys:
%%
%% - `max_concurrency' — the per-connection in-flight cap (non-neg int; `0' =
%%   unlimited).
%% - `rate' — a `bondy_regulator_rate_limit' token-bucket spec (a map; its
%%   contents are validated by the regulator when the bucket is built).
%%
%% Both are optional; an absent `handler' means unlimited concurrency and no rate
%% limit. Unknown keys are rejected so typos surface early.
validate_handler(#{handler := H}) when is_map(H) ->
    _ = maps:foreach(
        fun
            (max_concurrency, V) ->
                is_non_neg_int(V) orelse bad(handler, max_concurrency, V);
            (rate, V) ->
                is_map(V) orelse bad(handler, rate, V);
            (K, _V) ->
                throw({unknown_option, handler, K})
        end,
        H
    ),
    H;
validate_handler(#{handler := Other}) ->
    throw({invalid_option, handler, Other});
validate_handler(_) ->
    #{}.

%% @private
validate_network_timeout(#{network_timeout := T}) when is_integer(T), T > 0 ->
    T;
validate_network_timeout(#{network_timeout := T}) ->
    throw({invalid_network_timeout, T});
validate_network_timeout(_) ->
    ?DEFAULT_NETWORK_TIMEOUT.

%% @private Merge the user-supplied map (if any) over `Default`, validating each
%% user-supplied value with `ValidateFun`. Unknown keys are rejected so typos
%% surface early rather than being silently ignored.
merge_validate(Key, Spec, Default, ValidateFun) ->
    case maps:get(Key, Spec, #{}) of
        User when is_map(User) ->
            _ = maps:foreach(
                fun(K, V) ->
                    case is_map_key(K, Default) of
                        true ->
                            _ = ValidateFun(K, V),
                            ok;
                        false ->
                            throw({unknown_option, Key, K})
                    end
                end,
                User
            ),
            maps:merge(Default, User);
        Other ->
            throw({invalid_option, Key, Other})
    end.

%% @private
is_non_neg_int(V) -> is_integer(V) andalso V >= 0.

%% @private
is_pos_int(V) -> is_integer(V) andalso V > 0.

%% @private
bad(Group, Key, Value) -> throw({invalid_option, Group, Key, Value}).

%% @private
%% Secure-by-default: when TLS options are not supplied, peer verification is
%% on. Only relevant for tls/wss transports (consumed in later phases).
validate_tls(#{tls := TLS}) when is_map(TLS) ->
    maps:merge(#{verify => verify_peer}, TLS);
validate_tls(#{tls := _}) ->
    throw(invalid_tls);
validate_tls(_) ->
    #{verify => verify_peer}.

%% @private
methods() ->
    [
        ?WAMP_ANON_AUTH,
        ?WAMP_CRA_AUTH,
        ?WAMP_CRYPTOSIGN_AUTH,
        ?WAMP_TICKET_AUTH
    ].
