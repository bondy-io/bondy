%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_regulator_rate_limit).

-moduledoc """
""".

-include_lib("kernel/include/logger.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(TAB, ?MODULE).

-record(bondy_regulator_rate_limit, {
    key :: any(),
    algorithm :: algorithm(),
    %% N–requests-per-window or bucket‐size
    capacity :: pos_integer(),
    %% window length in ms (used only by fixed/sliding)
    window_ms :: pos_integer(),
    %% number of sub-windows (1 for fixed, >1 for sliding, 0 for token/leaky)
    buckets :: pos_integer(),
    %% tokens/ms (refill for token_bucket, drain for leaky_bucket)
    rate :: float(),
    atomics :: atomics:atomics_ref()
}).

-type t() :: #?MODULE{}.
-type key() :: any().
-type algorithm() :: token_bucket.
%% | fixed_window
%% | sliding_window
%% | leaky_bucket.
-type opts() :: #{
    capacity => pos_integer(),
    window_ms => pos_integer(),
    buckets => pos_integer(),
    rate => number()
}.
-type info() :: #{
    remaining := number(),
    resets_in := pos_integer()
}.

-export_type([t/0]).

%% API
-export([new/2]).
-export([new/3]).
-export([delete/1]).
-export([allow/2]).
-export([wait/2]).
-export([reset/1]).
-export([peek/1]).

-export([start_link/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).

%% =============================================================================
%% API
%% =============================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Creates a bucket that is NOT registered in the module's table: it has no key,
and the caller's reference to the returned term is the only thing keeping its
atomics array alive.

Use this for a bucket a single owner holds in its own state and passes to
`allow/2` directly — a per-session or per-connection limiter. Such a bucket is
never looked up by key, so registering it buys nothing and costs a row that
only the owner can ever free: if the owner dies without running its teardown,
the row is unreachable for good, because its key is not derivable from
anything. Unregistered, the array is freed by the VM when the owner's
reference goes, and there is no teardown to forget.

Use `new/3` only when some OTHER process must find the bucket by key — the
shared node / listener / realm buckets `m:bondy_rate_limiter` owns and reaps
with its own idle-TTL sweep.
""".
-spec new(Algo :: algorithm(), Options :: opts()) ->
    {ok, t()} | {error, Reason :: any()}.

new(Algo, Opts) ->
    case make(Algo, undefined, Opts) of
        #?MODULE{} = T ->
            ok = reset(T),
            {ok, T};
        {error, _} = Error ->
            Error
    end.

-doc """
Creates a bucket registered in the module's table under `Key`, so that it can
be found with `allow/2`, `peek/1` or `reset/1` given the key alone. The row is
the caller's to remove with `delete/1`.

For an owner-held bucket that nobody looks up by key, use `new/2` instead — see
why there.
""".
-spec new(Algo :: algorithm(), Key :: key(), Options :: opts()) ->
    {ok, t()} | {error, Reason :: any()}.

new(Algo, Key, Opts) ->
    case make(Algo, Key, Opts) of
        #?MODULE{} = T ->
            store(T);
        {error, _} = Error ->
            Error
    end.

%% @private
make(token_bucket = Algo, Key, Opts) when is_map(Opts) ->
    Ref = atomics:new(2, [{signed, false}]),
    %% Default = 5 reqs / second
    Rate = maps:get(rate, Opts, 5 / 1_000),
    %% Burst up
    Capacity = maps:get(capacity, Opts, 20),

    is_number(Rate) andalso Rate > 0 orelse
        error(
            badarg,
            [Algo, Key, Opts],
            [
                {error_info, #{
                    cause => #{3 => "rate should be a positive number"}
                }}
            ]
        ),

    is_integer(Capacity) andalso Capacity > 0 orelse
        error(
            badarg,
            [Algo, Key, Opts],
            [
                {error_info, #{
                    cause => #{3 => "capacity should be a positive integer"}
                }}
            ]
        ),

    #?MODULE{
        key = Key,
        algorithm = token_bucket,
        rate = Rate,
        capacity = Capacity,
        atomics = Ref,
        buckets = 0,
        window_ms = 0
    };
make(Algo, Key, Opts) ->
    %% Only support token_bucket for the time being
    error(
        badarg,
        [Algo, Key, Opts],
        [{error_info, #{cause => #{1 => "algorithm not supported"}}}]
    ).

-doc """
""".
-spec allow(key() | t(), Increment :: pos_integer()) ->
    {true, info()} | {false, info()} | no_return().

allow(#?MODULE{} = T, Increment) when is_integer(Increment); Increment > 0 ->
    Now = erlang:system_time(millisecond),
    Tokens0 = atomics:get(T#?MODULE.atomics, 1),
    LastRefillTs = atomics:get(T#?MODULE.atomics, 2),

    Tokens1 = calculate_tokens(T, Tokens0, LastRefillTs, Now),

    case Tokens1 >= Increment of
        true ->
            Tokens = Tokens1 - Increment,
            _ = atomics:exchange(T#?MODULE.atomics, 1, Tokens),
            _ = atomics:exchange(T#?MODULE.atomics, 2, Now),

            %% Next token availability
            ResetsIn =
                case Tokens >= Increment of
                    true ->
                        0;
                    false ->
                        calculate_resets_in(T, Tokens, Increment)
                end,

            Info = #{remaining => Tokens, resets_in => ResetsIn},
            {true, Info};
        false ->
            ResetsIn = calculate_resets_in(T, Tokens1, Increment),
            Info = #{remaining => 0, resets_in => ResetsIn},
            {false, Info}
    end;
allow(Key, Increment) ->
    allow(fetch(Key), Increment).

-doc """
""".
-spec wait(key() | t(), Increment :: pos_integer()) ->
    {true, info()} | {false, info()} | no_return().

wait(Term, Increment) ->
    case allow(Term, Increment) of
        {true, _} = Result ->
            Result;
        {false, #{resets_in := Millis}} ->
            timer:sleep(Millis),
            allow(Term, Increment)
    end.

-doc """
""".
-spec peek(key() | t()) -> info() | no_return().

peek(#?MODULE{} = T) ->
    Now = erlang:system_time(millisecond),
    Tokens0 = atomics:get(T#?MODULE.atomics, 1),
    LastRefillTs = atomics:get(T#?MODULE.atomics, 2),

    Tokens = calculate_tokens(T, Tokens0, LastRefillTs, Now),

    ResetsIn =
        case Tokens >= 1 of
            true ->
                0;
            false ->
                calculate_resets_in(T, Tokens, 1)
        end,

    #{remaining => Tokens, resets_in => ResetsIn};
peek(Key) ->
    peek(fetch(Key)).

-doc """
""".
-spec delete(key() | t()) -> ok.

delete(#?MODULE{key = undefined}) ->
    %% An unregistered bucket (`new/2`) owns no row. Its atomics array is
    %% freed when the last reference to the term goes, so there is nothing
    %% here to delete.
    ok;
delete(#?MODULE{} = T) ->
    delete(T#?MODULE.key);
delete(Key) ->
    ets:delete(?TAB, Key),
    ok.

-doc """
Fails with `badarg` exception if the limit doesn't exist.
""".
-spec reset(key() | t()) -> ok | no_return().

reset(#?MODULE{algorithm = token_bucket} = T) ->
    _ = atomics:exchange(T#?MODULE.atomics, 1, T#?MODULE.capacity),
    _ = atomics:exchange(T#?MODULE.atomics, 2, erlang:system_time(millisecond)),
    ok;
reset(Key) ->
    reset(fetch(Key)).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

%% The server exists to OWN `?TAB` — the registered buckets outlive any
%% individual caller, so the table must not be owned by one.
%%
%% It runs no reaper. It used to sweep the table every minute deleting rows
%% whose `atomics:get/2` raised `badarg`, on the belief that an unused atomics
%% array is garbage collected out from under its row. It is not: the row holds
%% a reference to the array, which is exactly what keeps it alive, so the read
%% always succeeded and the sweep never deleted anything — a full `ets:foldl`
%% per minute, forever, reclaiming nothing while reading as though orphans were
%% handled. (Falsifier: store an atomics ref in ETS, drop every other
%% reference, garbage-collect every process, read it back from the row —
%% `atomics:get/2` returns the value.)
%%
%% Registered buckets are reaped by their owner: `m:bondy_rate_limiter` sweeps
%% its own on an idle TTL and calls `delete/1`. Owner-held buckets are built
%% with `new/2` and are not in the table at all.
init(_) ->
    ?TAB = ets:new(?TAB, [
        named_table,
        ordered_set,
        {keypos, 2},
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    {ok, #{}}.

handle_call(_, _, State) ->
    {reply, ok, State}.

handle_cast(_Event, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

store(#?MODULE{} = T) ->
    case ets:insert_new(?TAB, T) of
        true ->
            ok = reset(T),
            {ok, T};
        false ->
            %% Ref will be GC'ed
            {error, already_exists}
    end.

fetch(Key) ->
    case ets:lookup(?TAB, Key) of
        [#?MODULE{} = T] ->
            T;
        [] ->
            error(badarg)
    end.

calculate_tokens(T, Tokens, LastRefillTs, Now) ->
    Delta = Now - LastRefillTs,
    trunc(min(T#?MODULE.capacity, Tokens + Delta * T#?MODULE.rate)).

calculate_resets_in(T, Tokens, Increment) ->
    trunc(math:ceil((Increment - Tokens) / T#?MODULE.rate)).

%% =============================================================================
%% EUNIT
%% =============================================================================

-ifdef(TEST).

token_bucket_test() ->
    {ok, Pid} = start_link(),
    try
        %% 1 req/sec without bursting
        {ok, T} = new(token_bucket, foo, #{capacity => 1, rate => 1 / 1000}),
        ?assertMatch({true, #{}}, allow(T, 1)),
        ?assertMatch({false, #{}}, allow(T, 1)),
        ?assertMatch({true, #{}}, wait(T, 1)),
        {false, Info} = allow(T, 1),
        ?assertEqual(Info, peek(T))
    after
        %% The server is REGISTERED: leaving it running orphans the name
        %% outside any supervision tree, and every later fixture's
        %% `application:ensure_all_started(bondy_regulator)` then fails
        %% with `{already_started, _}` on the sup child (measured — it
        %% cancelled bondy_rate_limit_test's whole fixture in full-eunit
        %% runs while both were green standalone).
        unlink(Pid),
        gen_server:stop(Pid)
    end.

-endif.
