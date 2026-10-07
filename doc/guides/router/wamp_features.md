# WAMP Features

This guide lists the WAMP features Bondy implements as a router, explains how
a session obtains them, and states the contracts of the RPC features that
Bondy extends or restricts.

## Features are build capabilities

The features Bondy announces are a property of the build, not of the
configuration. They are defined in `apps/bondy_router/include/bondy.hrl`
(`?DEALER_FEATURES` and `?BROKER_FEATURES`), seated in the application
environment at boot, and advertised in every `WELCOME` under
`roles.dealer.features` and `roles.broker.features`. There is no `bondy.conf`
key for any of them.

What a session may use is negotiated per session from its `HELLO`. For each
client role (`caller`, `callee`, `publisher`, `subscriber`), Bondy compares
the features the client announced with its own table for that role:

- A feature that both sides set to `true` is enabled.
- A feature that either side sets to `false` is disabled.
- A feature the client omits takes Bondy's value, except for the strict
  opt-in features `progressive_call_results`, `progressive_calls` and
  `call_canceling`. A client that omits one of these is given `false`
  (`bondy_connect_conformance_SUITE:progressive_results_need_opt_in`;
  `bondy_connect_cancel_SUITE:kill_without_callee_support_skips`).

### Dealer

| Feature | Advertised |
| --- | --- |
| `progressive_call_results` | `true` |
| `progressive_calls` | `true` |
| `call_timeout` | `true` |
| `call_canceling` | `true` |
| `caller_identification` | `true` |
| `payload_passthru_mode` | `true` |
| `pattern_based_registration` | `true` |
| `shared_registration` | `true` |
| `session_meta_api` | `true` |
| `registration_meta_api` | `true` |
| `reflection` | `true` |
| `caller_auth_claims` (Bondy only) | `true` |
| `sharded_registration` | `false` |
| `call_reroute` | `false` |
| `call_trustlevels` | `false` |
| `registration_revocation` | `false` |
| `testament_meta_api` | `false` |

### Broker

| Feature | Advertised |
| --- | --- |
| `payload_passthru_mode` | `true` |
| `publisher_identification` | `true` |
| `subscriber_blackwhite_listing` | `true` |
| `publisher_exclusion` | `true` |
| `pattern_based_subscription` | `true` |
| `event_retention` | `true` |
| `session_meta_api` | `true` |
| `reflection` | `true` |
| `sharded_subscription` | `false` |
| `publication_trustlevels` | `false` |
| `event_history` | `false` |
| `subscription_revocation` | `false` |
| `subscription_meta_api` | `false` |
| `acknowledge_event_received` (non-standard) | `false` |
| `acknowledge_subscriber_received` (non-standard) | `false` |

`reflection` is served by the `wamp.reflection.procedure.*`,
`wamp.reflection.topic.*` and `wamp.reflection.error.*` procedures (`list` and
`describe` for each).

## Call deadline

`CALL.Options._deadline` is a Bondy extension option. Its value is a positive
integer number of milliseconds, counted from the moment Bondy starts handling
the `CALL`. Any other value is ignored, and the call has no deadline.

- **Routed calls.** The deadline caps the call: the call expires at the
  earlier of its timeout and its deadline, and the caller receives
  `wamp.error.timeout`. For a progressive call, where each result or input
  chunk restarts the timeout, the deadline bounds the whole stream
  (`bondy_rpc_promise_SUITE:refresh_capped_by_deadline`,
  `bondy_connect_rpc_SUITE:progressive_deadline_caps_stream`).
- **Bondy's own procedures.** A `bondy.*` procedure that waits reads the same
  option and can only shorten its own wait, never lengthen it.
  `bondy.cluster.leave` bounds its survey of the remaining members with it, and
  an unanswered member counts as unsafe. `bondy.alarm.list`, `bondy.alarm.get`
  and `bondy.alarm.history` bound their cluster reads with it; a progressive
  `bondy.alarm.history` stream that runs out of deadline ends with
  `wamp.error.timeout` (`bondy_alarm_api_SUITE:a_stream_stops_at_the_deadline`).

## Call cancellation

`CANCEL` supports the modes `skip`, `kill` and `killnowait`, including when the
callee is connected to another cluster node: the caller's node relays the
`CANCEL` to the callee's node, which interrupts the callee
(`bondy_connect_cluster_rpc_SUITE:progressive_remote_cancel_interrupts_callee`).

- `skip` answers the caller at once and sends no `INTERRUPT`; a late result
  is discarded.
- `kill` sends an `INTERRUPT`; the callee's response settles the call.
- `killnowait` answers the caller at once and sends an `INTERRUPT`; a late
  result is discarded.

When a caller's session ends, Bondy sends `INTERRUPT` with mode `killnowait`
for each call it still has in flight, so the callee stops work nobody will
consume. A callee on the same node is interrupted directly. For a callee on
another node, the cancellation is relayed to that node
(`bondy_connect_cluster_rpc_SUITE:progressive_remote_caller_death_interrupts_callee`).

Bondy sends `INTERRUPT` only to a callee that announced `call_canceling` in
its `HELLO`. For any other callee, `kill` and `killnowait` act as `skip`: the
caller is answered at once and the callee's late result is discarded, whether
the callee is on the caller's node or another
(`bondy_connect_cancel_SUITE:kill_without_callee_support_skips`,
`killnowait_without_callee_support_skips`;
`bondy_connect_cluster_rpc_SUITE:remote_kill_without_callee_support_skips`).

## Payload Passthru Mode and Bondy's procedures

A `CALL` that carries `Options.ppt_scheme` to a procedure that Bondy itself
implements (the `bondy.*` and `wamp.*` procedures, and internal callbacks) is
refused with `wamp.error.invalid_argument`, because Bondy cannot read a
passthru payload
(`bondy_internal_decode_SUITE:callback_procedure_refuses_payload_passthru`).

## URI validation

URI validation rejects every control character, `\x00` to `\x1F` and `\x7F`,
in both the `loose` and the `strict` rule
(`bondy_wamp_uri_SUITE:control_chars_rejected`).

A realm URI is validated with the same rule when the realm is created, so a
realm URI that contains NUL is refused. The storage layer also refuses a
NUL-bearing realm (`bondy_db_publish_list_test`, "a NUL-bearing realm is
refused").
