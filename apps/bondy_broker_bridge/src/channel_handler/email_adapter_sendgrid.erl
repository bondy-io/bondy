-module(email_adapter_sendgrid).
-behaviour(email_adapter).


-record(state, {
    apiurl :: string(),
    apikey :: string()
}).


-define(EMAIL_API_PATH, "/mail/send").
-define(EMAIL_CONTENT_TYPE, "application/json").
-define(EMAIL_API_HEADERS(ApiKey), [
    {"Content-Type", ?EMAIL_CONTENT_TYPE},
    {"Accept", "application/json"},
    {"Authorization", "Bearer " ++ ApiKey}
]).

-define(HTTP_OPTIONS, [
    {timeout, 60000},
    {connect_timeout, 10000},
    {version, "HTTP/1.0"}
]).
-define(OPTIONS, [
    {body_format, binary},
    {full_result, true}
]).

-define(SINGLE_EMAIL_SINGLE_RECIPIENT_REQUEST(From, To, Subject, Content, ContentType), #{
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
-define(SINGLE_EMAIL_SINGLE_RECIPIENT_TEMPLATE_REQUEST(From, To, TemplateId, TemaplateData), #{
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


-export([start/0]).
-export([start/1]).
-export([stop/1]).
-export([send/6]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start() ->
    start([]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start(Options) ->
    ApiUrl = proplists:get_value(apiurl, Options),
    ApiKey = proplists:get_value(apikey, Options),

    {ok, #state{apiurl=ApiUrl, apikey=ApiKey}}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
stop(_Conn) ->
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
send(Conn, {ToEmail, ToEmail}, {FromName, FromEmail}, Subject, Message, Opt) ->
    send(Conn, {<<>>, ToEmail}, {FromName, FromEmail}, Subject, Message, Opt);

send(Conn, {ToName, ToEmail}, {FromEmail, FromEmail}, Subject, Message, Opt) ->
    send(Conn, {ToName, ToEmail}, {<<>>, FromEmail}, Subject, Message, Opt);

send(Conn, {_ToName, ToEmail}, {_FromName, FromEmail}, Subject, Message, Opt) ->
    ApiKey = Conn#state.apikey,
    ApiUrl = Conn#state.apiurl,

    Headers = ?EMAIL_API_HEADERS(ApiKey),
    Url = ApiUrl ++ ?EMAIL_API_PATH,

    Body = formatted_body(FromEmail, ToEmail, Subject, Message, Opt),

    Request = {Url, Headers, ?EMAIL_CONTENT_TYPE, Body},

    %% 202 Everything worked as expected (accepted)
    %% 400 Bad Request - Often missing a required parameter
    %% 401 Unauthorized - No valid API key provided
    %% 403 Request Forbidden
    %% 404 Not Found - The requested item doesn’t exist
    %% 413 Payload too large
    %% 500 Server Errors - something is wrong on Sendgrid's end

    try httpc:request(post, Request, ?HTTP_OPTIONS, ?OPTIONS) of
        {ok, {{_, StatusCode, _}, RespHeaders, RespBody}} ->
            process_response(StatusCode, RespHeaders, RespBody);
        {error, _Reason} = Error ->
            Error
    catch
        exit:{timeout, _} ->
            {error, timeout}
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
    Reason = bondy_wamp_json:decode(RespBody),
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
    FormattedBody = ?SINGLE_EMAIL_SINGLE_RECIPIENT_TEMPLATE_REQUEST(From, To,
        TemplateId, TemplateData#{<<"subject">> => Subject}),
    bondy_wamp_json:encode(FormattedBody);

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

    FormattedBody = ?SINGLE_EMAIL_SINGLE_RECIPIENT_REQUEST(From, To,
        Subject, Content, ContentType),
    bondy_wamp_json:encode(FormattedBody).