# erts flag coverage audit — `schema/hidden/vm_args.schema`

Which erts flags Bondy exposes as `bondy.conf` keys, which it does not, and why.
Coverage went from **36 of 69** to **47 of 69** in this pass; the 22 remaining are
excluded for the stated reasons, not overlooked.

## Method

The authoritative inventory is the running emulator, not documentation: `erl
+XXXinvalid` prints the full usage for the linked erts (here OTP 28 / erts-16.4).
There are no man pages in `~/otp/28.5`. Each usage entry was matched against the
`vm_args.+<flag>` targets the schema declares, then every candidate was **tested
by writing it to a file and starting an emulator with `-args_file`** — the same
path cuttlefish delivers on — and, where a `system_info` key exists, read back to
confirm it took effect rather than being tolerated.

Test the args-file path, not the command line: `erl +hmaxk true` fails on the
command line through erlexec's argv handling while the identical line in an
args-file works and applies.

## Two live mappings were broken

Found by the same diff, and worse than any gap:

| Key | Emitted | Reality |
|---|---|---|
| `vm.io.poolset.percentage` | `+IOpp` | **unknown flag** — the flag is `+IOPp` |
| `vm.io.pool_thread.percentage` | `+IOtp` | parsed as `+IOt` with value `p` — the flag is `+IOPt` |

Both doc comments already said `+IOPp`/`+IOPt`, so the targets were a
transposition. Chain reproduced end to end: cuttlefish exit 0 → generated
`+IOtp 50` → `bad I/O poll threads number: p`, node will not start, message names
no config file. Fixed; the corrected flags boot and `+SP 75:50` on a 14-CPU host
yields `schedulers=10, schedulers_online=7` as expected.

A third defect in the same file: `vm.io.dirty_scheduler.stack_size` referenced
validator `"=<128"`, which was never defined. An undefined reference is silently
unenforced, so `= 99999` passed validation, emitted `+sssdio 99999`, and the
emulator refused to start. Validator now defined.

**Absence from the usage output is not proof a flag is fake.** Five mapped
targets — `+e`, `+sfwi`, `+MMsco`, `+MMscs`, `+Muatags` — do not appear in it and
all boot fine. That is why the two above were tested rather than "corrected" on
sight.

## Added in this pass (28 keys)

Every one carries `{commented, …}` and **no `{default, …}`**, so an unset key
emits no flag. Proven: generated `vm.generated.args` is byte-identical between the
previous schema and this one for `dev`, `bridge`, `node_1` and `edge_1`.

| Area | Keys → flags |
|---|---|
| Per-process heap | `vm.process.min_heap_size` `+hms`, `.min_bin_vheap_size` `+hmbs`, `.max_heap_size` `+hmax`, `.max_heap_size.kill` `+hmaxk`, `.max_heap_size.error_logger` `+hmaxel`, `.max_heap_size.include_shared_binaries` `+hmaxib`, `.message_queue_data` `+hmqd`, `.dictionary_size` `+hpds` |
| Atom table | `vm.atom.limit` `+t` |
| Scheduler wakeup | `vm.cpu.scheduler.wakeup_threshold` `+swt`, `vm.cpu.dirty_scheduler.wakeup_threshold` `+swtdcpu`, `vm.io.dirty_scheduler.wakeup_threshold` `+swtdio`, `vm.cpu.scheduler.wakeup_strategy` `+sws`, `.wake_cleanup_threshold` `+swct` |
| Scheduler sizing | `vm.cpu.scheduler.percentage` + `.online_percentage` → `+SP`, `vm.cpu.dirty_scheduler.percentage` + `.online_percentage` → `+SDPcpu` (each a mapping pair plus a translation, the shape the existing `+S` pair already uses) |
| Scheduler binding/stack | `vm.cpu.scheduler.bind_type` `+sbt`, `.stack_size` `+sss`, `vm.cpu.dirty_scheduler.stack_size` `+sssdcpu` |
| I/O | `vm.io.eager_check` `+secio` |
| Ports | `vm.port.parallelism` `+spp` |
| Locking | `vm.reader_groups.limit` `+rg` |
| Distribution | `vm.distribution.node_table_gc_delay` `+zdntgc` |
| Shutdown | `vm.halt_flush_timeout` `+zhft`, `vm.system_process.outstanding_request_limit` `+zosrl` |
| Formatting | `vm.printable_range` `+pc` |

`+sbt` carries a warning in its doc comment: support is platform-dependent and
cuttlefish cannot check it. Any value but `u` refuses to start the emulator where
no CPU topology is exposed — verified on macOS with `ns`, which fails with
`setting scheduler bind type 'ns' failed: not supported` and no mention of
bondy.conf.

## Not mapped, and why (22)

**Not expressible — the value is joined to the flag name.** cuttlefish emits
`flag value`, so a flag whose argument is concatenated cannot be produced:
`+B[c|d|i]`, `+fn[u|a|l]`, `+n[s|a|d]` (also deprecated), and `+dcg` — verified,
`+dcg 256` fails with `bad decentralized counter groups limit: --` while
`+dcg256` boots. `+ssrct` is the related case of a flag taking *no* value.
Expressing any of these needs a translation that returns the flag itself, which
the target-plus-value model does not support.

**Debug, profiling and development only** — not operator configuration, and
several change code generation: `+D`, `+Dibpl`, `+d`, `+r`, `+T`, `+v`, `+V`,
`+JDdump`, `+JPcover`, `+JPperf`, `+JPperfdirectory`, `+JMsingle`.

**Owned by the release, not by `bondy.conf`:** `+i` (boot module).

**Deliberately withheld:** `+R` (compatibility release number) — a downgrade
switch whose failure mode is subtle and version-specific.

**Complex value:** `+sct` takes a CPU-topology descriptor whose grammar is worth
a dedicated mapping only if someone needs it.

**Expressible but undocumented here:** `+pad` (default process async data). It
boots as `+pad false`, but no authoritative statement of what it controls was
available offline, so no mapping was written rather than shipping a doc comment
that could not be backed.

**A family, not a flag:** `+M<X> <Y>`, the `erts_alloc` surface. The usage output
shows only the generic form and does not enumerate it; the schema already maps
three members (`+MMsco`, `+MMscs`, `+Muatags`). Enumerating the rest needs the
`erts_alloc` documentation, which is not installed locally — the one genuinely
open item in this audit.

## Precedence, and the `vm.args` contradiction it caused

Measured, and the two directions disagree:

- **erts `+` flags: last occurrence wins.** `+A 2 +A 4` yields
  `thread_pool_size=4`; an inline `+A 64` followed by `-args_file` containing
  `+A 9` yields 9. So the generated file, pulled in by the **last** line of
  `vm.args`, beats anything written inline above it.
- **`-name`: first occurrence wins**, with `Multiple -name given to erl, using
  the first`. Which is why node name and cookie stay in `vm.args`.

Consequence: any mapping carrying `{default, …}` silently overrode the same flag
written inline in `vm.args`. `config/{dev,bridge,prod_named}/vm.args` each
declared `+A 64` and `+P 2000000`, and none of them applied — every release ran
on the schema's `+A 1` and `+P 2097152`.

Resolved by asking, per flag, whether the schema default earns its keep:

- `vm.async_thread.number` had `{default, 1}`, which merely restates the erts
  default (measured: `thread_pool_size=1` with no flags) while destroying the
  `vm.args` layer's ability to set it. Changed to `{commented, 1}` — no
  behaviour change for a deployment that sets nothing, and inline `+A 64` now
  takes effect.
- `vm.process.limit` and `vm.port.limit` keep their `{default, 2097152}`: that is
  double the erts default of 1048576, so it is a deliberate Bondy choice, not a
  restatement. The inline `+P 2000000` copies were *lower* than the value
  actually in force and were removed rather than honoured.
- `+sbwt`, `+c` and `+C` inline copies matched the schema defaults exactly, so
  they were redundant and removed.
- `+K` was removed from all three files: it is absent from the erts 16.4 usage
  output, and both `+K true` and `+K false` leave
  `erlang:system_info(kernel_poll)` at `true`, so kernel polling is unconditional
  and the flag does nothing.
- `+zdbbl` stays inline in `prod_named`, which ships no `bondy.conf` template, so
  the schema's `{commented, "1MB"}` emits nothing and this is its only source.

Effective flag sets were then diffed for all nine releases by merging inline
`vm.args` with the generated file under last-wins. Net change: `+A 1 → 64`
everywhere it was declared, `+K` gone (proven inert), and for `prod`/`docker` —
which declare no `+A` at all — the flag is simply no longer emitted, falling back
to the identical erts default of 1. `prod_named`'s resulting layout was booted for
real: `thread_pool_size=64, process_limit=2097152`.

## Every remaining default, checked

The question asked of each: does this default state a Bondy choice, or does it
merely restate erts and thereby shadow `vm.args` for nothing? Measured by booting
with no flags and reading the value back, or from a default the emulator's usage
text states outright.

Converted to `{commented, …}` — proven restatements:

| Flag | Schema had | erts default | Evidence |
|---|---|---|---|
| `+A` | 1 | 1 | `thread_pool_size` |
| `+W` | `w` | `warning` | `error_logger:warning_map/0` |
| `+sssdio` | 40 | 40 | usage: `-sssdio size … (default 40)` |

Kept — the default diverges from erts, so it is a real choice:

| Flag | Schema | erts | Evidence |
|---|---|---|---|
| `+P` | 2097152 | 1048576 | `process_limit` |
| `+Q` | 2097152 | 1048576 | `port_limit` |
| `+e` | 256000 | 8192 | `ets_limit` |
| `+SDio` | 128 | 10 | `dirty_io_schedulers` |
| `-hidden`, `-start_epmd`, `-env ERL_DIST_PORT` | on, off, 27780 | opposite / none | Partisan owns clustering; these are deliberate |
| `+sbwt`, `+sbwtdcpu`, `+sbwtdio` | `none` | not established | the mappings' own comments state erts defaults to `short`, and `none` is the documented container recommendation |
| `+MMsco`, `+MMscs`, `+Muatags` | off, `"0MB"`, on | not established | `+MMsco`'s comment states erts defaults to true, so at least that one diverges; the three act as a set |

Kept deliberately **despite** being restatements:

| Flag | Schema | erts | Why keep |
|---|---|---|---|
| `+c` | on | true | Bondy's HLC and the stabilization proofs rest on monotonic-time semantics. Worth stating explicitly rather than inheriting. |
| `+C` | multi_time_warp | multi_time_warp | Same, and this was *not* always the erts default — pinning it is what makes the guarantee independent of the erts version. |

Not established, so left alone rather than guessed: `+scl` (on), `+sub` (off),
`+sfwi` (0), `-dist_listen` (true). No `system_info` key exposes them and the
usage text states no default. They are currently harmless — after the `vm.args`
cleanup nothing sets them inline — so the only cost is that they may be freezing
an erts default that could later change.

Net effect on the nine releases: `+W w` and `+sssdio 40` are no longer emitted,
and both fall back to the identical erts value (`error_logger:warning_map/0`
returns `warning` on a node booted from the new generated args). Nothing else
moved.

## A second shadowed declaration

`vm.async_thread.stack_size` was declared **twice**, with different datatypes: an
integer-kilowords version carrying `{default, 16}` and validator `range:16-8192`,
and later a `bytesize` version with a translation dividing into kilowords. The
later one wins, so the earlier block was dead — and actively misleading, since its
doc comment told operators to write kilowords while the live mapping rejects
`= 16` with *"must be in the range of 128KB to 64MB"*. Verified live behaviour:
`128KB` → `+a 16`, `1MB` → `+a 128`. The dead block and its now-unused validator
were removed; that validator's own message read `"must be 0 to 1024"` for a
16-8192 check.

## Caveat on the `-` flags

The last-wins measurement covers erts `+` flags. `-dist_listen`, `-start_epmd`,
`-hidden` and `-env` are erlexec/init flags, where `-name` demonstrably resolves
*first*-wins instead. Which rule applies to each was not established, so nothing
in this pass relies on it.
