# Alarms

An alarm is a statement that a **condition is true now**. It is not an event,
not a log line, and not a notification. A condition either holds or it does
not, so an alarm is identified by its id, and raising one that is already
raised restates it rather than creating a second alarm. When the condition
stops holding, the alarm clears.

Clearing is the producer's job, and every producer observes its condition on
its own schedule — so an alarm clears one cycle after the condition goes away,
not at the instant it does. The two retention ceilings, for instance, are
re-evaluated by the retained-message eviction pass once a minute.

A log line records that something happened at a moment. An alarm answers "what
is wrong with this node right now", which is the question an operator asks
first and the one a counter cannot answer.

Bondy replaces OTP's default `alarm_handler` with `m:bondy_alarm_handler`.
Producers keep calling `alarm_handler:set_alarm({Id, Description})` — the raw
OTP spelling — and gain severity, class and a runbook from the catalogue
without changing a line.

## The catalogue

`m:bondy_alarm_catalogue` enumerates every condition this build can raise. Each
entry declares what the raise site cannot say about itself: `severity`,
`class`, whether the condition should take the node out of the load balancer
(`affects_ready`), the `config_keys` that govern it, the `observe_with`
references that show more, and the `tasks` sanctioned as a remediation.

The enumeration is verified rather than asserted. `bondy_alarm_catalogue_test`
reads the compiled bytecode of every module in the build, finds every
`set_alarm` and `clear_alarm` call site, and fails if the id raised there has
no entry. A producer that invents an id cannot ship. The same test checks that
every `task` names a catalogued task, that every `observe_with` procedure
exists and is *not* a task, and that every declared detail key is delivered at
the raise site.

That last check is narrower than it sounds: three of the nine entries declare
detail keys and six declare none, so it proves an entry cannot lie about what
it declares — not that every alarm carries structured detail.

### Severity names the response

Three levels rather than syslog's eight — `warning`, `major`, `critical` —
because severity should name what the operator does: ignore in hours, page in
hours, page now. Syslog's middle levels go unused in practice, and an unused
level becomes a place to park alarms nobody has classified. Three levels force
the classification when the entry is written, which is the cheapest moment to
argue about it.

### Readiness is a separate declaration

Severity does not decide whether a node leaves the load balancer.
`affects_ready` is its own per-alarm flag, because the two judgements differ:
an unreachable upstream connector is `major` and must not drain the node, since
the WAMP data plane is unaffected; a failed durable store is also `major` and
must.

Every current entry declares `affects_ready => false`. Of the nine conditions,
only `bondy_db_main_unavailable` stops the node serving, and its readiness
flag deliberately does not travel through the alarm — see
`bondy_namespace_catalog:main_status/0`. A condition that must survive a crash
of the handler reporting it is recorded outside the alarm state and only
mirrored as an alarm.

`m:bondy_app`'s `is_ready/0` is the single readiness oracle, and reads the
published flag rather than calling the handler: `/ready` is polled per node per
second, and a `gen_event:call` would serialise that poll behind whatever else
the shared `alarm_handler` manager is doing.

## The runbook join

- **`observe_with`** names read-only procedures and metrics. Looking is always
  sanctioned, so a mutating procedure may never appear there — enforced by
  test, because one that did would let an agent act while believing it was only
  looking.

  The field is not called `signals`. `signal` is a first-class Bondy Lang
  module member meaning a push-based stream, and `m:bondy_signal_handler`
  handles OS signals; these references are pulled, not pushed.
  `m:bondy_task_catalogue` already used `observe_with` for the same kind of
  thing, and both now carry the same `#{kind, ref}` shape.
- A **task** is a `bondy.*` procedure sanctioned as a remediation, and must be
  an entry in `m:bondy_task_catalogue`, which carries its `impact` and
  `blast_radius`.

Six of the nine entries have no task, and that is the answer rather than a gap.
Only the mail relay and the MCP name collision have a remediation in the WAMP
API; nothing in `bondy.*` fixes a stalled drain, an unopenable durable store,
an unwritable retirement set, an oversized sync item or a retention ceiling. An
empty list stops the search rather than inviting improvisation.

Every rendered alarm carries a `catalogue_id`, because an alarm's id is
concrete (`{mail_relay_down, <<"smtp1">>}`) while an entry's is a pattern
(`{mail_relay_down, '_'}`). Without the join key a consumer would have to
re-implement the matching.

## State is node-local

Alarm state is never replicated. One of the conditions Bondy raises is that the
durable store is unavailable, so a subsystem that needed that store in order to
report on it would have a hole exactly where it matters most.

`bondy.alarm.list` therefore asks every cluster member and partitions the
membership into `answered` and `silent`. An empty alarm list with a silent node
is not the same answer as an empty list with none, and a caller that conflates
them eventually pages on the wrong one. The local node's alarms are read
directly and never depend on the fan-out, so a total transport failure still
answers for the node in front of you.

## History

Each node keeps a bounded ring of its last 100 **transitions**, newest first. A
restatement that changes nothing is not a transition and does not enter the
ring, which is what stops a producer that restates per offending item from
evicting the whole ring and flooding the event topics.

The ring bounds transitions, not time: an alarm oscillating on a three-second
probe fills it in five minutes. It is a convenience for an operator who is
already looking, never the audit record — every transition is also logged, and
Prometheus holds the durable series.

`bondy.alarm.history` walks those rings NODE AT A TIME, taking the serving
node's first and reaching its peers only when that node does not fill the page.
The common case therefore contacts no peer at all. Each transition carries a
`seq`, strictly increasing within its own ring, which is what the page resumes
from — `at` is a millisecond timestamp and is neither unique nor monotonic. A
caller that asked for progressive results gets the whole walk streamed instead,
one result per page.

The walk names what it missed. Every page carries `not_reached`, the members it
ASKED for history and did not hear from, and the set accumulates across the
pages of one walk, so the last page states the whole truth about it. That is
the same distinction `list` draws with `silent`: a node that could not be asked
is not a node that answered "nothing". A node the walk has not yet reached
appears in neither the page nor the set — it is asked on a later page.

A page is bounded in TIME as well as in size. The whole page shares one budget
and the caller's `CALL.Options._deadline` caps it, so a walk over several
unreachable peers costs one budget rather than one each. A page that runs out
stops early and its cursor resumes at the nodes it did not get to; the first
node of a page is always contacted, so a page can be cut short but never
emptied. A stream that runs out of deadline settles with `wamp.error.timeout`
rather than a final result — a truncated stream reporting `has_more` false
would claim to be complete.

## Correlation

An alarm raised on a request path carries `onset_trace_id`, the W3C trace id of
the occurrence that raised the condition. It survives restatement exactly as
`raised_at` does; a later occurrence's trace is discarded.

Most alarms will not have one. Bondy has no ambient trace context — a trace
rides in a message's options — and seven of the nine producers are background
probes, appliers and sweepers with no request to inherit from. The field is
absent there rather than filled with a freshly minted id that would correlate
with nothing.

`m:bondy_alarm_handler`'s `content/1` deliberately ignores `onset_trace_id`
when deciding whether a restatement changed anything. Were it compared, a
producer restating with a fresh trace would make every restatement a
transition.

## Surfaces

| Surface | What it gives you |
| --- | --- |
| `bondy.alarm.{list,get,history,catalogue}` | The cluster view, one alarm by id, a page of the cluster's transition history, and the catalogue. See `m:bondy_alarm_api`. |
| `bondy.alarm.{raised,updated,cleared}` | The same alarm shape, pushed on transition, in the master realm, demand-gated. |
| `bondy.task.{catalogue,describe}` | What may be done, with impact and blast radius. See `m:bondy_task_api`. |
| Prometheus | `bondy_alarms`, `bondy_alarm_active` (one series per alarm id, discriminator included) and `bondy_node_ready`. |
| Logs | Every transition: `warning` for a raise or update, `notice` for a clear. |
| `/ready` | 503 while any raised alarm declares `affects_ready`. |
| MCP | The read procedures and topics, through the shipped `bondy_sre_read` overlay. |

## What this subsystem does not do

**No notification, escalation, on-call schedule or silencing.** Alertmanager
and PagerDuty do that better. Bondy owns detection, state and a queryable
surface, because only Bondy knows its own invariants — a dangling storage root,
anti-entropy divergence, a frontier stall, peer clock skew. The operator owns
what to do about being told.

**No alarm ever sheds load.** RabbitMQ blocks publishers on its memory alarm,
and Bondy's regulator could do the same with better machinery. It will not. The
subsystem observes and reports; acting on what it observes stays an operator
decision taken outside the router. RabbitMQ's blocking behaviour is as famous
for confusing operators as it is for saving nodes.

**No acknowledge, clear or silence in the API.** An alarm states a condition
that is true now; clearing one without fixing the condition would make the
surface lie.

**No alarm state in the replicated store**, for the reason above.

## See also

- `m:bondy_alarm_handler` — the record, the history ring, and the readiness flag.
- `m:bondy_alarm_catalogue` — the declared table and the coverage contract.
- `m:bondy_alarm_api` — the read API and the cluster fan-out.
- `m:bondy_task_catalogue` — the sanctioned remediations and their grades.
