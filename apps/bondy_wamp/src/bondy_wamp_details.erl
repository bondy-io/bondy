%% -----------------------------------------------------------------------------
%%  Copyright (c) 2015-2021 Leapsight. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(bondy_wamp_details).
-include("bondy_wamp.hrl").

-type type()    ::  hello
                    | welcome
                    | abort
                    | goodbye
                    | event
                    | result
                    | invocation
                    | event_received
                    | subscriber_received.


-export_type([type/0]).


-export([new/2]).




%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Fails with an exception if the Options maps is not valid.
%% A Options map is valid if all its properties (keys) are valid. A property is
%% valid if it is a key defined by the WAMP Specification for the message type
%% or when the key is found in the list of extended_options configured in the
%% application environment and in both cases the key is valid according to the
%% WAMP regex specification.
%%
%% Example:
%%
%% ```
%% application:set_env(wamp, extende_options, [{call, [<<"_x">>, <<"_y">>]}).
%% ```
%%
%% Using this configuration only `call' messages would accept `<<"_x">>'
%% and `<<"_y">>' properties.
%% -----------------------------------------------------------------------------
-spec new(MessageType :: type(), Details :: map()) -> map() | no_return().

new(Type, Details) ->
    Extensions = app_config:get(wamp, [extended_details, Type], []),
    validate(Type, Details, Extensions).




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
validate(hello, Details0, Extensions) ->
    Spec = ?HELLO_DETAILS_SPEC,
    Details = bondy_wamp_utils:validate_map(Details0, Spec, Extensions),
    Roles =  maps:get(roles, Details),

    maps:size(Roles) > 0
        orelse error(#{
            code => missing_required_value,
            message => <<"No WAMP peer roles defined.">>,
            description => <<
                "At least one WAMP peer role is required in the "
                "HELLO.Details.roles dictionary"
            >>
        }),

    case key_value:get([caller, progressive_call_results], Details, false) of
        true ->
            key_value:get([caller, call_canceling], Details, false)
            orelse error(#{
                code => invalid_feature_request,
                message => <<"Invalid feature requested for Caller role">>,
                description => <<
                    "The feature progressive_call_results was requested "
                    "but the feature call_canceling was not, both need to be "
                    "requested for progressive_call_results to be enabled."
                >>
            });
        false ->
            ok
    end,

    case key_value:get([callee, progressive_call_results], Details, false) of
        true ->
            key_value:get([callee, call_canceling], Details, false)
            orelse error(#{
                code => invalid_feature_request,
                message => <<"Invalid feature requested for Callee role">>,
                description => <<
                    "The feature progressive_call_results was requested "
                    "but the feature call_canceling was not, both need to be "
                    "requested for progressive_call_results to be enabled."
                >>
            });
        false ->
            ok
    end,

    Details;

validate(welcome, Details, Extensions) ->
    Spec = ?WELCOME_DETAILS_SPEC,
    bondy_wamp_utils:validate_map(Details, Spec, Extensions);

validate(abort, Details, Extensions) ->
    Spec = #{},
    Opts = #{keep_unknown => true},
    bondy_wamp_utils:validate_map(Details, Spec, Extensions, Opts);

validate(goodbye, Details, Extensions) ->
    Spec = #{},
    Opts = #{keep_unknown => true},
    bondy_wamp_utils:validate_map(Details, Spec, Extensions, Opts);

validate(error, Details, Extensions) ->
    Spec = ?ERROR_DETAILS_SPEC,
    Opts = #{keep_unknown => true},
    bondy_wamp_utils:validate_map(Details, Spec, Extensions, Opts);

validate(event, Details, Extensions) ->
    Spec = ?EVENT_DETAILS_SPEC,
    bondy_wamp_utils:validate_map(Details, Spec, Extensions);

validate(event_received, Details, Extensions) ->
    Spec = ?EVENT_RECEIVED_DETAILS_SPEC,
    bondy_wamp_utils:validate_map(Details, Spec, Extensions);

validate(subscriber_received, Details, Extensions) ->
    Spec = ?SUBSCRIBER_RECEIVED_DETAILS_SPEC,
    bondy_wamp_utils:validate_map(Details, Spec, Extensions);

validate(result, Details, Extensions) ->
    Spec = ?RESULT_DETAILS_SPEC,
    Opts = #{keep_unknown => true},
    bondy_wamp_utils:validate_map(Details, Spec, Extensions, Opts);

validate(invocation, Details, Extensions) ->
    Spec = ?INVOCATION_DETAILS_SPEC,
    bondy_wamp_utils:validate_map(Details, Spec, Extensions);

validate(_, _, _) ->
    error(badarg).