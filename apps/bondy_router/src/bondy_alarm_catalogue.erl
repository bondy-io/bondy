%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_alarm_catalogue).
-moduledoc """
The declared table of every alarm this build can raise.

An alarm id used to be whatever its producer invented, known only once it fired
in production. This module is the enumeration: `bondy_alarm_handler` describes
the *shape* of an alarm, this describes the *set* of them.

## What an entry is for

Each entry declares what cannot be inferred from the raise site: how an operator
should react (`severity`), who is expected to act (`class`), whether the
condition should take the node out of the load balancer (`affects_ready`), and
which configuration governs it (`config_keys`). `config_keys` answers the most
common complaint about alarm systems that have no catalogue — you are told
`high_cpu_usage` and not which threshold tripped or where to change it.

## The coverage contract

`bondy_alarm_catalogue_test` reads the `debug_info` of every module in the
Bondy apps, finds every `set_alarm` / `clear_alarm` call, and asserts the id it
raises matches an entry here. A tenth producer that invents a new id fails that
test. It is the enumeration being *verified* rather than asserted, and it is
what keeps this module from rotting into documentation.

Two call sites build their id in a variable the reader cannot resolve; they are
named explicitly in that test rather than skipped silently, so a new
unresolvable site also fails.

## Matching

An `id_pattern` is either an atom (matching that id exactly) or a tuple of the
same arity as the id, where `'_'` matches any element. Producers key
per-service, per-relay and per-instance alarms as
`{Head, Discriminator}` — see `bondy_http_connector_http_pool:552` — so the
pattern is what makes those one catalogue entry rather than one per service.

## `detail_keys` is a checked contract

`detail_keys` names the keys an alarm carries under `details` — it is what an
agent parsing `bondy.alarm.list` reads to know which fields to expect.
`bondy_alarm_catalogue_test:declared_detail_keys_are_delivered` reads each
producer's raise site from its compiled abstract code and fails if a declared
key is not among the literal keys of the `details` map passed there. It checks
that direction only: a producer may carry more than it declares.

**The check is real but THIN: three of the nine entries declare keys and six
declare `[]`**, so it runs over a third of the table. Some of the six are
correct as they stand — `bondy_mcp_name_collision` carries its realm and name
in the ID, and says so at its entry — but the rest are producers that pass no
`details` at all, and an empty declaration cannot fail. Read "checked" as
"cannot lie about what it declares", not as "every alarm is described". The
population grows only when a producer starts carrying structured details.

## The runbook join

`observe_with` (what may be looked at) and `tasks` (what may be done) are the
runbook: an agent holding an alarm does not guess what to do about it. Both are
CHECKED by `bondy_alarm_catalogue_test`, and the checks are what make them
worth reading:

- a `task` must be a `bondy_task_catalogue` entry — so it names a real,
  implemented procedure carrying an `impact` grade;
- a `procedure` reference must be live (not one of the seven that reply
  `no_such_procedure`) and must **NOT** be a task. That last one is the safety
  half: `observe_with` is what may be looked at without sanction, so a mutating
  procedure appearing there would let an agent act while believing it was only
  looking;
- a `metric` reference must be a name something declares through
  `bondy_metrics:declare/1`. Metrics exported directly by a Prometheus
  collector (`bondy_alarms`, `bondy_alarm_active`, `bondy_node_ready`) do not
  go through `declare/1` and so cannot be named here — a stated limit.

The field is `observe_with` and NOT `signals`, which it was called first.
`signal` is a first-class Bondy Lang module member (`bondy_ast:signal_def/2`)
meaning a push-based stream, and the router already has
`m:bondy_signal_handler` for OS signals — three concepts, one word, and the
Bondy Lang one points the opposite way: these references are pulled, not
pushed. `bondy_task_catalogue` already used `observe_with` for the same kind of
thing, so the rename removes a synonym rather than adding a word.

**Six of the nine entries have no task at all, and that is the finding rather
than an omission.** Only the mail relay and the MCP collision have a sanctioned
remediation in the WAMP API; nothing in `bondy.*` fixes a stalled drain, an
unopenable main DB, an unwritable retirement set, an oversized sync item or a
retention ceiling. An empty list is the answer an agent needs — it stops
looking rather than improvising.

The join KEY is `bondy_alarm_api`'s `catalogue_id`, stamped on every rendered
alarm: an alarm's id is concrete and an entry's is a pattern, so without it a
consumer would have to re-implement `matches/2`.

## Not here yet

A condition language for `success_when` — `observe_with` on a task says where
to look, not what to expect. `severity` and `class` are declared here and joined onto the alarm
at RAISE time by `bondy_alarm_handler` — a producer need not, and mostly does
not, pass them.
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-export([list/0]).
-export([lookup/1]).

-type severity() :: bondy_alarm_handler:severity().
-type class() :: bondy_alarm_handler:class().

%% Somewhere to look, named so the reference can be CHECKED: a `procedure` ref
%% is a read-only `bondy.*` procedure, a `metric` ref a name declared through
%% `bondy_metrics:declare/1`. Shared with `bondy_task_catalogue`, whose
%% `observe_with` carries the same shape.
-type observe_ref() ::
    #{kind := procedure, ref := uri()}
    | #{kind := metric, ref := atom()}.

-type entry() :: #{
    id_pattern := atom() | tuple(),
    severity := severity(),
    class := class(),
    affects_ready := boolean(),
    summary := binary(),
    detail_keys := [atom()],
    config_keys := [binary()],
    observe_with := [observe_ref()],
    tasks := [uri()],
    %% Present only when the condition affects readiness through a mechanism
    %% OTHER than this alarm. See `bondy_db_main_unavailable`.
    readiness_via => binary()
}.

-export_type([entry/0, observe_ref/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Every declared alarm, in id order.

`affects_ready` is `false` on every entry, and that is a finding rather than an
oversight: of the nine conditions below, only `bondy_db_main_unavailable` stops
the node serving, and its readiness signal deliberately does not run through the
alarm — see that entry's `readiness_via`.

**So the readiness mechanism has no live producer, and its path is exercised
only by tests.** `bondy_alarm_handler` publishes the blocking flag into an
`atomics` cell that `bondy_app:is_ready/0` reads, and nothing in this build has
ever put a `true` in it outside `bondy_alarm_handler_test` and
`bondy_app_readiness_test`. The seam is kept because readiness is a per-alarm
judgement rather than a severity threshold (design D1) and this table is where
that judgement belongs — but the first entry to declare `true` is the one that
will find whatever is wrong with the path, and it should be landed expecting
that rather than trusting the mechanism because it is written down.
""".
-spec list() -> [entry()].

list() ->
    [
        %% `bondy_http_connector_http_pool:552`. Severe — calls to this
        %% service fail — but NOT a reason to drain the node: the other
        %% services and the whole WAMP data plane are unaffected, and if the
        %% upstream is down for everyone, draining every node takes the
        %% cluster out of rotation for a fault that is not Bondy's.
        #{
            id_pattern => {http_connector_service_down, '_'},
            severity => major,
            class => integration,
            affects_ready => false,
            summary =>
                <<"An HTTP connector service is failing its liveness probe">>,
            detail_keys => [service, endpoint, reason],
            observe_with => [
                #{kind => metric, ref => bondy_http_connector_pool_up},
                #{
                    kind => metric,
                    ref => bondy_http_connector_liveness_probes_total
                }
            ],
            %% Nothing here is remediable through the WAMP API: there are no
            %% `bondy.http_connector.*` procedures. The empty list is the
            %% honest answer and it is the one an agent needs — it stops
            %% looking rather than improvising.
            tasks => [],
            config_keys => [
                <<"http_connector.services.$service.liveness.interval">>,
                <<
                    "http_connector.services.$service.liveness."
                    "failure_threshold"
                >>,
                <<
                    "http_connector.services.$service.liveness."
                    "success_threshold"
                >>
            ]
        },
        %% `bondy_mail_relay:274`. Same reasoning as the connector: outbound
        %% mail is degraded, routing is not.
        #{
            id_pattern => {mail_relay_down, '_'},
            severity => major,
            class => integration,
            affects_ready => false,
            summary => <<"An outbound mail relay is failing its health check">>,
            detail_keys => [relay, consecutive_failures],
            observe_with => [
                #{kind => procedure, ref => <<"bondy.mail.status.get">>},
                #{kind => procedure, ref => <<"bondy.mail.relay.list">>},
                #{kind => metric, ref => bondy_mail_relay_up},
                #{kind => metric, ref => bondy_mail_failed_total}
            ],
            tasks => [<<"bondy.mail.test">>],
            config_keys => [
                <<"mail.relay.$name.health.failure_threshold">>,
                <<"mail.relay.$name.health.success_threshold">>
            ]
        },
        %% `bondy_mcp_gateway:553`. `class = realm` because the collision and
        %% its repair are both inside one realm's manifest; the realm and the
        %% colliding name are carried in the ID, which is why `detail_keys` is
        %% empty.
        %%
        %% `severity = major`, not `critical`: two MCP entries are hidden from
        %% one realm's manifest, which is a page-in-hours fault. The producer's
        %% moduledoc calls it "critical" in prose written before the D1
        %% vocabulary existed — that is description, not a classification.
        #{
            id_pattern => {bondy_mcp_name_collision, '_', '_'},
            severity => major,
            class => realm,
            affects_ready => false,
            summary =>
                <<
                    "Two MCP manifest entries in a realm resolve to the same "
                    "name; neither is exposed"
                >>,
            detail_keys => [],
            observe_with => [
                #{kind => procedure, ref => <<"bondy.mcp.overlay.list">>},
                #{kind => procedure, ref => <<"bondy.mcp.overlay.get">>}
            ],
            %% A collision is resolved by editing the overlay that caused it:
            %% rename the colliding entry and reload, or drop the document.
            tasks => [
                <<"bondy.mcp.overlay.load">>, <<"bondy.mcp.overlay.delete">>
            ],
            config_keys => []
        },
        %% `bondy_oplog_applier:2094`. Applied state is falling behind this
        %% node's own WAL. Not readiness-affecting: the node still serves, it
        %% serves stale durable reads — and a stall whose cause is shared
        %% would otherwise drain every node at once.
        #{
            id_pattern => {bondy_oplog_drain_stalled, '_'},
            severity => major,
            class => node,
            affects_ready => false,
            summary =>
                <<
                    "A WAL drain is processing frames without committing a "
                    "new position"
                >>,
            detail_keys => [instance_id, stalled_for_ms, committed_position],
            %% `committed_position`, in the alarm's own details, is the handle
            %% here: no metric or procedure reports drain progress.
            observe_with => [],
            tasks => [],
            config_keys => [<<"db.drain.stall_alarm">>]
        },
        %% `bondy_namespace_catalog:777`. The one condition here that stops
        %% the node serving — every durable table raises `*_not_provisioned`.
        %%
        %% `affects_ready => false` is deliberate and is NOT a claim that the
        %% node stays in rotation. The readiness signal for this condition is
        %% `persistent_term`-backed and must survive an `alarm_handler` crash,
        %% which this alarm cannot: the watcher re-installs a crashed handler
        %% with `[]`, so `bondy_alarm_handler:init/1` starts empty. The rule
        %% that follows, for every future entry: a condition that must survive
        %% a handler crash is not published as an alarm.
        #{
            id_pattern => bondy_db_main_unavailable,
            severity => critical,
            class => node,
            affects_ready => false,
            readiness_via => <<"bondy_namespace_catalog:main_status/0">>,
            summary => <<"The durable `main` database could not be opened">>,
            detail_keys => [],
            observe_with => [],
            tasks => [],
            config_keys => [<<"platform_data_dir">>]
        },
        %% `bondy_oplog_origin_bans:634`. `class = cluster` because reaping
        %% needs EVERY member to hold the retirement, so one node's unwritable
        %% path stops reclamation cluster-wide.
        #{
            id_pattern => bondy_oplog_retirement_not_persistent,
            severity => major,
            class => cluster,
            affects_ready => false,
            summary =>
                <<
                    "The origin retirement set cannot be read or written; "
                    "frontier reaping is disabled cluster-wide"
                >>,
            detail_keys => [],
            observe_with => [],
            tasks => [],
            config_keys => [<<"db.origin_retirement.path">>]
        },
        %% `bondy_oplog_responder:535`. `class = cluster`: the affected data
        %% cannot converge on ANY peer until the frame cap is raised.
        #{
            id_pattern => bondy_oplog_sync_oversized_items,
            severity => major,
            class => cluster,
            affects_ready => false,
            summary =>
                <<
                    "Anti-entropy is skipping stored values larger than the "
                    "inter-node frame cap; they cannot converge"
                >>,
            detail_keys => [],
            %% Both are named in the alarm's own description, which is what
            %% made them worth declaring: the prose and the join must not
            %% drift apart.
            observe_with => [
                #{kind => metric, ref => bondy_oplog_sync_oversized_item_total},
                #{
                    kind => metric,
                    ref => bondy_oplog_sync_oversized_item_last_bytes
                }
            ],
            tasks => [],
            config_keys => [<<"cluster.max_message_size">>]
        },
        %% `bondy_retained_message_manager:raise/3`. A configured ceiling
        %% doing its job: publication continues, retention stops. `warning`
        %% is the whole point of D1's bottom level — this is an in-hours
        %% capacity conversation, not a page.
        %%
        %% Cleared by `bondy_retained_message_manager:reconcile_limit_alarms/0`
        %% on the eviction cycle, so it states the ceiling is being hit NOW and
        %% not merely that it was hit once since boot.
        #{
            %% Instance-scoped by realm. The ceilings are node-wide VALUES but
            %% the counters they are compared against are per realm
            %% (`bondy_retained_message_manager:get_counters_ref/1`), so the
            %% condition is per realm: one realm over its ceiling says nothing
            %% about another, and a node-wide id would let either realm's
            %% recovery clear the other's alarm. `class` follows the id — the
            %% tenant whose publications are being refused is named by
            %% `realm_uri`.
            %%
            %% Worst-case cardinality is therefore one alarm per realm rather
            %% than one per node. That is the true number of conditions, and it
            %% reaches `bondy_alarm_active`'s labels; a deployment with
            %% thousands of realms all over their ceiling has a capacity
            %% problem before it has a cardinality problem.
            id_pattern => {retained_messages_count_limit, '_'},
            severity => warning,
            class => realm,
            affects_ready => false,
            summary =>
                <<
                    "A realm's retained messages have reached the configured "
                    "count limit; further messages are not retained"
                >>,
            detail_keys => [limit],
            observe_with => [],
            tasks => [],
            config_keys => [<<"wamp.message_retention.max_messages">>]
        },
        #{
            id_pattern => {retained_messages_memory_limit, '_'},
            severity => warning,
            class => realm,
            affects_ready => false,
            summary =>
                <<
                    "A realm's retained messages have reached the configured "
                    "memory limit; further messages are not retained"
                >>,
            detail_keys => [limit],
            observe_with => [],
            tasks => [],
            config_keys => [<<"wamp.message_retention.max_memory">>]
        }
    ].

-doc """
The entry declaring `Id`, if any.

`Id` is a concrete alarm id, not a pattern: `lookup({mail_relay_down,
<<"smtp">>})` finds the `{mail_relay_down, '_'}` entry.
""".
-spec lookup(Id :: term()) -> {ok, entry()} | error.

lookup(Id) ->
    case [E || #{id_pattern := P} = E <- list(), matches(P, Id)] of
        [Entry | _] -> {ok, Entry};
        [] -> error
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Arity is part of the pattern: `{bondy_mcp_name_collision, '_', '_'}` must
%% not match a two-element id that happens to share the head.
matches(Pattern, Id) when is_tuple(Pattern), is_tuple(Id) ->
    tuple_size(Pattern) == tuple_size(Id) andalso
        matches_elements(tuple_to_list(Pattern), tuple_to_list(Id));
matches(Pattern, Id) when is_atom(Pattern) ->
    Pattern == Id;
matches(_, _) ->
    false.

%% @private
matches_elements(Ps, Is) ->
    lists:all(
        fun
            ({'_', _}) -> true;
            ({P, I}) -> P == I
        end,
        lists:zip(Ps, Is)
    ).
