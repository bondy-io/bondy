%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Copyright (c) 2012-2014 Kivra
%%%
%%% Permission to use, copy, modify, and/or distribute this software for any
%%% purpose with or without fee is hereby granted, provided that the above
%%% copyright notice and this permission notice appear in all copies.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
%%%
%%% @doc Email Mailgun Adapter
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-module(email_adapter_mailgun2).
-behaviour(email_adapter).


-record(state, {
    apiurl :: string(),
    apikey :: string()
}).


-define(EMAIL_API_PATH(ApiUrl), ApiUrl ++ "/messages").
-define(EMAIL_API_AUTH_HEADER(ApiKey), [
    {"Authorization",
        "Basic " ++ base64:encode_to_string(lists:append(["api:", ApiKey]))
    }
]).

-define(FORM_URL_ENCODED, "application/x-www-form-urlencoded").
-define(HTTP_OPTIONS, [
    {timeout, 30000},
    {connect_timeout, 5000},
    {version, "HTTP/1.0"}
]).
-define(OPTIONS, [
    {body_format, binary},
    {full_result, false}
]).


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
    %% TODO: I think that this starts are not required in this context
    application:start(inets),
    application:start(crypto),
    application:start(asn1),
    application:start(public_key),
    application:start(ssl),

    Domain = proplists:get_value(domain, Options),
    ApiUrl = proplists:get_value(apiurl, Options),
    ApiKey = proplists:get_value(apikey, Options),

    {ok, #state{apiurl=ApiUrl ++ "/" ++ Domain, apikey=ApiKey}}.


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

send(Conn, {ToName, ToEmail}, {FromName, FromEmail}, Subject, Message, Opt) ->
    Body0 = [
        {<<"to">>, <<ToName/binary, $<, ToEmail/binary, $>>>},
        {<<"from">>, <<FromName/binary, $<, FromEmail/binary, $>>>}, {<<"subject">>, Subject}
    ],
    Request = construct_request(Conn,
        add_message(Message, lists:merge(Opt, Body0))
    ),

    %% 200 Everything worked as expected
    %% 400 Bad Request - Often missing a required parameter
    %% 401 Unauthorized - No valid API key provided
    %% 402 Request Failed - Parameters were valid but request failed
    %% 404 Not Found - The requested item doesn’t exist
    %% 413 Request Entity Too Large - Attachment size is too big
    %% 500, 502, 503, 504 Server Errors - something is wrong on Mailgun’s end

    try httpc:request(post, Request, ?HTTP_OPTIONS, ?OPTIONS) of
        {ok, {200, Payload}} ->
            {ok, Payload};
        {ok, {Status, Payload}} ->
            {error, {Status, Payload}};
        Error ->
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
add_message([], Body)    -> Body;

add_message([H|T], Body) -> add_message(T, [H|Body]).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
construct_request(Conn, Body) ->
    {
        ?EMAIL_API_PATH(Conn#state.apiurl),
        ?EMAIL_API_AUTH_HEADER(Conn#state.apikey),
        ?FORM_URL_ENCODED,
        url_encode(Body)
    }.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
url_encode(Data) ->
    url_encode(Data, <<"">>).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
url_encode([], Acc) ->
    Acc;

url_encode([{Key, Value} | T], <<"">>) ->
    url_encode(T,
        <<(escape_uri(Key))/binary, $=, (escape_uri(Value))/binary>>
    );

url_encode([{Key, Value} | T], Acc) ->
    url_encode(T,
        <<Acc/binary, $&, (escape_uri(Key))/binary, $=,
        (escape_uri(Value))/binary>>
    ).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
escape_uri(S) when is_list(S) ->
    escape_uri(unicode:characters_to_binary(S), <<>>);

escape_uri(B) ->
    escape_uri(B, <<>>).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
escape_uri(<<C, Rest/binary>>, Acc) ->
    if  C >= $0, C =< $9 -> escape_uri(Rest, <<Acc/binary, C>>);
        C >= $A, C =< $Z -> escape_uri(Rest, <<Acc/binary, C>>);
        C >= $a, C =< $z -> escape_uri(Rest, <<Acc/binary, C>>);
        C =:= $          -> escape_uri(Rest, <<Acc/binary, $+>>);
        C =:= $.; C =:= $-; C =:= $~; C =:= $_ ->
            escape_uri(Rest, <<Acc/binary, C>>);
        true ->
            H = C band 16#F0 bsr 4, L = C band 16#0F,
            escape_uri(Rest, <<Acc/binary, $%, (tohexl(H)), (tohexl(L))>>)
    end;

escape_uri(<<>>, Acc) ->
    Acc.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
tohexl(C) when C < 10 -> $0 + C;
tohexl(C) when C < 17 -> $a + C - 10.
