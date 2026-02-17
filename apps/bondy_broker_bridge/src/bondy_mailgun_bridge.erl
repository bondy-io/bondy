%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mailgun_bridge).

-moduledoc """
Bridge implementation that sends emails via the Mailgun API.

Uses the `email` application with the `email_adapter_mailgun2` adapter.
Supports `text/plain` and `text/html` body content (no template support).

## Action specification

| Key | Type | Description |
|-----|------|-------------|
| `<<"email_address">>` | binary | Recipient address |
| `<<"sender">>` | binary | Sender address |
| `<<"subject">>` | binary | Email subject |
| `<<"body">>` | map | `<<"text/plain">>` and/or `<<"text/html">>` |
| `<<"options">>` | map | Additional options (optional) |

## Configuration

The `email_sender` key in the bridge config is injected into the `mops`
context so that action templates can reference `{{email_sender}}`.
""".

-behaviour(bondy_broker_bridge).

-include_lib("kernel/include/logger.hrl").


-define(PRODUCE_ACTION_SPEC, #{
    <<"email_address">> => #{
        alias => email_address,
        required => true,
        datatype => binary,
        allow_null => false,
        allow_undefined => false
    },
    <<"sender">> => #{
        alias => sender,
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (Val) when is_list(Val) ->
                {ok, list_to_binary(Val)};
            (Val) when is_binary(Val) ->
                {ok, Val}
        end
    },
    <<"subject">> => #{
        alias => subject,
        required => true,
        datatype => binary,
        allow_null => false,
        allow_undefined => false
    },
    <<"body">> => #{
        alias => body,
        required => true,
        validator => ?BODY_CONTENT_SPEC
    },
    <<"options">> => #{
        alias => options,
        required => false,
        datatype => map,
        allow_null => false,
        allow_undefined => true
    }
}).

-define(BODY_CONTENT_SPEC, #{
    <<"text/plain">> => #{
        required => false,
        datatype => binary,
        allow_null => false,
        allow_undefined => false
    },
    <<"text/html">> => #{
        required => false,
        datatype => binary,
        allow_null => false,
        allow_undefined => false
    }
}).


-export([init/1]).
-export([validate_action/1]).
-export([apply_action/1]).
-export([terminate/2]).



%% =============================================================================
%% BONDY_BROKER_BRIDGE CALLBACKS
%% =============================================================================



-doc """
Configure and start the `email` application for Mailgun.

Extracts `email_sender` from config and returns it as the bridge context.
""".
init(Config) ->

    ?LOG_DEBUG(#{
        description => "Configuration",
        config => Config
    }),

    try
        application:set_env([{email, Config}]),

        {ok, _} = application:ensure_all_started(email),

        %% set the email sender in the context for the action using mops
        case lists:keyfind(email_sender, 1, Config) of
            false ->
                error({invalid_config, Config});
            SenderTuple ->
                Context = maps:from_list([SenderTuple]),
                {ok, Context}
        end
    catch
        _:Reason ->
            ?LOG_ERROR(#{
                description => "Error while initialising bridge",
                config => Config,
                reason => Reason
            }),
            {error, Reason}
    end.



-doc "Validate a Mailgun email action spec.".
validate_action(Action0) ->
    try maps_utils:validate(Action0, ?PRODUCE_ACTION_SPEC) of
        Action1 ->
            {ok, Action1}
    catch
       _:Reason->
            {error, Reason}
    end.


-doc "Send an email via Mailgun.".
apply_action(Action) ->

    ?LOG_DEBUG(#{
        description => "Action",
        action => Action
    }),
    EmailAddress = maps:get(<<"email_address">>, Action),

    try send_email(Action) of
        {ok, MessageId} ->
            ?LOG_INFO(#{
                description => "Message sent successfully",
                email_address => EmailAddress,
                message_id => MessageId
            }),
            ok;
        {error, Reason} = Error ->
            ?LOG_ERROR(#{
                description => "Error while sending email",
                email_address => EmailAddress,
                reason => Reason
            }),
            Error
    catch
        Class:EReason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while sending email",
                email_address => EmailAddress,
                class => Class,
                reason => EReason,
                stacktrace => Stacktrace
            }),
            {error, EReason}
    end.


-doc "Stop the `email` application.".
terminate(_Reason, _State) ->
    _  = application:stop(email),
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec send_email(map())
    -> {ok, binary()} | {error, Reason :: any()} | no_return().

send_email(Action) ->
    #{
        <<"sender">> := Sender,
        <<"subject">> := Subject,
        <<"email_address">> := Email,
        <<"body">> := Body,
        <<"options">> := _Options
    } = Action,
    FormattedBody = formatted_body(Body),

    %% 200 Everything worked as expected
    %% 400 Bad Request - Often missing a required parameter
    %% 401 Unauthorized - No valid API key provided
    %% 402 Request Failed - Parameters were valid but request failed
    %% 404 Not Found - The requested item doesn’t exist
    %% 413 Request Entity Too Large - Attachment size is too big
    %% 500, 502, 503, 504 Server Errors - something is wrong on Mailgun’s end

    case email:send(Email, Sender, Subject, FormattedBody) of
        {ok, Res} ->
            #{<<"id">> := Ref} = bondy_wamp_json:decode(Res, [{object_format, map}]),
            {ok, Ref};
        {error, timeout} = Error ->
            Error;
        {error, {Status, RespBody}}
            when Status == 400 orelse Status == 413 ->
                %% Unrecoverable, there is an issue with our request
                error(RespBody);
        {error, {Status, _}} = Error
            when Status == 401 orelse Status == 402 orelse Status == 404 ->
                %% An implementation error,
                %% recoverable but needs manual intervention
                Error;
        {error, {Status, _}} = Error
            when Status >= 500 ->
                %% Emails service Error, recoverable by retrying
                Error;
        {error, _} = Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
formatted_body(#{<<"text/html">> := HTML}) ->
    Message =  <<
        "Please open this email with an HTML viewer to complete the process."
    >>,
    [{html, HTML}, {text, Message}];

formatted_body(#{<<"text/plain">> := Text}) ->
    [{text, Text}].
