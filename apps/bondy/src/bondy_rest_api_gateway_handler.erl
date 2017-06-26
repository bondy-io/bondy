%% 
%%  bondy_rest_api_gateway_handler.erl -
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

%% -----------------------------------------------------------------------------
%% @doc
%% This module implements a generic Cowboy rest handler that handles a resource
%% specified using the Bondy API Gateway Specification (JAGS) Description 
%% Language which is a specification for describing, producing and consuming 
%% RESTful Web Services from and by Bondy.
%%
%% For every path defined in a JAGS file, Bondy will configure and install a 
%% Cowboy route using this module. The initial state of the module responds to 
%% a contract between this module and the {@link bondy_api_gateway_spec_parser} 
%% and contains the parsed and preprocessed definition of the paths 
%% specification which this module uses to dynamically implement its behaviour.
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_rest_api_gateway_handler).
-include("bondy.hrl").

-type state() :: #{
    api_context => map(),
    session => any(),
    realm_uri => binary(), 
    deprecated => boolean(),
    security => map(),
    encoding => json | msgpack
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
    % Ctxt0 = bondy_context:set_peer(
    %     bondy_context:new(), cowboy_req:peer(Req)),
    % Ctxt1 = bondy_context:set_session_id(SessionId, Ctxt0),
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
    case bondy_security_utils:authenticate(bearer, Val, Realm, Peer) of
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
                user_id => ?CHARS2BIN(bondy_security:get_username(AuthCtxt))
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
            Req1 = reply(
                bondy_utils:error_http_code(Code), Enc, Response, Req0),
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
    provide(Req, St#{encoding => json}).


to_msgpack(Req, St) ->
    provide(Req, St#{encoding => msgpack}).


from_json(Req, St) ->
    accept(Req, St#{encoding => json}).


from_msgpack(Req, St) ->
    accept(Req, St#{encoding => msgpack}).




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Provides the resource representation for a GET or HEAD 
%% executing the configured action
%% @end
%% -----------------------------------------------------------------------------
provide(Req0, #{api_spec := Spec, encoding := Enc} = St0)  -> 
    Method = method(Req0),
    case perform_action(Method, maps:get(Method, Spec), St0) of
        {ok, Response, St1} ->
            #{
                <<"body">> := Body,
                <<"headers">> := Headers
            } = Response,
            Req1 = cowboy_req:set_resp_headers(Headers, Req0),
            {maybe_encode(Enc, Body, Spec), Req1, St1};
        
        {ok, HTTPCode, Response, St1} ->
            Req1 = reply(HTTPCode, Enc, Response, Req0),
            {stop, Req1, St1};
        
        {error, #{<<"body">> := #{<<"code">> := Code}} = Response, St1} ->
            Req1 = reply(
                bondy_utils:error_http_code(Code), Enc, Response, Req0),
            {stop, Req1, St1};
        
        {error, HTTPCode, Response, St1} ->
            Req1 = reply(HTTPCode, Enc, Response, Req0),
            {stop, Req1, St1}
    end.




%% @private
%% -----------------------------------------------------------------------------
%% @doc
%% Accepts a POST, PATCH, PUT or DELETE over a resource by executing 
%% the configured action
%% @end
%% -----------------------------------------------------------------------------
accept(Req0, #{api_spec := Spec, encoding := Enc} = St0) -> 
    Method = method(Req0),
    %% We now know the encoding so we will decode the body
    St1 = decode_body_in_context(St0),

    case perform_action(Method, maps:get(Method, Spec), St1) of
        {ok, Response, St2} ->
            Req1 = prepare_request(Enc, Response, Req0),
            {maybe_location(Method, Response), Req1, St2};
        
        {ok, HTTPCode, Response, St2} ->
            Req1 = reply(HTTPCode, Enc, Response, Req0),
            {stop, Req1, St2};
        
        {error, #{<<"code">> := Code} = Response, St2} ->
            Req1 = reply(
                bondy_utils:error_http_code(Code), Enc, Response, Req0),
            {stop, Req1, St2};
        
        {error, HTTPCode, Response, St2} ->
            Req1 = reply(HTTPCode, Enc, Response, Req0),
            {stop, Req1, St2}
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
-spec update_context(tuple(), map()) -> map().

update_context({error, Map}, #{<<"request">> := _} = Ctxt) when is_map(Map) ->
    maps_utils:put_path([<<"action">>, <<"error">>], Map, Ctxt);

update_context({result, Result}, #{<<"request">> := _} = Ctxt) ->
    maps_utils:put_path([<<"action">>, <<"result">>], Result, Ctxt);

update_context({security, Claims}, #{<<"request">> := _} = Ctxt) ->
    Map = #{
        <<"realm_uri">> => maps:get(<<"aud">>, Claims),
        <<"session">> => maps:get(<<"id">>, Claims),
        <<"authid">> => maps:get(<<"sub">>, Claims),
        <<"authrole">> => maps:get(<<"scope">>, Claims),
        <<"authscope">> => maps:get(<<"scope">>, Claims),
        <<"authmethod">> => <<"oauth2">>,
        <<"authprovider">> => maps:get(<<"iss">>, Claims)
    },
    maps:put(<<"security">>, Map, Ctxt);

update_context(Req0, Ctxt) ->
    %% At the moment we do not support partially reading the body
    %% nor streams so we drop the NewReq
    {ok, Bin, Req1} = cowboy_req:read_body(Req0),
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
        <<"body">> => Bin,
        <<"body_length">> => cowboy_req:body_length(Req1) 
    },
    maps:put(<<"request">>, M, Ctxt).


%% @private
decode_body_in_context(St) ->
    Ctxt = maps:get(api_context, St),
    Path = [<<"request">>, <<"body">>],
    Bin = maps_utils:get_path(Path, Ctxt),
    Body = bondy_utils:decode(maps:get(encoding, St), Bin),
    maps:update(api_context, maps_utils:put_path(Path, Body, Ctxt), St).



%% @private
-spec perform_action(binary(), map(), state()) ->
    {ok, Response :: map(), state()} 
    | {ok, Code :: integer(), Response :: map(), state()} 
    | {error, Response :: map(), state()} 
    | {error, Code :: integer(), Response :: map(), state()}.

perform_action(
    _, #{<<"action">> := #{<<"type">> := <<"static">>}} = Spec, St0) ->
    Ctxt0 = maps:get(api_context, St0),
    %% We get the response directly as it should be statically defined
    Result = maps_utils:get_path([<<"response">>, <<"on_result">>], Spec),
    Response = bondy_utils:eval_term(Result, Ctxt0),
    St1 = maps:update(api_context, Ctxt0, St0),
    {ok, Response, St1};

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
    } = bondy_utils:eval_term(Act, Ctxt0),
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
            Ctxt1 = update_context(
                {error, bondy_error:error_map(Reason)}, Ctxt0),
            Response = bondy_utils:eval_term(maps:get(<<"on_error">>, RSpec), Ctxt1),
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
        <<"procedure">> := P,
        <<"arguments">> := A,
        <<"arguments_kw">> := Akw,
        <<"options">> := Opts,
        <<"retries">> := _R,
        <<"timeout">> := _T
    } = bondy_utils:eval_term(Act, Ctxt0),
    RSpec = maps:get(<<"response">>, Spec),

    %% @TODO We need to recreate ctxt and session from token
    Peer = maps_utils:get_path([<<"request">>, <<"peer">>], Ctxt0),
    RealmUri = maps:get(realm_uri, St0),
    WampCtxt0 = #{
        peer => Peer, 
        realm_uri => RealmUri,
        awaiting_calls => sets:new(),
        timeout => 5000,
        session => bondy_session:new(Peer, RealmUri, #{
            roles => #{
                caller => #{
                    features => #{
                        call_timeout => true,
                        call_canceling => false,
                        caller_identification => true,
                        call_trustlevels => true,
                        progressive_call_results => false
                    }
                }
            }
        })
    },

    case bondy:call(P, Opts, A, Akw, WampCtxt0) of
        {ok, Result0, _WampCtxt1} ->
            %% mops uses binary keys
            Result1 = #{
                <<"details">> => maps:get(details, Result0),
                <<"arguments">> => maps:get(arguments, Result0),
                <<"arguments_kw">> => maps:get(arguments_kw, Result0)
            },
            Ctxt1 = update_context({result, Result1}, Ctxt0),
            Response = bondy_utils:eval_term(
                maps:get(<<"on_result">>, RSpec), Ctxt1),
            St1 = maps:update(api_context, Ctxt1, St0),
            {ok, Response, St1};
        {error, Error, _WampCtxt1} ->
            %% @REVIEW At the moment all error maps use binary keys, if we 
            %% move to atoms we need to turn them into binaries 
            Ctxt1 = update_context({error, Error}, Ctxt0),
            Response = bondy_utils:eval_term(
                maps:get(<<"on_error">>, RSpec), Ctxt1),
            St1 = maps:update(api_context, Ctxt1, St0),
            Code = maps:get(<<"status_code">>, Response, 500),
            {error, Code, Response, St1}
    end.



%% @private
from_http_response(StatusCode, RespHeaders, RespBody, Spec, St0) 
when StatusCode >= 400 andalso StatusCode < 600->
    Ctxt0 = maps:get(api_context, St0),
    Error = #{ 
        <<"status_code">> => StatusCode,
        <<"body">> => RespBody,
        <<"headers">> => maps:from_list(RespHeaders)
    },
    Ctxt1 = update_context({error, Error}, Ctxt0),
    Response = bondy_utils:eval_term(maps:get(<<"on_error">>, Spec), Ctxt1),
    St1 = maps:update(api_context, Ctxt1, St0),
    {error, StatusCode, Response, St1};

from_http_response(StatusCode, RespHeaders, RespBody, Spec, St0) ->
    Ctxt0 = maps:get(api_context, St0),
    Result = #{ 
        <<"status_code">> => StatusCode,
        <<"body">> => RespBody,
        <<"headers">> => maps:from_list(RespHeaders)
    },
    Ctxt1 = update_context({result, Result}, Ctxt0),
    Response = bondy_utils:eval_term(maps:get(<<"on_result">>, Spec), Ctxt1),
    St1 = maps:update(api_context, Ctxt1, St0),
    {ok, StatusCode, Response, St1}.

  




reply_auth_error(Error, Scheme, Realm, Enc, Req) ->
    #{
        <<"code">> := Code,
        <<"message">> := Msg,
        <<"description">> := Desc
    } = Body = bondy_error:error_map({Error, 401}),
    Auth = <<
        Scheme/binary,
        " realm=", $", Realm/binary, $", $\,,
        " error=", $", Code/binary, $", $\,,
        " message=", $", Msg/binary, $", $\,,
        " description=", $", Desc/binary, $"
    >>,
    Resp = #{ 
        <<"status_code">> => 401,
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
    cowboy_req:set_resp_body(bondy_utils:maybe_encode(Enc, Body), Req1).


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




%% @private
maybe_encode(_, <<>>, _) ->
    <<>>;

maybe_encode(_, Body, #{<<"action">> := #{<<"type">> := <<"forward">>}}) ->
    Body;

maybe_encode(Enc, Body, _) ->
    bondy_utils:maybe_encode(Enc, Body).