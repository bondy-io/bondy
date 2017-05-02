%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2017. All rights reserved.
%% -----------------------------------------------------------------------------

-module(juno_rest_api_gateway_spec).

-define(VARS_KEY, <<"variables">>).
-define(DEFAULTS_KEY, <<"defaults">>).

-define(HTTP_METHODS, [
     <<"delete">>,
    <<"get">>,
    <<"head">>,
    <<"options">>,
    <<"patch">>,
    <<"post">>,
    <<"put">>
]).

-define(API_HOST, #{
    <<"host">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"realm_uri">> => #{
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"auth">> => #{
        required => false,
        datatype => map,
        validator => fun(_) ->
            %% TODO
            true
        end
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
        validator => ?API_PATH_DEFAULTS
    },
    <<"versions">> => #{
        required => true,
        allow_null => false,
        datatype => map,
        validator => fun(M) -> 
            R = maps:map(
                fun(_, V) -> maps_utils:validate(V, ?API_VERSION) end, M),
            {ok, R}
        end
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
    <<"info">> => #{
        required => false,
        datatype => map,
        validator => ?API_INFO
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
        validator => ?API_PATH_DEFAULTS
    },
    <<"paths">> => #{
        required => true,
        allow_null => false,
        datatype => map,
        validator => fun(M1) -> 
            R = maps:map(
                fun(_, V1) -> maps_utils:validate(V1, ?API_PATH) end, M1),
            {ok, R}
        end
    }
}).

-define(API_INFO, #{
    <<"title">> => #{
        required => true,
        allow_null => true,
        datatype => binary},
    <<"description">> => #{
        required => true,
        allow_null => true,
        datatype => binary}
}).

-define(API_PATH_DEFAULTS, #{
    <<"https_only">> => #{
        required => true,
        default => false,
        datatype => boolean
    },
    <<"timeout">> => #{
        required => true,
        default => 60000,
        datatype => timeout
    },
    <<"retries">> => #{
        required => true,
        default => 0,
        validator => integer
    },
    <<"accepts">> => #{
        required => true,
        allow_null => false,
        default => [<<"application/json">>, <<"application/msgpack">>],
        datatype => {in, [<<"application/json">>, <<"application/msgpack">>]}
    },
    <<"provides">> => #{
        required => true,
        allow_null => false,
        default => [<<"application/json">>, <<"application/msgpack">>],
        datatype => {in, [<<"application/json">>, <<"application/msgpack">>]}
    },
    <<"headers">> => #{
        required => true,
        allow_null => false,
        default => #{}
    }
}).


-define(API_PATH, #{
    <<"is_collection">> => #{
        required => true,
        allow_null => false,
        default => false,
        datatype => boolean
    },
    ?VARS_KEY => #{
        required => true,
        default => #{},
        datatype => map
    },
    ?DEFAULTS_KEY => #{
        required => true,
        default => #{},
        datatype => map,
        validator => ?API_PATH_DEFAULTS
    },
    <<"accepts">> => #{
        required => true,
        allow_null => false,
        default => <<"{{defaults.accepts}}">>,
        datatype => {list, binary}
    },
    <<"provides">> => #{
        required => true,
        allow_null => false,
        default => <<"{{defaults.provides}}">>,
        datatype => {list, binary}
    }, 
    <<"delete">> => #{
        required => false,
        validator => ?REQ
    },
    <<"get">> => #{
        required => false,
        validator => ?REQ
    },
    <<"head">> => #{
        required => false,
        validator => ?REQ
    },
    <<"options">> => #{
        required => false,
        validator => ?REQ
    },
    <<"patch">> => #{
        required => false,
        validator => ?REQ
    },
    <<"post">> => #{
        required => false,
        validator => ?REQ
    },
    <<"put">> => #{
        required => false,
        validator => ?REQ
    }
}).


-define(REQ, #{
    <<"info">> => #{
        required => false,
        validator => ?API_PATH_INFO
    },
    <<"action">> => #{
        required => true,
        allow_null => false,
        validator => ?ACTION
    },
    <<"response">> => #{
        required => true,
        allow_null => false,
        validator => #{
            <<"on_timeout">> => #{
                required => true,
                allow_null => false,
                validator => ?RESPONSE
            },
            <<"on_result">> => #{
                required => true,
                allow_null => false,
                validator => ?RESPONSE
            },
            <<"on_error">> => #{
                required => true,
                allow_null => false,
                validator => ?RESPONSE
            }   
        }
    }

}).

-define(ACTION, #{
    <<"type">> => #{
        required => true,
        allow_null => false,
        datatype => {in, [
            <<"wamp_call">>,
            <<"wamp_publish">>,
            <<"wamp_register">>,
            <<"wamp_unregister">>,
            <<"wamp_subscribe">>,
            <<"wamp_unsubscribe">>,
            <<"http_request">>
        ]}
    },
    <<"timeout">> => #{
        required => true,
        default => <<"{{defaults.timeout}}">>,
        datatype => timeout
    },
    <<"retries">> => #{
        required => true,
        default => <<"{{defaults.retries}}">>,
        datatype => integer
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
        default => #{},
        datatype => map
    },
    <<"arguments">> => #{
        required => true,
        allow_null => true,
        default => [],
        datatype => list
    },
    <<"arguments_kw">> => #{
        required => true,
        allow_null => true,
        default => #{},
        datatype => map
    }
}).

-define(RESPONSE, #{
    <<"headers">> => #{
        required => true,
        allow_null => false,
        default => <<"{{defaults.headers}}">>,
        datatype => map
    },
    <<"body">> => #{
        required => true,
        allow_null => false,
        default => <<>>,
        datatype => binary
    }
}).

-define(API_PATH_INFO, #{
    <<"description">> => #{
        required => false,
        allow_null => true,
        datatype => binary
    },
    <<"parameters">> => #{
        required => false,
        validator => ?API_PARAMS
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


-export([from_file/1]).
-export([get_context/1]).
-export([analyse/1]).
-export([gen_code/2]).
-export([eval_term/2]).
-export([pp/1]).
-compile({parse_transform, parse_trans_codegen}).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_context(cowboy_req:req()) -> map().
get_context(Req) ->
     #{
        <<"request">> => #{
            <<"peer">> => cowboy_req:peer(Req),
            <<"scheme">> => cowboy_req:scheme(Req),
            <<"path">> => cowboy_req:path(Req),
            <<"host">> => cowboy_req:host(Req),
            <<"host_url">> => cowboy_req:host_url(Req),
            <<"host_info">> => cowboy_req:host_info(Req),
            <<"port">> => cowboy_req:port(Req),
            <<"headers">> => maps:from_list(cowboy_req:headers(Req)),
            <<"qs">> => cowboy_req:qs(Req),
            <<"params">> => maps:from_list(cowboy_req:parse_qs(Req)),
            <<"body">> => cowboy_req:body(Req),
            <<"body_length">> => cowboy_req:body_length(Req) 
        },
        <<"action">> => #{
            <<"result">> => fun(_) -> undefined_map end,
            <<"error">> => fun(_) -> undefined_map end,
            <<"timeout">> => fun(_) -> undefined_map end
        }
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
analyse(Spec) ->
    analyse(Spec, get_context()).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
gen_code(Name, PathSpec) ->
    ModName = list_to_atom(
        "juno_rest_api_gateway_handler_" ++ integer_to_list(erlang:phash2(Name))),
    AllowedMethods = maps:get(<<"allowed_methods">>, PathSpec),
    IsCollection = maps:get(<<"is_collection">>, PathSpec),
    Accepts = content_types_accepted(maps:get(<<"accepts">>, PathSpec)),
    Provides = content_types_provided(maps:get(<<"provides">>, PathSpec)),
    Get = maps:get(<<"get">>, PathSpec, undefined),

    codegen:gen_module(
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
            {from_json, 2},
            {to_msgpack, 2},
            {from_msgpack, 2}
        ],
        [
            {init, fun(Req, _Opts) ->
                Session = undefined, %TODO
                % SessionId = 1,
                % Ctxt0 = juno_context:set_peer(
                %     juno_context:new(), cowboy_req:peer(Req)),
                % Ctxt1 = juno_context:set_session_id(SessionId, Ctxt0),
                St = #{
                    is_collection => {'$var', IsCollection}, 
                    session => Session,
                    % context => Ctxt1, 
                    gateway_context => ?MODULE:get_context(Req)
                },
                {cowboy_rest, Req, St}
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
                {true, Req, St}
            end},
            {resource_exists, fun(Req, St) ->
                {true, Req, St}
            end},
            {resource_existed, fun(Req, St) ->
                {false, Req, St}
            end},
            {to_json, fun(Req, St) ->
                {<<>>, Req, St}
            end},
            {to_json, fun
                (<<"GET">>, Req, St) -> 
                    Spec = {'$var', Get},
                    Action = maps:get(<<"action">>, Spec),
                    Resp = maps:get(<<"response">>, Spec),
                    Result = perform_action(Action, St),
                    Body = response(json, Result, St),
                    {Body, Req, St};
                (<<"HEAD">>, Req, St) -> 
                    {<<>>, Req, St};
                (<<"OPTIONS">>, Req, St) -> 
                    {<<>>, Req, St}
            end},
            {from_json, fun(Req, St) ->
                from_json(cowboy_req:method(Req), Req, St)
            end},
            {from_json, fun
                (<<"PATCH">>, Req, St) -> 
                    {<<>>, Req, St};
                (<<"POST">>, Req, St) -> 
                    {<<>>, Req, St};
                (<<"PUT">>, Req, St) -> 
                    {<<>>, Req, St}
            end},
            {to_msgpack, fun(Req, St) ->
                {<<>>, Req, St}
            end},
            {from_msgpack, fun(Req, St) ->
                from_msgpack(cowboy_req:method(Req), Req, St)
            end},
            {from_msgpack, fun
                (<<"PATCH">>, Req, St) -> 
                    {<<>>, Req, St};
                (<<"POST">>, Req, St) -> 
                    {<<>>, Req, St};
                (<<"PUT">>, Req, St) -> 
                    {<<>>, Req, St}
            end},
            {perform_action, fun
                (#{<<"type">> := <<"wamp_call">>} = M, St0) -> 
                    GC0 = maps:get(gateway_context, St0),
                    Action0 = maps:get(<<"action">>, GC0),
                    %% Arguments might be funs waiting for the
                    %% request.* values to be bound
                    %% so we need to evaluate them passing the
                    %% context
                    #{
                        <<"arguments">> := A,
                        <<"arguments_kw">> := Akw,
                        <<"details">> := D,
                        <<"procedure">> := P,
                        <<"retries">> := _R,
                        <<"timeout">> := _T
                    } = ?MODULE:eval_term(M, GC0),
                    
                    Msg = juno:call(D, P, A, Akw),
                    %% Use Map to make wamp call
                    %% and set the action.[result, error, timeout]
                    Result = <<>>,
                    Action1 = maps:update(<<"result">>, Result, Action0),
                    GC1 = maps:update(<<"action">>, Action1, GC0),
                    {<<>>, maps:update(gateway_context, GC1, St)}
            end}      
        ]
    ).



pp(Forms) ->
    io:fwrite("~s", [[erl_pp:form(F) || F <- Forms]]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec from_file(file:filename()) -> {ok, any()} | {error, any()}.
from_file(Filename) ->
    case file:consult(Filename) of
        {ok, [Spec]} when is_map(Spec) ->
            analyse(Spec, get_context());
        _ ->
            {error, {invalid_specification_format, Filename}}
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
get_context() ->
    #{
        <<"request">> => #{
            <<"peer">> => fun(X) -> maps:get(<<"peer">>, X) end,
            <<"scheme">> => fun(X) -> maps:get(<<"scheme">>, X) end,
            <<"path">> => fun(X) -> maps:get(<<"path">>, X) end,
            <<"host">> => fun(X) -> maps:get(<<"host">>, X) end,
            <<"host_url">> => fun(X) -> maps:get(<<"host_url">>, X) end,
            <<"host_info">> => fun(X) -> maps:get(<<"host_info">>, X) end,
            <<"port">> => fun(X) -> maps:get(<<"port">>, X) end,
            <<"headers">> => fun(Req) -> maps:from_list(cowboy_req:headers(Req)) end,
            <<"qs">> => fun cowboy_req:qs/1,
            <<"params">> => fun(Req) -> 
                maps:from_list(cowboy_req:parse_qs(Req)) end,
            <<"body">> => fun cowboy_req:body/1,
            <<"body_length">> => fun cowboy_req:body_length/1
        },
        <<"action">> => #{
            <<"result">> => fun(_) -> undefined_map end,
            <<"error">> => fun(_) -> undefined_map end,
            <<"timeout">> => fun(_) -> undefined_map end
        }
    }.


%% @private
-spec analyse(Spec :: map(), Ctxt :: map()) -> NewSpec :: map().
analyse(Spec, Ctxt) ->
    analyse_host(maps_utils:validate(Spec, ?API_HOST), Ctxt).


%% @private
-spec analyse_host(map(), map()) -> map().
analyse_host(Host0, Ctxt0) ->
    {Vars, Host1} = maps:take(?VARS_KEY, Host0),
    {Defs, Host2} = maps:take(?DEFAULTS_KEY, Host1),
    Ctxt1 = Ctxt0#{
        ?VARS_KEY => Vars,
        ?DEFAULTS_KEY => Defs
    },
    %% analyse all versions
    Vs0 = maps:get(<<"versions">>, Host2),
    Fun = fun(_, V) -> analyse_version(V, Ctxt1) end,
    Vs1 = maps:map(Fun, Vs0),
    maps:update(<<"versions">>, Vs1, Host2).


%% @private
-spec analyse_version(map(), map()) -> map().
analyse_version(Vers0, Ctxt0) ->
    {VVars, Vers1} = maps:take(?VARS_KEY, Vers0),
    {VDefs, Vers2} = maps:take(?DEFAULTS_KEY, Vers1),
    #{?VARS_KEY := CVars, ?DEFAULTS_KEY := CDefs} = Ctxt0,
    %% We merge variables and defaults
    Ctxt1 = maps:update(?VARS_KEY, maps:merge(CVars, VVars), Ctxt0),
    Ctxt2 = maps:update(?DEFAULTS_KEY, maps:merge(CDefs, VDefs), Ctxt1),
    Fun = fun(Uri, P) -> 
        try analyse_path(P, Ctxt2) 
        catch 
            error:{badkey, Key} ->
                io:format("Path ~p\nCtxt: ~p\nST:~p", [P, Ctxt2,erlang:get_stacktrace()]),
                error({badarg, <<"The key '", Key/binary, "' does not exist in path section '", Uri/binary, "'.">>})
        end
    end,
    maps:update(
        <<"paths">>, maps:map(Fun, maps:get(<<"paths">>, Vers2)), Vers2).


%% @private
analyse_path(Path0, Ctxt0) ->
    {PVars, Path1} = maps:take(?VARS_KEY, Path0),
    {PDefs, Path2} = maps:take(?DEFAULTS_KEY, Path1),
    
    %% We merge variables and defaults
    Vars0 = maps:merge(maps:get(?VARS_KEY, Ctxt0), PVars),
    Defs0 = maps:merge(maps:get(?DEFAULTS_KEY, Ctxt0), PDefs),
    Ctxt1 = maps:update(
        ?DEFAULTS_KEY, Defs0, maps:update(?VARS_KEY, Vars0, Ctxt0)),
    
    %% We evaluate variables by iterating over each variables and 
    %% updating the context in each turn as we might have interdependencies
    %% amongst them
    VFun = fun(Var, Val, ICtxt) ->
        IVars1 = maps:update(
            Var, eval_term(Val, ICtxt), maps:get(?VARS_KEY, ICtxt)),
        maps:update(?VARS_KEY, IVars1, ICtxt)
    end,
    Ctxt2 = maps:fold(VFun, Ctxt1, Vars0),
    
    %% We evaluate defaults
    DFun = fun(Var, Val, ICtxt) ->
        IDefs1 = maps:update(
            Var, eval_term(Val, ICtxt), maps:get(?DEFAULTS_KEY, ICtxt)),
        maps:update(?DEFAULTS_KEY, IDefs1, ICtxt)
    end,
    Ctxt3 = maps:fold(DFun, Ctxt2, Defs0),
    %% Now we evaluate each request type spec
    AllowedMethods = sets:to_list(
        sets:intersection(
            sets:from_list(?HTTP_METHODS), 
            sets:from_list(maps:keys(Path2)
            )
        )
    ),
    case AllowedMethods of
        [] -> 
            error({
                missing_required_key, 
                <<"At least one request method should be specified">>});
        L ->
            PFun = fun(Method, IPath) ->
                Section = maps:get(Method, IPath),
                try  maps:update(
                        Method, 
                        analyse_request_method(Section, Ctxt3), 
                        IPath
                    )
                catch
                    error:{badkey, Key} ->
                        io:format("Method ~p\nCtxt: ~p\nST:~p", [Section, Ctxt3, erlang:get_stacktrace()]),
                        error({badarg, <<"The key '", Key/binary, "' does not exist in path method section '", Method/binary, $'>>})
                end
            end,
            Path3 = lists:foldl(PFun, Path2, L),
            
            Path4 = maps:put(<<"allowed_methods">>, AllowedMethods, Path3),
            Path5 = maps:update_with(
                <<"accepts">>, fun(V) -> eval_term(V, Ctxt3) end, Path4),
            maps:update_with(
                <<"provides">>, fun(V) -> eval_term(V, Ctxt3) end, Path5)
    end.


%% @private
analyse_request_method(Spec, Ctxt) ->
    #{
        % <<"accepts">> := Acc,
        % <<"provides">> := Prov,
        <<"action">> := Act,
        <<"response">> := #{
            <<"on_timeout">> := T,
            <<"on_result">> := R,
            <<"on_error">> := E
        }
    } = Spec,
    Spec#{
        % <<"accepts">> := eval_term(Acc, Ctxt),
        % <<"provides">> := eval_term(Prov, Ctxt),
        <<"action">> => analyse_action(Act, Ctxt),
        <<"response">> => #{
            <<"on_timeout">> => eval_term(T, Ctxt),
            <<"on_result">> => eval_term(R, Ctxt),
            <<"on_error">> => eval_term(E, Ctxt)
        }
    }.


%% @private
-spec analyse_action(map(), map()) -> map().
analyse_action(#{<<"type">> := <<"wamp_call">>} = Spec, Ctxt) ->
    #{
        <<"timeout">> := TO,
        <<"retries">> := R,
        <<"procedure">> := P,
        <<"details">> := D,
        <<"arguments">> := A,
        <<"arguments_kw">> := Akw
    } = Spec,
    Spec#{
        <<"timeout">> => eval_term(TO, Ctxt),
        <<"retries">> => eval_term(R, Ctxt),
        <<"procedure">> => eval_term(P, Ctxt),
        <<"details">> => eval_term(D, Ctxt),
        <<"arguments">> => eval_term(A, Ctxt),
        <<"arguments_kw">> => eval_term(Akw, Ctxt)
    };

analyse_action(#{<<"type">> := Action}, _) ->
    error({unsupported_action, Action}).


%% @private
-spec eval_term(any(), map()) -> any().
eval_term(Map, Ctxt) when is_map(Map) ->
    maps:map(fun(_, V) -> mop:eval(V, Ctxt) end, Map);

eval_term(L, Ctxt) when is_list(L) ->
    [mop:eval(X, Ctxt) || X <- L];

eval_term(T, Ctxt) ->
    mop:eval(T, Ctxt).


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