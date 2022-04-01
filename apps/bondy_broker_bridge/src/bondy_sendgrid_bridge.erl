%% =============================================================================
%%  bondy_sendgrid_bridge.erl -
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
%% =============================================================================

-module(bondy_sendgrid_bridge).
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
    },
    <<"template_id">> => #{
        alias => template_id,
        required => false,
        datatype => binary,
        allow_null => false,
        allow_undefined => false
    },
    <<"template_data">> => #{
        alias => template_data,
        required => true,
        datatype => map,
        allow_null => false,
        allow_undefined => false,
        default => #{}
    }
}).

-define(RETRY_TIMES, 3).
-define(RETRY_BACKOFF_MS, 2000).


-export([init/1]).
-export([validate_action/1]).
-export([apply_action/1]).
-export([terminate/2]).



%% =============================================================================
%% BONDY_BROKER_BRIDGE CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Initialises the sendgrid module with the provided configuration.
%% @end
%% -----------------------------------------------------------------------------
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



%% -----------------------------------------------------------------------------
%% @doc Validates the action specification.
%% An action spec is a map containing the following keys:
%%
%% * `email_address :: binary()' - the email address to send the email.
%% * `subject :: binary()' - the email subject
%% * `body :: binary()' - the email body
%% * `options :: map()' - options
%% @end
%% -----------------------------------------------------------------------------
validate_action(Action0) ->
    try maps_utils:validate(Action0, ?PRODUCE_ACTION_SPEC) of
        Action1 ->
            {ok, Action1}
    catch
       _:Reason->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc Evaluates the action specification `Action' against the context
%% `Ctxt' using `mops' and send the message to Sendgrid.
%% @end
%% -----------------------------------------------------------------------------
apply_action(Action) ->

    ?LOG_DEBUG(#{
        description => "Action",
        action => Action
    }),
    EmailAddress = maps:get(<<"email_address">>, Action),

    try do_send_with_retry(Action, ?RETRY_TIMES, ?RETRY_BACKOFF_MS) of
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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
terminate(_Reason, _State) ->
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
    Options = maps:with([<<"template_id">>, <<"template_data">>], Body),
    FormattedBody = formatted_body(Body),

    %% 202 Everything worked as expected (accepted)
    %% 400 Bad Request - Often missing a required parameter
    %% 401 Unauthorized - No valid API key provided
    %% 403 Request Forbidden
    %% 404 Not Found - The requested item doesn’t exist
    %% 413 Payload too large
    %% 500 Server Errors - something is wrong on Sendgrid's end

    case email:send(Email, Sender, Subject, FormattedBody, Options) of
        {ok, Res} ->
            #{<<"id">> := Ref} = jsone:decode(Res, [{object_format, map}]),
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
-spec formatted_body(map()) -> list() | no_return().
 
formatted_body(#{<<"template_id">> := _, <<"template_data">> := _}) ->
    %% the message is not used when a template is provided
    [];

formatted_body(#{<<"text/html">> := HTML}) ->
    Message =  <<
        "Please open this email with an HTML viewer to complete the process."
    >>,
    [{html, HTML}, {text, Message}];

formatted_body(#{<<"text/plain">> := Text}) ->
    [{text, Text}];

formatted_body(_) ->
    error({error, <<"Missing body data Keys: [text/html, text/plain or template_id and template_data]">>}).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec do_send_with_retry(map(), integer(), backoff:backoff())
    -> {ok, binary()} | {error, Reason :: any()} | no_return().

do_send_with_retry(Action, 1, _Backoff) ->
    try send_email(Action) of
        {ok, _} = Success ->
            Success;
        {error, _Reason} ->
            error({error, <<"Max retries reached">>})
    catch
        _:_ ->
            error({error, <<"Max retries reached">>})
    end;

do_send_with_retry(Action, Times, Backoff) ->
    try send_email(Action) of
        {ok, _} = Success ->
            Success;
        {error, timeout} ->
            {Time, Backoff1} = backoff:fail(Backoff),
            ok = timer:sleep(Time),
            do_send_with_retry(Action, Times - 1, Backoff1);
        {error, _} = Error ->
            error(Error)
    catch
        _:Reason ->
            error({error, Reason})
    end.