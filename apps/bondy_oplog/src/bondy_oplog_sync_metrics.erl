%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_sync_metrics).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Metrics for the AAE sync response path.

An AAE sync response is packed up to `bondy_oplog_config:sync_max_response_bytes/0`
— derived from Partisan's `max_message_size` — so a batch never trips the
transport frame cap (which would drop the peer with `emsgsize`). A single item
whose serialized size *alone* exceeds that ceiling cannot be framed to a peer at
all; it is skipped and reported here, so it never poisons the peer connection and
never replicates until `cluster.max_message_size` is raised above it.

Two families surface the condition, shared by both sync payloads — MST pages
(`get_pages`) and catalogue cells (bootstrap snapshot):

- `bondy_oplog_sync_oversized_item_total{kind}` — a counter of skipped items.
- `bondy_oplog_sync_oversized_item_last_bytes{kind}` — a gauge holding the size
  of the LAST skipped item, i.e. how high `max_message_size` must be raised (use
  `max`/`max_over_time` in the query for the worst case seen).

Alongside the metrics, the sync responder raises a first-class SASL alarm
(`{bondy_oplog_sync_oversized_items, node()}`) while skipping is ongoing — so
the condition shows in `alarm_handler:get_alarms/0`, the `bondy_alarms` gauge
and the cluster overview, not only on a rate graph. The responder drives the
alarm off the counter and clears it once skipping stops (see the responder's
`check_oversized_alarm`).

The metric families are node-wide with a low-cardinality `kind` label (`page` |
`cell`); the per-item detail (instance, key, size) rides in a rate-limited
WARNING log so metric cardinality stays bounded even with millions of instances
per node.
""").

-define(M_OVERSIZED_TOTAL, bondy_oplog_sync_oversized_item_total).
-define(M_OVERSIZED_LAST_BYTES, bondy_oplog_sync_oversized_item_last_bytes).

%% One WARNING per kind per this window; the counter/alarm carry the rest.
-define(LOG_THROTTLE_MS, 60000).
-define(LOG_THROTTLE_TAB, bondy_oplog_sync_oversized_log_throttle).

-type kind() :: page | cell.

-export([declare/0]).
-export([report_oversized/4]).
-export([oversized_total/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Declare the oversized-item exposition families. Called once at startup by the
sync responder (the node's sync-serving process); idempotent.
""".
-spec declare() -> ok.

declare() ->
    ok = bondy_metrics:declare(#{
        name => ?M_OVERSIZED_TOTAL,
        help => <<
            "AAE sync items (MST pages or catalogue cells) skipped because a "
            "single item's serialized size exceeds the sync response ceiling "
            "(Partisan max_message_size x headroom). A non-zero rate means "
            "stored values are too large to replicate — raise "
            "cluster.max_message_size."
        >>
    }),
    ok = bondy_metrics:declare(#{
        name => ?M_OVERSIZED_LAST_BYTES,
        help => <<
            "Serialized size, in bytes, of the most recently skipped oversized "
            "AAE sync item, by kind. Query with max/max_over_time for the worst "
            "case; indicates how high cluster.max_message_size must be raised."
        >>
    }),
    %% Touch both counters at zero so the family is present from boot — the
    %% dashboard shows a flat `0` instead of "no data" on a healthy node, and
    %% the operator can tell "no oversizing" apart from "metric missing".
    ok = bondy_metrics:counter(#{
        name => ?M_OVERSIZED_TOTAL, label => #{kind => page}, delta => 0
    }),
    ok = bondy_metrics:counter(#{
        name => ?M_OVERSIZED_TOTAL, label => #{kind => cell}, delta => 0
    }),
    _ = ensure_log_throttle_table(),
    ok.

-doc """
Flag a sync item whose inline values make it undeliverable within the transport
frame cap. Node-wide metrics drive operator alerting (a Grafana rule on the
total's rate is the alarm; the gauge shows how far over the cap we are); the
WARNING carries the per-item detail so metric cardinality stays bounded.
""".
-spec report_oversized(
    Kind :: kind(),
    Id :: term(),
    Size :: non_neg_integer(),
    MaxBytes :: pos_integer()
) -> ok.

report_oversized(Kind, Id, Size, MaxBytes) when
    Kind == page orelse Kind == cell
->
    Label = #{kind => Kind},
    ok = bondy_metrics:counter(#{name => ?M_OVERSIZED_TOTAL, label => Label}),
    ok = bondy_metrics:gauge(#{
        name => ?M_OVERSIZED_LAST_BYTES, value => Size, label => Label
    }),
    %% Metrics (and the responder's alarm) are the always-on signal; the log is
    %% rate-limited detail so a persistently oversized item does not spam it
    %% every sync round.
    maybe_log(Kind, Id, Size, MaxBytes),
    ok.

-doc """
The node-wide count of oversized AAE sync items skipped so far (all kinds). The
sync responder polls this to drive the oversized-items alarm.
""".
-spec oversized_total() -> non_neg_integer().

oversized_total() ->
    kind_total(page) + kind_total(cell).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
kind_total(Kind) ->
    case
        bondy_metrics:value(#{
            name => ?M_OVERSIZED_TOTAL, label => #{kind => Kind}
        })
    of
        N when is_integer(N) -> N;
        _ -> 0
    end.

%% @private
ensure_log_throttle_table() ->
    case ets:whereis(?LOG_THROTTLE_TAB) of
        undefined ->
            try
                ets:new(?LOG_THROTTLE_TAB, [
                    named_table, public, set, {read_concurrency, true}
                ])
            catch
                error:badarg -> ?LOG_THROTTLE_TAB
            end;
        _ ->
            ?LOG_THROTTLE_TAB
    end.

%% @private
%% Emit at most one WARNING per kind per `?LOG_THROTTLE_MS`. If the throttle
%% table is absent (e.g. under a unit test that never ran `declare/0`) we log
%% unthrottled rather than swallow the detail.
maybe_log(Kind, Id, Size, MaxBytes) ->
    case should_log(Kind) of
        true ->
            ?LOG_WARNING(#{
                description =>
                    "An AAE sync item exceeds the transport frame cap and "
                    "cannot be replicated; it is skipped. Raise "
                    "cluster.max_message_size above the item size for this "
                    "data to converge.",
                kind => Kind,
                item => Id,
                item_bytes => Size,
                sync_response_limit_bytes => MaxBytes,
                max_message_size =>
                    bondy_oplog_config:partisan_max_message_size()
            });
        false ->
            ok
    end.

%% @private
should_log(Kind) ->
    Now = erlang:monotonic_time(millisecond),
    try ets:lookup(?LOG_THROTTLE_TAB, Kind) of
        [{Kind, Last}] when Now - Last < ?LOG_THROTTLE_MS ->
            false;
        _ ->
            true = ets:insert(?LOG_THROTTLE_TAB, {Kind, Now}),
            true
    catch
        %% Table not created (no declare/0 yet) — log unthrottled.
        error:badarg -> true
    end.
