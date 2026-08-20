# How to check your configuration for keys Bondy no longer reads

Bondy cannot fail the boot on a key it does not recognise. A stale, renamed or
mistyped key in `bondy.conf` is dropped without a word: the node starts, and the
subsystem you meant to configure runs on its default. `scripts/migrate_conf.escript`
is the tool that tells you which of your settings that applies to.

Run it before every upgrade, and after every hand-edit of a `bondy.conf`.

## Why a tool rather than a boot check

The release builds its application config by running `cuttlefish` once per schema
set — the VM arguments, then the application schemas — and each run reads your
*whole* `bondy.conf` while knowing only its own subset of keys. Every key owned
by another set therefore looks unrecognised to the run currently executing, so
all the runs are told to tolerate keys they do not know.

That tolerance cannot distinguish "belongs to the other schema set" from
"belongs to no schema at all". It is structural, not a policy that could be
switched off: the flag lives in the release-generation plugin's template, and
removing it would abort the boot on the first invocation for essentially every
application key in the file.

So a key is genuinely dead only if *no* schema maps it. That is the question
this tool answers.

## check

```bash
# From a built checkout
just conf-check etc/bondy.conf

# Or directly, from a built checkout or an unpacked release
./scripts/migrate_conf.escript check etc/bondy.conf
```

Nothing is written. It exits `0` when there is nothing to change, `1` when there
is, and `2` when the check itself could not be performed — a runbook must not
read the last as the first. [Keys whose meaning
changed](#keys-whose-meaning-changed) are the one thing it reports without
affecting the exit code.

Findings are grouped by what you have to do about them:

| Group | Meaning |
|---|---|
| `RENAME` | The same setting exists under a new key. |
| `CONTESTED` | A rename is available, but applying it would change behaviour — read the explanation before acting. |
| `ALREADY SET` | The new key is set in this file too, with a different value. |
| `DROP` | The setting has no equivalent on this release. |
| `BY HAND` | Several live keys are plausible and the name does not decide between them. Candidates are listed. |
| `NOT ON THIS RELEASE` | The new key exists in a later version than the schemas you pointed at. |
| `NO RULE` | The tool has nothing for this key. It is still not read. |

The verdict line comes last and covers every section, so a file can have every
key recognised and still report findings — most often listener ones.

`CONTESTED` exists because activating a key that was inert is not automatically
the right migration. A key that never reached its subsystem may hold a value
that contradicts the rest of the file, and silently making it effective would
change how the node behaves. The tool reports the conflict and leaves the
decision to you.

`ALREADY SET` is the related case: of two lines for one key, the last one in the
file wins, so performing the rename would discard one of the two values without
saying so. The tool reports both and renames neither.

### Checking against the release you are upgrading *to*

By default the schemas are found next to the tool — `schema/` in a checkout,
`releases/<version>/` in an unpacked release. To ask "will the *next* release
read my current file", point it at that release's schemas:

```bash
./scripts/migrate_conf.escript check etc/bondy.conf \
    --schema-dir /path/to/new-release/releases/<version> \
    --schema-dir /path/to/new-release/releases/<version>/schema
```

## Keys whose meaning changed

A key can survive an upgrade and still stop meaning what it did. That is
invisible to every other section — the key is live, so it is not a finding, and
nothing fails to start — so the tool reports these separately, under
`CHANGED MEANING`.

There is nothing to rename and nothing to drop — `migrate` copies the line
through untouched. The only thing to do is confirm the value still says what you
meant by it.

These do not set the exit code. A file that legitimately sets such a key could
otherwise never exit `0`, and a gate that cannot be satisfied gets ignored. The
verdict line names the count instead, so `clean` cannot be read as silence:

```
RESULT  clean -- every key is read and every listener is declared; 1 key changed meaning in this release
```

On this release there is one entry, `listeners.$name.linger.timeout`, whose unit
changed from milliseconds to seconds. The tool prints what to check; the
[listeners guide](listeners.md) documents the key. Note that
`listeners.$name.http.linger.timeout` is a different setting, still in
milliseconds, and is not reported.

## Listeners

The tool separately reports which listeners your file will actually start,
because that has its own silent failure.

A listener you do not declare does not exist. A `bondy.conf` with no
`listeners.*` key at all starts the three built-in defaults — `admin`,
`api_gateway_http` and `wamp_tcp` — and nothing else, so a file still
configuring its listeners through the removed per-scheme keys loses every TLS
and bridge-relay listener with no symptom other than a refused connection.

The report therefore lists the listeners your file will actually start, and calls
out two failures separately:

- **GONE** — the file configures a listener through one of the removed
  per-scheme blocks and the node will not start it. Both the listener and every
  setting on it are lost.
- **WILL NOT BOOT** — a listener is declared with options but without its
  identity (`transport`, `protocol` and a bind target). This is what a key-by-key
  rename produces on its own, and it is worse than losing one listener:
  `bondy_listener_config:resolve/2` refuses the whole inventory on the first bad
  entry, so the node fails to start with
  `{invalid_listener, <name>, {missing, transport}}`.

The administrable endpoint cannot be lost either way: Bondy always provides the
reserved `admin` listener, so it needs no declaration of its own. Its *options*
still have to be stated under `listeners.admin.*` — a listener's options are read
under its current name, and `admin` is the name it carries.

## advanced.config

If an `advanced.config` sits beside your `bondy.conf`, its stanzas are checked
too. A stanza naming an application the release does not have is overlaid onto
nothing and silently ignored — most often `{bondy, ...}`, whose OTP application
is now `bondy_router`, or `{plum_db, ...}`, whose application is gone.

`advanced.config` is reported but never rewritten: it is a term file, and
rewriting it would discard every comment in it.

## migrate

```bash
./scripts/migrate_conf.escript migrate etc/bondy.conf --out etc/bondy.conf.new
```

Writes a converted file. Never in place, and never over a file that already
exists.

The conversion is line-oriented, so comments, blank lines, key order and the
column your `=` sits in all survive. A file with nothing to migrate comes back
byte for byte.

What it does to each key follows from the check:

- **Renamed** keys are rewritten in place. These settings **start applying** —
  they were being ignored before, so check that each value is still the one you
  want.
- **Everything else** is commented out, with the reason on the lines above it.
  This changes nothing about how the node runs: the key was already being
  discarded. It only makes the discard visible, and leaves the value in the file
  where you can see what it was.

Feeding the output back to `check` reports it clean.

It does **not** synthesise listener blocks. Getting a listener inventory wrong
produces a node with no way in, so the tool derives the block for you and prints
it, and you decide.

## See also

- [How to migrate your configuration from 1.0.0-rc.65](migrating_from_1.0.0-rc.65.md)
- [Listeners](listeners.md)
