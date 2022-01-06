%% =============================================================================
%%  ksuid.erl -
%%
%%  Copyright (c) 2020 Leapsight Holdings Limited. All rights reserved.
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
%% @doc This module implements the Bondy session identifier.  They consist of a
%% 56-bit WAMP Session Identifier and a 104-bit randomly generated payload.
%%
%% The WAMP Session Identifier is an integer drawn randomly from a uniform
%% distribution over the complete range `[1, 2^53]'
%% i.e. (between `1' and `9007199254740992').
%%
%% The string representation is fixed at 27-characters encoded using base62 to
%% be URL friendly.
%%
%% The uniqueness property does not depend on any host-identifiable information
%% or the wall clock. Instead it depends on the improbability of random
%% collisions in such a large number space.
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_session_id).

-include_lib("wamp/include/wamp.hrl").

-define(LEN, 160).
-define(EXT_LEN, 56).
-define(ENCODED_LEN, 27).

-type t()           ::  binary().

-export([new/0]).
-export([new/1]).
-export([to_external/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new() -> t().

new() ->
    %% IDs in the _global scope_ MUST be drawn _randomly_ from a _uniform
    %% distribution_ over the complete range [0, 2^53]
    new(rand:uniform(9007199254740992)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(ExtId :: id()) -> t().

new(ExtId) ->
    <<Id:?LEN/integer>> = append_payload(<<ExtId:?EXT_LEN/integer>>),
    encode(Id).



to_external(Base62) when is_binary(Base62) ->
    Bin = base62:decode(Base62),
    <<SessionId:?EXT_LEN/integer, _/binary>> = <<Bin:?LEN/integer>>,
    SessionId.


%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
append_payload(Timestamp) ->
    PayloadSize = trunc((?LEN - ?EXT_LEN) / 8),
    Payload = payload(PayloadSize),
    <<Timestamp/binary, Payload/binary>>.


%% @private
payload(ByteSize) ->
    crypto:strong_rand_bytes(ByteSize).


%% @private
encode(Id) ->
    Base62 = base62:encode(Id),
    list_to_binary(
        lists:flatten(string:pad(Base62, ?ENCODED_LEN, leading, $0))
    ).