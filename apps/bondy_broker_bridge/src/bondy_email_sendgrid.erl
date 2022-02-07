%% =============================================================================
%%  bondy_email_sendgrid.erl -
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
%%
%% Copyright (c) 2012-2014 Kivra
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
%% =============================================================================

-module(bondy_email_sendgrid).
-behaviour(bondy_email_backend).


-define(HTTP_OPTIONS, [
    {timeout, 60000},
    {connect_timeout, 10000},
    {version, "HTTP/1.0"}
]).
-define(OPTIONS, [
    {body_format, binary},
    {full_result, true}
]).

-define(REQUEST(From, To, Subject, Content, ContentType), #{
    <<"personalizations">> => [
        #{<<"to">> => [#{<<"email">> => To}]}
    ],
    <<"from">> => #{
        <<"email">> => From
    },
    <<"subject">> => Subject,
    <<"content">> => [
        #{
            <<"type">> => ContentType,
            <<"value">> => Content
        }
    ]
}).
-define(TEMPLATE_REQUEST(From, To, TemplateId, TemaplateData), #{
    <<"personalizations">> => [
        #{
            <<"to">> => [#{<<"email">> => To}],
            <<"dynamic_template_data">> => TemaplateData
        }
    ],
    <<"from">> => #{
        <<"email">> => From
    },
    <<"template_id">> => TemplateId
}).


-export([start/1]).
-export([stop/0]).
-export([send/6]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start(Host, Port, Opts) ->
    PoolSize = key_value:get(pool_size, Opts, 25),
    SockOpts = key_value:get(sock_opts, Opts, #{}),
    GunOpts = #{
        conn_opts => #{
            connect_timeout => 5000,
            % retry => 3,
            % retry_timeout => 5000,
            sock_opts => SockOpts,
            transport => ssl
        },
        size => PoolSize
    }],

    case gun_pool:start_pool(Host, Port, GunOpts) of
        {ok, _Pid} ->
            Headers = [
                %% gun_pool will choose the pool from the host header
                {<<"host">>, Host},
                {<<"content-type">>, <<"application/json">>},
                {<<"accept">>, <<"application/json">>},
                {<<"authorization">>, list_to_binary("Bearer " ++ ApiKey)}
            ]),

            Ctxt = #{
                <<"headers">> => Headers
            },
            {ok, Ctxt};
        {error, _} = Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
stop(Host, Port) ->
    gun_pool:stop_pool(Host, Port).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
send({ToEmail, ToEmail}, {FromName, FromEmail}, Subject, Message, Opt) ->
    send({<<>>, ToEmail}, {FromName, FromEmail}, Subject, Message, Opt);

send({ToName, ToEmail}, {FromEmail, FromEmail}, Subject, Message, Opt) ->
    send({ToName, ToEmail}, {<<>>, FromEmail}, Subject, Message, Opt);

send({_ToName, ToEmail}, {_FromName, FromEmail}, Subject, Message, Opt) ->
    Path = list_to_binary(ApiUrl ++ "/mail/send"),

    Headers = maps:get(<<"headers">>, Opts, []),

    Body = formatted_body(FromEmail, ToEmail, Subject, Message, Opt),

    GunOpts = [],

    %% 202 Everything worked as expected (accepted)
    %% 400 Bad Request - Often missing a required parameter
    %% 401 Unauthorized - No valid API key provided
    %% 403 Request Forbidden
    %% 404 Not Found - The requested item doesn’t exist
    %% 413 Payload too large
    %% 500 Server Errors - something is wrong on Sendgrid's end

    case gun_pool:post(Path, Headers, Body, GunOpts) of
        {async, Ref} ->
            case gun_pool:await(Ref, 2500) of
                {response, fin, Status, RespHeaders} ->
                    process_response(Status, RespHeaders, <<>>);
                {response, nofin, Status, RespHeaders} ->
                    case gun_pool:await_body(Ref, 2500) of
                        {ok, Body} ->
                            process_response(Status, RespHeaders, Body);
                        {error, _} = Error ->
                            Error
                    end
            end;
        {error, _} = Error ->
            Error
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec process_response(integer(), list(), string() | binary())
    -> {ok, binary()} | {error, Reason :: any()}.

process_response(202, RespHeaders, _RespBody) ->
    MessageId =
        case lists:keyfind("x-message-id", 1, RespHeaders) of
            false -> <<>>;
            {_, MsgId} -> list_to_binary(MsgId)
        end,
    {ok, <<"{\"id\":\"", MessageId/binary, "\"}">>};

process_response(StatusCode, _RespHeaders, RespBody)
when StatusCode == 400 orelse
    StatusCode == 401 orelse StatusCode == 403 orelse
    StatusCode == 404 orelse
    StatusCode == 413 orelse
    StatusCode == 500 ->
    Reason = jsone:decode(RespBody, [{object_format, map}]),
    {error, {StatusCode, Reason}};

process_response(StatusCode, _RespHeaders, _RespBody)
when StatusCode == 408 orelse StatusCode == 504 ->
    {error, timeout};

process_response(StatusCode, _RespHeaders, _RespBody) ->
    {error, {StatusCode, server_error}}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
formatted_body(From, To, Subject, _Body, #{<<"template_id">> := TemplateId} = Options) ->
    TemplateData = maps:get(<<"template_data">>, Options),
    FormattedBody = ?TEMPLATE_REQUEST(From, To,
        TemplateId, TemplateData#{<<"subject">> => Subject}),
    jsone:encode(FormattedBody);

formatted_body(From, To, Subject, Body, _Options) ->
    Type = lists:keyfind(<<"html">>, 1, Body),
    {ContentType, Content} =
        case Type of
            false ->
                %% [{text, Text}]
                {<<"text">>, Text} = lists:keyfind(<<"text">>, 1, Body),
                {<<"text/plain">>, Text};
            {<<"html">>, HTML} ->
                %% [{html, HTML}]
                {<<"text/html">>, HTML}
        end,

    FormattedBody = ?REQUEST(From, To,
        Subject, Content, ContentType),
    jsone:encode(FormattedBody).