%% =============================================================================
%%  bondy_broker_bridge.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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
%% @doc Initialises the external broker or system as an event sink.
%% An implementation should use this callback for example to setup the
%% environment, load any plugin code and connect to any external system.
%% @end
%% -----------------------------------------------------------------------------
-callback init(Config :: any()) ->
    {ok, Ctxt :: #{binary() => any()}} | {error, Reason :: any()}.


%% -----------------------------------------------------------------------------
%% @doc Parses and validates the action `Action'.
%% This function is called before calling `apply_action/1`
%%
%% Use this function to define any default values required before
%% `apply_action/1` gets called.
%% @end
%% -----------------------------------------------------------------------------
-callback validate_action(Action :: map()) ->
    {ok, ValidAction :: map()} | {error, Reason :: any()}.


%% -----------------------------------------------------------------------------
%% @doc Evaluates the action `Action'.
%% @end
%% -----------------------------------------------------------------------------
-callback apply_action(Action :: map()) ->
    ok
    | {retry, Reason :: any()}
    | {error, Reason :: any()}.


%% -----------------------------------------------------------------------------
%% @doc Terminates the broker bridge and all its subscribers.
%% An implementer should use this call to cleanup the environment, tear down
%% any plugin code and disconnect from external systems.
%% @end
%% -----------------------------------------------------------------------------
-callback terminate(Reason :: any(), State :: any()) -> ok.
