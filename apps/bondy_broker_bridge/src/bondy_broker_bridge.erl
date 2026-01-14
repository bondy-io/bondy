%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc This module defines the behaviour for providing event bridging
%% functionality, allowing
%% a supervised process (implemented via bondy_subscriber) to consume WAMP
%% events based on a normal subscription to publish (or
%% produce) those events to an external system, e.g. another message broker, by
%% previously applying a transformation specification based on a templating
%% language..
%%
%% Each broker bridge is implemented as a callback module exporting a
%% predefined set of callback functions.
%%
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_broker_bridge).



%% =============================================================================
%% CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% Initialises the external broker or system as an event sink.
%% An implementation should use this callback for example to setup the
%% environment, load any plugin code and connect to any external system.
%% -----------------------------------------------------------------------------
-callback init(Config :: any()) ->
    {ok, Ctxt :: #{binary() => any()}} | {error, Reason :: any()}.


%% -----------------------------------------------------------------------------
%% Parses and validates the action `Action'.
%% This function is called before calling `apply_action/1`
%%
%% Use this function to define any default values required before
%% `apply_action/1` gets called.
%% -----------------------------------------------------------------------------
-callback validate_action(Action :: map()) ->
    {ok, ValidAction :: map()} | {error, Reason :: any()}.


%% -----------------------------------------------------------------------------
%% Evaluates the action `Action'.
%% -----------------------------------------------------------------------------
-callback apply_action(Action :: map()) ->
    ok
    | {retry, Reason :: any()}
    | {error, Reason :: any()}.


%% -----------------------------------------------------------------------------
%% Terminates the broker bridge and all its subscribers.
%% An implementer should use this call to cleanup the environment, tear down
%% any plugin code and disconnect from external systems.
%% -----------------------------------------------------------------------------
-callback terminate(Reason :: any(), State :: any()) -> ok.
