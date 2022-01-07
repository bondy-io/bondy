%% =============================================================================
%%  bondy_http_gateway_api_spec_parser.erl - parses the Bondy API Specification file
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
%% This module implements a parser for the Bondy API Specification Format which
%% is used to dynamically define one or more RESTful APIs.
%%
%% The parser uses maps_utils:validate and a number of validation specifications
%% and as a result is its error reporting is not great but does its job.
%% The plan is to replace this with an ad-hoc parser to give the user more
%% useful error information.
%%
%% ## API Specification Format
%%
%% ### Host Spec
%%
%% ### API Spec
%%
%% ### Version Spec
%%
%% ### Path Spec
%%
%% ### Method Spec
%%
%% ### Action Spec
%%
%% ### Action Spec
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_http_gateway_api_spec_parser).
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("http_api.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-define(VARS_KEY, <<"variables">>).
-define(DEFAULTS_KEY, <<"defaults">>).
-define(STATUS_CODES_KEY, <<"status_codes">>).
-define(LANGUAGES_KEY, <<"languages">>).
-define(MOD_PREFIX, "bondy_http_api_gateway_rest_handler_").

-define(DEFAULT_CONN_TIMEOUT, 8000).
-define(DEFAULT_TIMEOUT, 60000).
-define(DEFAULT_RETRIES, 0).
-define(DEFAULT_RETRY_TIMEOUT, 5000).
-define(DEFAULT_ACCEPTS, [<<"application/json">>, <<"application/msgpack">>]).
-define(DEFAULT_PROVIDES, [<<"application/json">>, <<"application/msgpack">>]).
-define(DEFAULT_HEADERS, #{}).
-define(DEFAULT_SECURITY, #{}).
-define(DEFAULT_SCHEMES, [<<"http">>]).

%% MAP VALIDATION SPECS to use with maps_utils.erl
-define(HTTP_METHODS, [
    <<"delete">>,
    <<"get">>,
    <<"head">>,
    <<"options">>,
    <<"patch">>,
    <<"post">>,
    <<"put">>
]).

-define(DEFAULT_STATUS_CODES, #{
    ?BONDY_ERROR_ALREADY_EXISTS =>              ?HTTP_BAD_REQUEST,
    ?BONDY_ERROR_NOT_FOUND =>                   ?HTTP_NOT_FOUND,
    ?BONDY_ERROR_BAD_GATEWAY =>                 ?HTTP_SERVICE_UNAVAILABLE,
    ?BONDY_ERROR_HTTP_API_GATEWAY_INVALID_EXPR =>    ?HTTP_INTERNAL_SERVER_ERROR,
    ?BONDY_ERROR_TIMEOUT =>                     ?HTTP_GATEWAY_TIMEOUT,
    %% REVIEW
    ?WAMP_AUTHORIZATION_FAILED =>               ?HTTP_INTERNAL_SERVER_ERROR,
    ?WAMP_CANCELLED =>                          ?HTTP_BAD_REQUEST,
    ?WAMP_CLOSE_REALM =>                        ?HTTP_INTERNAL_SERVER_ERROR,
    ?WAMP_DISCLOSE_ME_NOT_ALLOWED =>            ?HTTP_BAD_REQUEST,
    ?WAMP_GOODBYE_AND_OUT =>                    ?HTTP_INTERNAL_SERVER_ERROR,
    ?WAMP_INVALID_ARGUMENT =>                   ?HTTP_BAD_REQUEST,
    ?WAMP_INVALID_URI =>                        ?HTTP_BAD_REQUEST,
    ?WAMP_NET_FAILURE =>                        ?HTTP_BAD_GATEWAY,
    %% REVIEW
    ?WAMP_NOT_AUTHORIZED =>                     ?HTTP_FORBIDDEN,
    ?WAMP_NO_ELIGIBLE_CALLE =>                  ?HTTP_BAD_GATEWAY,
    ?WAMP_NO_SUCH_PROCEDURE =>                  ?HTTP_NOT_IMPLEMENTED,
    ?WAMP_NO_SUCH_REALM =>                      ?HTTP_BAD_GATEWAY,
    ?WAMP_NO_SUCH_REGISTRATION =>               ?HTTP_BAD_GATEWAY,
    ?WAMP_NO_SUCH_ROLE =>                       ?HTTP_BAD_REQUEST,
    ?WAMP_NO_SUCH_SESSION =>                    ?HTTP_INTERNAL_SERVER_ERROR,
    ?WAMP_NO_SUCH_SUBSCRIPTION =>               ?HTTP_BAD_GATEWAY,
    ?WAMP_OPTION_DISALLOWED_DISCLOSE_ME =>      ?HTTP_BAD_REQUEST,
    ?WAMP_OPTION_NOT_ALLOWED =>                 ?HTTP_BAD_REQUEST,
    ?WAMP_PROCEDURE_ALREADY_EXISTS =>           ?HTTP_BAD_REQUEST,
    ?WAMP_SYSTEM_SHUTDOWN =>                    ?HTTP_INTERNAL_SERVER_ERROR
}).

-define(MOPS_PROXY_FUN_TYPE, tuple).

-define(API_HOST, #{
    <<"id">> => #{
        alias => id,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"name">> => #{
        alias => id,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"host">> => #{
        alias => host,
        required => true,
        allow_null => false,
        datatype => binary,
        validator => fun
            (<<"_">>) -> {ok, '_'}; % Cowboy needs an atom
            (Val) -> {ok, Val}
        end
    },
    <<"realm_uri">> => #{
        alias => realm_uri,
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"meta">> => #{
        alias => meta,
        required => false,
        datatype => map
    },
    ?VARS_KEY => #{
        alias => variables,
        required => true,
        allow_null => false,
        default => #{},
        datatype => map
    },
    ?DEFAULTS_KEY => #{
        alias => defaults,
        required => true,
        allow_null => false,
        default => #{},
        datatype => map,
        validator => ?DEFAULTS_SPEC
    },
    ?STATUS_CODES_KEY => #{
        alias => paths,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => map,
        default => #{}
    },
    <<"versions">> => #{
        alias => versions,
        required => true,
        allow_null => false,
        datatype => map
        % , validator => fun(M) ->
        %     R = maps:map(
        %         fun(_, Ver) -> maps_utils:validate(Ver, ?API_VERSION) end, M),
        %     {ok, R}
        % end
    }
}).

-define(API_VERSION, #{
    <<"base_path">> => #{
        alias => base_path,
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"is_active">> => #{
        alias => is_active,
        required => true,
        allow_null => false,
        default => true,
        datatype => boolean
    },
    <<"is_deprecated">> => #{
        alias => is_deprecated,
        required => true,
        allow_null => false,
        default => false,
        datatype => boolean
    },
    <<"pool_size">> => #{
        alias => pool_size,
        required => true,
        allow_null => false,
        default => 200,
        datatype => pos_integer
    },
    <<"info">> => #{
        alias => info,
        required => false,
        datatype => map,
        validator => #{
            <<"title">> => #{
                alias => title,
                required => true,
                allow_null => true,
                datatype => binary},
            <<"description">> => #{
                alias => description,
                required => true,
                allow_null => true,
                datatype => binary}
        }
    },
    ?VARS_KEY => #{
        alias => variables,
        required => true,
        allow_null => false,
        default => #{},
        datatype => map
    },
    ?DEFAULTS_KEY => #{
        alias => defaults,
        required => true,
        allow_null => false,
        default => #{},
        datatype => map
    },
    ?STATUS_CODES_KEY => #{
        alias => paths,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => map,
        default => #{}
    },
    ?LANGUAGES_KEY => #{
        alias => languages,
        required => true,
        allow_null => false,
        allow_undefined => false,
        default => [<<"en">>],
        datatype => {list, binary}
    },
    <<"paths">> => #{
        alias => paths,
        required => true,
        allow_null => false,
        datatype => map,
        validator => fun(M1) ->
            Inner = fun
                (<<"/">> = P, _) ->
                    error({invalid_path, P});
                (<<"/ws">> = P, _) ->
                    error({reserved_path, P});
                (_, Val) ->
                    Val
            end,
            {ok, maps:map(Inner, M1)}
        end
    }
}).

-define(DEFAULTS_SPEC, #{
    <<"schemes">> => #{
        alias => schemes,
        required => true,
        default => ?DEFAULT_SCHEMES
    },
    <<"security">> => #{
        alias => security,
        required => true,
        allow_null => false,
        % datatype => map,
        default => #{}
    },
    <<"body_max_bytes">> => #{
        alias => body_max_bytes,
        required => true,
        datatype => pos_integer,
        default => 25000000 %% 25MB
    },
    <<"body_read_bytes">> => #{
        alias => body_read_bytes,
        required => true,
        datatype => pos_integer,
        default => 8000000 %% 8MB is Cowboy 2 default
    },
    <<"body_read_seconds">> => #{
        alias => body_read_seconds,
        required => true,
        datatype => pos_integer,
        default => 15000 %% 15 secs is Cowboy 2 default
    },
    <<"timeout">> => #{
        alias => timeout,
        required => true,
        % datatype => timeout,
        default => ?DEFAULT_TIMEOUT
    },
    <<"connect_timeout">> => #{
        alias => connect_timeout,
        required => true,
        default => ?DEFAULT_CONN_TIMEOUT
    },
    <<"retries">> => #{
        alias => retries,
        required => true,
        % datatype => integer,
        default => ?DEFAULT_RETRIES
    },
    <<"retry_timeout">> => #{
        alias => retry_timeout,
        required => true,
        default => ?DEFAULT_RETRY_TIMEOUT
    },
    <<"accepts">> => #{
        alias => accepts,
        required => true,
        allow_null => false,
        default => ?DEFAULT_ACCEPTS
    },
    <<"provides">> => #{
        alias => provides,
        required => true,
        allow_null => false,
        default => ?DEFAULT_PROVIDES
    },
    <<"headers">> => #{
        alias => headers,
        required => true,
        allow_null => false,
        default => ?DEFAULT_HEADERS
    }
}).

-define(BASIC, #{
    <<"type">> => #{
        alias => type,
        required => true,
        allow_null => false,
        default => <<"basic">>,
        datatype => {in, [<<"basic">>]}
    },
    <<"schemes">> => #{
        alias => schemes,
        required => true,
        allow_null => false,
        default => ?DEFAULT_SCHEMES,
        datatype => {list, binary}
    }
}).

-define(APIKEY, #{
    <<"type">> => #{
        alias => type,
        required => true,
        allow_null => false,
        default => <<"api_key">>,
        datatype => {in, [<<"api_key">>]}
    },
    <<"schemes">> => #{
        alias => schemes,
        required => true,
        allow_null => false,
        default => ?DEFAULT_SCHEMES,
        datatype => {list, binary}
    },
    <<"header_name">> => #{
        alias => header_name,
        required => true,
        allow_null => false,
        default => <<"authorization">>,
        datatype => binary
    }
}).

-define(OAUTH2_SPEC, #{
    <<"type">> => #{
        alias => type,
        required => true,
        allow_null => false,
        datatype => {in, [<<"oauth2">>]}
    },
    <<"schemes">> => #{
        alias => scheme,
        required => true,
        allow_null => false,
        default => ?DEFAULT_SCHEMES,
        datatype => {list, binary}
    },
    <<"flow">> => #{
        alias => flow,
        required => true,
        default => null,
        datatype => {in, [
            <<"authorization_code">>,
            <<"implicit">>,
            <<"resource_owner_password_credentials">>,
            <<"client_credentials">>
        ]}
    },
    <<"token_path">> => #{
        alias => token_path,
        required => false,
        datatype => binary
    },
    <<"revoke_token_path">> => #{
        alias => revoke_token_path,
        required => false,
        datatype => binary
    },
    <<"description">> => #{
        alias => description,
        required => false,
        datatype => binary
    }
}).

-define(DEFAULT_PATH, #{
    <<"variables">> => #{},
    <<"defaults">> => #{},
    <<"is_collection">> => false,
    <<"headers">> => <<"{{defaults.headers}}">>,
    <<"accepts">> => <<"{{defaults.accepts}}">>,
    <<"provides">> => <<"{{defaults.provides}}">>,
    <<"schemes">> => <<"{{defaults.schemes}}">>,
    <<"security">> => <<"{{defaults.security}}">>,
    <<"body_max_bytes">> => <<"{{defaults.body_max_bytes}}">>,
    <<"body_read_bytes">> => <<"{{defaults.body_read_bytes}}">>,
    <<"body_read_seconds">> => <<"{{defaults.body_read_seconds}}">>,
    <<"timeout">> => <<"{{defaults.timeout}}">>,
    <<"connect_timeout">> => <<"{{defaults.connect_timeout}}">>,
    <<"retries">> => <<"{{defaults.retries}}">>,
    <<"retry_timeout">> => <<"{{defaults.retry_timeout}}">>
}).

-define(API_PATH, #{
    <<"is_collection">> => #{
        alias => is_collection,
        required => true,
        allow_null => false,
        datatype => boolean
    },
    ?VARS_KEY => #{
        alias => variables,
        required => true,
        datatype => map
    },
    ?DEFAULTS_KEY => #{
        alias => defaults,
        required => true,
        allow_null => false,
        datatype => map
    },
    <<"accepts">> => #{
        alias => accepts,
        required => true,
        allow_null => false,
        datatype => {list, binary}
    },
    <<"provides">> => #{
        alias => provides,
        required => true,
        allow_null => false,
        datatype => {list, binary}
    },
    <<"schemes">> => #{
        alias => schemes,
        required => true,
        allow_null => false,
        datatype => {list, binary}
    },
    <<"security">> => #{
        alias => security,
        required => true,
        allow_null => false,
        datatype => [map, binary, ?MOPS_PROXY_FUN_TYPE],
        validator => fun
            (#{<<"type">> := <<"oauth2">>} = V) ->
                {ok, maps_utils:validate(V, ?OAUTH2_SPEC)};
            (#{<<"type">> := <<"basic">>} = V) ->
                {ok, maps_utils:validate(V, ?BASIC)};
            (#{<<"type">> := <<"api_key">>} = V) ->
                {ok, maps_utils:validate(V, ?APIKEY)};
            (V) ->
                #{} =:= V
        end
    },
    <<"delete">> => #{
        alias => delete,
        required => false,
        datatype => [binary, map] % To support mop expressions
    },
    <<"get">> => #{
        alias => get,
        required => false,
        datatype => [binary, map] % To support mop expressions
    },
    <<"head">> => #{
        alias => head,
        required => false,
        datatype => [binary, map] % To support mop expressions
    },
    <<"options">> => #{
        alias => options,
        required => false,
        datatype => [binary, map] % To support mop expressions
    },
    <<"patch">> => #{
        alias => patch,
        required => false,
        datatype => [binary, map] % To support mop expressions
    },
    <<"post">> => #{
        alias => post,
        required => false,
        datatype => [binary, map] % To support mop expressions
    },
    <<"put">> => #{
        alias => put,
        required => false,
        datatype => [binary, map] % To support mop expressions
    },
    <<"summary">> => #{
        alias => summary,
        required => false,
        datatype => binary
    },
    <<"description">> => #{
        alias => description,
        required => false,
        datatype => binary
    }
}).

-define(PATH_DEFAULTS, #{
    <<"schemes">> => #{
        alias => schemes,
        required => true,
        default => <<"{{defaults.schemes}}">>
    },
    <<"security">> => #{
        alias => security,
        required => true,
        allow_null => false,
        datatype => map
    },
    <<"body_max_bytes">> => #{
        alias => body_max_bytes,
        required => true,
        datatype => pos_integer,
        default => 25000000 %% 25MB
    },
    <<"body_read_bytes">> => #{
        alias => body_read_bytes,
        required => true,
        datatype => pos_integer,
        default => 8000000 %% 8MB is Cowboy 2 default
    },
    <<"body_read_seconds">> => #{
        alias => body_read_seconds,
        required => true,
        datatype => pos_integer,
        default => 15000 %% 15 secs is Cowboy 2 default
    },
    <<"timeout">> => #{
        alias => timeout,
        required => true,
        datatype => timeout
    },
    <<"connect_timeout">> => #{
        alias => connect_timeout,
        required => true,
        datatype => timeout
    },
    <<"retries">> => #{
        alias => retries,
        required => true,
        datatype => integer
    },
    <<"retry_timeout">> => #{
        alias => retry_timeout,
        required => true,
        datatype => integer
    },
    <<"accepts">> => #{
        alias => accepts,
        required => true,
        allow_null => false,
        datatype => {list, binary}
    },
    <<"provides">> => #{
        alias => provides,
        required => true,
        allow_null => false,
        datatype => {list, binary}
    },
    <<"headers">> => #{
        alias => headers,
        required => true,
        allow_null => false
    }
}).

-define(DEFAULT_REQ, #{
    <<"body_max_bytes">> => <<"{{defaults.body_max_bytes}}">>,
    <<"body_read_bytes">> => <<"{{defaults.body_read_bytes}}">>,
    <<"body_read_seconds">> => <<"{{defaults.body_read_seconds}}">>
}).

-define(REQ_SPEC, #{
    <<"info">> => #{
        alias => info,
        required => false,
        validator => #{
            <<"description">> => #{
                alias => description,
                required => false,
                allow_null => true,
                datatype => binary
            },
            <<"parameters">> => #{
                alias => parameters,
                required => false,
                validator => ?API_PARAMS
            }
        }
    },
    <<"body_max_bytes">> => #{
        alias => body_max_bytes,
        required => true,
        datatype => [pos_integer, binary, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"body_read_bytes">> => #{
        alias => body_read_bytes,
        required => true,
        datatype => [pos_integer, binary, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"body_read_seconds">> => #{
        alias => body_read_seconds,
        required => true,
        datatype => [pos_integer, binary, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"action">> => #{
        alias => action,
        required => true,
        allow_null => false,
        validator => fun
            (#{<<"type">> := <<"static">>} = V) ->
                {ok, maps_utils:validate(V, ?STATIC_ACTION_SPEC)};
            (#{<<"type">> := <<"wamp_", _/binary>>} = V) ->
                {ok, maps_utils:validate(V, ?WAMP_ACTION_SPEC)};
            (#{<<"type">> := <<"forward">>} = V) ->
                {ok, maps_utils:validate(V, ?FWD_ACTION_SPEC)};
            (V) ->
                #{} =:= V
        end
    },
    <<"response">> => #{
        alias => response,
        required => true,
        allow_null => false
    }

}).

-define(BODY_ALL_DATATYPES, [
    binary,
    boolean,
    list,
    map,
    number,
    string,
    ?MOPS_PROXY_FUN_TYPE
]).

-define(DEFAULT_STATIC_ACTION, #{
    <<"body">> => <<>>,
    <<"headers">> => #{}
}).

-define(STATIC_ACTION_SPEC, #{
    <<"type">> => #{
        alias => type,
        required => true,
        allow_null => false,
        datatype => {in, [<<"static">>]}
    },
    <<"headers">> => #{
        alias => headers,
        required => true,
        datatype => [map, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"body">> => #{
        alias => body,
        required => true,
        datatype => ?BODY_ALL_DATATYPES
    }
}).

-define(DEFAULT_FWD_ACTION, #{
    <<"path">> => <<"{{request.path}}">>,
    <<"query_string">> => <<"{{request.query_string}}">>,
    <<"headers">> => <<"{{request.headers}}">>,
    <<"body">> => <<"{{request.body}}">>,
    <<"timeout">> => <<"{{defaults.timeout}}">>,
    <<"connect_timeout">> => <<"{{defaults.connect_timeout}}">>,
    <<"retries">> => <<"{{defaults.retries}}">>,
    <<"retry_timeout">> => <<"{{defaults.retry_timeout}}">>
}).

-define(FWD_ACTION_SPEC, #{
    <<"type">> => #{
        alias => type,
        required => true,
        allow_null => false,
        datatype => {in, [<<"forward">>]}
    },
    <<"http_method">> => #{
        alias => host,
        required => false,
        allow_null => false,
        datatype => {in, [
            <<"delete">>, <<"get">>, <<"head">>, <<"options">>,
            <<"patch">>, <<"post">>, <<"put">>
        ]}
    },
    <<"host">> => #{
        alias => host,
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"path">> => #{
        alias => path,
        required => true,
        datatype => [binary, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"query_string">> => #{
        alias => query_string,
        required => true,
        datatype => [binary, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"headers">> => #{
        alias => headers,
        required => true,
        datatype => [map, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"body">> => #{
        alias => body,
        required => true,
        datatype => ?BODY_ALL_DATATYPES
    },
    <<"timeout">> => #{
        alias => timeout,
        required => true,
        datatype => [timeout, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"connect_timeout">> => #{
        alias => connect_timeout,
        required => true,
        datatype => [timeout, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"retries">> => #{
        alias => retries,
        required => true,
        datatype => [integer, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"retry_timeout">> => #{
        alias => retry_timeout,
        required => true,
        datatype => [timeout, ?MOPS_PROXY_FUN_TYPE]
    }
}).

-define(MAP_OR_FUNCTION, fun
    (X) when is_map(X) ->
        true;
    (F) when is_function(F) ->
        true;
    (_) ->
        false
end).

-define(DEFAULT_WAMP_ACTION, #{
    <<"options">> => #{},
    <<"args">> => [],
    <<"kwargs">> => #{},
    <<"timeout">> => <<"{{defaults.timeout}}">>,
    <<"connect_timeout">> => <<"{{defaults.connect_timeout}}">>,
    <<"retries">> => <<"{{defaults.retries}}">>,
    <<"retry_timeout">> => <<"{{defaults.retry_timeout}}">>
}).

-define(WAMP_ACTION_SPEC, #{
    <<"type">> => #{
        alias => type,
        required => true,
        allow_null => false,
        datatype => {in, [
            <<"wamp_call">>,
            <<"wamp_publish">>,
            <<"wamp_register">>,
            <<"wamp_unregister">>,
            <<"wamp_subscribe">>,
            <<"wamp_unsubscribe">>
        ]}
    },
    <<"timeout">> => #{
        alias => timeout,
        required => true,
        datatype => [timeout, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"retries">> => #{
        alias => retries,
        required => true,
        datatype => [integer, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"procedure">> => #{
        alias => procedure,
        required => true,
        allow_null => false,
        datatype => [binary, ?MOPS_PROXY_FUN_TYPE],
        validator => fun
            (X) when is_binary(X) -> wamp_uri:is_valid(X);
            (X) -> mops:is_proxy(X)
        end
    },
    <<"options">> => #{
        alias => options,
        required => true,
        allow_null => true,
        datatype => [map, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"args">> => #{
        aliases => [args, <<"arguments">>, arguments],
        required => true,
        allow_null => true,
        datatype => [list, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"kwargs">> => #{
        aliases => [kwargs, <<"arguments_kw">>, arguments_kw],
        required => true,
        allow_null => true,
        datatype => [map, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"payload">> => #{
        aliases => [payload],
        required => false,
        allow_null => true,
        datatype => [binary, ?MOPS_PROXY_FUN_TYPE]
    }
}).

-define(DEFAULT_RESPONSE, #{
    <<"headers">> => <<"{{defaults.headers}}">>,
    <<"body">> => <<>>
}).

-define(RESPONSE_SPEC, #{
    <<"headers">> => #{
        alias => headers,
        required => true,
        allow_null => false,
        datatype => [map, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"body">> => #{
        alias => body,
        required => true,
        allow_null => false,
        datatype => ?BODY_ALL_DATATYPES
    },
    <<"status_code">> => #{
        alias => status_code,
        required => false,
        allow_null => false,
        datatype => [integer, binary, ?MOPS_PROXY_FUN_TYPE]
    },
    <<"uri">> => #{
        alias => uri,
        required => false,
        allow_null => false,
        datatype => [binary, ?MOPS_PROXY_FUN_TYPE]
    }
}).

-define(API_PARAMS, #{
    <<"name">> => #{
        alias => name,
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"in">> => #{
        alias => in,
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"description">> => #{
        alias => description,
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"required">> => #{
        alias => required,
        required => true,
        allow_null => false,
        datatype => boolean
    },
    <<"type">> => #{
        alias => type,
        required => true,
        allow_null => false,
        datatype => binary
    }
}).

-define(VAR(Term), {var, Term}).

-define(SCHEME_HEAD,
    {
        ?VAR(scheme),
        ?VAR(host),
        ?VAR(realm),
        ?VAR(path),
        ?VAR(mod),
        ?VAR(state)
    }
).


-type scheme_rule()     ::  {
                                Scheme :: binary(),
                                Host :: route_match(),
                                Realm :: binary(),
                                Path :: route_match(),
                                Handler :: module(),
                                Opts :: any()
                            }.
%% Cowboy types
-type route_path()      ::  {
                                Path :: route_match(),
                                Handler :: module(),
                                Opts :: any()
                            }.
-type route_rule()      ::  {Host :: route_match(), Paths :: [route_path()]}.
-type route_match()     ::  '_' | iodata().


-export([from_file/1]).
-export([parse/1]).
-export([dispatch_table/1]).
-export([dispatch_table/2]).




%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% Loads a file and calls {@link parse/1}.
%% @end
%% -----------------------------------------------------------------------------
-spec from_file(file:filename()) -> {ok, any()} | {error, any()}.

from_file(Filename) ->
    case bondy_utils:json_consult(Filename) of
        {ok, Spec} when is_map(Spec) ->
            {ok, parse(Spec, get_context_proxy())};
        {ok, _} ->
            {error, invalid_specification_format};
        {error, Reason} ->
            ?LOG_WARNING(#{
                description => "Error while parsing API Gateway Specification file",
                filename => Filename,
                reason => Reason
            }),
            {error, invalid_json_format}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Parses the Spec map returning a new valid spec where all defaults have been
%% applied and all variables have been replaced by either a value of a promise.
%% Fails with in case the Spec is invalid.
%%
%% Variable replacepement is performed using our "mop" library.
%% @end
%% -----------------------------------------------------------------------------
-spec parse(map()) ->
    map() | {error, invalid_specification_format} | no_return().

parse(Map) when is_map(Map) ->
    parse(Map, get_context_proxy());

parse(_) ->
    {error, invalid_specification_format}.


%% -----------------------------------------------------------------------------
%% @doc
%% Given a valid API Spec or list of Specs returned by {@link parse/1},
%% dynamically generates a cowboy dispatch table.
%% @end
%% -----------------------------------------------------------------------------
-spec dispatch_table([map()] | map()) ->
    [{Scheme :: binary(), [route_rule()]}] | no_return().

dispatch_table(API) when is_map(API) ->
    dispatch_table([API], []);

dispatch_table(Specs) when is_list(Specs) ->
    dispatch_table(Specs, []).


%% -----------------------------------------------------------------------------
%% @doc
%% Given a list of valid API Specs returned by {@link parse/1} and
%% dynamically generates the cowboy dispatch table.
%% Notice this does not update the cowboy dispatch table. You will need to do
%% that yourself.
%% @end
%% -----------------------------------------------------------------------------
-spec dispatch_table([map()] | map(), [route_rule()]) ->
    [{Scheme :: binary(), [route_rule()]}] | no_return().

dispatch_table(API, RulesToAdd) when is_map(API) ->
    dispatch_table([API], RulesToAdd);

dispatch_table(L, RulesToAdd) when is_list(L), is_list(RulesToAdd) ->
    SchemeRules = lists:flatten([do_dispatch_table(X) || X <- L]),
    R0 = leap_relation:relation(?SCHEME_HEAD, SchemeRules),

    %% We make sure all realms exists
    Realms = leap_relation:project(R0, [{var, realm}]),
    _ = [check_realm_exists(Realm) || {Realm} <- leap_relation:tuples(Realms)],

    %% We add the additional rules
    Schemes = leap_relation:tuples(leap_relation:project(R0, [{var, scheme}])),
    A0 = leap_relation:relation(?SCHEME_HEAD, [
        {S, H, undefined, P, M, O} ||
            {H, HRules} <- RulesToAdd,
            {P, M, O} <- HRules,
            {S} <- Schemes
    ]),
    R1 = leap_relation:union(R0, A0),

    %% We project the desired output
    PMS = {function, collect, [?VAR(path), ?VAR(mod), ?VAR(state)]},
    Proj1 = {?VAR(scheme), ?VAR(host), {as, PMS, ?VAR(pms)}},

    % [{scheme, host, [{path, mode, state}]}]
    R2 = leap_relation:summarize(R1, Proj1, #{}),
    HPMS = {function, collect, [?VAR(host), ?VAR(pms)]},
    Proj2 = {?VAR(scheme), {as, HPMS, ?VAR(hpms)}},
    SHP = leap_relation:summarize(R2, Proj2, #{}),
    leap_relation:tuples(SHP).




%% =============================================================================
%% PRIVATE: PARSING THE API SPECIFICATION
%% =============================================================================



%% @private
-spec parse(Spec :: map(), Ctxt :: map()) ->
    NewSpec :: map() |  {error, invalid_specification_format} | no_return().

parse(Spec, Ctxt) when is_map(Spec) ->
    parse_host(maps_utils:validate(Spec, ?API_HOST), Ctxt);

parse(_, _) ->
    {error, invalid_specification_format}.


%% @private
-spec parse_host(map(), map()) -> map().
parse_host(Host0, Ctxt0) ->
    {Vars, Host1} = maps:take(?VARS_KEY, Host0),
    {Defs, Host2} = maps:take(?DEFAULTS_KEY, Host1),
    {Codes, Host3} = maps:take(?STATUS_CODES_KEY, Host2),

    Ctxt1 = Ctxt0#{
        ?VARS_KEY => Vars,
        ?DEFAULTS_KEY => Defs,
        ?STATUS_CODES_KEY => maps:merge(Codes, ?DEFAULT_STATUS_CODES)
    },

    %% parse all versions
    Vs0 = maps:get(<<"versions">>, Host3),
    Fun = fun(_, V) -> parse_version(V, Ctxt1) end,
    Vs1 = maps:map(Fun, Vs0),
    Host4 = maps:without([?VARS_KEY, ?DEFAULTS_KEY], Host3),
    maps:update(<<"versions">>, Vs1, Host4).


%% @private
-spec parse_version(map(), map()) -> map().
parse_version(V0, Ctxt0) ->
    %% We merge variables and defaults
    {V1, Ctxt1} = merge_eval_vars(V0, Ctxt0),
    %% We then validate the resulting version
    V2 = maps_utils:validate(V1, ?API_VERSION),
    %% We merge again in case the validation added defaults
    {V3, Ctxt2} = merge_eval_vars(V2, Ctxt1),
    %% We parse the status_codes and merge them into ctxt
    {Codes1, V4} = maps:take(?STATUS_CODES_KEY, V3),
    Codes0 = maps:get(?STATUS_CODES_KEY, Ctxt1),
    Ctxt3 = maps:put(?STATUS_CODES_KEY, maps:merge(Codes0, Codes1), Ctxt2),

    %% Finally we parse the contained paths
    Fun = fun(Uri, P) ->
        try
            parse_path(P, Ctxt3)
        catch
            error:{badkey, Key} ->
                error({
                    badarg,
                    <<"The key '", Key/binary, "' does not exist in path '", Uri/binary, "'.">>
                })
        end
    end,
    V5 = maps:without([?VARS_KEY, ?DEFAULTS_KEY], V4),
    maps:update(
        <<"paths">>, maps:map(Fun, maps:get(<<"paths">>, V5)), V5).


%% @private
parse_path(P0, Ctxt0) ->
    %% The path should have at least one HTTP method
    %% otherwise this will fail with an error
    L = allowed_methods(P0),
    %% We merge path spec with gateway default spec
    P1  = maps:merge(?DEFAULT_PATH, P0),
    %% We merge path's variables and defaults into context
    {P2, Ctxt1} = merge_eval_vars(P1, eval_vars(Ctxt0)),
    %% Ctxt1 = eval(Ctxt0),
    %% P11 = eval(P1, Ctxt1),
    %% {P2, Ctxt2} = merge(P11, Ctxt1),

    %% We apply defaults and evaluate before validating
    %% Ctxt2 = eval_vars(P2, Ctxt1),
    Ctxt2 = Ctxt1,
    P3 = validate(?DEFAULTS_KEY, P2, ?PATH_DEFAULTS),

    P4 = parse_path_elements(P3, Ctxt2),

    %% Finally we validate the resulting path
    P5 = maps_utils:validate(P4, ?API_PATH),
    %% HTTP (and COWBOY) requires uppercase method names
    P6 = maps:put(<<"allowed_methods">>, to_uppercase(L), P5),
    P7 = maps:without([?VARS_KEY, ?DEFAULTS_KEY], P6),

    %% Now we evaluate each request type spec
    PFun = fun(Method, IPath) ->
        Sec0 = maps:get(Method, IPath),
        try
            Sec1 = parse_request_method(Method, Sec0, Ctxt2),
            Sec2 = maps_utils:validate(Sec1, ?REQ_SPEC),
            maps:update(Method, Sec2, IPath)
        catch
            error:{badkey, Key} ->
                error({badarg, <<"The key '", Key/binary, "' does not exist in path method section '", Method/binary, $'>>})
        end
    end,
    lists:foldl(PFun, P7, L).


%% @private
parse_path_elements(Path, Ctxt) ->
    L = [
        <<"accepts">>,
        <<"provides">>,
        <<"schemes">>,
        <<"security">>
    ],
    parse_path_elements(L, Path, Ctxt).


%% @private
parse_path_elements([H|T], P0, Ctxt) ->
    P1 = case maps:is_key(H, P0) of
        true ->
            P0;
        false ->
            %% We assign a default and fail if none exists
            case maps:find(H, maps:get(?DEFAULTS_KEY, Ctxt)) of
                {ok, Val} ->
                    maps:put(H, Val, P0);
                error ->
                    error({
                        badarg,
                        <<"The key ", H/binary, " does not exist in path.">>
                    })
            end
    end,
    Eval = fun(V) -> mops_eval(V, Ctxt) end,
    P2 = maps:update_with(H, Eval, P1),
    parse_path_elements(T, P2, Ctxt);

parse_path_elements([], Path, _) ->
    Path.


%% @private
parse_request_method(Method, Spec, Ctxt) when is_binary(Spec) ->
    parse_request_method(Method, mops_eval(Spec, Ctxt), Ctxt);

%% parse_request_method(<<"options">>, Spec, Ctxt) ->
%%     #{<<"response">> := Resp} = Spec,
%%     Spec#{
%%         <<"response">> => parse_response(Resp, Ctxt)
%%     };

parse_request_method(Method, Spec0, Ctxt) ->
    Spec1 = maps:merge(?DEFAULT_REQ, Spec0),
    #{
        <<"action">> := Act,
        <<"response">> := Resp,
        <<"body_max_bytes">> := MB,
        <<"body_read_bytes">> := BL,
        <<"body_read_seconds">> := SL
    } = Spec1,
    Spec1#{
        <<"action">> => parse_action(Method, Act, Ctxt),
        <<"response">> => parse_response(Method, Resp, Ctxt),
        <<"body_max_bytes">> => mops_eval(MB, Ctxt),
        <<"body_read_bytes">> => mops_eval(BL, Ctxt),
        <<"body_read_seconds">> => mops_eval(SL, Ctxt)
    }.


%% @private
%% -----------------------------------------------------------------------------
%% @doc
%% Parses a path action section definition. Before applying validations
%% this function applies defaults values and evaluates all terms
%% (using mops:eval/2).
%% If the action type provided is not reconised it fails with
%% `{unsupported_action_type, Type}'.
%% If an action type is not provided if fails with `action_type_missing'.
%% @end
%% -----------------------------------------------------------------------------
-spec parse_action(binary(), map(), map()) -> map().

parse_action(_, #{<<"type">> := <<"wamp_", _/binary>>} = Spec, Ctxt) ->
    maps_utils:validate(
        mops_eval(maps:merge(?DEFAULT_WAMP_ACTION, Spec), Ctxt),
        ?WAMP_ACTION_SPEC
    );

parse_action(_, #{<<"type">> := <<"forward">>} = Spec, Ctxt) ->
    maps_utils:validate(
        mops_eval(maps:merge(?DEFAULT_FWD_ACTION, Spec), Ctxt),
        ?FWD_ACTION_SPEC
    );

parse_action(_, #{<<"type">> := <<"static">>} = Spec, Ctxt) ->
    maps_utils:validate(
        mops_eval(maps:merge(?DEFAULT_STATIC_ACTION, Spec), Ctxt),
        ?STATIC_ACTION_SPEC
    );

parse_action(_, #{<<"type">> := Type}, _) ->
    error({unsupported_action_type, Type});

parse_action(<<"options">>, Spec, _) ->
    Spec;

parse_action(_, _, _) ->
    error(action_type_missing).



parse_response(_, Spec0, Ctxt) ->
    OR0 = maps:get(<<"on_result">>, Spec0, ?DEFAULT_RESPONSE),
    OE0 = maps:get(<<"on_error">>, Spec0, ?DEFAULT_RESPONSE),
    [OR1, OE1] = [
        maps_utils:validate(
            mops_eval(maps:merge(?DEFAULT_RESPONSE, X), Ctxt),
            ?RESPONSE_SPEC
        ) || X <- [OR0, OE0]
    ],
    #{
        <<"on_result">> => OR1,
        <<"on_error">> => OE1
    }.





%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Lower level variables and defaults override previous ones
%% @end
%% -----------------------------------------------------------------------------
merge_eval_vars(Spec0, Ctxt0) ->
    %% We merge (override) ctxt variables and defaults
    VVars = maps:get(?VARS_KEY, Spec0, #{}),
    MVars = maps:merge(maps:get(?VARS_KEY, Ctxt0), VVars),
    VDefs = maps:get(?DEFAULTS_KEY, Spec0, #{}),
    MDefs = maps:merge(maps:get(?DEFAULTS_KEY, Ctxt0), VDefs),

    %% We update the API section
    Spec1 = Spec0#{?VARS_KEY => MVars, ?DEFAULTS_KEY => MDefs},
    %% We also update the ctxt as we use it as an accummulator
    Ctxt1 = maps:update(?VARS_KEY, MVars, Ctxt0),
    Ctxt2 = maps:update(?DEFAULTS_KEY, MDefs, Ctxt1),
    eval_vars(Spec1, Ctxt2).


%% @private
eval_vars(Ctxt) ->
    element(1, eval_vars(Ctxt, Ctxt)).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% We assume Ctxt0 has been previously evaluated.
%% Variables are evaluated before defaults
%%
%% If at level 1 we have:
%% a = b
%% b = 1
%% c = 2
%% After eval we get:
%% a = 1
%% b = 1
%% c = 2
%%
%% If at level 2 we have:
%% a = 2
%% c = b
%% After eval we get:
%% a = 2
%% b = 1
%% c = 1
%% @end
%% -----------------------------------------------------------------------------
eval_vars(S0, Ctxt0) ->
    Vars = maps:get(?VARS_KEY, S0, #{}),
    Defs = maps:get(?DEFAULTS_KEY, S0, #{}),
    %% We evaluate variables by iterating over each
    %% updating the context in each turn as we might have interdependencies
    %% amongst them
    VFun = fun(Var, Val, ICtxt) ->
        IVars1 = maps:update(
            Var, mops_eval(Val, ICtxt), maps:get(?VARS_KEY, ICtxt)),
        maps:update(?VARS_KEY, IVars1, ICtxt)
    end,
    Ctxt1 = maps:fold(VFun, Ctxt0, Vars),

    %% We evaluate defaults
    DFun = fun(Var, Val, ICtxt) ->
        IDefs1 = maps:update(
            Var, mops_eval(Val, ICtxt), maps:get(?DEFAULTS_KEY, ICtxt)),
        maps:update(?DEFAULTS_KEY, IDefs1, ICtxt)
    end,
    Ctxt2 = maps:fold(DFun, Ctxt1, Defs),
    S1 = S0#{
        ?VARS_KEY => maps:with(maps:keys(Vars), maps:get(?VARS_KEY, Ctxt2)),
        ?DEFAULTS_KEY => maps:with(maps:keys(Defs), maps:get(?DEFAULTS_KEY, Ctxt2))
    },
    {S1, Ctxt2}.



%% @private
validate(Key, Map, Spec) ->
    maps:update(
        Key, maps_utils:validate(maps:get(Key, Map), Spec), Map).



%% @private
to_uppercase(L) when is_list(L) ->
    [to_uppercase(M) || M <- L];

to_uppercase(<<"delete">>) ->
    <<"DELETE">>;

to_uppercase(<<"get">>) ->
    <<"GET">>;

to_uppercase(<<"head">>) ->
    <<"HEAD">>;

to_uppercase(<<"options">>) ->
    <<"OPTIONS">>;

to_uppercase(<<"patch">>) ->
    <<"PATCH">>;

to_uppercase(<<"post">>) ->
    <<"POST">>;

to_uppercase(<<"put">>) ->
    <<"PUT">>.



%% @private
allowed_methods(Path) ->
    L = sets:to_list(
        sets:intersection(
            sets:from_list(?HTTP_METHODS),
            sets:from_list(maps:keys(Path)
            )
        )
    ),
    case L of
        [] ->
            error(
                {missing_required_key,
            <<"At least one request method should be specified">>});
        _ ->
            L
    end.



%% =============================================================================
%% PRIVATE: GENERATING DISPATCH TABLE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec do_dispatch_table(map()) -> [scheme_rule()].

do_dispatch_table(API) ->
    #{
        <<"host">> := Host,
        <<"realm_uri">> := Realm,
        <<"versions">> := Vers
    } = API,

    lists:append([
        dispatch_table_version(Host, Realm, V) || V <- maps:to_list(Vers)
    ]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dispatch_table_version(binary(), binary(), tuple()) ->
    [scheme_rule()] | no_return().

dispatch_table_version(_, _, {_, #{<<"is_active">> := false}}) ->
    [];

dispatch_table_version(Host, Realm, {_Name, Version}) ->
    #{
        <<"base_path">> := BasePath,
        <<"is_deprecated">> := Deprecated,
        <<"paths">> := Paths
    } = Version,
    [
        dispatch_table_path(Host, BasePath, Deprecated, Realm, P, Version)
        || P <- maps:to_list(Paths)
    ].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dispatch_table_path(
    binary(), binary(), boolean(), binary(), tuple(), map()) ->
    [scheme_rule()] | no_return().

dispatch_table_path(
    Host, BasePath, Deprecated, Realm, {Path, Spec0}, Version) ->
    AbsPath = <<BasePath/binary, Path/binary>>,
    {Accepts, Spec1} = maps:take(<<"accepts">>, Spec0),
    {Provides, Spec2} = maps:take(<<"provides">>, Spec1),
    Spec3 = Spec2#{
        <<"content_types_accepted">> => content_types_accepted(Accepts),
        <<"content_types_provided">> => content_types_provided(Provides)
    },

    Schemes = maps:get(<<"schemes">>, Spec3),
    Sec = maps:get(<<"security">>, Spec3),
    Mod = bondy_http_gateway_rest_handler,
    %% Args required by bondy_http_gateway_rest_handler
    Languages = [string:lowercase(X) || X <- maps:get(?LANGUAGES_KEY, Version)],
    Args = #{
        api_spec => Spec3,
        realm_uri => Realm,
        deprecated => Deprecated,
        security => Sec,
        languages => Languages
    },
    lists:flatten([
        [
            {S, Host, Realm, AbsPath, Mod, Args},
            security_scheme_rules(S, Host, BasePath, Realm, Sec)
        ] || S <- Schemes
    ]).


%% @private
%% The OAUTH2 spec requires the scheme to be HTTPS but we
%% will enable it anyway as we assume BONDY would be behind
%% an HTTPS load balancer
security_scheme_rules(
    S, Host, BasePath, Realm,
    #{
        <<"type">> := <<"oauth2">>,
        <<"flow">> := _Any
    } = Sec) ->

    Token = get_token_path(Sec),
    Revoke = get_revoke_path(Sec),

    St = #{
        realm_uri => Realm,
        token_path => Token,
        revoke_path => Revoke
    },

    Mod = bondy_oauth2_rest_handler,
    [
        {S, Host, Realm, <<BasePath/binary, Token/binary>>, Mod, St},
        %% Revoke is secured
        {S, Host, Realm, <<BasePath/binary, Revoke/binary>>, Mod, St},
        %% Json Web Key Set path, in which we publish the public
        {S, Host, Realm, <<BasePath/binary, "/oauth/jwks">>, Mod, St}
    ];

security_scheme_rules(_, _, _, _, _) ->
    %% TODO for other types
    [].


%% @private
get_token_path(#{<<"token_path">> := Token}) ->
    validate_rel_path(Token);

get_token_path(_) ->
    <<"/oauth/token">>.


%% @private
get_revoke_path(#{<<"revoke_token">> := Token}) ->
    validate_rel_path(Token);

get_revoke_path(_) ->
    <<"/oauth/revoke">>.


%% @private
validate_rel_path(<<$/, _Rest/binary>> = Val) ->
    remove_trailing_slash(Val);

validate_rel_path(Val) ->
    error({invalid_path, Val}).


%% @private
remove_trailing_slash(Bin) ->
    case binary:last(Bin) of
        $/ -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns a context where all keys have been assigned funs that take
%% a context as an argument.
%% @end
%% -----------------------------------------------------------------------------
get_context_proxy() ->
    %% We cannot used funs as they will break when we run the
    %% parse transform, so we use mops:proxy()
    #{
        <<"request">> => mops:proxy(),
        <<"action">> => mops:proxy(),
        <<"security">> => mops:proxy()
    }.



%% @private
content_types_accepted(L) when is_list(L) ->
    [content_types_accepted(T) || T <- L];

content_types_accepted(<<"application/json; charset=utf-8">>) ->
    {
        {<<"application">>, <<"json">>, [{<<"charset">>, <<"utf-8">>}]},
        from_json
    };

content_types_accepted(<<"application/json">>) ->
    % {<<"application/json">>, from_json};
    {
        {<<"application">>, <<"json">>, '*'},
        from_json
    };

content_types_accepted(<<"application/msgpack; charset=utf-8">>) ->
    {
        {<<"application">>, <<"msgpack">>, [{<<"charset">>, <<"utf-8">>}]},
        from_msgpack
    };

content_types_accepted(<<"application/msgpack">>) ->
    % {<<"application/msgpack">>, from_msgpack}.
    {{<<"application">>, <<"msgpack">>, '*'}, from_msgpack};

content_types_accepted(<<"application/x-www-form-urlencoded">>) ->
    {
        {<<"application">>, <<"x-www-form-urlencoded">>, '*'},
        from_form_urlencoded
    };

content_types_accepted(Bin) ->
    {Bin, accept}.


%% @private
content_types_provided(L) when is_list(L) ->
    [X || {_, X} <- lists:ukeysort(1, [content_types_provided(T) || T <- L])];

content_types_provided(<<"application/json">>) ->
    % {<<"application/json">>, to_json};
    T = {
        {<<"application">>, <<"json">>, '*'},
        to_json
    },
    %% We force JSON to have the priority as Cowboy chooses based on the order
    %% when no content-type was requested by the user
    {1, T};

content_types_provided(<<"application/json; charset=utf-8">>) ->
    T = {
        {<<"application">>, <<"json">>, [{<<"charset">>, <<"utf-8">>}]},
        to_json
    },
    %% We force JSON to have the priority as Cowboy chooses based on the order
    %% when no content-type was requested by the user
    {1, T};

content_types_provided(<<"application/msgpack">>) ->
    % {<<"application/msgpack">>, to_msgpack};
    T = {{<<"application">>, <<"msgpack">>, '*'}, to_msgpack},
    {2, T};

content_types_provided(<<"application/msgpack; charset=utf-8">>) ->
    T = {{<<"application">>, <<"msgpack">>, [{<<"charset">>, <<"utf-8">>}]}, to_msgpack},
    {2, T};

content_types_provided(Bin) ->
    {3, {Bin, provide}}.


% @TODO Avoid doing this and require the user to setup the environment first!
check_realm_exists(Uri) ->
    case bondy_realm:lookup(Uri) of
        {error, not_found} ->
            Reason = {
                badarg,  <<"There is no realm named ", $', Uri/binary, $'>>
            },
            error(Reason);
        _ ->
            ok
    end.



mops_eval(Expr, Ctxt) ->
    try
        mops:eval(Expr, Ctxt)
    catch
        error:{invalid_expression, [Expr, Term]} ->
            throw(#{
                <<"code">> => ?BONDY_ERROR_HTTP_API_GATEWAY_INVALID_EXPR,
                <<"message">> => iolist_to_binary([
                    <<"There was an error evaluating the MOPS expression '">>,
                    Expr,
                    "' with value '",
                    io_lib:format("~p", [Term]),
                    "'"
                ]),
                <<"description">> => <<"This might be due to an error in the action expression (mops) itself or as a result of a key missing in the response to a gateway action (WAMP or HTTP call).">>
            });
        error:{badkey, Key} ->
            throw(#{
                <<"code">> => ?BONDY_ERROR_HTTP_API_GATEWAY_INVALID_EXPR,
                <<"message">> => <<"There is no value for key '", Key/binary, "' in the HTTP Request context.">>,
                <<"description">> => <<"This might be due to an error in the action expression (mops) itself or as a result of a key missing in the response to a gateway action (WAMP or HTTP call).">>
            });
        error:{badkeypath, Path} ->
            throw(#{
                <<"code">> => ?BONDY_ERROR_HTTP_API_GATEWAY_INVALID_EXPR,
                <<"message">> => <<"There is no value for path '", Path/binary, "' in the HTTP Request context.">>,
                <<"description">> => <<"This might be due to an error in the action expression (mops) itself or as a result of a key missing in the response to a gateway action (WAMP or HTTP call).">>
            })
    end.