# perf-cluster + k6 smoke — first Bondy router perf numbers (M2 + M7-min)

A minimal path to the **first WAMP-router performance numbers**: a 3-node Bondy
cluster on Fly that accepts **anonymous** WAMP-over-WebSocket clients, plus a k6
pub/sub load that measures broker delivery latency. Deliberately small first
(tens of VUs) to validate the pipeline before the 3000-sessions/node target.

## Pieces

| Path | Role |
|---|---|
| `config/security_config.json` | one realm `com.leapsight.perf`, anonymous → full pub/sub/rpc grants |
| `config/bondy.conf.template` | M0 profile + `security.config_file` |
| `fly.toml` | app `bondy-perf-1`, `/ws` publicly exposed on 18080 (Fly edge TLS → cleartext) |
| `run-perf.sh` | deploy → scale → health-gate → print WS URL + k6 command |
| `../k6/lib/wamp.js` | minimal WAMP v2 JSON client (HELLO/SUB/PUB/CALL) |
| `../k6/pubsub_smoke.js` | each VU subscribes + self-publishes (`exclude_me:false`); measures delivery latency |

Reuses the **proven M0 image** (`../m0-fly-spike/Dockerfile`).

## Prerequisites (yours)

1. `fly auth login` (once).
2. **k6** on PATH — `brew install k6` — to run the smoke locally.

## Run

```sh
# from the repo root
FLY_ORG=<org> just perf-deploy      # deploy 3 nodes, print the WS URL + k6 cmd
just perf-smoke                     # k6 pub/sub smoke (default 50 VUs)
just perf-smoke 200                 # more VUs
just perf-logs                      # tail cluster logs
just perf-down                      # stop machines (halt cost)
just perf-destroy                   # delete the app
```

## What the smoke measures

- `wamp_delivery_latency_ms` — publish → own-event round trip through the broker (p50/p95/p99)
- `wamp_welcome_latency_ms` / `wamp_subscribe_latency_ms` — handshake + subscribe
- `wamp_session_ok` rate, `wamp_events_received`, `wamp_ws_connect_errors`

## Scope / not-yet

First-numbers only. Self-delivery (`exclude_me:false`) exercises the local
broker path, not cross-node routing — that comes with separate pub/sub roles.
No node pinning, no distributed LGs, no cryptosign. Those are M7 proper.
For a real run, bump `fly.toml` `[[vm]]` to performance-2x/8GB.
