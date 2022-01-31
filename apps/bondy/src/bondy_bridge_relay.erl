%% =============================================================================
%%  bondy_bridge_relay_listener.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
%% A permanent bridge is always restarted, even after a node crash.
%% A transient bridge is restarted only if it terminated
%% abnormally. In case of a node crash they will not be restarted.
%% A temporary bridge is never restarted, not even after
%% recovering from a node crash.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_bridge_relay).

-include_lib("wamp/include/wamp.hrl").
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
            permanent, transient, temporary,
            <<"permanent">>, <<"transient">>, <<"temporary">>
        ]},
        validator => fun
            (permanent) -> true;
            (transient) -> true;
            (temporary) -> true;
            (<<"permanent">>) -> {ok, permanent};
            (<<"transient">>) -> {ok, transient};
            (<<"temporary">>) -> {ok, temporary};
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
    reconnect => #{
        alias => <<"reconnect">>,
        required => true,
        default => #{},
        validator => ?RECONNECT_SPEC
    },
    ping => #{
        alias => <<"ping">>,
        required => true,
        default => #{},
        validator => ?PING_SPEC
    },
    %% Client opts!
    tls_opts => #{
        alias => <<"tls_opts">>,
        required => true,
        default => #{},
        validator => ?TLS_OPTS_SPEC
    },
    socket_opts => #{
        alias => <<"socket_opts">>,
        required => true,
        default => #{},
        validator => ?SOCKET_OPTS_SPEC
    },
    timeout => #{
        alias => <<"timeout">>,
        required => true,
        default => timer:seconds(5),
        datatype => timeout
    },
    idle_timeout => #{
        alias => <<"idle_timeout">>,
        required => true,
        default => timer:hours(24),
        datatype => timeout
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
        validator => {list, ?REALM_SPEC}
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
    versions => #{
        alias => <<"versions">>,
        required => true,
        default => 'tlsv1.3',
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
    interval => #{
        alias => <<"interval">>,
        required => true,
        default => timer:seconds(30),
        datatype => pos_integer
    },
    max_retries => #{
        alias => <<"max_retries">>,
        required => true,
        default => 3,
        datatype => [integer, {in, [infinity, <<"infinity">>]}],
        validator => fun
            (X) when is_integer(X) -> X > 0;
            (infinity) -> infinity;
            (<<"infinity">>) -> {ok, infinity};
            (_) -> false
        end
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
        validator => {list, ?ACTION_SPEC}

    },
    topics => #{
        alias => <<"topics">>,
        required => true,
        default => [],
        validator => {list, ?ACTION_SPEC}
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
        default => ?EXACT_MATCH,
        datatype => {in, ?MATCH_STRATEGIES}
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
                {ok, both}
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
-type restart()     ::  permanent | transient | temporary.
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
-export([forward/2]).
-export([list/0]).
-export([lookup/1]).
-export([new/1]).
-export([remove/1]).
-export([exists/1]).



%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec forward(Ref :: bondy_ref:t(), Msg :: any()) ->
    ok.

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
-spec add(t()) -> ok | {error, already_exists}.

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




%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
type_and_version(Map) ->
    Map#{
        version => ?VERSION,
        type => ?TYPE
    }.