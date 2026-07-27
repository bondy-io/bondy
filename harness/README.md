# harness/ — Bondy router test harness (implementation)

Implementation of the perf & correctness harness designed in
[`_design/test-harness/`](../_design/test-harness/) (docs `00`–`06`). The design
is the source of truth; this tree is where it gets built, milestone by milestone
(`06`). **Pinned target: git tag `develop-perf.1`** — re-baseline on cadence
(`05 R12`).

## Status

| Milestone | Dir | State |
|---|---|---|
| **M0** — Fly fault-injection capability spike (blocking) | [`m0-fly-spike/`](m0-fly-spike/) | **built; awaiting a run** (needs `fly auth login`) |
| M1 — walking skeleton (local Docker) | — | not started |
| M2 — WAMP client libs (`bondy_load_client`, k6) | — | not started |
| M3 — `chaosd` + chaos-agent (Erlang) | — | not started |
| M4 — correctness tier P1–P5 (`jepsen.bondy`) | — | not started |
| M5 — RIB & retry tier P6/P7 (CT/PropEr) | — | not started |
| M6–M9 — Fly cluster, k6 scale, scale-under-fault, matrix | — | not started |

Planned layout (from `02`): `chaosd/`, `chaos_agent/`, `bondy_load_client/`,
`jepsen.bondy/`, `k6/`. Only `m0-fly-spike/` exists so far — the walking-skeleton
discipline (`06`) builds one thin, demoable slice at a time.

## Start here

`m0-fly-spike/README.md` — M0 is blocking; every downstream milestone that uses a
network or clock fault gates on M0's `FLY_FAULT_CAPABILITY.md`.
