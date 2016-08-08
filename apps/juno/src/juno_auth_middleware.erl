%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2011 - 2016. All rights reserved.
%% =============================================================================


-module(juno_auth_middleware).
-behaviour(cowboy_middleware).

-export([execute/2]).



execute(Req0, Env0) ->
    Ctxt0 = juno_context:set_peer(juno_context:new(), cowboy_req:peer(Req0)),
    try 
        case get_value(handler, Env0) of
            juno_ws_handler -> 
                Env1 = set_ctxt(Ctxt0, Env0),
                {ok, Req0, Env1};
            Other ->
                Ctxt1 = case get_realm_uri(Env0) of
                    undefined -> Ctxt0;
                    Uri -> Ctxt0#{realm_uri => Uri}
                end,
                Ctxt2 = authenticate(Req0, Ctxt1),
                Env1 = set_ctxt(Ctxt2, Env0),
                {ok, Req0, Env1}
        end
	catch
        throw:{authenticate, Realm} ->
            Req1 = cowboy_req:set_resp_header(
                <<"www-authenticate">>, 
                <<"Basic realm=\"", Realm/binary, "\"">>, 
                Req0),
            Req2 = cowboy_req:reply(401, Req1),
			{stop, Req2};
        throw:Reason ->
            Req1 = juno_rest_utils:set_resp_error_body(Reason, Req0),
            Req2 = cowboy_req:reply(401, Req1),
			{stop, Req2}
    end.

    
%% @private
authenticate(Req, Ctxt) ->
    authenticate_scheme(parse_authorization_header(Req, Ctxt), Ctxt).


%% @private
authenticate_scheme({basic, Username, Pass}, Ctxt) ->
    SecCtxt = maybe_throw(
        juno_security:authenticate(bin2str(Username), Pass, conn_info(Ctxt))),
    maps:merge(Ctxt, SecCtxt);
    
authenticate_scheme({digest, _List}, _Ctxt0) ->
    %% TODO support
    throw({unsupported_scheme, <<"Digest">>});
authenticate_scheme({bearer, _Bin}, _Ctxt0) ->
    %% TODO support OAUTH
    throw({unsupported_scheme, <<"Bearer">>});
authenticate_scheme({Scheme, _Payload}, _Ctxt0) ->
    %% TODO support via custom functions
    throw({unsupported_scheme, Scheme}).


%% @private
maybe_throw({error, Reason}) ->
    throw(Reason);
maybe_throw({ok, Value}) ->
    Value;
maybe_throw(Value) ->
    Value.


%% @private
bin2str(Bin) ->
    unicode:characters_to_list(Bin, utf8, utf8).


%% @private
conn_info(#{peer := {IP, _Port}}) ->
    [{ip, IP}].


%% @private
-spec parse_authorization_header(cowboy_req:req(), juno_context:context()) ->
    undefined | tuple().
parse_authorization_header(Req0, Ctxt) ->
    try cowboy_req:parse_header(<<"authorization">>, Req0) of
        undefined -> 
            case maps:get(realm_uri, Ctxt, undefined) of
                undefined -> throw({authenticate, <<"undefined">>});
                Realm -> throw({authenticate, Realm})
            end;
        Val -> Val
    catch
        error:function_clause ->
            %% cow_http_hd.erl only parses basic, digest and bearer schemes
            Bin = cowboy_req:header(<<"authorization">>, Req0),
            case Parsed = binary:split(Bin, [<<"\s">>]) of
                [_, _] = Parsed ->
                    list_to_tuple(Parsed);
                Other ->
                    throw({invalid_authorization, Other})
            end
    end.


%% private
get_realm_uri(Env) ->
    get_value(realm_uri, get_value(auth, Env)).




%% @private
get_value(_, undefined) ->
    undefined;

get_value(Key, Env) when is_list(Env) ->
    case lists:keyfind(Key, 1, Env) of
        {Key, Value} -> Value;
        false -> undefined 
    end;

get_value(Key, Env) when is_map(Env) ->
    maps:get(Key, Env, undefined).


%% @private
set_value(Key, Value, Env) when is_list(Env) ->
    lists:keyreplace(Key, 1, Env, {Key, Value});

set_value(Key, Value, Env) when is_map(Env) ->
    maps:put(Key, Value, Env).


%% @private
set_ctxt(Ctxt, Env) ->
    case get_value(handler_opts, Env) of
        undefined -> 
            lager:error("handler_opts does not exist in environment. Middleware must be incorrectly configured. cowboy_router needs to be called first."),
            Env;
        Opts0 ->
            Opts1 = set_value(juno_context, Ctxt, Opts0),
            set_value(handler_opts, Opts1, Env)
    end.