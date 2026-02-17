%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_aws_sns_bridge).

-moduledoc """
Bridge implementation that sends SMS messages via AWS SNS.

Uses `erlcloud_sns:publish_to_phone/2` to deliver SMS. The erlcloud
application is configured and started during `init/1`.

## Action specification

| Key | Type | Description |
|-----|------|-------------|
| `<<"phone_number">>` | binary | Recipient phone number (E.164 format) |
| `<<"text_message">>` | binary | SMS text content |
""".

-behaviour(bondy_broker_bridge).

-include_lib("kernel/include/logger.hrl").


-define(PRODUCE_ACTION_SPEC, #{
    <<"phone_number">> => #{
        alias => phone_number,
        required => true,
        datatype => binary,
        allow_null => false,
        allow_undefined => false
    },
    <<"text_message">> => #{
        alias => text_message,
        required => true,
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



-doc "Configure and start the `erlcloud` application with the provided config.".
init(Config) ->

    ?LOG_DEBUG(#{
        description => "Configuration",
        config => Config
    }),

    %% TODO: check the proper configuration (using default at the moment)
    %% {lhttpc, [{pool_size, 1000},{connection_timeout, 300000}]}
    application:set_env([{erlcloud, Config}]),

    try application:ensure_all_started(erlcloud) of
        {ok, _} ->
            {ok, #{}};
        Error ->
            Error
    catch
       _:Reason ->
           ?LOG_ERROR(#{
                description => "Error while initialising bridge",
                config => Config,
                reason => Reason
            }),
            {error, Reason}
    end.


-doc "Validate an SNS SMS action spec (`phone_number`, `text_message`).".
validate_action(Action0) ->
    try maps_utils:validate(Action0, ?PRODUCE_ACTION_SPEC) of
        Action1 ->
            {ok, Action1}
    catch
       _:Reason->
            {error, Reason}
    end.


-doc "Send an SMS via `erlcloud_sns:publish_to_phone/2`.".
apply_action(Action) ->

    ?LOG_DEBUG(#{
        description => "Action",
        action => Action
    }),
    PhoneNumber = maps:get(<<"phone_number">>, Action),

    try send_sms(Action) of
        {ok, MessageId} ->
            ?LOG_INFO(#{
                description => "Message sent successfully",
                phone_number => PhoneNumber,
                message_id => MessageId
            }),
            ok;
        {error, Reason} = Error ->
            ?LOG_ERROR(#{
                description => "Error while sending message",
                phone_number => PhoneNumber,
                reason => Reason
            }),
            Error
    catch
        Class:EReason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while sending message",
                phone_number => PhoneNumber,
                class => Class,
                reason => EReason,
                stacktrace => Stacktrace
            }),
            {error, EReason}
    end.


-doc "Stop the `erlcloud` application.".
terminate(_Reason, _State) ->
    _  = application:stop(erlcloud),
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec send_sms(map()) ->
    {ok, binary()} | {error, Reason :: any()} | no_return().

send_sms(Action) ->
    #{
        <<"phone_number">> := PhoneNumber,
        <<"text_message">> := SMSText
    } = Action,

    %% returns the message id or an erlang error with {sns_error, Reason}
    try erlcloud_sns:publish_to_phone(PhoneNumber, SMSText) of
        MessageId ->
            {ok, MessageId}
    catch
        error:Reason ->
            {error, Reason}
    end.
