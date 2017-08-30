%% =============================================================================
%%  bondy_api_gateway_handler.erl -
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



%% -----------------------------------------------------------------------------
%% @doc
%% This module implements a generic Cowboy rest handler that handles a resource
%% specified using the Bondy API Gateway Specification Format (BAGS),
%% a JSON-based format for describing, producing and consuming
%% RESTful Web Services using Bondy.
%%
%% For every path defined in a BAGS file, Bondy will configure and install a
%% Cowboy route using this module. The initial state of the module responds to
%% a contract between this module and the {@link bondy_api_gateway_spec_parser}
%% and contains the parsed and preprocessed definition of the paths
%% specification which this module uses to dynamically implement its behaviour.
%%
%% See {@link bondy_api_gateway} for a detail description of the
%% Bondy API Gateway Specification Format.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_api_gateway_handler).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(DEFAULT_MAX_BODY_LEN, 1024*1024*25). %% 25MB

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
-export([options/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([is_authorized/2]).
-export([resource_exists/2]).
-export([previously_existed/2]).
-export([to_json/2]).
-export([to_msgpack/2]).
-export([from_json/2]).
-export([from_msgpack/2]).
-export([from_form_urlencoded/2]).
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
        api_context => init_context(Req)
    },
    {cowboy_rest, Req, St1}.


allowed_methods(Req, #{api_spec := Spec} = St) ->
    {maps:get(<<"allowed_methods">>, Spec), Req, St}.


content_types_accepted(Req, #{api_spec := Spec} = St) ->
    {maps:get(<<"content_types_accepted">>, Spec), Req, St}.


content_types_provided(Req, #{api_spec := Spec} = St) ->
    {maps:get(<<"content_types_provided">>, Spec), Req, St}.


options(Req, #{api_spec := Spec} = St) ->
    Allowed = iolist_to_binary(
        lists:join(<<$,>>, maps:get(<<"allowed_methods">>, Spec))
    ),
    Headers0 = eval_headers(Req, St),
    Headers1 = case maps:find(<<"access-control-allow-methods">>, Headers0) of
        {ok, _V} ->
            maps:put(<<"access-control-allow-methods">>, Allowed, Headers0);
        false ->
            Headers0
    end,
    Headers2 = maps:put(<<"allow">>, Allowed, Headers1),
    {ok, cowboy_req:set_resp_headers(Headers2, Req), St}.


is_authorized(Req0, #{security := #{<<"type">> := <<"oauth2">>}} = St0) ->
    %% TODO get auth method and status from St and validate
    %% check scopes vs action requirements
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            {true, Req0, St0};
        _ ->
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
                {error, unknown_realm} ->
                    Response = #{
                        <<"body">> => maps:put(
                            <<"status_code">>, 401, bondy_error:map(unknown_realm)),
                        <<"headers">> => eval_headers(Req0, St0)
                    },
                    Req2 = reply(401, json, Response, Req0),
                    {stop, Req2, St0};
                {error, Reason} ->
                    Req1 = cowboy_req:set_resp_headers(eval_headers(Req0, St0), Req0),
                    Req2 = reply_auth_error(
                        Reason, <<"Bearer">>, Realm, json, Req1),
                    {stop, Req2, St0}
            end
    end;

is_authorized(Req, #{security := #{<<"type">> := <<"api_key">>}} = St) ->
    %% TODO get auth method and status from St and validate
    %% check scopes vs action requirements
    {true, Req, St};

is_authorized(Req, #{security := _} = St)  ->
    {true, Req, St}.


resource_exists(Req, #{api_spec := Spec} = St) ->
    IsCollection = maps:get(<<"is_collection">>, Spec, false),
    Method = cowboy_req:method(Req),
    Resp = case {IsCollection, Method} of
        {true, <<"POST">>} ->
            %% A collection resource always exists.
            %% However, during a POST the check should be considered to
            %% refer to the resource that is about to be created and added
            %% to the collection, and not the collection itself.
            %% This allows Cowboy to return `201 Created` instead of `200 OK`.
            false;
        {true, _} ->
            true;
        {false, _} ->
            %% TODO We should check for real here, but we carry on and let
            %% the underlying action to actually reply with a 404
            true
    end,
    {Resp, Req, St}.


previously_existed(Req, St) ->
    %% TODO
    {false, Req, St}.

delete_resource(Req0, #{api_spec := Spec} = St0) ->
    Method = method(Req0),
    Enc = json,
    St1 = St0#{encoding => Enc}, % TODO get this by parsing headers
    case perform_action(Method, maps:get(Method, Spec), St1) of
        {ok, Response, St2} ->
            Headers = maps:get(<<"headers">>, Response),
            Req1 = cowboy_req:set_resp_headers(Headers, Req0),
            {true, Req1, St2};

        {ok, HTTPCode, Response, St2} ->
            Req1 = reply(HTTPCode, Enc, Response, Req0),
            {stop, Req1, St2};

        {error, Response, St2} ->
            Req1 = reply(get_status_code(Response), Enc, Response, Req0),
            {stop, Req1, St2};

        {error, HTTPCode, Response, St2} ->
            Req1 = reply(HTTPCode, Enc, Response, Req0),
            {stop, Req1, St2}
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


from_form_urlencoded(Req, St) ->
    accept(Req, St#{encoding => urlencoded}).


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
    try perform_action(Method, maps:get(Method, Spec), St0) of
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

        {error, Response, St1} ->
            Req1 = reply(get_status_code(Response), Enc, Response, Req0),
            {stop, Req1, St1};

        {error, HTTPCode, Response, St1} ->
            Req1 = reply(HTTPCode, Enc, Response, Req0),
            {stop, Req1, St1}
    catch
        throw:Reason ->
            Response = #{
                <<"body">> => bondy_error:map(Reason),
                <<"headers">> => #{}
            },
            Req1 = reply(get_status_code(Response, 400), Enc, Response, Req0),
            {stop, Req1, St0};
        Class:Reason ->
            _ = lager:error(
                "type=~p, reason=~p, stacktrace=~p",
                [Class, Reason, erlang:get_stacktrace()]),
            Response = #{
                <<"body">> => bondy_error:map(Reason),
                <<"headers">> => #{}
            },
            Req1 = reply(get_status_code(Response, 500), Enc, Response, Req0),
            {stop, Req1, St0}
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
    try
        %% We now read the body from the request into the context
        {ok, Req1, St1} = read_body(Req0, St0),
        case perform_action(Method, maps:get(Method, Spec), St1) of
            {ok, Response, St2} ->
                Req2 = prepare_request(Enc, Response, Req1),
                {maybe_location(Method, Response), Req2, St2};

            {ok, HTTPCode, Response, St2} ->
                {stop, reply(HTTPCode, Enc, Response, Req1), St2};

            {error, Response, St2} ->
                Req2 = reply(
                    get_status_code(Response), Enc, Response, Req1),
                {stop, Req2, St2};

            {error, HTTPCode, Response, St2} ->
                {stop, reply(HTTPCode, Enc, Response, Req1), St2}
        end
    catch
        throw:Reason ->
            ErrResp = #{
                <<"body">> => bondy_error:map(Reason),
                <<"headers">> => #{}
            },
            Req = reply(get_status_code(ErrResp, 400), Enc, ErrResp, Req0),
            {stop, Req, St0};
        Class:Reason ->
            _ = lager:error(
                "type=~p, reason=~p, stacktrace=~p",
                [Class, Reason, erlang:get_stacktrace()]),
            ErrResp = #{
                <<"body">> => bondy_error:map(Reason),
                <<"headers">> => #{}
            },
            Req = reply(get_status_code(ErrResp, 500), Enc, ErrResp, Req0),
            {stop, Req, St0}
    end.




%% =============================================================================
%% PRIVATE
%% =============================================================================


get_status_code(Term) ->
    get_status_code(Term, 500).


%% @private
get_status_code(#{<<"status_code">> := Code}, _) ->
    Code;

get_status_code(#{<<"body">> := ErrorBody}, _) ->
    get_status_code(ErrorBody);

get_status_code(ErrorBody, Default) ->
    case maps:find(<<"status_code">>, ErrorBody) of
        {ok, Val} ->
            Val;
        _ ->
            case maps:find(<<"code">>, ErrorBody) of
                {ok, Val} ->
                    uri_to_status_code(Val);
                _ ->
                    Default
            end
    end.


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

update_context({security, Claims}, #{<<"request">> := Req} = Ctxt) ->
    Lang = maps_utils:get_path(
        [<<"headers">>, <<"accept-language">>], Req, <<"en">>),
    Map = #{
        <<"realm_uri">> => maps:get(<<"aud">>, Claims),
        <<"session">> => maps:get(<<"id">>, Claims),
        <<"client_id">> => maps:get(<<"iss">>, Claims),
        <<"username">> => maps:get(<<"sub">>, Claims),
        <<"authmethod">> => <<"oauth2">>, %% Todo get this dynamically
        <<"groups">> => maps:get(<<"groups">>, Claims),
        <<"locale">> => Lang,
        <<"meta">> => maps:get(<<"meta">>, Claims)
    },
    maps:put(<<"security">>, Map, Ctxt);

update_context({body, Body}, #{<<"request">> := _} = Ctxt0) ->
    Ctxt1 = maps_utils:put_path([<<"request">>, <<"body">>], Body, Ctxt0),
    maps_utils:put_path(
        [<<"request">>, <<"body_length">>], byte_size(Body), Ctxt1).


init_context(Req) ->
    M = #{
        <<"method">> => method(Req),
        <<"scheme">> => cowboy_req:scheme(Req),
        <<"peer">> => cowboy_req:peer(Req),
        <<"path">> => cowboy_req:path(Req),
        <<"host">> => cowboy_req:host(Req),
        <<"port">> => cowboy_req:port(Req),
        <<"headers">> => cowboy_req:headers(Req),
        <<"query_string">> => cowboy_req:qs(Req),
        <<"query_params">> => maps:from_list(cowboy_req:parse_qs(Req)),
        <<"bindings">> => bondy_utils:to_binary_keys(cowboy_req:bindings(Req)),
        <<"body">> => <<>>,
        <<"body_length">> => 0
    },
    maps:put(<<"request">>, M, #{}).

%% @private

%% is_multipart_form_body(Req) ->
%%     case cowboy_req:parse_header(<<"content-type">>, Req) of
%%         {<<"multipart">>, <<"form-data">>, _} ->
%%             true;
%%         _ ->
%%             false
%%     end.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% By default, Cowboy will attempt to read up to 8MB of data, for up to 15
%% seconds. The call will return once Cowboy has read at least 8MB of data, or
%% at the end of the 15 seconds period.
%% We get the path's body_max_bytes, body_bytes_limit and body_seconds_limit
%% attributes to configure the cowboy_req's length and period options and also
%% setup a total max length.
%% @end
%% -----------------------------------------------------------------------------
-spec read_body(cowboy_req:request(), state()) ->
    {ok, cowboy_req:request(), state()} | no_return().

read_body(Req, St) ->
    read_body(Req, St, <<>>).


%% @private
read_body(Req0, #{api_spec := Spec, api_context := Ctxt0} = St0, Acc) ->
    MSpec = maps:get(method(Req0), Spec),

    Opts = #{
        length => maps:get(<<"body_bytes_limit">>, MSpec),
        period => maps:get(<<"body_seconds_limit">>, MSpec)
    },
    MaxLen = maps:get(<<"body_max_bytes">>, MSpec),
    Len = byte_size(Acc),
    case cowboy_req:read_body(Req0, Opts) of
        {_, Data, _Req1} when byte_size(Data) > MaxLen - Len ->
            throw({badarg, {body_max_bytes_exceeded, MaxLen}});
        {ok, Data, Req1} ->
            %% @TODO Stream Body in the future using WAMP Progressive Calls
            %% The API Spec will need a way to tell me you want to stream
            Body = <<Acc/binary, Data/binary>>,
            Ctxt1 = update_context({body, Body}, Ctxt0),
            {ok, Req1, maps:update(api_context, Ctxt1, St0)};
        {more, Data, Req1} ->
            read_body(Req1, St0, <<Acc/binary, Data/binary>>)
    end.


%% @private
decode_body_in_context(Method, St)
when Method =:= <<"post">>
orelse Method =:= <<"patch">>
orelse Method =:= <<"put">> ->
    Ctxt = maps:get(api_context, St),
    Path = [<<"request">>, <<"body">>],
    Bin = maps_utils:get_path(Path, Ctxt),
    Enc = maps:get(encoding, St),
    try
        Body = bondy_utils:decode(Enc, Bin),
        maps:update(api_context, maps_utils:put_path(Path, Body, Ctxt), St)
    catch
        Class:Error ->
            _ = lager:info(
                "Error while decoding HTTP body, "
                "type=~p, reason=~p, stacktrace=~p",
                [Class, Error, erlang:get_stacktrace()]
            ),
            throw({badarg, {decoding, Enc}})
    end;

decode_body_in_context(_, #{api_context := Ctxt} = St) ->
    Path = [<<"request">>, <<"body">>],
    maps:update(api_context, maps_utils:put_path(Path, <<>>, Ctxt), St).



%% @private
-spec perform_action(binary(), map(), state()) ->
    {ok, Response :: any(), state()}
    | {ok, Code :: integer(), Response :: any(), state()}
    | {error, Response :: map(), state()}
    | {error, Code :: integer(), Response :: any(), state()}.

perform_action(
    Method, #{<<"action">> := #{<<"type">> := <<"static">>}} = Spec, St0) ->
    St1 = decode_body_in_context(Method, St0),
    Ctxt0 = maps:get(api_context, St1),
    %% We get the response directly as it should be statically defined
    Result = maps_utils:get_path([<<"response">>, <<"on_result">>], Spec),
    Response = mops:eval(Result, Ctxt0),
    St2 = maps:update(api_context, Ctxt0, St1),
    {ok, Response, St2};

perform_action(
    Method,
    #{<<"action">> := #{<<"type">> := <<"forward">>} = Act} = Spec,
    St0) ->
    %% At the moment we just do not decode it and asume upstream accepts
    %% the same type
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
    } = mops:eval(Act, Ctxt0),

    Opts = [
        {connect_timeout, CT},
        {recv_timeout, T}
    ],
    Url = url(Host, Path, QS),
    _ = lager:info(
        "Gateway is forwarding request to upstream host, "
        "method=~p, upstream_url=~p, headers=~p, body=~p, opts=~p",
        [Method, Url, Headers, Body, Opts]
    ),
    RSpec = maps:get(<<"response">>, Spec),

    case hackney:request(
        method_to_atom(Method), Url, maps:to_list(Headers), Body, Opts)
    of
        {ok, StatusCode, RespHeaders} when Method =:= <<"HEAD">> ->
            from_http_response(StatusCode, RespHeaders, <<>>, RSpec, St0);

        {ok, StatusCode, RespHeaders, ClientRef} ->
            {ok, RespBody} = hackney:body(ClientRef),
            from_http_response(StatusCode, RespHeaders, RespBody, RSpec, St0);

        {error, Reason} ->
            Error = #{
                <<"code">> => <<"com.leapsight.bondy.bad_gateway">>,
                <<"status_code">> => 502,
                <<"message">> => <<"Error while connecting with upstream URL">>,
                <<"description">> => Reason %% TODO convert to string
            },
            throw(Error)
    end;

perform_action(
    Method,
    #{<<"action">> := #{<<"type">> := <<"wamp_call">>} = Act} = Spec, St0) ->
    St1 = decode_body_in_context(Method, St0),
    Ctxt0 = maps:get(api_context, St1),
    %% Arguments might be funs waiting for the
    %% request.* values to be bound
    %% so we need to evaluate them passing the context
    #{
        <<"procedure">> := P,
        <<"arguments">> := A,
        <<"arguments_kw">> := Akw,
        <<"options">> := Opts,
        <<"retries">> := _R,
        <<"timeout">> := T
    } = mops:eval(Act, Ctxt0),
    RSpec = maps:get(<<"response">>, Spec),

    %% @TODO We need to recreate ctxt and session from token
    Peer = maps_utils:get_path([<<"request">>, <<"peer">>], Ctxt0),
    RealmUri = maps:get(realm_uri, St1),
    WampCtxt0 = #{
        peer => Peer,
        subprotocol => {http, text, maps:get(encoding, St0)},
        realm_uri => RealmUri,
        awaiting_calls => sets:new(),
        timeout => T,
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
            Result1 = bondy_utils:to_binary_keys(Result0),
            Ctxt1 = update_context({result, Result1}, Ctxt0),
            Response = mops:eval(
                maps:get(<<"on_result">>, RSpec), Ctxt1),
            St2 = maps:update(api_context, Ctxt1, St1),
            {ok, Response, St2};
        {error, WampError0, _WampCtxt1} ->
            StatusCode = uri_to_status_code(maps:get(error_uri, WampError0)),
            WampError1 = bondy_utils:to_binary_keys(WampError0),
            Error = maps:put(<<"status_code">>, StatusCode, WampError1),
            Ctxt1 = update_context({error, Error}, Ctxt0),
            Response = mops:eval(maps:get(<<"on_error">>, RSpec), Ctxt1),
            St2 = maps:update(api_context, Ctxt1, St1),
            Code = maps:get(<<"status_code">>, Response, 500),
            {error, Code, Response, St2}
    end.



%% @private
from_http_response(StatusCode, RespHeaders, RespBody, Spec, St0)
when StatusCode >= 400 andalso StatusCode < 600->
    Ctxt0 = maps:get(api_context, St0),
    Error = #{
        <<"status_code">> => StatusCode,
        <<"body">> => RespBody,
        <<"headers">> => RespHeaders
    },
    Ctxt1 = update_context({error, Error}, Ctxt0),
    Response = mops:eval(maps:get(<<"on_error">>, Spec), Ctxt1),
    St1 = maps:update(api_context, Ctxt1, St0),
    {error, StatusCode, Response, St1};

from_http_response(StatusCode, RespHeaders, RespBody, Spec, St0) ->
    Ctxt0 = maps:get(api_context, St0),
    % HeadersMap = maps:with(?HEADERS, maps:from_list(RespHeaders)),
    Result0 = #{
        <<"status_code">> => StatusCode,
        <<"body">> => RespBody,
        <<"headers">> => RespHeaders
    },
    Result1 = case lists:keyfind(<<"Location">>, 1, RespHeaders) of
        {_, Uri} ->
            maps:put(<<"uri">>, Uri, Result0);
        _ ->
            maps:put(<<"uri">>, <<>>, Result0)
    end,
    Ctxt1 = update_context({result, Result1}, Ctxt0),
    Response = mops:eval(maps:get(<<"on_result">>, Spec), Ctxt1),
    St1 = maps:update(api_context, Ctxt1, St0),
    {ok, StatusCode, Response, St1}.


reply_auth_error(Error, Scheme, Realm, Enc, Req) ->
    Body = maps:put(<<"status_code">>, 401, bondy_error:map(Error)),
    Code = maps:get(<<"code">>, Body, <<>>),
    Msg = maps:get(<<"message">>, Body, <<>>),
    Desc = maps:get(<<"description">>, Body, <<>>),
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
    Body = maps:get(<<"body">>, Response),
    Headers = maps:get(<<"headers">>, Response),
    Req1 = cowboy_req:set_resp_headers(Headers, Req0),
    cowboy_req:set_resp_body(bondy_utils:maybe_encode(Enc, Body), Req1).


%% @private
maybe_location(<<"post">>, #{<<"uri">> := Uri}) when Uri =/= <<>> ->
    {true, Uri};

maybe_location(_, _) ->
    true.




%% @private
url(Host, Path, <<>>) ->
    <<Host/binary, Path/binary>>;

url(Host, Path, QS) ->
    <<Host/binary, Path/binary, $?, QS/binary>>.




%% -----------------------------------------------------------------------------
% private
%% @doc
%% The Spec uses lowercase for the method names but Cowboy uses uppercase
%% @end
%% -----------------------------------------------------------------------------
method(Req) ->
    method_to_lowercase(cowboy_req:method(Req)).

method_to_lowercase(<<"DELETE">>) -> <<"delete">>;
method_to_lowercase(<<"GET">>) -> <<"get">>;
method_to_lowercase(<<"HEAD">>) -> <<"head">>;
method_to_lowercase(<<"OPTIONS">>) -> <<"options">>;
method_to_lowercase(<<"PATCH">>) -> <<"patch">>;
method_to_lowercase(<<"POST">>) -> <<"post">>;
method_to_lowercase(<<"PUT">>) -> <<"put">>.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% This function exists just becuase because hackney (http client) uses atoms
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


%% @private
uri_to_status_code(timeout) ->                                     504;
uri_to_status_code(?BONDY_ERROR_TIMEOUT) ->                        504;
uri_to_status_code(?WAMP_ERROR_AUTHORIZATION_FAILED) ->            403;
uri_to_status_code(?WAMP_ERROR_CANCELLED) ->                       500;
uri_to_status_code(?WAMP_ERROR_CLOSE_REALM) ->                     500;
uri_to_status_code(?WAMP_ERROR_DISCLOSE_ME_NOT_ALLOWED) ->         400;
uri_to_status_code(?WAMP_ERROR_GOODBYE_AND_OUT) ->                 500;
uri_to_status_code(?WAMP_ERROR_INVALID_ARGUMENT) ->                400;
uri_to_status_code(?WAMP_ERROR_INVALID_URI) ->                     502;
uri_to_status_code(?WAMP_ERROR_NET_FAILURE) ->                     502;
uri_to_status_code(?WAMP_ERROR_NOT_AUTHORIZED) ->                  401;
uri_to_status_code(?WAMP_ERROR_NO_ELIGIBLE_CALLE) ->               502;
uri_to_status_code(?WAMP_ERROR_NO_SUCH_PROCEDURE) ->               501;
uri_to_status_code(?WAMP_ERROR_NO_SUCH_REALM) ->                   502;
uri_to_status_code(?WAMP_ERROR_NO_SUCH_REGISTRATION) ->            502;
uri_to_status_code(?WAMP_ERROR_NO_SUCH_ROLE) ->                    400;
uri_to_status_code(?WAMP_ERROR_NO_SUCH_SESSION) ->                 500;
uri_to_status_code(?WAMP_ERROR_NO_SUCH_SUBSCRIPTION) ->            502;
uri_to_status_code(?WAMP_ERROR_OPTION_DISALLOWED_DISCLOSE_ME) ->   400;
uri_to_status_code(?WAMP_ERROR_OPTION_NOT_ALLOWED) ->              400;
uri_to_status_code(?WAMP_ERROR_PROCEDURE_ALREADY_EXISTS) ->        400;
uri_to_status_code(?WAMP_ERROR_SYSTEM_SHUTDOWN) ->                 500;
uri_to_status_code(_) ->                                           500.


%% @private
eval_headers(Req, #{api_spec := Spec, api_context := Ctxt}) ->
    Expr = maps_utils:get_path(
        [<<"response">>, <<"on_error">>, <<"headers">>],
        maps:get(method(Req), Spec),
        #{}
    ),
    mops:eval(Expr, Ctxt).
