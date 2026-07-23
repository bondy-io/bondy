%% =============================================================================
%% Tests for `bondy_metrics` — the counters/atomics-backed primitive.
%% Verifies first-touch allocation, idempotent re-use of the same ref,
%% per-label isolation, type safety, gauge set/read, and delete.
%% =============================================================================

-module(bondy_metrics_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    ok.

metrics_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun counter_increments/0,
        fun counter_default_delta_is_one/0,
        fun counter_with_explicit_delta/0,
        fun counter_label_isolation/0,
        fun gauge_writes_absolute_value/0,
        fun gauge_delta_adds/0,
        fun value_returns_undefined_for_unknown/0,
        fun type_clash_returns_error/0,
        fun with_name_returns_all_labels/0,
        fun delete_drops_the_metric/0,
        fun all_returns_every_metric/0,
        fun info_returns_metadata_without_reading_value/0,
        fun declare_stores_open_descriptor/0,
        fun declare_is_idempotent/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

counter_increments() ->
    Name = mk_name(),
    ok = bondy_metrics:counter(#{name => Name}),
    ok = bondy_metrics:counter(#{name => Name}),
    ok = bondy_metrics:counter(#{name => Name}),
    ?assertEqual(3, bondy_metrics:value(#{name => Name})),
    bondy_metrics:delete(#{name => Name}).

counter_default_delta_is_one() ->
    Name = mk_name(),
    ok = bondy_metrics:counter(#{name => Name}),
    ?assertEqual(1, bondy_metrics:value(#{name => Name})),
    bondy_metrics:delete(#{name => Name}).

counter_with_explicit_delta() ->
    Name = mk_name(),
    ok = bondy_metrics:counter(#{name => Name, delta => 5}),
    ok = bondy_metrics:counter(#{name => Name, delta => 7}),
    ?assertEqual(12, bondy_metrics:value(#{name => Name})),
    bondy_metrics:delete(#{name => Name}).

counter_label_isolation() ->
    Name = mk_name(),
    LA = #{namespace => a},
    LB = #{namespace => b},
    [
        bondy_metrics:counter(#{name => Name, label => LA})
     || _ <- lists:seq(1, 4)
    ],
    [
        bondy_metrics:counter(#{name => Name, label => LB})
     || _ <- lists:seq(1, 9)
    ],
    ?assertEqual(4, bondy_metrics:value(#{name => Name, label => LA})),
    ?assertEqual(9, bondy_metrics:value(#{name => Name, label => LB})),
    bondy_metrics:delete(#{name => Name, label => LA}),
    bondy_metrics:delete(#{name => Name, label => LB}).

declare_stores_open_descriptor() ->
    %% The descriptor is an open map: `help` is required, and any extra
    %% metadata (a future `unit`, here) is preserved verbatim in
    %% declared/0 without an API change — the extensibility contract.
    Name = mk_name(),
    ok = bondy_metrics:declare(#{
        name => Name, help => <<"H">>, unit => <<"milliseconds">>
    }),
    Declared = bondy_metrics:declared(),
    ?assertEqual(
        #{help => <<"H">>, unit => <<"milliseconds">>},
        maps:get(Name, Declared)
    ),
    %% `name` is the key, not part of the descriptor.
    ?assertNot(maps:is_key(name, maps:get(Name, Declared))).

declare_is_idempotent() ->
    Name = mk_name(),
    ok = bondy_metrics:declare(#{name => Name, help => <<"first">>}),
    ok = bondy_metrics:declare(#{name => Name, help => <<"second">>}),
    ?assertEqual(
        #{help => <<"second">>},
        maps:get(Name, bondy_metrics:declared())
    ).

gauge_writes_absolute_value() ->
    Name = mk_name(),
    ok = bondy_metrics:gauge(#{name => Name, value => 100}),
    ?assertEqual(100, bondy_metrics:value(#{name => Name})),
    %% Overwrite with a smaller value — gauges go down too.
    ok = bondy_metrics:gauge(#{name => Name, value => 42}),
    ?assertEqual(42, bondy_metrics:value(#{name => Name})),
    bondy_metrics:delete(#{name => Name}).

gauge_delta_adds() ->
    Name = mk_name(),
    ok = bondy_metrics:gauge(#{name => Name, delta => 1}),
    ok = bondy_metrics:gauge(#{name => Name, delta => 2}),
    ?assertEqual(3, bondy_metrics:value(#{name => Name})),
    ok = bondy_metrics:gauge(#{name => Name, delta => -3}),
    ?assertEqual(0, bondy_metrics:value(#{name => Name})),
    %% `value` still writes the absolute value on the same gauge.
    ok = bondy_metrics:gauge(#{name => Name, value => 7}),
    ?assertEqual(7, bondy_metrics:value(#{name => Name})),
    bondy_metrics:delete(#{name => Name}).

value_returns_undefined_for_unknown() ->
    Name = mk_name(),
    ?assertEqual(undefined, bondy_metrics:value(#{name => Name})).

type_clash_returns_error() ->
    Name = mk_name(),
    ok = bondy_metrics:counter(#{name => Name}),
    ?assertMatch(
        {error, {wrong_type, counter}},
        bondy_metrics:gauge(#{name => Name, value => 1})
    ),
    bondy_metrics:delete(#{name => Name}).

with_name_returns_all_labels() ->
    Name = mk_name(),
    ok = bondy_metrics:counter(#{name => Name, label => #{ns => a}, delta => 3}),
    ok = bondy_metrics:counter(#{name => Name, label => #{ns => b}, delta => 5}),
    Rows = bondy_metrics:with_name(Name),
    ?assertEqual(2, length(Rows)),
    Map = maps:from_list(Rows),
    ?assertEqual(3, maps:get(#{ns => a}, Map)),
    ?assertEqual(5, maps:get(#{ns => b}, Map)),
    bondy_metrics:delete(#{name => Name, label => #{ns => a}}),
    bondy_metrics:delete(#{name => Name, label => #{ns => b}}).

delete_drops_the_metric() ->
    Name = mk_name(),
    ok = bondy_metrics:counter(#{name => Name, delta => 9}),
    ?assertEqual(9, bondy_metrics:value(#{name => Name})),
    ok = bondy_metrics:delete(#{name => Name}),
    ?assertEqual(undefined, bondy_metrics:value(#{name => Name})).

all_returns_every_metric() ->
    Name1 = mk_name(),
    Name2 = mk_name(),
    ok = bondy_metrics:counter(#{name => Name1, delta => 2}),
    ok = bondy_metrics:gauge(#{name => Name2, value => 17}),
    All = bondy_metrics:all(),
    Matching = [
        R
     || R <- All,
        maps:get(name, R) =:= Name1 orelse
            maps:get(name, R) =:= Name2
    ],
    ?assertEqual(2, length(Matching)),
    %% Verify the shape: each entry has name, label, type, value.
    lists:foreach(
        fun(R) ->
            ?assert(maps:is_key(name, R)),
            ?assert(maps:is_key(label, R)),
            ?assert(maps:is_key(type, R)),
            ?assert(maps:is_key(value, R))
        end,
        Matching
    ),
    bondy_metrics:delete(#{name => Name1}),
    bondy_metrics:delete(#{name => Name2}).

info_returns_metadata_without_reading_value() ->
    Name = mk_name(),
    ok = bondy_metrics:counter(#{name => Name, delta => 5}),
    {ok, Entry} = bondy_metrics:info(#{name => Name}),
    ?assertEqual(counter, maps:get(type, Entry)),
    ?assert(maps:is_key(ref, Entry)),
    ?assertEqual(not_found, bondy_metrics:info(#{name => never_registered_x})),
    bondy_metrics:delete(#{name => Name}).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_name() ->
    list_to_atom(
        "metric_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).
