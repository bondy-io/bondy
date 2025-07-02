%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
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
    key             :: any(),
    algorithm       :: algorithm(),
    %% N–requests-per-window or bucket‐size
    capacity        :: pos_integer(),
    %% window length in ms (used only by fixed/sliding)
    window_ms       :: pos_integer(),
    %% number of sub-windows (1 for fixed, >1 for sliding, 0 for token/leaky)
    buckets         :: pos_integer(),
    %% tokens/ms (refill for token_bucket, drain for leaky_bucket)
    rate            :: float(),
    atomics         :: atomics:atomics_ref()
}).

-record(state, {
    purge_interval = timer:minutes(1) :: pos_integer()
}).


-type t()           ::  #?MODULE{}.
-type key()         ::  any().
-type algorithm()   ::  token_bucket.
                        %% | fixed_window
                        %% | sliding_window
                        %% | leaky_bucket.
-type opts()        :: #{
                            capacity => pos_integer(),
                            window_ms => pos_integer(),
                            buckets => pos_integer(),
                            rate => number()
                        }.
-type info()        :: #{
                            remaining := number(),
                            resets_in := pos_integer()
                        }.

-export_type([t/0]).

%% API
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
new(Name, [
    {limit, 100},
    {window, {1, minute}},
    {algorithm, sliding},
    {backend, ets}
]).
""".
-spec new(Algo :: algorithm(), Key :: key(), Options :: opts()) ->
    {ok, t()} | {error, Reason :: any()}.

new(token_bucket = Algo, Key, Opts) when is_map(Opts) ->
    Ref = atomics:new(2, [{signed, false}]),
    %% Default = 5 reqs / second
    Rate = maps:get(rate, Opts, 5 / 1_000),
    %% Burst up
    Capacity = maps:get(capacity, Opts, 20),

    is_number(Rate) andalso Rate > 0
        orelse error(
            badarg,
            [Algo, Key, Opts],
            {error_info, #{
                cause => #{3 => "capacity should be a positive number"}
            }}
        ),

    is_integer(Capacity) andalso Capacity > 0
        orelse error(
            badarg,
            [Algo, Key, Opts],
            {error_info, #{
                cause => #{3 => "capacity should be a positive integer"}
            }}
        ),

    T = #?MODULE{
        key = Key,
        algorithm = token_bucket,
        rate = Rate,
        capacity = Capacity,
        atomics = Ref,
        buckets = 0,
        window_ms = 0
    },

    store(T);

new(Algo, Key, Opts) ->
    %% Only support token_bucket for the time being
    error(
        badarg,
        [Algo, Key, Opts],
        {error_info, #{cause => #{1 => "algorithm not supported"}}}
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
            ResetsIn = case Tokens >= Increment of
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

    ResetsIn = case Tokens >= 1 of
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



init(_) ->
    ?TAB = ets:new(?TAB, [
        named_table,
        ordered_set,
        {keypos, 2},
        public, {read_concurrency, true}, {write_concurrency, true}
    ]),
    State = #state{purge_interval = timer:minutes(1)},
    ok = schedule_purge(State),
    {ok, State}.


handle_call(_, _, State) ->
    {reply, ok, State}.


handle_cast(_Event, State) ->
    {noreply, State}.

handle_info(purge, State) ->
    ok = purge(),
    ok = schedule_purge(State),
    {noreply, State};

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
%% GEN_SERVER PRIVATE HELPERS
%% =============================================================================




schedule_purge(#state{purge_interval = PurgeInterval}) ->
    _TRef = erlang:send_after(PurgeInterval, self(), purge),
    ok.


purge() ->
    Count = ets:foldl(
        fun(#?MODULE{atomics = Ref} = T, Acc) ->
            try
                _ = atomics:get(Ref, 1),
                Acc
            catch
                error:badarg ->
                    %% Atomics was garbage collected so we purge from ets
                    ets:delete(?MODULE, T#?MODULE.key),
                    Acc + 1
            end
        end,
        0,
        ?TAB
    ),

    case Count > 0 of
        true ->
            ?LOG_INFO(#{
                message => "Purged inactive rate limiters",
                count => Count
            });

        false ->
            ok
    end.




%% =============================================================================
%% EUNIT
%% =============================================================================


-ifdef(TEST).

token_bucket_test() ->
    {ok, _Pid} = start_link(),
    %% 1 req/sec without bursting
    {ok, T} = new(token_bucket, foo, #{capacity => 1, rate => 1 / 1000}),
    ?assertMatch({true, #{}}, allow(T, 1)),
    ?assertMatch({false, #{}}, allow(T, 1)),
    ?assertMatch({true, #{}}, wait(T, 1)),
    {false, Info} = allow(T, 1),
    ?assertEqual(Info, peek(T)).






-endif.



