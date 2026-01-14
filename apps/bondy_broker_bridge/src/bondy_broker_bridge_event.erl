%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
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
