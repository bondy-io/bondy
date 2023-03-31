%% =============================================================================
%%  bondy_consistent_hashing.erl -
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
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
%% It uses Jump Consistent Hash algorithm described in
%% [A Fast, Minimal Memory, Consistent Hash Algorithm](https://arxiv.org/ftp/
%% arxiv/papers/1406/1406.2294.pdf).
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_consistent_hashing).

-define(MAGIC, 16#27BB2EE687B0B0FD).
-define(MASK, 16#FFFFFFFFFFFFFFFF).

-export([bucket/2]).
-export([bucket/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec bucket(Key :: term(), Buckets :: pos_integer()) -> Bucket :: integer().

bucket(Key, Buckets) ->
    bucket(Key, Buckets, jch).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec bucket(Key :: term(), Buckets :: pos_integer(), Algo :: atom()) ->
    Bucket :: integer().

bucket(_, 1, _) ->
    0;

bucket(Key, Buckets, jch)
when is_integer(Key) andalso is_integer(Buckets) andalso Buckets > 1 ->
    jump_consistent_hash(Key, Buckets);

bucket(Key, _, _) when is_integer(Key) ->
    %% Unknown algorithm
    error(badarg);

bucket(Key, Buckets, Algo) ->
    bucket(erlang:phash2(Key), Buckets, Algo).



%% =============================================================================
%% PRIVATE
%% =============================================================================



jump_consistent_hash(Key, N) ->
    jump_consistent_hash(Key, N, -1, 0).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% The following is the C++ implementation in
%% A Fast, Minimal Memory, Consistent Hash Algorithm
%% https://arxiv.org/pdf/1406.2294.pdf
%%
%% @end
%% -----------------------------------------------------------------------------

%% static int32_t jump_consistent_hash(uint64_t key, int32_t num_buckets) {
%%   int64_t b = -1, j = 0;
%%   while (j < num_buckets) {
%%     b = j;
%%     key = key * 2862933555777941757ULL + 1;
%%     j = (b + 1) * ((double)(1LL << 31) / (double)((key >> 33) + 1));
%%   }
%%   return (int32_t)b;
%% }
%%
jump_consistent_hash(Key, N, _, J0) when J0 < N ->
    %% B1 = J0,
    NewKey = (Key * ?MAGIC + 1) band ?MASK,
    J1 = trunc((J0 + 1) * ((1 bsl 31) / ((NewKey bsr 33) + 1)) ),
    jump_consistent_hash(NewKey, N, J0, J1);

jump_consistent_hash(_, _, B, _) ->
    B.



-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

jch_test_() ->
    Cases =
        %% {Expect, Key, Buckets}
        [
            {0, 0, 1},
            {0, 3, 1},
            {0, 0, 2},
            {1, 4, 2},
            {0, 7, 2},
            {55, 1, 128},
            {120, 129, 128},
            {0, 0, 100000000},
            {38172097, 128, 100000000},
            {1644467860, 128, 2147483648},
            {92, 18446744073709551615, 128}
        ],
    [?_assertEqual(Expect, bucket(K, B, jch)) || {Expect, K, B} <- Cases].

-endif.
