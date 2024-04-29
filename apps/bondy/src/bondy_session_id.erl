%% =============================================================================
%%  bondy_session_id.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight Holdings Limited. All rights reserved.
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

-define(MAX_EXT_ID, ?MAX_ID).
-define(ENCODED_LEN, 27).
-define(LEN, 160).
-define(EXT_LEN, 56).


-type t()           ::  binary().

-export([new/0]).
-export([new/1]).
-export([to_external/1]).
-export([is_type/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Returns a new globally unique session id based on a new random external
%% identifier.
%% @end
%% -----------------------------------------------------------------------------
-spec new() -> t().

new() ->
    %% IDs in the _global scope_ MUST be drawn _randomly_ from a _uniform
    %% distribution_ over the complete range [0, 2^53]
    new(rand:uniform(?MAX_EXT_ID)).


%% -----------------------------------------------------------------------------
%% @doc Returns a new globally unique session id based on the external
%% identifier `ExternalId'.
%% @end
%% -----------------------------------------------------------------------------
-spec new(ExternalId :: id()) -> t().

new(ExternalId)
when is_integer(ExternalId)
andalso ExternalId >= 1
andalso ExternalId =< ?MAX_EXT_ID ->

    %% First segment is the external id as a 56-bit binary
    ExternalIdBin = <<ExternalId:?EXT_LEN/integer>>,

    %% Second part is 104-bit of random data
    PayloadSize = trunc((?LEN - ?EXT_LEN) / 8),
    Payload = crypto:strong_rand_bytes(PayloadSize),

    %% We append first and second part
    <<Id:?LEN/integer>> = <<ExternalIdBin/binary, Payload/binary>>,

    %% We encode using base62
    Base62 = base62:encode(Id),

    %% We pad to 27 chars and return as binary
    iolist_to_binary(string:pad(Base62, ?ENCODED_LEN, leading, $0)).


%% -----------------------------------------------------------------------------
%% @doc Returns the external session identifier i.e. the WAMP Session ID.
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(Base62 :: binary()) -> WAMPSessionId :: id().

to_external(Base62) when is_binary(Base62) ->
    %% We decode the string
    Bin = base62:decode(Base62),

    %% We extract the first segment (56-bits) as an integer
    <<ExternalId:?EXT_LEN/integer, _/binary>> = <<Bin:?LEN/integer>>,

    ExternalId.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_type(Base62) when is_binary(Base62) andalso byte_size(Base62) =:= 27 ->
    true;

is_type(_) ->
    false.