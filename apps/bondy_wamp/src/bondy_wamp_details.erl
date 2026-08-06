%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_details).
-moduledoc """
Builds and validates the `Details` dictionary of WAMP messages such as `HELLO`,
`WELCOME`, `EVENT`, `RESULT` and `INVOCATION`, honouring the extended details
configured in the application environment.
""".
-include("bondy_wamp.hrl").

-type type() ::
    hello
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

-doc """
Fails with an exception if the Options maps is not valid.

A Options map is valid if all its properties (keys) are valid. A property is
valid if it is a key defined by the WAMP Specification for the message type
or when the key is found in the list of extended_options configured in the
application environment and in both cases the key is valid according to the
WAMP regex specification.

Example:

```erlang
application:set_env(wamp, extende_options, [{call, [<<"_x">>, <<"_y">>]}).
```

Using this configuration only `call` messages would accept `<<"_x">>`
and `<<"_y">>` properties.
""".
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
    Roles = maps:get(roles, Details),

    maps:size(Roles) > 0 orelse
        error(
            bondy_error:new(missing_required_value, #{
                message => ~"No WAMP peer roles defined.",
                description => <<
                    "At least one WAMP peer role is required in the "
                    "HELLO.Details.roles dictionary"
                >>,
                details => #{key => ~"roles"}
            })
        ),

    case key_value:get([caller, progressive_call_results], Details, false) of
        true ->
            key_value:get([caller, call_canceling], Details, false) orelse
                error(
                    bondy_error:new(invalid_feature_request, #{
                        message => ~"Invalid feature requested for Caller role",
                        description => <<
                            "The feature progressive_call_results was requested "
                            "but the feature call_canceling was not, both need to be "
                            "requested for progressive_call_results to be enabled."
                        >>,
                        details => #{role => ~"caller"}
                    })
                );
        false ->
            ok
    end,

    case key_value:get([callee, progressive_call_results], Details, false) of
        true ->
            key_value:get([callee, call_canceling], Details, false) orelse
                error(
                    bondy_error:new(invalid_feature_request, #{
                        message => ~"Invalid feature requested for Callee role",
                        description => <<
                            "The feature progressive_call_results was requested "
                            "but the feature call_canceling was not, both need to be "
                            "requested for progressive_call_results to be enabled."
                        >>,
                        details => #{role => ~"callee"}
                    })
                );
        false ->
            ok
    end,

    %% Progressive Calls pairs with call_canceling too (a streamed call must be
    %% cancellable mid-stream). Read the canonical `[Role, features, Feature]`
    %% path from `Roles` — the same path `bondy_dealer:session_feature/3` uses.
    %% (NOTE: the `progressive_call_results` checks above read `[Role, Feature]`
    %% from `Details`, which does not descend into the nested `features` map, so
    %% that pre-existing pairing check does not currently fire — tracked
    %% separately.)
    ok = require_call_canceling(caller, progressive_calls, Roles),
    ok = require_call_canceling(callee, progressive_calls, Roles),

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

%% @private
%% WAMP advanced-profile pairing: a role that announces `Feature` MUST also
%% announce `call_canceling`, otherwise the HELLO is rejected. `Roles` is the
%% `HELLO.Details.roles` map; features are read at `[Role, features, Feature]`.
require_call_canceling(Role, Feature, Roles) ->
    case key_value:get([Role, features, Feature], Roles, false) of
        true ->
            key_value:get([Role, features, call_canceling], Roles, false) orelse
                error(
                    bondy_error:new(invalid_feature_request, #{
                        message => ~"Invalid feature requested",
                        description => iolist_to_binary([
                            "The feature ",
                            atom_to_binary(Feature, utf8),
                            " was requested for the ",
                            atom_to_binary(Role, utf8),
                            " role but call_canceling was not; both are "
                            "required for ",
                            atom_to_binary(Feature, utf8),
                            "."
                        ]),
                        details => #{role => Role, feature => Feature}
                    })
                ),
            ok;
        false ->
            ok
    end.
