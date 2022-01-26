-module(bondy_aws_sns_bridge).
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
%% @private

-export([init/1]).
-export([validate_action/1]).
-export([apply_action/1]).
-export([terminate/2]).



%% =============================================================================
%% BONDY_BROKER_BRIDGE CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Initialises the erlcloud module with the provided configuration.
%% @end
%% -----------------------------------------------------------------------------
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
                description => "Error while initialising brigde",
                config => Config,
                reason => Reason
            }),
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc Validates the action specification.
%% An action spec is a map containing the following keys:
%%
%% * `phone_number :: binary()' - the phone number to send the sms.
%% * `text_message :: binary()' - the sms text
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
%% `Ctxt' using `mops' and send the message to Amazon SNS.
%% @end
%% -----------------------------------------------------------------------------
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
                description => "Error while sending sms",
                phone_number => PhoneNumber,
                reason => Reason
            }),
            Error
    catch
        Class:EReason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while sending sms",
                phone_number => PhoneNumber,
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
-spec send_sms(map())
    -> {ok, binary()} | {error, Reason :: any()} | no_return().

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