%% =============================================================================
%%  bondy_api_gateway_spec.erl -
%% 
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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


-module(bondy_api_gateway_spec).

-define(VARS_KEY, <<"variables">>).
-define(DEFAULTS_KEY, <<"defaults">>).
-define(MOD_PREFIX, "bondy_api_gateway_handler_").

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

-define(MOP_PROXY_FUN_TYPE, {function, 1}).

-define(API_HOST, #{
    <<"host">> => #{
        required => true,
        allow_null => false,
        datatype => binary,
        validator => fun
            (<<"_">>) -> {ok, '_'}; % Cowboy requirement
            (Val) -> {ok, Val}
        end
    },
    <<"realm_uri">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    ?VARS_KEY => #{
        required => true,
        allow_null => false,
        default => #{},
        datatype => map
    },
    ?DEFAULTS_KEY => #{
        required => true,
        allow_null => false,
        default => #{},
        datatype => map,
        validator => ?DEFAULTS_SPEC
    },
    <<"versions">> => #{
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
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"is_active">> => #{
        required => true, 
        allow_null => false,
        default => false,
        datatype => boolean
    },
    <<"is_deprecated">> => #{
        required => true, 
        allow_null => false,
        default => false,
        datatype => boolean
    },
    <<"pool_size">> => #{
        required => true,
        allow_null => false,
        default => 200,
        datatype => pos_integer
    },
    <<"info">> => #{
        required => false,
        datatype => map,
        validator => #{
            <<"title">> => #{
                required => true,
                allow_null => true,
                datatype => binary},
            <<"description">> => #{
                required => true,
                allow_null => true,
                datatype => binary}
        }
    },
    ?VARS_KEY => #{
        required => true,
        allow_null => false,
        default => #{},
        datatype => map
    },
    ?DEFAULTS_KEY => #{
        required => true,
        allow_null => false,
        default => #{},
        datatype => map
    },
    <<"paths">> => #{
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
                    % maps_utils:validate(Val, ?API_PATH) 
                    Val
            end,
            {ok, maps:map(Inner, M1)}
        end
    }
}).


-define(DEFAULTS_SPEC, #{
    <<"schemes">> => #{
        required => true,
        default => ?DEFAULT_SCHEMES
    },
    <<"security">> => #{
        required => true,
        allow_null => false,
        % datatype => map,
        default => #{}
    },
    <<"timeout">> => #{
        required => true,
        % datatype => timeout,
        default => ?DEFAULT_TIMEOUT
    },
    <<"connect_timeout">> => #{
        required => true,
        default => ?DEFAULT_CONN_TIMEOUT
    },
    <<"retries">> => #{
        required => true,
        % datatype => integer,
        default => ?DEFAULT_RETRIES
    },
    <<"retry_timeout">> => #{
        required => true,
        default => ?DEFAULT_RETRY_TIMEOUT
    },
    <<"accepts">> => #{
        required => true,
        allow_null => false,
        default => ?DEFAULT_ACCEPTS
    },
    <<"provides">> => #{
        required => true,
        allow_null => false,
        default => ?DEFAULT_PROVIDES
    },
    <<"headers">> => #{
        required => true,
        allow_null => false,
        default => ?DEFAULT_HEADERS
    }
}).


-define(BASIC, #{
    <<"type">> => #{
        required => true,
        allow_null => false,
        default => <<"basic">>,
        datatype => {in, [<<"basic">>]}
    },
    <<"schemes">> => #{
        required => true,
        allow_null => false,
        default => ?DEFAULT_SCHEMES,
        datatype => {list, binary}
    }
}).

-define(APIKEY, #{
    <<"type">> => #{
        required => true,
        allow_null => false,
        default => <<"api_key">>,
        datatype => {in, [<<"api_key">>]}
    },
    <<"schemes">> => #{
        required => true,
        allow_null => false,
        default => ?DEFAULT_SCHEMES,
        datatype => {list, binary}
    }, 
    <<"header_name">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    }
}).

-define(OAUTH2_SPEC, #{
    <<"type">> => #{
        required => true,
        allow_null => false,
        datatype => {in, [<<"oauth2">>]}
    },
    <<"schemes">> => #{
        required => true,
        allow_null => false,
        default => ?DEFAULT_SCHEMES,
        datatype => {list, binary}
    }, 
    <<"flow">> => #{
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
        required => false,
        datatype => binary
    },
    <<"revoke_token_path">> => #{
        required => false,
        datatype => binary
    },
    <<"description">> => #{
        required => false,
        datatype => binary   
    }
}).


-define(DEFAULT_PATH, #{
    <<"is_collection">> => false,
    <<"variables">> => #{},
    <<"defaults">> => #{},
    <<"accepts">> => <<"{{defaults.accepts}}">>,
    <<"provides">> => <<"{{defaults.provides}}">>,
    <<"schemes">> => <<"{{defaults.schemes}}">>,
    <<"security">> => <<"{{defaults.security}}">>
}).

-define(API_PATH, #{
    <<"is_collection">> => #{
        required => true,
        allow_null => false,
        datatype => boolean
    },
    ?VARS_KEY => #{
        required => true,
        datatype => map
    },
    ?DEFAULTS_KEY => #{
        required => true,
        allow_null => false,
        datatype => map
    },
    <<"accepts">> => #{
        required => true,
        allow_null => false,
        datatype => {list,
            {in, [
                <<"application/json">>, <<"application/msgpack">>
            ]}
        }
    },
    <<"provides">> => #{
        required => true,
        allow_null => false,
        datatype => {list, 
            {in, [
                <<"application/json">>, <<"application/msgpack">>
            ]}
        }
    },
    <<"schemes">> => #{
        required => true,
        allow_null => false,
        datatype => {list, binary}
    }, 
    <<"security">> => #{
        required => true,
        allow_null => false,
        datatype => map,
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
        required => false,
        datatype => map
    },
    <<"get">> => #{
        required => false,
        datatype => map
    },
    <<"head">> => #{
        required => false,
        datatype => map
    },
    <<"options">> => #{
        required => false,
        datatype => map
    },
    <<"patch">> => #{
        required => false,
        datatype => map
    },
    <<"post">> => #{
        required => false,
        datatype => map
    },
    <<"put">> => #{
        required => false,
        datatype => map
    }
}).

-define(DEFAULT_PATH_DEFAULTS, #{
    <<"schemes">> => <<"{{defaults.schemes}}">>,
    <<"security">> => <<"{{defaults.security}}">>,
    <<"accepts">> => <<"{{defaults.accepts}}">>,
    <<"provides">> => <<"{{defaults.provides}}">>,
    <<"headers">> => <<"{{defaults.headers}}">>,
    <<"timeout">> => <<"{{defaults.timeout}}">>,
    <<"connect_timeout">> => <<"{{defaults.connect_timeout}}">>,
    <<"retries">> => <<"{{defaults.retries}}">>,
    <<"retry_timeout">> => <<"{{defaults.retry_timeout}}">>,
    <<"security">> => <<"{{defaults.security}}">>
}).

-define(PATH_DEFAULTS, #{
    <<"schemes">> => #{
        required => true,
        default => <<"{{defaults.schemes}}">>
    },
    <<"security">> => #{
        required => true,
        allow_null => false,
        datatype => map
    },
    <<"timeout">> => #{
        required => true,
        datatype => timeout
    },
    <<"connect_timeout">> => #{
        required => true,
        datatype => timeout
    },
    <<"retries">> => #{
        required => true,
        datatype => integer
    },
    <<"retry_timeout">> => #{
        required => true,
        datatype => integer
    },
    <<"accepts">> => #{
        required => true,
        allow_null => false,
        datatype => {list, 
            {in, [<<"application/json">>, <<"application/msgpack">>]}}
    },
    <<"provides">> => #{
        required => true,
        allow_null => false,
        datatype => {list, 
            {in, [<<"application/json">>, <<"application/msgpack">>]}}
    },
    <<"headers">> => #{
        required => true,
        allow_null => false
    }
}).


-define(REQ_SPEC, #{
    <<"info">> => #{
        required => false,
        validator => #{
            <<"description">> => #{
                required => false,
                allow_null => true,
                datatype => binary
            },
            <<"parameters">> => #{
                required => false,
                validator => ?API_PARAMS
            }
        }
    },
    <<"action">> => #{
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
        required => true,
        allow_null => false
    }

}).

-define(DEFAULT_STATIC_ACTION, #{
    <<"resource">> => <<>>,
    <<"timeout">> => <<"{{defaults.timeout}}">>,
    <<"connect_timeout">> => <<"{{defaults.connect_timeout}}">>,
    <<"retries">> => <<"{{defaults.retries}}">>,
    <<"retry_timeout">> => <<"{{defaults.retry_timeout}}">>
}).

-define(STATIC_ACTION_SPEC, #{
    <<"type">> => #{
        required => true,
        allow_null => false,
        datatype => {in, [<<"static">>]}
    },
    <<"resource">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"timeout">> => #{
        required => true,
        datatype => timeout
    },
    <<"connect_timeout">> => #{
        required => true,
        datatype => timeout
    },
    <<"retries">> => #{
        required => true,
        datatype => integer
    },
    <<"retry_timeout">> => #{
        required => true,
        datatype => integer
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
        required => true,
        allow_null => false,
        datatype => {in, [<<"forward">>]}
    },
    <<"host">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"path">> => #{
        required => true,
        datatype => [binary, ?MOP_PROXY_FUN_TYPE]
    },
    <<"query_string">> => #{
        required => true,
        datatype => [binary, ?MOP_PROXY_FUN_TYPE]
    },
    <<"headers">> => #{
        required => true,
        datatype => [binary, ?MOP_PROXY_FUN_TYPE]
    },
    <<"body">> => #{
        required => true,
        datatype => [binary, ?MOP_PROXY_FUN_TYPE]
    },
    <<"timeout">> => #{
        required => true,
        datatype => [timeout, ?MOP_PROXY_FUN_TYPE]
    },
    <<"connect_timeout">> => #{
        required => true,
        datatype => [timeout, ?MOP_PROXY_FUN_TYPE]
    },
    <<"retries">> => #{
        required => true,
        datatype => [integer, ?MOP_PROXY_FUN_TYPE]
    },
    <<"retry_timeout">> => #{
        required => true,
        datatype => [timeout, ?MOP_PROXY_FUN_TYPE]
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
    <<"arguments">> => [],
    <<"arguments_kw">> => #{},
    <<"timeout">> => <<"{{defaults.timeout}}">>,
    <<"connect_timeout">> => <<"{{defaults.connect_timeout}}">>,
    <<"retries">> => <<"{{defaults.retries}}">>,
    <<"retry_timeout">> => <<"{{defaults.retry_timeout}}">>
}).

-define(WAMP_ACTION_SPEC, #{
    <<"type">> => #{
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
        required => true,
        datatype => [timeout, ?MOP_PROXY_FUN_TYPE]
    },
    <<"retries">> => #{
        required => true,
        datatype => [integer, ?MOP_PROXY_FUN_TYPE]
    },
    <<"procedure">> => #{
        required => true,
        allow_null => false,
        datatype => binary,
        validator => fun wamp_uri:is_valid/1
    },
    <<"options">> => #{
        required => true,
        allow_null => true,
        datatype => [map, ?MOP_PROXY_FUN_TYPE]
    },
    <<"arguments">> => #{
        required => true,
        allow_null => true,
        datatype => [list, ?MOP_PROXY_FUN_TYPE]
    },
    <<"arguments_kw">> => #{
        required => true,
        allow_null => true,
        datatype => [map, ?MOP_PROXY_FUN_TYPE]
    }
}).

-define(DEFAULT_RESPONSE, #{
    <<"headers">> => <<"{{defaults.headers}}">>,
    <<"body">> => <<>>
}).

-define(RESPONSE_SPEC, #{
    <<"headers">> => #{
        required => true,
        allow_null => false,
        datatype => [map, ?MOP_PROXY_FUN_TYPE]
    },
    <<"body">> => #{
        required => true,
        allow_null => false,
        datatype => [binary, ?MOP_PROXY_FUN_TYPE]
    }
}).


-define(API_PARAMS, #{
    <<"name">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"in">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"description">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"required">> => #{
        required => true,
        allow_null => false,
        datatype => boolean
    },
    <<"type">> => #{
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

-type mfb()             ::  {
                                Handler :: module(), 
                                Filename :: file:filename(), 
                                Binary :: binary()
                            }.
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
-export([update_context/2]).
-export([parse/1]).
-export([compile/1]).
-export([load/1]).
-export([gen_path_code/2]).
-export([eval_term/2]).
-export([pp/1]).

-export([maybe_encode/2]).
-export([method_to_lowercase/1]).
-export([perform_action/3]).

-compile({parse_transform, parse_trans_codegen}).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Creates a context object based on the passed Request 
%% (`cowboy_request:request()').
%% @end
%% -----------------------------------------------------------------------------
-spec update_context(cowboy_req:req() | {atom(), map()}, map()) -> map().

update_context({error, Map}, #{<<"request">> := _} = Ctxt) when is_map(Map) ->
    M = #{
        <<"error">> => Map
    },
    maps:put(<<"action">>, M, Ctxt);

update_context({result, Result}, #{<<"request">> := _} = Ctxt) ->
    M = #{
        <<"result">> => Result
    },
    maps:put(<<"action">>, M, Ctxt);

update_context(Req0, Ctxt) ->
    %% At the moment we do not support partially reading the body
    %% nor streams so we drop the NewReq
    {ok, Body, Req1} = cowboy_req:read_body(Req0),

    M = #{
        <<"method">> => cowboy_req:method(Req1),
        <<"scheme">> => cowboy_req:scheme(Req1),
        <<"peer">> => cowboy_req:peer(Req1),
        <<"path">> => cowboy_req:path(Req1),
        <<"host">> => cowboy_req:host(Req1),
        <<"port">> => cowboy_req:port(Req1),
        <<"headers">> => cowboy_req:headers(Req1),
        <<"query_string">> => cowboy_req:qs(Req1),
        <<"query_params">> => maps:from_list(cowboy_req:parse_qs(Req1)),
        <<"bindings">> => to_binary_keys(cowboy_req:bindings(Req1)),
        <<"body">> => Body,
        <<"body_length">> => cowboy_req:body_length(Req1) 
    },
    maps:put(<<"request">>, M, Ctxt).



%% -----------------------------------------------------------------------------
%% @doc
%% Loads a file and calls {@link parse/1}.
%% @end
%% -----------------------------------------------------------------------------
-spec from_file(file:filename()) -> {ok, any()} | {error, any()}.
from_file(Filename) ->
    case file:consult(Filename) of
        {ok, [Spec]} when is_map(Spec) ->
            {ok, parse(Spec, get_context_proxy())};
        _ ->
            {error, invalid_specification_format}
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
-spec parse(map()) -> map() | no_return().

parse(Spec) ->
    parse(Spec, get_context_proxy()).


%% -----------------------------------------------------------------------------
%% @doc
%% Given a valid API Spec returned by {@link parse/1}, dynamically generates
%% and compiles ({@link compile/1}) the erlang modules implementing the 
%% cowboy rest handler behaviour for each API path.
%% @end
%% -----------------------------------------------------------------------------
-spec compile([map()] | map()) -> {[mfb()], [scheme_rule()]} | no_return().

compile(API) when is_map(API) ->
    compile([API]);

compile(L) when is_list(L) ->
    Tuples = [do_compile(X) || X <- L],
    %% From [{mfb(), [scheme_rule()]}] to {[mfb()], [scheme_rule()]}
    {MFBs, Rules} = lists:unzip(lists:append(Tuples)),
    {MFBs, lists:append(Rules)}.


%% -----------------------------------------------------------------------------
%% @doc
%% Given a valid API Spec returned by {@link parse/1}, loads the set
%% of modules returned from a call to {@link compile/1} into the code server. 
%% @end
%% -----------------------------------------------------------------------------
-spec load({[mfb()], [scheme_rule()]}) -> 
    [{Scheme :: binary(), [route_rule()]}] | no_return().

load({MFBs, SchemeRules}) ->
    %% Review: shall we purge existing modules?
    %% TODO We need to consider the case of an existing API being
    %% updated and thus any dangling modules will need to be identified and 
    %% purged too. We can do this by comparing the existing cowboy routes
    %% by getting them from the cowboy env var named 'dispatch_table'
    %% however notice we might need to call purge twice on them as they might
    %% remain in the old code table
    % _ = [code:purge(Mod) || {Mod, _, _} <- MFBs],
    
    %% We load the new modules atomically in two steps, moving the existing modules
    %% from current to old code. New requests will execute the new code while 
    %% inflight request will continue using the old code.
    {ok, Prepared} = code:prepare_loading(MFBs),
    %% ... if we needed to do anything we would here ...
    ok = code:finish_loading(Prepared),

    R = leap_relation:relation(?SCHEME_HEAD, SchemeRules),

    %% We make sure all realms exists
    Realms = leap_relation:project(R, [{var, realm}]),
    _ = [bondy_realm:get(Realm) || {Realm} <- leap_relation:tuples(Realms)],

    %% We project the desired output
    PMS = {function, collect, [?VAR(path), ?VAR(mod), ?VAR(state)]},
    Proj1 = {?VAR(scheme), ?VAR(host), {as, PMS, ?VAR(pms)}},
    HPMS = {function, collect, [?VAR(host), ?VAR(pms)]},
    Proj2 = {?VAR(scheme), {as, HPMS, ?VAR(hpms)}},
    SHP = leap_relation:summarize(
        leap_relation:summarize(R, Proj1, #{}), 
        Proj2, #{}
    ),
    leap_relation:tuples(SHP).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
pp(Forms) ->
    io:fwrite("~s", [[erl_pp:form(F) || F <- Forms]]).




%% =============================================================================
%% PRIVATE: PARSING
%% =============================================================================




%% @private
-spec parse(Spec :: map(), Ctxt :: map()) -> NewSpec :: map().
parse(Spec, Ctxt) ->
    parse_host(maps_utils:validate(Spec, ?API_HOST), Ctxt).


%% @private
-spec parse_host(map(), map()) -> map().
parse_host(Host0, Ctxt0) ->
    {Vars, Host1} = maps:take(?VARS_KEY, Host0),
    {Defs, Host2} = maps:take(?DEFAULTS_KEY, Host1),
    Ctxt1 = Ctxt0#{
        ?VARS_KEY => Vars,
        ?DEFAULTS_KEY => Defs
    },
    
    %% parse all versions
    Vs0 = maps:get(<<"versions">>, Host2),
    Fun = fun(_, V) -> parse_version(V, Ctxt1) end,
    Vs1 = maps:map(Fun, Vs0),
    Host3 = maps:without([?VARS_KEY, ?DEFAULTS_KEY], Host2),
    maps:update(<<"versions">>, Vs1, Host3).


%% @private
-spec parse_version(map(), map()) -> map().
parse_version(V0, Ctxt0) ->
    %% We merge variables and defaults
    {V1, Ctxt1} = merge(V0, Ctxt0),
    %% We then validate the resulting version
    V2 = maps_utils:validate(V1, ?API_VERSION),
    %% We merge again in case the validation added defaults
    {V3, Ctxt2} = merge(V2, Ctxt1),
    %% Finally we parse the contained paths
    Fun = fun(Uri, P) -> 
        try 
            parse_path(P, Ctxt2) 
        catch 
            error:{badkey, Key} ->
                io:format(
                    "Path ~p~nST:~p~n", 
                    [P, erlang:get_stacktrace()]),
                error({
                    badarg, 
                    <<"The key '", Key/binary, "' does not exist in path '", Uri/binary, "'.">>
                })
        end
    end,
    V4 = maps:without([?VARS_KEY, ?DEFAULTS_KEY], V3),
    maps:update(
        <<"paths">>, maps:map(Fun, maps:get(<<"paths">>, V4)), V4).


%% @private
parse_path(P0, Ctxt0) ->
    %% The path should have at least one HTTP method
    %% otherwise this will fail with an error
    L = allowed_methods(P0),
    %% We merge path spec with gateway default spec
    P1  = maps:merge(?DEFAULT_PATH, P0),
    %% We merge path's defaults key with gateway defaults
    % Defs0 = maps:merge(?DEFAULT_PATH_DEFAULTS, maps:get(?DEFAULTS_KEY, P1)),
    % P2 = maps:update(?DEFAULTS_KEY, Defs0, P1),
    P2 = P1,
    %% We merge path's variables and defaults into context
    {P3, Ctxt1} = merge(P2, eval(Ctxt0)),

    %% We apply defaults and evaluate before validating
    Ctxt2 = eval(P3, Ctxt1),
    P4 = validate(?DEFAULTS_KEY, P3, ?PATH_DEFAULTS),

    P5 = parse_path_elements(P4, Ctxt2),

    %% FInally we validate the resulting path
    P6 = maps_utils:validate(P5, ?API_PATH),
    %% HTTP (and COWBOY) requires uppercase method names
    P7 = maps:put(<<"allowed_methods">>, to_uppercase(L), P6),
    P8 = maps:without([?VARS_KEY, ?DEFAULTS_KEY], P7), 

    %% Now we evaluate each request type spec
    PFun = fun(Method, IPath) ->
        Sec0 = maps:get(Method, IPath),
        try  
            Sec1 = parse_request_method(Sec0, Ctxt2), 
            Sec2 = maps_utils:validate(Sec1, ?REQ_SPEC),
            maps:update(Method, Sec2, IPath)
        catch
            error:{badkey, Key} ->
                io:format("Method ~p\nCtxt: ~p\nST:~p", [Sec0, Ctxt2, erlang:get_stacktrace()]),
                error({badarg, <<"The key '", Key/binary, "' does not exist in path method section '", Method/binary, $'>>})
        end
    end,
    lists:foldl(PFun, P8, L).
    

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
    Eval = fun(V) -> eval_term(V, Ctxt) end,    
    P2 = maps:update_with(H, Eval, P1),
    parse_path_elements(T, P2, Ctxt);

parse_path_elements([], Path, _) ->
    Path.

    
%% @private
parse_request_method(Spec, Ctxt) ->
    #{
        % <<"accepts">> := Acc,
        % <<"provides">> := Prov,
        <<"action">> := Act,
        <<"response">> := Resp
    } = Spec,
    Spec#{
        % <<"accepts">> := eval_term(Acc, Ctxt),
        % <<"provides">> := eval_term(Prov, Ctxt),
        
        <<"action">> => parse_action(Act, Ctxt),
        %% TODO we should be doing parser_response() here!
        <<"response">> => parse_response(Resp, Ctxt)
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
-spec parse_action(map(), map()) -> map().
parse_action(#{<<"type">> := <<"wamp_", _/binary>>} = Spec, Ctxt) ->
    maps_utils:validate(
        eval_term(maps:merge(?DEFAULT_WAMP_ACTION, Spec), Ctxt), 
        ?WAMP_ACTION_SPEC
    );

parse_action(#{<<"type">> := <<"forward">>} = Spec, Ctxt) ->
    maps_utils:validate(
        eval_term(maps:merge(?DEFAULT_FWD_ACTION, Spec), Ctxt), 
        ?FWD_ACTION_SPEC
    );

parse_action(#{<<"type">> := <<"static">>} = Spec, Ctxt) ->
    maps_utils:validate(
        eval_term(maps:merge(?DEFAULT_STATIC_ACTION, Spec), Ctxt), 
        ?STATIC_ACTION_SPEC
    );

parse_action(#{<<"type">> := Type}, _) ->
    error({unsupported_action_type, Type});

parse_action(_, _) ->
    error(action_type_missing).



parse_response(Spec0, Ctxt) ->
    OR0 = maps:get(<<"on_result">>, Spec0, ?DEFAULT_RESPONSE),
    OE0 = maps:get(<<"on_error">>, Spec0, ?DEFAULT_RESPONSE),

    [OR1, OE1] = [
        maps_utils:validate(
            eval_term(maps:merge(?DEFAULT_RESPONSE, X), Ctxt), 
            ?RESPONSE_SPEC
        ) || X <- [OR0, OE0]
    ],
    #{
        <<"on_result">> => OR1,
        <<"on_error">> => OE1
    }.


%% @private
-spec eval_term(any(), map()) -> any().
eval_term(F, Ctxt) when is_function(F, 1) ->
    F(Ctxt);

eval_term(Map, Ctxt) when is_map(Map) ->
    F = fun
        (_, V) when is_map(V) ->
            eval_term(V, Ctxt);
        (_, V) when is_list(V) ->
            eval_term(V, Ctxt);
        (_, V) -> 
            mops:eval(V, Ctxt) 
    end,
    maps:map(F, Map);

eval_term(L, Ctxt) when is_list(L) ->
    [eval_term(X, Ctxt) || X <- L];

eval_term(T, Ctxt) ->
    mops:eval(T, Ctxt).




merge(S0, Ctxt0) ->
    %% We merge variables and defaults
    VVars = maps:get(?VARS_KEY, S0, #{}),
    VDefs = maps:get(?DEFAULTS_KEY, S0, #{}),
    MVars = maps:merge(maps:get(?VARS_KEY, Ctxt0), VVars),
    MDefs = maps:merge(maps:get(?DEFAULTS_KEY, Ctxt0), VDefs),
    %% We update section and ctxt
    S1 = S0#{?VARS_KEY => MVars, ?DEFAULTS_KEY => MDefs},
    Ctxt1 = maps:update(?VARS_KEY, MVars, Ctxt0),
    Ctxt2 = maps:update(?DEFAULTS_KEY, MDefs, Ctxt1),
    {S1, Ctxt2}.


eval(Ctxt) ->
    eval(Ctxt, Ctxt).


%% @private
eval(S0, Ctxt0) ->
    Vars = maps:get(?VARS_KEY, S0),
    Defs = maps:get(?DEFAULTS_KEY, S0),
    %% We evaluate variables by iterating over each 
    %% updating the context in each turn as we might have interdependencies
    %% amongst them
    VFun = fun(Var, Val, ICtxt) ->
        IVars1 = maps:update(
            Var, eval_term(Val, ICtxt), maps:get(?VARS_KEY, ICtxt)),
        maps:update(?VARS_KEY, IVars1, ICtxt)
    end,
    Ctxt1 = maps:fold(VFun, Ctxt0, Vars),
    
    %% We evaluate defaults
    DFun = fun(Var, Val, ICtxt) ->
        IDefs1 = maps:update(
            Var, eval_term(Val, ICtxt), maps:get(?DEFAULTS_KEY, ICtxt)),
        maps:update(?DEFAULTS_KEY, IDefs1, ICtxt)
    end,
    maps:fold(DFun, Ctxt1, Defs).



%% =============================================================================
%% PRIVATE: COMPILE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec do_compile(map()) -> [{mfb(), [scheme_rule()]}].

do_compile(API) ->
    #{
        <<"host">> := Host,
        <<"realm_uri">> := Realm,
        <<"versions">> := Vers
    } = API,

    lists:append([compile_version(Host, Realm, V) || V <- maps:to_list(Vers)]).
    

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec compile_version(binary(), binary(), tuple()) ->
    [{mfb(), [scheme_rule()]}] | no_return().

compile_version(_, _, {_, #{<<"is_active">> := false}}) ->
    [];

compile_version(Host, Realm, {_Name, Spec}) ->
    #{
        <<"base_path">> := BasePath,
        <<"is_deprecated">> := Deprecated,
        <<"paths">> := Paths
    } = Spec,
    [compile_path(Host, BasePath, Deprecated, Realm, P) 
        || P <- maps:to_list(Paths)].


%% -----------------------------------------------------------------------------
%% @doc
%% Generates and compiles the erlang code for the path's cowboy rest handler
%% returning a tuple containing an mfb() and a list of scheme_rule() objects.
%% @end
%% -----------------------------------------------------------------------------
-spec compile_path(binary(), binary(), boolean(), binary(), tuple()) -> 
    {mfb(), [scheme_rule()]} | no_return().

compile_path(Host, BasePath, Deprecated, Realm, {Path, Spec}) ->
    AbsPath = <<BasePath/binary, Path/binary>>,
    {Mod, Forms} = gen_path_code(AbsPath, Spec),
    {ok, Mod, Bin} = compile:forms(Forms, [verbose, report_errors]),
    FName = atom_to_list(Mod) ++ ".erl",
    State = #{
        realm_uri => Realm, 
        deprecated => Deprecated,
        authmethod => oauth2 %% TODO Get this from API Version Spec
    },
    Schemes = maps:get(<<"schemes">>, Spec),
    Sec = maps:get(<<"security">>, Spec),
    Rules = lists:flatten([
        [
            {S, Host, Realm, AbsPath, Mod, State},
            security_scheme_rules(S, Host, BasePath, Realm, Sec)
        ] || S <- Schemes
    ]),
    {{Mod, FName, Bin}, Rules}.
    

%% @private
%% The OAUTH2 spec requires the scheme to be HTTPS but we 
%% will enable it anyway as we assume BONDY would be behind
%% an HTTPS load balancer
security_scheme_rules(
    S, Host, BasePath, Realm, 
    #{
        <<"type">> := <<"oauth2">>, 
        <<"flow">> := <<"resource_owner_password_credentials">>
    } = Sec) ->

    #{
        <<"token_path">> := Token,
        <<"revoke_token_path">> := Revoke
    } = Sec,

    A = #{realm_uri => Realm},
    B = #{authmethod => oauth2, realm_uri => Realm},

    Mod = bondy_api_oauth2_handler,
    [
        {S, Host, Realm, <<BasePath/binary, Token/binary>>, Mod, A},
        %% Revoke is secured
        {S, Host, Realm, <<BasePath/binary, Revoke/binary>>, Mod, B}
    ];

security_scheme_rules(_, _, _, _, _) ->
    %% TODO for other types
    [].

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec gen_path_code(binary(), PathSpec :: map()) -> 
    {Mod :: atom(), Forms :: list()} | no_return().

gen_path_code(Name, PathSpec) ->
    ModName = list_to_atom(?MOD_PREFIX ++ integer_to_list(erlang:phash2(Name))),
    AllowedMethods = maps:get(<<"allowed_methods">>, PathSpec),
    IsCollection = maps:get(<<"is_collection">>, PathSpec),
    Accepts = content_types_accepted(maps:get(<<"accepts">>, PathSpec)),
    Provides = content_types_provided(maps:get(<<"provides">>, PathSpec)),
    
    % Delete = maps:get(<<"delete">>, PathSpec, #{}),
    Get = maps:get(<<"get">>, PathSpec, #{}),
    Head = maps:get(<<"head">>, PathSpec, #{}),
    % Options = maps:get(<<"options">>, PathSpec, #{}),
    Patch = maps:get(<<"patch">>, PathSpec, #{}),
    Post = maps:get(<<"post">>, PathSpec, #{}),
    Put = maps:get(<<"put">>, PathSpec, #{}),

    %% The arguments for codegen:gen_module should be inline, so we cannot
    %% generate the list dynamically and use {'$var', any()} to inject
    %% values
    Forms = codegen:gen_module(
        {'$var', ModName},
        [
            {init, 2},
            {allowed_methods, 2},
            {content_types_accepted, 2},
            {content_types_provided, 2},
            {is_authorized, 2},
            {resource_exists, 2},
            {resource_existed, 2},
            {to_json, 2},
            {to_msgpack, 2},
            {provide, 4},
            {from_json, 2},
            {from_msgpack, 2}
        ],
        [
            %% API
            {init, fun(Req, St0) ->
                io:format("Entering init with state: ~p~n", [St0]),
                Session = undefined, %TODO
                % SessionId = 1,
                % Ctxt0 = bondy_context:set_peer(
                %     bondy_context:new(), cowboy_req:peer(Req)),
                % Ctxt1 = bondy_context:set_session_id(SessionId, Ctxt0),
                St1 = St0#{
                    is_collection => {'$var', IsCollection}, 
                    session => Session,
                    % context => Ctxt1, 
                    api_context => update_context(Req, #{})
                },
                {cowboy_rest, Req, St1}
            end},
            {allowed_methods, fun(Req, St) ->
                {{'$var', AllowedMethods}, Req, St}
            end},
            {content_types_accepted, fun(Req, St) ->
                {{'$var', Accepts}, Req, St}
            end},
            {content_types_provided, fun(Req, St) ->
                {{'$var', Provides}, Req, St}
            end},
            {is_authorized, fun(Req, St) ->
                %% TODO get auth method and status from St and validate
                %% check scopes vs action requirements
                {true, Req, St}
            end},
            {resource_exists, fun(Req, St) ->
                %% TODO
                {true, Req, St}
            end},
            {resource_existed, fun(Req, St) ->  
                {false, Req, St}
            end},
            {to_json, fun(Req, St) ->
                provide(cowboy_req:method(Req), json, Req, St)
            end},
            {to_msgpack, fun(Req, St) ->
                provide(cowboy_req:method(Req), msgpack, Req, St)
            end},
            {provide, fun
                (<<"GET">>, Enc, Req0, St0) -> 
                    Spec = {'$var', Get},
                    case perform_action(<<"GET">>, Spec, St0) of
                        {ok, Body, Headers, St1} ->
                            Req1 = cowboy_req:set_resp_headers(Headers, Req0),
                            {maybe_encode(Enc, Body), Req1, St1};
                        {error, #{<<"code">> := Code} = Body, Headers, St1} ->
                            Req1 = cowboy_req:set_resp_headers(Headers, Req0),
                            Json = maybe_encode(Enc, Body),
                            Req2 = cowboy_req:set_resp_body(Json, Req1),
                            Req3 = cowboy_req:reply(
                                bondy_utils:error_uri_to_status_code(Code), Req2),
                            {stop, Req3, St1}
                    end;          
                (<<"HEAD">>, Enc, Req0, St0) -> 
                    Spec = {'$var', Head},
                    case perform_action(<<"HEAD">>, Spec, St0) of
                        {ok, Body, Headers, St1} ->
                            Req1 = cowboy_req:set_resp_headers(Headers, Req0),
                            {maybe_encode(Enc, Body), Req1, St1};
                        {ok, HTTPCode, Body, Headers, St1} ->
                            Req1 = cowboy_req:set_resp_headers(Headers, Req0),
                            Req2 = cowboy_req:set_resp_body(
                                maybe_encode(Enc, Body), Req1),
                            Req3 = cowboy_req:reply(HTTPCode, Req2),
                            {stop, Req3, St1};
                        {error, #{<<"code">> := Code} = Body, Headers, St1} ->
                            Req1 = cowboy_req:set_resp_headers(Headers, Req0),
                            Req2 = cowboy_req:set_resp_body(
                                maybe_encode(Enc, Body), Req1),
                            Req3 = cowboy_req:reply(
                                bondy_utils:error_uri_to_status_code(Code), Req2),
                            {stop, Req3, St1};
                        {error, HTTPCode, Body, Headers, St1} ->
                            Req1 = cowboy_req:set_resp_headers(Headers, Req0),
                            Req2 = cowboy_req:set_resp_body(
                                maybe_encode(Enc, Body), Req1),
                            Req3 = cowboy_req:reply(HTTPCode, Req2),
                            {stop, Req3, St1}
                    end
            end},
            {from_json, fun(Req, St) ->
                from_json(cowboy_req:method(Req), Req, St)
            end},
            {from_json, fun
                (<<"PATCH">>, Req, St) -> 
                    _Spec = {'$var', Patch},
                    %% true, {true, URI}, false
                    {true, Req, St};
                (<<"POST">>, Req, St) -> 
                    _Spec = {'$var', Post},
                    %% true, {true, URI}, false
                    Uri = <<>>, %TODO
                    {{true, Uri}, Req, St};
                (<<"PUT">>, Req, St) -> 
                    _Spec = {'$var', Put},
                    %% true, {true, URI}, false
                    {true, Req, St}
            end},
            {from_msgpack, fun(Req, St) ->
                from_msgpack(cowboy_req:method(Req), Req, St)
            end},
            {from_msgpack, fun
                (<<"PATCH">>, Req, St) -> 
                    _Spec = {'$var', Patch},
                    %% true, {true, URI}, false
                    {true, Req, St};
                (<<"POST">>, Req, St) -> 
                    _Spec = {'$var', Post},
                    %% true, {true, URI}, false
                    Uri = <<>>, %TODO
                    {{true, Uri}, Req, St};
                (<<"PUT">>, Req, St) -> 
                    _Spec = {'$var', Put},
                    %% true, {true, URI}, false
                    {true, Req, St}
            end},
            %% PRIVATE
            {update_context, fun update_context/2},
            {maybe_encode, fun maybe_encode/2},
            {perform_action, fun perform_action/3},
            {to_binary_keys, fun to_binary_keys/1},
            {eval_term, fun eval_term/2},
            {method_to_lowercase, fun method_to_lowercase/1},
            {from_http_response, fun from_http_response/5},
            {url, fun url/3}
        ]
    ),
    {ModName, Forms}.


%% @private
%% -----------------------------------------------------------------------------
%% @doc
%% Returns a context where all keys have been assigned funs that take 
%% a context as an argument.
%% @end
%% -----------------------------------------------------------------------------
get_context_proxy() ->
    %% We cannot used funs as they will break when we run the 
    %% parse transform, so we use '$mop_proxy'
    #{
        <<"request">> => '$mop_proxy',
        <<"action">> => '$mop_proxy'
    }.



%% @private
content_types_accepted(L) when is_list(L) ->
    [content_types_accepted(T) || T <- L];

content_types_accepted(<<"application/json">>) ->
    {<<"application/json">>, from_json};

content_types_accepted(<<"application/msgpack">>) ->
    {<<"application/msgpack">>, from_msgpack}.


%% @private
content_types_provided(L) when is_list(L) ->
    [content_types_provided(T) || T <- L];

content_types_provided(<<"application/json">>) ->
    {<<"application/json">>, to_json};

content_types_provided(<<"application/msgpack">>) ->
    {<<"application/msgpack">>, to_msgpack}.



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


%% @private
validate(Key, Map, Spec) ->
    maps:update(
        Key, maps_utils:validate(maps:get(Key, Map), Spec), Map).
    
to_binary_keys(Map) ->
    F = fun(K, V, Acc) ->
        maps:put(list_to_binary(atom_to_list(K)), V, Acc)
    end,
    maps:fold(F, #{}, Map).





%% @private
perform_action(_, #{}, St) ->
    {ok, <<>>, [], St};

perform_action(
    Method,
    #{<<"action">> := #{<<"type">> := <<"forward">>} = Act} = Spec, 
    St0) ->
    Ctxt0 = maps:get(api_context, St0),
    %% Arguments might be funs waiting for the
    %% request.* values to be bound
    %% so we need to evaluate them passing the
    %% context
    #{
        <<"host">> := Host,
        <<"path">> := Path,
        <<"query_string">> := QS,
        <<"headers">> := Headers,
        <<"timeout">> := T,
        <<"connect_timeout">> := CT,
        % <<"retries">> := R,
        % <<"retry_timeout">> := RT,
        <<"body">> := Body
    } = eval_term(Act, Ctxt0),
    Opts = [
        {connect_timeout, CT},
        {recv_timeout, T}
    ],
    Url = url(Host, Path, QS),
    io:format(
        "Gateway is forwarding request to ~p~n", 
        [[Method, Url, Headers, Body, Opts]]
    ),
    RSpec = maps:get(<<"response">>, Spec),

    case hackney:request(
        method_to_lowercase(Method), Url, Headers, Body, Opts) 
    of
        {ok, StatusCode, RespHeaders} when Method =:= head ->
            from_http_response(StatusCode, RespHeaders, <<>>, RSpec, St0);
        
        {ok, StatusCode, RespHeaders, ClientRef} ->
            {ok, Body} = hackney:body(ClientRef),
            from_http_response(StatusCode, RespHeaders, Body, RSpec, St0);
        
        {error, Reason} ->
            Ctxt1 = update_context({error, bondy_error:error_map(Reason)}, Ctxt0),
            #{
                <<"body">> := Body,
                <<"headers">> := Headers
            } = eval_term(maps:get(<<"on_error">>, RSpec), Ctxt1),
            St1 = maps:update(api_context, Ctxt1, St0),
            {error, Body, Headers, St1}
    end;

perform_action(
    _Method, 
    #{<<"action">> := #{<<"type">> := <<"wamp_call">>} = Act} = Spec, St0) ->
    Ctxt0 = maps:get(api_context, St0),
    %% Arguments might be funs waiting for the
    %% request.* values to be bound
    %% so we need to evaluate them passing the
    %% context
    #{
        <<"arguments">> := A,
        <<"arguments_kw">> := Akw,
        <<"options">> := Opts,
        <<"procedure">> := P,
        <<"retries">> := _R,
        <<"timeout">> := _T
    } = eval_term(Act, Ctxt0),
    RSpec = maps:get(<<"response">>, Spec),
    case bondy:call(P, Opts, A, Akw) of
        {ok, Result, Ctxt1} ->
            Ctxt2 = update_context({result, Result}, Ctxt1),
            #{
                <<"body">> := Body,
                <<"headers">> := Headers
            } = eval_term(maps:get(<<"on_result">>, RSpec), Ctxt2),
            St1 = maps:update(api_context, Ctxt2, St0),
            {ok, Body, Headers, St1};
        {error, Error, Ctxt1} ->
            Ctxt2 = update_context({error, Error}, Ctxt1),
            #{
                <<"body">> := Body,
                <<"headers">> := Headers
            } = eval_term(maps:get(<<"on_error">>, RSpec), Ctxt2),
            St1 = maps:update(api_context, Ctxt2, St0),
            Code = 500,
            {error, Code, Body, Headers, St1}
    end.


%% @private
from_http_response(StatusCode, RespBody, RespHeaders, Spec, St0) 
when StatusCode >= 400 andalso StatusCode < 600->
    Ctxt0 = maps:get(api_context, St0),
    Error = #{ 
        <<"status_code">> => StatusCode,
        <<"body">> => RespBody,
        <<"headers">> => maps:from_list(RespHeaders)
    },
    Ctxt1 = update_context({error, Error}, Ctxt0),
    #{
        <<"body">> := Body,
        <<"headers">> := Headers
    } = eval_term(maps:get(<<"on_error">>, Spec), Ctxt1),
    St1 = maps:update(api_context, Ctxt1, St0),
    {error, StatusCode, Body, Headers, St1};

from_http_response(StatusCode, RespBody, RespHeaders, Spec, St0) ->
    Ctxt0 = maps:get(api_context, St0),
    Result = #{ 
        <<"status_code">> => StatusCode,
        <<"body">> => RespBody,
        <<"headers">> => maps:from_list(RespHeaders)
    },
    Ctxt1 = update_context({error, Result}, Ctxt0),
    #{
        <<"body">> := Body,
        <<"headers">> := Headers
    } = eval_term(maps:get(<<"on_result">>, Spec), Ctxt1),
    St1 = maps:update(api_context, Ctxt1, St0),
    {ok, StatusCode, Body, Headers, St1}.


%% @private
maybe_encode(_, <<>>) ->
    <<>>;

maybe_encode(json, Term) ->
    case jsx:is_json(Term) of
        true ->
            Term;
        false ->
            jsx:encode(Term)
    end;

 maybe_encode(msgpack, Term) ->
     %% TODO see if we can catch error when Term is already encoded
     msgpack:pack(Term).


%% @private
%% -----------------------------------------------------------------------------
%% @doc
%% Used for hackney HTTP client
%% @end
%% -----------------------------------------------------------------------------
method_to_lowercase(<<"DELETE">>) -> delete;
method_to_lowercase(<<"GET">>) -> get;
method_to_lowercase(<<"HEAD">>) -> head;
method_to_lowercase(<<"OPTIONS">>) -> options;
method_to_lowercase(<<"PATCH">>) -> patch;
method_to_lowercase(<<"POST">>) -> post;
method_to_lowercase(<<"PUT">>) -> put.


%% @private
url(Host, Path, <<>>) ->
    <<Host/binary, Path/binary>>;

url(Host, Path, QS) ->
    <<Host/binary, Path/binary, $?, QS/binary>>.


