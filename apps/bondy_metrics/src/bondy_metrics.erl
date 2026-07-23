%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_metrics).

-behaviour(gen_server).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Counter / gauge primitive backed by the BIF `counters` and `atomics`
modules.

Inspired by [`shortishly/metrics`](https://github.com/shortishly/metrics);
implements the small subset we need with the same single-map API. The
hot path (increment, set, read) is wait-free: a single ETS read to
locate the counter reference, then a `counters:add/3` or
`counters:put/3` call against the BIF-backed array. There is no ETS
write contention on counter mutation — the reference is allocated once
on first-touch and never moves.

## Storage

| Layer | Concern |
|---|---|
| ETS `bondy_metrics_tab` | `{ {Name, Label} => #{type, ref} }` — first-touch registry |
| ETS `bondy_metrics_declared_tab` | `{ Name => descriptor() }` — exposition declaration registry (`declare/1`) |
| `counters:new(Slots, [write_concurrency])` | per-metric atomic array (1 slot for counter/gauge, `2 + num_buckets` for histogram) |

Allocating a counter races safely: the loser of an `insert_new` race
re-reads and uses the winner's reference, dropping the unused
`counters` array on the floor (it is small and unrooted; the GC reaps
it).

## Types

- **counter** — monotonically increasing; `counter/1` accepts an
  optional `delta` (default `1`) and adds it.
- **gauge** — arbitrary up/down value; `gauge/1` accepts a `value`
  (absolute, written via `counters:put/3`) or a `delta` (added via
  `counters:add/3`, for occupancy-style gauges whose writers only see
  increments and decrements).
- **histogram** — a wait-free, fixed-bucket log-linear histogram for
  observing a stream of non-negative values (latencies, sizes).
  `histogram/1` records one observation: a single `counters:add` to
  each of the count slot, the sum slot, and the value's bucket. The
  bucket layout (`hist_bucket_index/1` …) keeps `?HIST_SUB_BITS`
  significant bits per octave, so percentiles recovered from the
  buckets (`histogram_stats/1`) carry a bounded relative error.
  `histogram_snapshot/1` returns the cumulative `#{count, sum,
  buckets}`; `histogram_delta/2` subtracts two snapshots for
  per-interval reporting.

Type is fixed at first-touch: re-using a name across types returns
`{error, {wrong_type, _}}`. `value/1` on a histogram returns its
observation `count` (slot 1).

## Labels

Optional `label` map for the second dimension of the metric key. Empty
label (default) is used when the metric is not partitioned. Two metrics
with the same `name` but different labels are independent counters and
the storage cost scales with the cross-product of distinct labels.

## Read APIs

- `value/1` — one (Name, Label) pair.
- `with_name/1` — every metric matching a name (across all labels);
  cheap because the registry walks one match-spec.
- `all/0` — every metric on the node; intended for exposition.

## Application lifecycle

A gen_server owns the registry table. The hot-path primitives are
public-table operations so they bypass the gen_server entirely. The
gen_server handles `delete/1` (which both removes the row and drops
the reference) and any future management API.

A restart wipes the table; on first-touch every counter is re-allocated
from zero. Counters are gauge-style observations of running totals, not
durable accounting — if a consumer needs survival across restart they
need a separate persistence layer.
""").

-define(SERVER, ?MODULE).
-define(TAB, bondy_metrics_tab).
%% Registry of declared exposition families, one `{name(), descriptor()}`
%% row each.
-define(DECLARED_TAB, bondy_metrics_declared_tab).
-define(POS, 1).

%% Histogram bucket layout. ?HIST_SUB_BITS significant bits below the
%% leading set bit → 2^?HIST_SUB_BITS linearly-spaced sub-buckets per
%% octave (≈6% max relative error). Values are clamped to ?HIST_MAX_VALUE
%% so the bucket count is fixed and small. Slot 1 is the observation
%% count, slot 2 the running sum, and bucket `I` is slot `3 + I`.
-define(HIST_SUB_BITS, 4).
-define(HIST_SUB_COUNT, (1 bsl ?HIST_SUB_BITS)).
-define(HIST_MAX_BITS, 30).
-define(HIST_MAX_VALUE, ((1 bsl ?HIST_MAX_BITS) - 1)).
-define(HIST_COUNT_POS, 1).
-define(HIST_SUM_POS, 2).
%% bucket I → counters slot ?HIST_BUCKET_BASE + I (= 3 + I)
-define(HIST_BUCKET_BASE, 3).

-record(state, {}).

-type name() :: atom().
-type label() :: map().
-type type() :: counter | gauge | histogram.
-type spec() :: #{
    name := name(),
    label => label(),
    delta => integer(),
    value => integer()
}.
-type declaration() :: #{name := name(), help := binary(), _ => _}.
%% Everything except `name`, keyed by name in `declared/0`. Open map so
%% future metadata (e.g. `unit`) is a non-breaking addition.
-type descriptor() :: #{help := binary(), _ => _}.
-type entry() :: #{type := type(), ref := counters:counters_ref()}.
-type histogram() :: #{
    count := non_neg_integer(),
    sum := non_neg_integer(),
    buckets := [{non_neg_integer(), non_neg_integer()}]
}.

-export_type([name/0, label/0, type/0, spec/0, histogram/0]).
-export_type([declaration/0, descriptor/0]).

-export([child_spec/0]).
-export([start_link/0]).

%% Counter / gauge / histogram mutation
-export([counter/1]).
-export([gauge/1]).
-export([histogram/1]).

%% Exposition declaration registry
-export([declare/1]).
-export([declared/0]).

%% Reads
-export([value/1]).
-export([with_name/1]).
-export([family/1]).
-export([all/0]).
-export([info/1]).
-export([histogram_snapshot/1]).

%% Histogram helpers (pure; computed from a snapshot)
-export([histogram_delta/2]).
-export([histogram_stats/1]).
-export([hist_num_buckets/0]).
-export([hist_bucket_index/1]).
-export([hist_bucket_low/1]).
-export([hist_bucket_high/1]).
-export([hist_percentile/3]).

%% Management
-export([delete/1]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% =============================================================================
%% API
%% =============================================================================

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

?DOC("""
Add to a counter. Default `delta` is `1`. Allocates on first touch.

Returns `ok` on success or `{error, {wrong_type, _}}` if the name is
already in use by a metric of a different type.
""").
-spec counter(spec()) -> ok | {error, term()}.

counter(#{name := Name} = M) ->
    Label = maps:get(label, M, #{}),
    Delta = maps:get(delta, M, 1),
    operate(
        {Name, Label},
        counter,
        fun(Ref) -> counters:add(Ref, ?POS, Delta) end
    ).

?DOC("""
Write to a gauge. Allocates on first touch.

With `value` writes the absolute value (`counters:put/3`); with `delta`
adds to the current value (`counters:add/3`) — the up/down form used by
occupancy gauges (e.g. open sessions) whose writers only know about
increments. `value` wins when both are given.

Returns `ok` on success or `{error, {wrong_type, _}}` if the name is
already in use by a metric of a different type.
""").
-spec gauge(spec()) -> ok | {error, term()}.

gauge(#{name := Name, value := V} = M) when is_integer(V) ->
    Label = maps:get(label, M, #{}),
    operate(
        {Name, Label},
        gauge,
        fun(Ref) -> counters:put(Ref, ?POS, V) end
    );
gauge(#{name := Name, delta := D} = M) when is_integer(D) ->
    Label = maps:get(label, M, #{}),
    operate(
        {Name, Label},
        gauge,
        fun(Ref) -> counters:add(Ref, ?POS, D) end
    ).

?DOC("""
Record one observation into a histogram. `value` is clamped to
non-negative. Wait-free: one `counters:add` to each of the count slot,
the sum slot, and the observation's bucket. Allocates the bucket array
on first touch.

Returns `ok` or `{error, {wrong_type, _}}` if the name is already a
counter/gauge.
""").
-spec histogram(spec()) -> ok | {error, term()}.

histogram(#{name := Name, value := V} = M) when is_integer(V) ->
    Label = maps:get(label, M, #{}),
    Obs = max(V, 0),
    I = hist_bucket_index(Obs),
    operate(
        {Name, Label},
        histogram,
        fun(Ref) ->
            counters:add(Ref, ?HIST_COUNT_POS, 1),
            counters:add(Ref, ?HIST_SUM_POS, Obs),
            counters:add(Ref, ?HIST_BUCKET_BASE + I, 1),
            ok
        end
    ).

?DOC("""
Declares a metric family for exposition, recording its help text.

This is the single source of truth for *which* `bondy_metrics` families
an exporter should expose and their descriptions. It lives here, next to
the primitive, so every layer declares a family **where it defines and
populates it** — a lower app (e.g. a storage layer) does not have to
reach up into an exporter that sits above it. Exporters read `declared/0`
and render only what is declared, so ad-hoc/internal counters never leak.

Takes a map spec — consistent with `counter/1`/`gauge/1`/`histogram/1`,
and open for extension: `name` and `help` are required, and any further
keys (e.g. a future `unit`) are stored verbatim in the family's
descriptor and surfaced by `declared/0` without an API change. The type
(counter/gauge/histogram) is deliberately NOT declared here — it is
fixed by first-touch on the metric itself (`counter/1` vs `gauge/1` vs
`histogram/1`), the single source of truth; declaring a type would let
it disagree with reality.

Idempotent; re-declaring replaces the descriptor. Wait-free — a single
`ets:insert` into a public table, off the gen_server; safe to call at
any rate (though the intent is setup code). Like the counters,
declarations do not survive a `bondy_metrics` restart — the registering
setup runs again on a full restart.
""").
-spec declare(Declaration :: declaration()) -> ok.

declare(#{name := Name, help := Help} = Spec) when
    is_atom(Name) andalso is_binary(Help)
->
    true = ets:insert(?DECLARED_TAB, {Name, maps:remove(name, Spec)}),
    ok.

?DOC("""
Returns the declared exposition families as `#{Name => descriptor()}`,
where each descriptor is an open map carrying at least `help` (plus any
extra metadata passed to `declare/1`).
""").
-spec declared() -> #{name() => descriptor()}.

declared() ->
    maps:from_list(ets:tab2list(?DECLARED_TAB)).

?DOC("""
Read the current value of one (Name, Label) pair. Returns `undefined`
when the metric does not exist.
""").
-spec value(#{name := name(), label => label()}) ->
    integer() | undefined.

value(#{name := Name} = M) ->
    Label = maps:get(label, M, #{}),
    case lookup_entry({Name, Label}) of
        {ok, #{ref := Ref}} -> counters:get(Ref, ?POS);
        not_found -> undefined
    end.

?DOC("""
Return `[{Label, Value}]` for every metric registered under `Name`.
""").
-spec with_name(name()) -> [{label(), integer()}].

with_name(Name) when is_atom(Name) ->
    MS = [{{{Name, '$1'}, '$2'}, [], [{{'$1', '$2'}}]}],
    [{L, read(Entry)} || {L, Entry} <- ets:select(?TAB, MS)].

?DOC("""
Return every metric registered under `Name` in exposition form: one
`#{label, type, value}` row per label combination. For counters and
gauges `value` is the integer reading; for histograms it is the full
cumulative snapshot (`histogram()`), so exposition layers can render
buckets without a second lookup per row.
""").
-spec family(name()) ->
    [
        #{
            label := label(),
            type := type(),
            value := integer() | histogram()
        }
    ].

family(Name) when is_atom(Name) ->
    MS = [{{{Name, '$1'}, '$2'}, [], [{{'$1', '$2'}}]}],
    [family_row(L, Entry) || {L, Entry} <- ets:select(?TAB, MS)].

?DOC("""
Return every metric on the node, intended for exposition. Each row is
`#{name, label, type, value}`.
""").
-spec all() ->
    [
        #{
            name := name(),
            label := label(),
            type := type(),
            value := integer()
        }
    ].

all() ->
    [
        #{name => N, label => L, type => T, value => counters:get(R, ?POS)}
     || {{N, L}, #{type := T, ref := R}} <- ets:tab2list(?TAB)
    ].

?DOC("""
Metadata for one metric without reading the value. Useful when callers
want to inspect type without paying for the counters read.
""").
-spec info(#{name := name(), label => label()}) ->
    {ok, entry()} | not_found.

info(#{name := Name} = M) ->
    lookup_entry({Name, maps:get(label, M, #{})}).

?DOC("""
Cumulative snapshot of a histogram: `#{count, sum, buckets}` where
`buckets` is the ascending `[{BucketIndex, Count}]` of occupied buckets.
Returns `not_found` when the metric does not exist, or
`{error, {wrong_type, _}}` when it is not a histogram.
""").
-spec histogram_snapshot(#{name := name(), label => label()}) ->
    {ok, histogram()} | not_found | {error, term()}.

histogram_snapshot(#{name := Name} = M) ->
    Label = maps:get(label, M, #{}),
    case lookup_entry({Name, Label}) of
        {ok, #{type := histogram, ref := Ref}} ->
            {ok, #{
                count => counters:get(Ref, ?HIST_COUNT_POS),
                sum => counters:get(Ref, ?HIST_SUM_POS),
                buckets => read_hist_buckets(Ref, hist_num_buckets() - 1, [])
            }};
        {ok, #{type := Other}} ->
            {error, {wrong_type, Other}};
        not_found ->
            not_found
    end.

?DOC("""
Per-interval delta `Cur - Prev` of two histogram snapshots. Both must
come from the same (cumulative) histogram; bucket counts only grow, so
the delta is non-negative. Used by periodic emitters to report the last
window rather than all-time totals.
""").
-spec histogram_delta(histogram(), histogram()) -> histogram().

histogram_delta(
    #{count := C1, sum := S1, buckets := B1},
    #{count := C0, sum := S0, buckets := B0}
) ->
    Prev = maps:from_list(B0),
    Delta = lists:filtermap(
        fun({I, C}) ->
            case C - maps:get(I, Prev, 0) of
                D when D > 0 -> {true, {I, D}};
                _ -> false
            end
        end,
        B1
    ),
    #{count => C1 - C0, sum => S1 - S0, buckets => Delta}.

?DOC("""
Summary statistics over a histogram snapshot (or delta):
`#{count, mean, p50, p95, p99, max}`. `mean` is exact (sum/count);
percentiles and `max` are nearest-rank estimates recovered from the
bucket bounds (conservative — rounded up to the bucket upper bound).
All-zero when `count` is 0.
""").
-spec histogram_stats(histogram()) -> #{atom() => non_neg_integer()}.

histogram_stats(#{count := 0}) ->
    #{count => 0, mean => 0, p50 => 0, p95 => 0, p99 => 0, max => 0};
histogram_stats(#{count := Count, sum := Sum, buckets := Buckets}) ->
    Max =
        case Buckets of
            [] -> 0;
            _ -> hist_bucket_high(element(1, lists:last(Buckets)))
        end,
    #{
        count => Count,
        mean => Sum div Count,
        p50 => hist_percentile(Buckets, Count, 0.50),
        p95 => hist_percentile(Buckets, Count, 0.95),
        p99 => hist_percentile(Buckets, Count, 0.99),
        max => Max
    }.

?DOC("""
The fixed number of histogram buckets. The bucket array reserves this
many slots (after the count and sum slots).
""").
-spec hist_num_buckets() -> pos_integer().

hist_num_buckets() ->
    hist_bucket_index(?HIST_MAX_VALUE) + 1.

?DOC("""
Map an observation to its bucket index in `0..hist_num_buckets()-1`.
Non-positive clamps to bucket `0`; values above `?HIST_MAX_VALUE` clamp
to the top bucket.
""").
-spec hist_bucket_index(integer()) -> non_neg_integer().

hist_bucket_index(V) when not is_integer(V) ->
    error({badarg, V});
hist_bucket_index(V) when V =< 0 ->
    0;
hist_bucket_index(V) when V < ?HIST_SUB_COUNT ->
    %% Linear region: buckets 0..(?HIST_SUB_COUNT-1) are exact.
    V;
hist_bucket_index(V0) ->
    V = min(V0, ?HIST_MAX_VALUE),
    K = msb(V),
    Shift = K - ?HIST_SUB_BITS,
    Sub = (V bsr Shift) - ?HIST_SUB_COUNT,
    (K - ?HIST_SUB_BITS) * ?HIST_SUB_COUNT + ?HIST_SUB_COUNT + Sub.

?DOC("""
Inclusive lower bound (smallest value) that maps to bucket `I`.
""").
-spec hist_bucket_low(non_neg_integer()) -> non_neg_integer().

hist_bucket_low(I) when is_integer(I), I >= 0, I < ?HIST_SUB_COUNT ->
    I;
hist_bucket_low(I) when is_integer(I) ->
    {Sub, Shift} = hist_decode(I),
    (?HIST_SUB_COUNT + Sub) bsl Shift.

?DOC("""
Inclusive upper bound (largest value) that maps to bucket `I`.
""").
-spec hist_bucket_high(non_neg_integer()) -> non_neg_integer().

hist_bucket_high(I) when is_integer(I), I >= 0, I < ?HIST_SUB_COUNT ->
    I;
hist_bucket_high(I) when is_integer(I) ->
    {Sub, Shift} = hist_decode(I),
    ((?HIST_SUB_COUNT + Sub + 1) bsl Shift) - 1.

?DOC("""
Nearest-rank percentile over an ascending `[{BucketIndex, Count}]` list
with `Total` the sum of counts. Returns the bucket upper bound at
percentile `P` (a float in `(0.0, 1.0]`), or `0` when `Total` is 0.
""").
-spec hist_percentile(
    [{non_neg_integer(), non_neg_integer()}], non_neg_integer(), float()
) -> non_neg_integer().

hist_percentile(_Sorted, 0, _P) ->
    0;
hist_percentile(Sorted, Total, P) when
    is_list(Sorted),
    is_integer(Total),
    Total > 0,
    is_float(P),
    P > 0.0,
    P =< 1.0
->
    Threshold = max(1, ceil(Total * P)),
    hist_percentile_scan(Sorted, Threshold, 0).

?DOC("""
Drop a metric. The row is removed from the registry and the underlying
counters reference is GC'd. Subsequent `value/1` on the same name
returns `undefined` until the next write re-allocates.
""").
-spec delete(#{name := name(), label => label()}) -> ok.

delete(#{name := Name} = M) ->
    Label = maps:get(label, M, #{}),
    gen_server:call(?SERVER, {delete, {Name, Label}}).

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([]) ->
    _ = ets:new(?TAB, [
        set,
        public,
        named_table,
        {keypos, 1},
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    %% Exposition declaration registry: `#{Name => Help}` as one row per
    %% family. A public table so `declare/1` is a wait-free `ets:insert`
    %% off the gen_server, like the counter hot path. Shares the counter
    %% table's lifecycle — a gen_server restart wipes both (see moduledoc).
    _ = ets:new(?DECLARED_TAB, [
        set,
        public,
        named_table,
        {keypos, 1},
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    {ok, #state{}}.

handle_call({delete, Key}, _From, State) ->
    true = ets:delete(?TAB, Key),
    {reply, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% Look up the entry; allocate on first-touch with insert_new. On race
%% (insert_new returns false) we re-lookup so the loser uses the winner's
%% reference and the abandoned counters array is GC'd.
operate(Key, Type, Op) ->
    case lookup_entry(Key) of
        {ok, #{type := Type, ref := Ref}} ->
            Op(Ref);
        {ok, #{type := Other}} ->
            {error, {wrong_type, Other}};
        not_found ->
            Ref0 = counters:new(slots_for(Type), [write_concurrency]),
            Entry = #{type => Type, ref => Ref0},
            case ets:insert_new(?TAB, {Key, Entry}) of
                true ->
                    Op(Ref0);
                false ->
                    %% lost the race; retry with the winner's ref
                    operate(Key, Type, Op)
            end
    end.

%% Slot count for the BIF-backed array. counter/gauge are a single atomic;
%% a histogram is count + sum + one slot per bucket.
slots_for(histogram) -> ?HIST_BUCKET_BASE - 1 + hist_num_buckets();
slots_for(_) -> 1.

lookup_entry(Key) ->
    case ets:lookup(?TAB, Key) of
        [{_, Entry}] -> {ok, Entry};
        [] -> not_found
    end.

%% @private
family_row(Label, #{type := histogram, ref := Ref}) ->
    Snapshot = #{
        count => counters:get(Ref, ?HIST_COUNT_POS),
        sum => counters:get(Ref, ?HIST_SUM_POS),
        buckets => read_hist_buckets(Ref, hist_num_buckets() - 1, [])
    },
    #{label => Label, type => histogram, value => Snapshot};
family_row(Label, #{type := Type, ref := Ref}) ->
    #{label => Label, type => Type, value => counters:get(Ref, ?POS)}.

read(#{ref := Ref}) -> counters:get(Ref, ?POS).

%% =============================================================================
%% PRIVATE: histogram bucket math
%% =============================================================================

%% Walk bucket slots high→low, prepending non-empty buckets so the result
%% is ascending by index.
read_hist_buckets(_Ref, I, Acc) when I < 0 ->
    Acc;
read_hist_buckets(Ref, I, Acc) ->
    case counters:get(Ref, ?HIST_BUCKET_BASE + I) of
        0 -> read_hist_buckets(Ref, I - 1, Acc);
        C -> read_hist_buckets(Ref, I - 1, [{I, C} | Acc])
    end.

%% Position (0-based) of the highest set bit of V (V >= 1).
msb(V) ->
    msb(V, 0).

msb(V, Acc) when V < 2 ->
    Acc;
msb(V, Acc) ->
    msb(V bsr 1, Acc + 1).

%% Recover {SubBucket, Shift} for a bucket index in the log region
%% (I >= ?HIST_SUB_COUNT). Inverse of `hist_bucket_index/1`'s log branch.
hist_decode(I) ->
    K = (I bsr ?HIST_SUB_BITS) + ?HIST_SUB_BITS - 1,
    Sub = I band (?HIST_SUB_COUNT - 1),
    {Sub, K - ?HIST_SUB_BITS}.

hist_percentile_scan([{I, C} | _], Threshold, Acc) when Acc + C >= Threshold ->
    hist_bucket_high(I);
hist_percentile_scan([{_, C} | Rest], Threshold, Acc) ->
    hist_percentile_scan(Rest, Threshold, Acc + C);
hist_percentile_scan([], _Threshold, _Acc) ->
    %% Unreachable when Threshold =< Total, but stay total.
    0.
