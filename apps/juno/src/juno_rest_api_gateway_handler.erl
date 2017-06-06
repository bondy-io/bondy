-module(juno_rest_api_gateway_handler).
-include("juno.hrl").

-type state() :: #{
    api_context => map(),
    session => any(),
    realm_uri => binary(), 
    deprecated => boolean(),
    security => map()
}.


-export([init/2]).
-export([allowed_methods/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([is_authorized/2]).
-export([resource_exists/2]).
-export([resource_existed/2]).
-export([to_json/2]).
-export([to_msgpack/2]).
-export([from_json/2]).
-export([from_msgpack/2]).
-export([delete_resource/2]).
-export([delete_completed/2]).





%% =============================================================================
%% API
%% =============================================================================



init(Req, St0) ->
    Session = undefined, %TODO
    % SessionId = 1,
    % Ctxt0 = juno_context:set_peer(
    %     juno_context:new(), cowboy_req:peer(Req)),
    % Ctxt1 = juno_context:set_session_id(SessionId, Ctxt0),
    St1 = St0#{
        session => Session,
        api_context => update_context(Req, #{})
    },
    {cowboy_rest, Req, St1}.


allowed_methods(Req, #{api_spec := Spec} = St) ->
    {maps:get(<<"allowed_methods">>, Spec), Req, St}.


content_types_accepted(Req, #{api_spec := Spec} = St) ->
    {maps:get(<<"content_types_accepted">>, Spec), Req, St}.


content_types_provided(Req, #{api_spec := Spec} = St) ->
    {maps:get(<<"content_types_provided">>, Spec), Req, St}.


is_authorized(Req0, #{security := #{<<"type">> := <<"oauth2">>}} = St0) ->
    %% TODO get auth method and status from St and validate
    %% check scopes vs action requirements
    Realm = maps:get(realm_uri, St0),
    Val = cowboy_req:parse_header(<<"authorization">>, Req0),
    Realm = maps:get(realm_uri, St0),
    Peer = cowboy_req:peer(Req0),
    case juno_security_utils:authenticate(bearer, Val, Realm, Peer) of
        {ok, Claims} when is_map(Claims) ->
            %% The token claims
            Ctxt = update_context(
                {security, Claims}, maps:get(api_context, St0)),
            St1 = maps:update(api_context, Ctxt, St0),
            {true, Req0, St1};
        {ok, AuthCtxt} ->
            %% TODO Here we need the token or the session withe the
            %% token grants and not the AuthCtxt
            St1 = St0#{
                user_id => ?CHARS2BIN(juno_security:get_username(AuthCtxt))
            },
            %% TODO update context
            {true, Req0, St1};
        {error, Reason} ->
            Req2 = reply_auth_error(
                Reason, <<"Bearer">>, Realm, json, Req0),
            {stop, Req2, St0}
    end;


is_authorized(Req, #{security := #{<<"type">> := <<"api_key">>}} = St) ->
    %% TODO get auth method and status from St and validate
    %% check scopes vs action requirements
    {true, Req, St};

is_authorized(Req, #{security := _} = St)  ->
    {true, Req, St}.


resource_exists(Req, St) ->
    %% TODO
    {true, Req, St}.


resource_existed(Req, St) ->
    %% TODO
    {false, Req, St}.

delete_resource(Req0, #{api_spec := Spec} = St0) ->
    Method = method(Req0),
    Enc = json,
    case perform_action(Method, maps:get(Method, Spec), St0) of
        {ok, Response, St1} ->
            Headers = maps:get(<<"headers">>, Response),
            Req1 = cowboy_req:set_resp_headers(Headers, Req0),
            {true, Req1, St1};
        
        {ok, HTTPCode, Response, St1} ->
            Req1 = reply(HTTPCode, Enc, Response, Req0),
            {stop, Req1, St1};
        
        {error, #{<<"body">> := #{<<"code">> := Code}} = Response, St1} ->
            Req1 = reply(juno_utils:error_http_code(Code), Enc, Response, Req0),
            {stop, Req1, St1};
        
        {error, HTTPCode, Response, St1} ->
            Req1 = reply(HTTPCode, Enc, Response, Req0),
            {stop, Req1, St1}
    end.




delete_completed(Req, St) ->
    %% Called after delete_resource
    %% We asume deletes are final and synchronous
    {true, Req, St}.


to_json(Req, St) ->
    provide(json, Req, St).


to_msgpack(Req, St) ->
    provide(msgpack, Req, St).


from_json(Req, St) ->
    accept(json, Req, St).


from_msgpack(Req, St) ->
    accept(msgpack, Req, St).




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
%% -----------------------------------------------------------------------------
%% @doc
%% Provides the resource representation for a GET or HEAD 
%% executing the configured action
%% @end
%% -----------------------------------------------------------------------------
provide(Enc, Req0, #{api_spec := Spec} = St0)  -> 
    Method = method(Req0),
    case perform_action(Method, maps:get(Method, Spec), St0) of
        {ok, Response, St1} ->
            #{
                <<"body">> := Body,
                <<"headers">> := Headers
            } = Response,
            Req1 = cowboy_req:set_resp_headers(Headers, Req0),
            {juno_utils:maybe_encode(Enc, Body), Req1, St1};
        
        {ok, HTTPCode, Response, St1} ->
            Req1 = reply(HTTPCode, Enc, Response, Req0),
            {stop, Req1, St1};
        
        {error, #{<<"body">> := #{<<"code">> := Code}} = Response, St1} ->
            Req1 = reply(
                juno_utils:error_http_code(Code), Enc, Response, Req0),
            {stop, Req1, St1};
        
        {error, HTTPCode, Response, St1} ->
            Req1 = reply(HTTPCode, Enc, Response, Req0),
            {stop, Req1, St1}
    end.




%% @private
%% -----------------------------------------------------------------------------
%% @doc
%% Accepts an POST, PATCH, PUT or DELETE over a resource by executing the configured action
%% @end
%% -----------------------------------------------------------------------------
accept(Enc, Req0, #{api_spec := Spec} = St0) -> 
    Method = method(Req0),
    case perform_action(Method, maps:get(Method, Spec), St0) of
        {ok, Response, St1} ->
            Req1 = prepare_request(Enc, Response, Req0),
            {maybe_location(Method, Response), Req1, St1};
        
        {ok, HTTPCode, Response, St1} ->
            Req1 = reply(HTTPCode, Enc, Response, Req0),
            {stop, Req1, St1};
        
        {error, #{<<"code">> := Code} = Response, St1} ->
            Req1 = reply(
                juno_utils:error_http_code(Code), Enc, Response, Req0),
            {stop, Req1, St1};
        
        {error, HTTPCode, Response, St1} ->
            Req1 = reply(HTTPCode, Enc, Response, St1),
            {stop, Req1, St1}
    end.






%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Creates a context object based on the passed Request 
%% (`cowboy_request:request()').
%% @end
%% -----------------------------------------------------------------------------
-spec update_context(cowboy_req:req() | map(), map()) -> map().

update_context({error, Map}, #{<<"request">> := _} = Ctxt) when is_map(Map) ->
    maps_utils:put_path([<<"action">>, <<"error">>], Map, Ctxt);

update_context({result, Result}, #{<<"request">> := _} = Ctxt) ->
    maps_utils:put_path([<<"action">>, <<"result">>], Result, Ctxt);

update_context({security, Claims}, #{<<"request">> := _} = Ctxt) ->
    Map = #{

    },
    maps:put(<<"security">>, Map, Ctxt);

update_context(Req0, Ctxt) ->
    %% At the moment we do not support partially reading the body
    %% nor streams so we drop the NewReq
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    M = #{
        <<"method">> => method(Req1),
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




%% @private
-spec perform_action(binary(), map(), state()) ->
    {ok, Response :: map(), state()} 
    | {ok, Code :: integer(), Response :: map(), state()} 
    | {error, Response :: map(), state()} 
    | {error, Code :: integer(), Response :: map(), state()}.

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
    } = juno_utils:eval_term(Act, Ctxt0),
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
        method_to_atom(Method), Url, maps:to_list(Headers), Body, Opts) 
    of
        {ok, StatusCode, RespHeaders} when Method =:= head ->
            from_http_response(StatusCode, RespHeaders, <<>>, RSpec, St0);
        
        {ok, StatusCode, RespHeaders, ClientRef} ->
            {ok, RespBody} = hackney:body(ClientRef),
            from_http_response(StatusCode, RespHeaders, RespBody, RSpec, St0);
        
        {error, Reason} ->
            Ctxt1 = update_context({error, juno_error:error_map(Reason)}, Ctxt0),
            Response = juno_utils:eval_term(maps:get(<<"on_error">>, RSpec), Ctxt1),
            St1 = maps:update(api_context, Ctxt1, St0),
            {error, Response, St1}
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
        <<"details">> := D,
        <<"procedure">> := P,
        <<"retries">> := _R,
        <<"timeout">> := _T
    } = juno_utils:eval_term(Act, Ctxt0),
    RSpec = maps:get(<<"response">>, Spec),
    case juno:call(D, P, A, Akw) of
        {ok, Result, Ctxt1} ->
            Ctxt2 = update_context({result, Result}, Ctxt1),
            Response = juno_utils:eval_term(
                maps:get(<<"on_result">>, RSpec), Ctxt2),
            St1 = maps:update(api_context, Ctxt2, St0),
            {ok, Response, St1};
        {error, Error, Ctxt1} ->
            Ctxt2 = update_context({error, Error}, Ctxt1),
            Response = juno_utils:eval_term(maps:get(<<"on_error">>, RSpec), Ctxt2),
            St1 = maps:update(api_context, Ctxt2, St0),
            Code = 500,
            {error, Code, Response, St1}
    end.



%% @private
from_http_response(StatusCode, RespHeaders, RespBody, Spec, St0) 
when StatusCode >= 400 andalso StatusCode < 600->
    Ctxt0 = maps:get(api_context, St0),
    Error = #{ 
        <<"http_code">> => StatusCode,
        <<"body">> => RespBody,
        <<"headers">> => maps:from_list(RespHeaders)
    },
    Ctxt1 = update_context({error, Error}, Ctxt0),
    Response = juno_utils:eval_term(maps:get(<<"on_error">>, Spec), Ctxt1),
    St1 = maps:update(api_context, Ctxt1, St0),
    {error, StatusCode, Response, St1};

from_http_response(StatusCode, RespHeaders, RespBody, Spec, St0) ->
    Ctxt0 = maps:get(api_context, St0),
    Result = #{ 
        <<"http_code">> => StatusCode,
        <<"body">> => RespBody,
        <<"headers">> => maps:from_list(RespHeaders)
    },
    Ctxt1 = update_context({error, Result}, Ctxt0),
    Response = juno_utils:eval_term(maps:get(<<"on_result">>, Spec), Ctxt1),
    St1 = maps:update(api_context, Ctxt1, St0),
    {ok, StatusCode, Response, St1}.

  




reply_auth_error(Error, Scheme, Realm, Enc, Req) ->
    #{
        <<"code">> := Code,
        <<"message">> := Msg,
        <<"description">> := Desc
    } = Body = juno_error:error_map({Error, 401}),
    Auth = <<
        Scheme/binary,
        " realm=", $", Realm/binary, $", $\,,
        " error=", $", Code/binary, $", $\,,
        " message=", $", Msg/binary, $", $\,,
        " description=", $", Desc/binary, $"
    >>,
    Resp = #{ 
        <<"http_code">> => 401,
        <<"body">> => Body,
        <<"headers">> => #{
            <<"www-authenticate">> => Auth
        }
    },
    reply(401, Enc, Resp, Req).


%% @private
-spec reply(integer(), atom(), map(), cowboy_req:req()) -> 
    cowboy_req:req().

reply(HTTPCode, Enc, Response, Req) ->
    cowboy_req:reply(HTTPCode, prepare_request(Enc, Response, Req)).



%% @private
-spec prepare_request(atom(), map(), cowboy_req:req()) -> 
    cowboy_req:req().

prepare_request(Enc, Response, Req0) ->
    #{
        <<"body">> := Body,
        <<"headers">> := Headers
    } = Response,
    Req1 = cowboy_req:set_resp_headers(Headers, Req0),
    cowboy_req:set_resp_body(juno_utils:maybe_encode(Enc, Body), Req1).


%% @private
maybe_location(<<"post">>, #{<<"uri">> := Uri}) ->
    {true, Uri};

maybe_location(_, _) ->
    true.


%% @private
to_binary_keys(Map) ->
    F = fun(K, V, Acc) ->
        maps:put(list_to_binary(atom_to_list(K)), V, Acc)
    end,
    maps:fold(F, #{}, Map).



%% @private
url(Host, Path, <<>>) ->
    <<Host/binary, Path/binary>>;

url(Host, Path, QS) ->
    <<Host/binary, Path/binary, $?, QS/binary>>.




% private
method(Req) ->
    method_to_lowercase(cowboy_req:method(Req)).

method_to_lowercase(<<"DELETE">>) -> <<"delete">>;
method_to_lowercase(<<"GET">>) -> <<"get">>;
method_to_lowercase(<<"HEAD">>) -> <<"head">>;
method_to_lowercase(<<"OPTIONS">>) -> <<"options">>;
method_to_lowercase(<<"PATCH">>) -> <<"patch">>;
method_to_lowercase(<<"POST">>) -> <<"post">>;
method_to_lowercase(<<"PUT">>) -> <<"put">>.

%% @private
%% -----------------------------------------------------------------------------
%% @doc
%% The Hackney uses atoms
%% @end
%% -----------------------------------------------------------------------------
method_to_atom(<<"delete">>) -> delete;
method_to_atom(<<"get">>) -> get;
method_to_atom(<<"head">>) -> head;
method_to_atom(<<"options">>) -> options;
method_to_atom(<<"patch">>) -> patch;
method_to_atom(<<"post">>) -> post;
method_to_atom(<<"put">>) -> put.
