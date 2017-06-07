%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2017. All rights reserved.
%% -----------------------------------------------------------------------------

-module(juno_rest_api_gateway_spec_parser).

-define(VARS_KEY, <<"variables">>).
-define(DEFAULTS_KEY, <<"defaults">>).
-define(MOD_PREFIX, "juno_rest_api_gateway_handler_").

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
        default => <<"authorization">>,
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
    <<"body">> => <<>>,
    <<"headers">> => #{}
}).

-define(STATIC_ACTION_SPEC, #{
    <<"type">> => #{
        required => true,
        allow_null => false,
        datatype => {in, [<<"static">>]}
    },
    <<"headers">> => #{
        required => true,
        datatype => [map, ?MOP_PROXY_FUN_TYPE]
    },
    <<"body">> => #{
        required => true,
        datatype => [map, binary, ?MOP_PROXY_FUN_TYPE]
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
        datatype => [map, ?MOP_PROXY_FUN_TYPE]
    },
    <<"body">> => #{
        required => true,
        datatype => [map, binary, ?MOP_PROXY_FUN_TYPE]
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
    <<"details">> => #{},
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
    <<"details">> => #{
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
        datatype => [map, binary, ?MOP_PROXY_FUN_TYPE]
    },
    <<"uri">> => #{
        required => false,
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
    case file:consult(Filename) of
        {ok, [Spec]} when is_map(Spec) ->
            {ok, parse(Spec, get_context_proxy())};
        _ ->
            {error, {invalid_specification_format, Filename}}
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
%% a cowboy dispatch table.
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
%% Given a valid API Spec returned by {@link parse/1}, dynamically generates
%% a cowboy dispatch table.
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
    _ = [juno_realm:get(Realm) || {Realm} <- leap_relation:tuples(Realms)],

    
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
                false ->
                    error({
                        badarg, 
                        <<"The key ", H/binary, " does not exist in path.">>
                    })
            end
    end,    
    Eval = fun(V) -> juno_utils:eval_term(V, Ctxt) end,    
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
        % <<"accepts">> := juno_utils:eval_term(Acc, Ctxt),
        % <<"provides">> := juno_utils:eval_term(Prov, Ctxt),
        
        <<"action">> => parse_action(Act, Ctxt),
        %% TODO we should be doing parser_response() here!
        <<"response">> => parse_response(Resp, Ctxt)
    }.


%% @private
%% -----------------------------------------------------------------------------
%% @doc
%% Parses a path action section definition. Before applying validations
%% this function applies defaults values and evaluates all terms 
%% (using mop:eval/2).
%% If the action type provided is not reconised it fails with 
%% `{unsupported_action_type, Type}'. 
%% If an action type is not provided if fails with `action_type_missing'.
%% @end
%% -----------------------------------------------------------------------------
-spec parse_action(map(), map()) -> map().
parse_action(#{<<"type">> := <<"wamp_", _/binary>>} = Spec, Ctxt) ->
    maps_utils:validate(
        juno_utils:eval_term(maps:merge(?DEFAULT_WAMP_ACTION, Spec), Ctxt), 
        ?WAMP_ACTION_SPEC
    );

parse_action(#{<<"type">> := <<"forward">>} = Spec, Ctxt) ->
    maps_utils:validate(
        juno_utils:eval_term(maps:merge(?DEFAULT_FWD_ACTION, Spec), Ctxt), 
        ?FWD_ACTION_SPEC
    );

parse_action(#{<<"type">> := <<"static">>} = Spec, Ctxt) ->
    maps_utils:validate(
        juno_utils:eval_term(maps:merge(?DEFAULT_STATIC_ACTION, Spec), Ctxt), 
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
            juno_utils:eval_term(maps:merge(?DEFAULT_RESPONSE, X), Ctxt), 
            ?RESPONSE_SPEC
        ) || X <- [OR0, OE0]
    ],
    #{
        <<"on_result">> => OR1,
        <<"on_error">> => OE1
    }.

%% @private
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
            Var, juno_utils:eval_term(Val, ICtxt), maps:get(?VARS_KEY, ICtxt)),
        maps:update(?VARS_KEY, IVars1, ICtxt)
    end,
    Ctxt1 = maps:fold(VFun, Ctxt0, Vars),
    
    %% We evaluate defaults
    DFun = fun(Var, Val, ICtxt) ->
        IDefs1 = maps:update(
            Var, juno_utils:eval_term(Val, ICtxt), maps:get(?DEFAULTS_KEY, ICtxt)),
        maps:update(?DEFAULTS_KEY, IDefs1, ICtxt)
    end,
    maps:fold(DFun, Ctxt1, Defs).



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

    lists:append([dispatch_table_version(Host, Realm, V) || V <- maps:to_list(Vers)]).
    

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dispatch_table_version(binary(), binary(), tuple()) ->
    [scheme_rule()] | no_return().

dispatch_table_version(_, _, #{<<"is_active">> := false}) ->
    [];

dispatch_table_version(Host, Realm, {_Name, Spec}) ->
    #{
        <<"base_path">> := BasePath,
        <<"is_deprecated">> := Deprecated,
        <<"paths">> := Paths
    } = Spec,
    [dispatch_table_path(Host, BasePath, Deprecated, Realm, P) 
        || P <- maps:to_list(Paths)].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dispatch_table_path(binary(), binary(), boolean(), binary(), tuple()) -> 
    [scheme_rule()] | no_return().

dispatch_table_path(Host, BasePath, Deprecated, Realm, {Path, Spec0}) ->
    AbsPath = <<BasePath/binary, Path/binary>>,
    {Accepts, Spec1} = maps:take(<<"accepts">>, Spec0),
    {Provides, Spec2} = maps:take(<<"provides">>, Spec1),
    Spec3 = Spec2#{
        <<"content_types_accepted">> => content_types_accepted(Accepts),
        <<"content_types_provided">> => content_types_provided(Provides)
    },
    
    Schemes = maps:get(<<"schemes">>, Spec3),
    Sec = maps:get(<<"security">>, Spec3),
    Mod = juno_rest_api_gateway_handler,
    %% State informally defined in juno_rest_api_gateway_handler
    State = #{
        api_spec => Spec3,
        realm_uri => Realm, 
        deprecated => Deprecated,
        security => Sec
    },
    lists:flatten([
        [
            {S, Host, Realm, AbsPath, Mod, State},
            security_scheme_rules(S, Host, BasePath, Realm, Sec)
        ] || S <- Schemes
    ]).
    

%% @private
%% The OAUTH2 spec requires the scheme to be HTTPS but we 
%% will enable it anyway as we assume JUNO would be behind
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

    St = #{realm_uri => Realm},

    Mod = juno_rest_oauth2_handler,
    [
        {S, Host, Realm, <<BasePath/binary, Token/binary>>, Mod, St},
        %% Revoke is secured
        {S, Host, Realm, <<BasePath/binary, Revoke/binary>>, Mod, St}
    ];

security_scheme_rules(_, _, _, _, _) ->
    %% TODO for other types
    [].



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
        <<"action">> => '$mop_proxy',
        <<"security">> => '$mop_proxy'
    }.



%% @private
content_types_accepted(L) when is_list(L) ->
    [content_types_accepted(T) || T <- L];

content_types_accepted(<<"application/json">>) ->
    % {<<"application/json">>, from_json};
    {{<<"application">>, <<"json">>, '*'}, from_json};


content_types_accepted(<<"application/msgpack">>) ->
    % {<<"application/msgpack">>, from_msgpack}.
    {{<<"application">>, <<"msgpack">>, '*'}, from_msgpack}.


%% @private
content_types_provided(L) when is_list(L) ->
    [content_types_provided(T) || T <- L];

content_types_provided(<<"application/json">>) ->
    % {<<"application/json">>, to_json};
    {{<<"application">>, <<"json">>, '*'}, to_json};

content_types_provided(<<"application/msgpack">>) ->
    % {<<"application/msgpack">>, to_msgpack};
    {{<<"application">>, <<"msgpack">>, '*'}, to_msgpack}.





