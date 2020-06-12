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
    State = rand:seed_s(exs1024s, {Key, Key, Key}),
    jch(-1, 0, Buckets, State);

bucket(Key, Buckets, Algo) ->
    bucket(erlang:phash2(Key), Buckets, Algo).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
jch(Bucket, Jump, Buckets, _) when Jump >= Buckets ->
    Bucket;

jch(_, Jump, Buckets, State0) ->
    {Random, State1} = rand:uniform_s(State0),
    NewJump = trunc((Jump + 1) / Random),
    jch(Jump, NewJump, Buckets, State1).