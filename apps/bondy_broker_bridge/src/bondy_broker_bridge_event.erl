%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_broker_bridge_event).

-moduledoc """
Helper for converting a WAMP `#event{}` record into the flat map used
as the `<<"event">>` key in the `mops` evaluation context.

The resulting map has binary keys so that `mops` template expressions
like `{{event.topic}}` resolve correctly.
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-export([new/3]).



%% =============================================================================
%% API
%% =============================================================================


-doc """
Build an event context map from a WAMP event record.

Adds an `<<"ingestion_timestamp">>` (millisecond system time) for
observability.
""".
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
