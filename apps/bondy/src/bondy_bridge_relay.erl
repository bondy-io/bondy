%% =============================================================================
%%  bondy_bridge_relay.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
%% @doc
%% restart defines when a terminated bridge must be restarted.
%% A permanent bridge is always restarted, even after recovering from a Bondy
%% node crash or when the node is manually stopped and re-started. Bondy
%% persists the configuration of permanent bridges in the database and reads
%% them during startup.
%% A transient bridge is restarted only if it terminated abnormally. In case of
%% a node crash or manually stopped and re-started they will not be restarted.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_bridge_relay).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-define(TYPE, bridge_relay).
-define(VERSION, <<"1.0">>).
-define(PLUMDB_PREFIX, {?MODULE, all}).

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
        datatype => {in, [
            permanent, transient,
            <<"permanent">>, <<"transient">>
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
        default => #{},
        validator => begin ?RECONNECT_SPEC end
    },
    ping => #{
        alias => <<"ping">>,
        required => true,
        default => #{},
        validator => begin ?PING_SPEC end
    },
    %% Client opts!
    tls_opts => #{
        alias => <<"tls_opts">>,
        required => true,
        default => #{
            verify => verify_none
        },
        validator => begin ?TLS_OPTS_SPEC end
    },
    socket_opts => #{
        alias => <<"socket_opts">>,
        required => true,
        default => #{
            keepalive => true,
            nodelay => true
        },
        validator => begin ?SOCKET_OPTS_SPEC end
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
        default => infinity,
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
        validator => {list, begin ?REALM_SPEC end}
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
        datatype => {in, [
            verify_peer, verify_none,
            <<"verify_peer">>, <<"verify_none">>
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
        datatype => {in, [
            wildcard, none,
            <<"wildcard">>, <<"none">>
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
        datatype => {list, {in, [
            'tlsv1.2', 'tlsv1.3',
            <<"tlsv1.2">>, <<"tlsv1.3">>,
            <<"1.2">>, <<"1.3">>
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
        datatype => {in, [
            'jitter', 'normal',
            <<"jitter">>, <<"normal">>
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
    max_attempts => #{
        alias => <<"max_attempts">>,
        required => true,
        default => 2,
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
                        case catch binary_to_existing_atom(Mod) of
                            {'EXIT', _} -> false;
                            Val -> {ok, Val}
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
        validator => begin {list, ?PROCEDURE_ACTION_SPEC} end

    },
    topics => #{
        alias => <<"topics">>,
        required => true,
        default => [],
        validator => begin {list, ?TOPIC_ACTION_SPEC} end
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
        default => begin ?EXACT_MATCH end,
        datatype => begin {in, ?MATCH_STRATEGIES} end
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

-define(TOPIC_ACTION_SPEC, begin ?ACTION_SPEC end #{
}).

-define(PROCEDURE_ACTION_SPEC, begin ?ACTION_SPEC end #{
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
    name            :=  binary(),
    nodestring      :=  binary(),
    enabled         :=  boolean(),
    restart         :=  restart(),
    endpoint        :=  endpoint(),
    transport       :=  tcp | tls,
    reconnect       :=  reconnect(),
    ping            :=  ping(),
    tls_opts        :=  tls_opts(),
    timeout         :=  timeout(),
    idle_timeout    :=  timeout(),
    parallelism     :=  pos_integer(),
    max_frame_size  :=  pos_integer() | infinity,
    realms          :=  [realm()]
}.

-type endpoint()    ::  {
                            inet:ip_address() | inet:hostname(),
                            inet:port_number()
                        }.
-type restart()     ::  permanent | transient.
-type realm()       ::  #{}.
-type reconnect()   ::  #{}.
-type ping()        ::  #{}.
-type tls_opts()    ::  #{
    cacertfile      :=  file:filename_all(),
    certfile        :=  file:filename_all(),
    keyfile         :=  file:filename_all(),
    verify          :=  ssl:verify_type(),
    versions        :=  [ssl:tls_version()]
}.

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




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec forward(Ref :: bondy_ref:t() | [bondy_ref:t()], Msg :: any()) ->
    ok.

forward([], _) ->
    ok;

forward([H|T], Msg) ->
    ok = forward(H, Msg),
    forward(T, Msg);

forward(Ref, Msg) ->
    bondy_bridge_relay_client:forward(Ref, Msg).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(Data :: map()) -> t() | no_return().

new(Data) ->
    type_and_version(maps_utils:validate(Data, ?BRIDGE_RELAY_SPEC)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(t()) -> ok | {error, already_exists | any()}.

add(#{type := ?TYPE, name := Name} = Bridge0) ->
    case exists(Name) of
        true ->
            {error, already_exists};
        false ->
            Bridge = Bridge0#{nodestring => bondy_config:nodestring()},
            plum_db:put(?PLUMDB_PREFIX, Name, Bridge)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(Name :: binary()) -> ok.

remove(Name) ->
    plum_db:delete(?PLUMDB_PREFIX, Name).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec exists(Name :: binary()) -> boolean().

exists(Name) ->
    case lookup(Name) of
        {ok, _} -> true;
        {error, not_found} -> false
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(Name :: binary()) -> {ok, t()} | {error, not_found}.

lookup(Name) ->
    case plum_db:get(?PLUMDB_PREFIX, Name) of
        undefined ->
            {error, not_found};
        Value when is_map(Value) ->
            {ok, Value}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list() -> [t()].

list() ->
    PDBOpts = [
        {resolver, lww},
        {remove_tombstones, true}
    ],
    [V || {_, V} <- plum_db:match(?PLUMDB_PREFIX, '_', PDBOpts)].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
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
type_and_version(Map) ->
    Map#{
        version => ?VERSION,
        type => ?TYPE
    }.