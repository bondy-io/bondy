%% -----------------------------------------------------------------------------
%%  Copyright (c) 2015-2021 Leapsight. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(bondy_wamp_options).
-include("bondy_wamp.hrl").

-type type()    ::  publish
                    | subscribe
                    | call
                    | cancel
                    | register
                    | interrupt
                    | yield.


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
-spec new(MessageType :: type(), Opts :: map()) -> map() | no_return().

new(Type, Opts) ->
    Extensions = app_config:get(wamp, [extended_options, Type], []),
    validate(Type, Opts, Extensions).




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
validate(call, Opts, Extensions) ->
    Spec = ?CALL_OPTS_SPEC,
    bondy_wamp_utils:validate_map(Opts, Spec, Extensions);

validate(cancel, Opts, Extensions) ->
    Spec = ?CALL_CANCELLING_OPTS_SPEC,
    bondy_wamp_utils:validate_map(Opts, Spec, Extensions);

validate(interrupt, Opts, Extensions) ->
    Spec = ?CALL_CANCELLING_OPTS_SPEC,
    bondy_wamp_utils:validate_map(Opts, Spec, Extensions);

validate(publish, Opts, Extensions) ->
    Spec = ?PUBLISH_OPTS_SPEC,
    bondy_wamp_utils:validate_map(Opts, Spec, Extensions);

validate(register, Opts, Extensions) ->
    Spec = ?REGISTER_OPTS_SPEC,
    bondy_wamp_utils:validate_map(Opts, Spec, Extensions);

validate(subscribe, Opts, Extensions) ->
    Spec = ?SUBSCRIBE_OPTS_SPEC,
    bondy_wamp_utils:validate_map(Opts, Spec, Extensions);

validate(yield, Opts, Extensions) ->
    Spec = ?YIELD_OPTIONS_SPEC,
    bondy_wamp_utils:validate_map(Opts, Spec, Extensions);

validate(_, _, _) ->
    error(badarg).