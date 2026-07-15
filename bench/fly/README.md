# bondy_mst — Linux bench substrate on Fly.io

Long-lived SSH-only Debian 12 VM for executing pack-store QA #14
(write-path floor) on Linux. See
`_design/latest/PACK_STORE_WRITE_PATH_FLOOR_BENCH_PLAN.md` for the
bench plan itself; this README is the operator runbook for the
Fly.io substrate.

> **Where lives what**:
> - `fly.toml` is at the **repo root** (not `bench/fly/`). flyctl
>   resolves the build context relative to the config's location,
>   and the Dockerfile's `COPY .` needs the project source visible.
> - `Dockerfile`, `entrypoint.sh`, and this README live under
>   `bench/fly/`.
> - The `just bench-fly-*` recipes drive everything from the repo
>   root so fly auto-discovers `fly.toml`.

## Image contents

- Base: `hexpm/elixir:1.18.4-erlang-28.0-debian-bookworm-*-slim`
  — community-maintained, OTP 28 + Elixir 1.18 baked in.
- `rebar3`, `just` pinned in the Dockerfile build args.
- `sysstat` (iostat, vmstat), `strace`, `procps` — companion data
  tools the bench plan §4 calls for.
- The bondy_mst repo at `/opt/bondy_mst`, pre-compiled under both
  rebar3 and mix so the first ssh session doesn't pay compile
  cost.

Re-pin OTP / Elixir by bumping the `FROM` tag in
`bench/fly/Dockerfile`, not via `[build.args]` — those versions
are part of the base image, not installed by us.

## TL;DR via just

The project's `justfile` ships a `bench-fly-*` recipe set that
wraps every fly command with the right `--config` and
`--dockerfile` flags (the build context has to be the repo root,
not `bench/fly/` — see the Dockerfile note below). The recipes
below are all run from the repo root.

```bash
# Install fly CLI: https://fly.io/docs/flyctl/install/
fly auth login

# One-time setup (creates app + volume + first deploy)
just bench-fly-init

# Per bench session — non-interactive, one-shot:
just bench-fly-bench-all                 # runs all 4 layers, tees output
just bench-fly-results                   # SFTPs /data/results/ to ./fly-bench-results/
just bench-fly-down                      # stop the VM to drop idle cost

# Per bench session — interactive (poke around, run one layer at a time):
just bench-fly-shell                     # ssh into the VM at /opt/bondy_mst
# (exit when done)
just bench-fly-down

# Re-deploy after Dockerfile or source edits:
just bench-fly-deploy

# Validate the Dockerfile locally without spending Fly cycles:
just bench-fly-build-local               # ~3-5 min, needs Docker Desktop
```

> **Apple Silicon caveat**: `bench-fly-build-local` runs the
> linux/amd64 build under QEMU emulation, which has a known bug
> that segfaults during Elixir hex-dep compilation
> (`mix compile`). The build reaches `rebar3 compile` + NIFs +
> `mix deps.get` cleanly — that proves the structure is right —
> then crashes at the Elixir compile step. **Fly's remote
> builder runs native amd64 hardware and is not affected.** If
> local validation fails past `mix deps.get`, just
> `just bench-fly-deploy` to validate the rest against Fly's
> builder.

Full recipe list: `just --list | grep bench-fly`.

## Raw fly commands (fallback)

If you'd rather drive fly directly, all commands run from the
**repo root** (where `fly.toml` lives):

```bash
fly auth login

# One-time setup.
fly apps create bondy-mst-bench --org leapsight
fly volumes create bench_data --size 10 --region lhr --app bondy-mst-bench

# Build + deploy (remote build via fly's builder VM).
fly deploy --remote-only

# Per session.
fly machine start
fly ssh console
# inside the VM:
cd /opt/bondy_mst
just bench-one profile_syscalls    2>&1 | tee /data/results/layer1_$(date +%Y%m%d_%H%M).txt
just bench-one profile_pack_one_put 2>&1 | tee /data/results/layer2_$(date +%Y%m%d_%H%M).txt
just bench-one mst_pack_put         2>&1 | tee /data/results/layer3a_$(date +%Y%m%d_%H%M).txt
just bench-e2e 30                   2>&1 | tee /data/results/layer3b_$(date +%Y%m%d_%H%M).txt
exit

# Pull results, stop VM.
fly ssh sftp get -r /data/results ./fly-bench-results
fly machine stop
```

## Sanity check inside the VM

```bash
erl -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().' -noshell
elixir --version
just --version
```

Should print OTP 28, Elixir 1.18, just 1.36.

## Companion data (bench plan §4)

The §4 vmstat / iostat / strace collection runs alongside an
already-running layer-3 bench. Use two terminals:

```bash
# Terminal 1
just bench-fly-run mst_pack_put

# Terminal 2 (within ~5s of starting Terminal 1)
just bench-fly-companion 60        # 60-second sample window
```

## After the bench session

```bash
just bench-fly-results              # SFTPs /data/results/ locally
just bench-fly-down                 # stops the VM
```

Idle cost drops to volume-only (~$1.50/month for 10 GB). Next
`bench-fly-shell` / `bench-fly-run` / `bench-fly-bench-all`
auto-starts within ~5 s.

Once results are local, write `_RESULTS.md` per bench plan §5.

## Costs (as of plan-write, 2026-05-24)

| Item                          | Rate              | Per-month (24/7) | Per-bench session |
|-------------------------------|-------------------|------------------|-------------------|
| performance-2x dedicated CPU  | $0.043/hour       | ~$32             | ~$0.10 (2h)       |
| 10 GB volume                  | $0.15/GB/month    | $1.50            | n/a (standing)    |
| Egress                        | first 100 GB free | $0               | $0                |
| **Total** (idle most of time) |                   | **~$2/month**    | **+$0.10/run**    |

If you forget to stop the machine, worst case is ~$32/month — set
a calendar reminder or use `fly machine stop` immediately after
each session.

## Caveats

The bench-plan §10 appendix lists four caveats that should be
reflected in any results doc; the key ones for the substrate:

1. **Firecracker microVM**, not bare metal. Adds ~1-3% I/O
   overhead vs the host kernel. Doesn't change the OS-specific
   vs architectural verdict at the ~70× signal level, but the
   `_RESULTS.md` environment section must note the substrate.
2. **OTP 28** — if production ships on a different OTP minor,
   the bench numbers may be off by whatever `prim_file` driver
   changes happened between versions. Re-pin the `OTP_VERSION`
   build arg when production OTP is fixed.

## Tearing down

```bash
just bench-fly-results          # pull results first — volume goes too
just bench-fly-destroy          # confirms with a `type "destroy"` prompt
```

Or via raw fly: `fly apps destroy bondy-mst-bench`.

Volume data is **not recoverable** after `apps destroy`. The
`bench-fly-destroy` recipe wraps the call in a confirmation
prompt to make the mistake harder.
