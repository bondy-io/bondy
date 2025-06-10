%% =============================================================================
%%  bondy_broker_bridge_event.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_broker_bridge_event).
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-export([new/3]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(uri(), binary(), wamp_event()) -> map().

new(RealmUri, Topic, #event{} = Event) ->
    #{
        <<"realm">> => RealmUri,
        <<"topic">> => Topic,
        <<"subscription_id">> => Event#event.subscription_id,
        <<"publication_id">> => Event#event.publication_id,
        <<"details">> => Event#event.details,
        <<"args">> => Event#event.args,
        <<"kwargs">> => Event#event.kwargs,
        <<"ingestion_timestamp">> => erlang:system_time(millisecond)
    }.