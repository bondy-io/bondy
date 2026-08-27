# Platform directories

Bondy resolves five directories from `bondy.conf`. Each one has a different
relationship to persistence and to container volumes, and the differences are
not interchangeable: one of them holds durable state that must survive a
restart, and another holds a socket that must not be placed on network storage
at all. Choosing the wrong backing store for a directory is a boot failure, not
a degradation.

## The five directories

| Key | Holds | Must persist | Mount a volume? |
| --- | --- | --- | --- |
| `platform_etc_dir` | `bondy.conf`, templates, TLS material | No | Yes — this is how you supply configuration |
| `platform_data_dir` | The durable stores: `bondy_db`, the write-ahead log, Merkle search trees | Yes | Yes — a volume or PersistentVolume |
| `platform_log_dir` | Log files, when a file handler is configured | No | Optional — only if you collect logs from disk |
| `platform_tmp_dir` | Scratch space | No | Optional |
| `platform_runtime_dir` | The internal admin listener's Unix domain socket | No | **No — see below** |

In a release the defaults are relative to the release root (`./etc`, `./data`,
`./log`, `./tmp`, `./run`). In the container images they are absolute:
`/bondy/etc`, `/bondy/data`, `/bondy/log`, `/bondy/tmp`, `/bondy/run`. Inside a
container the start hook fixes all of them and ignores the corresponding
`BONDY_*_DIR` environment variables, so a container relocates a directory
through `bondy.conf`, not through the environment.

## `platform_runtime_dir`

This directory holds objects that exist only while the node is running and that
require a filesystem with full local semantics. Today that is one file: the
Unix domain socket for the internal admin listener, the endpoint that stays
reachable when no TCP listener binds.

It is separate from `platform_tmp_dir` because the two have opposite
requirements. Scratch space is something you are invited to relocate — onto a
larger disk, onto shared storage, out of the container's writable layer — and
`platform_tmp_dir` is a declared volume in the images for exactly that reason. A
control socket cannot go anywhere an operator might relocate it, because not
every filesystem can hold one.

### The filesystem requirement

`platform_runtime_dir` must be on a filesystem that supports AF_UNIX socket
inodes. These do not:

- NFS
- SMB/CIFS, including Azure Files
- 9p, which is how a Windows drive appears inside WSL2
- Several FUSE-backed CSI drivers, including object-storage gateways
- gVisor's gofer

On any of them, binding the socket fails with `enotsup` and the node refuses to
start. That refusal is deliberate: `admin_local` starts in the `early` phase, and
a node that came up without its administrable endpoint would be discovered by
whoever is already locked out of it.

The first sign is a warning about a stale socket file that could not be removed,
also carrying `enotsup`, immediately before the bind error. Both name the path.

Two other values of the key fail the bind:

- A directory the node cannot write yields `eacces`.
- A directory deep enough to push the socket path past the `sockaddr_un`
  length limit — 108 bytes on Linux, 104 on macOS — yields `einval`. The error
  reports the path's size in bytes so you can compare it against the limit.

## Containers

The images create `/bondy/run` and give it to the `bondy` user, and it is
deliberately **not** a declared `VOLUME`. It sits on the container's own
writable layer, which supports the bind. Nothing needs configuring and nothing
needs mounting: a `docker run` with no `-v` at all comes up with the socket
bound at `/bondy/run/bondy_admin.sock`, owned by `bondy` and readable only by
its owner.

Do not mount anything there. A volume at `/bondy/run` replaces a filesystem that
works with whichever one the volume driver provides, which is the failure this
directory exists to avoid. Mount `/bondy/data`, `/bondy/etc`, and — if you want
it — `/bondy/log` and `/bondy/tmp`.

### Read-only root filesystems

`readOnlyRootFilesystem: true` in Kubernetes, or `docker run --read-only`,
removes the writable layer, and `/bondy/run` becomes unwritable — the bind then
fails with `eacces`. This is the one case that needs a mount, and it must be
node-local storage:

```yaml
volumes:
  - name: bondy-run
    emptyDir: {}
volumeMounts:
  - name: bondy-run
    mountPath: /bondy/run
```

`emptyDir: {}` is backed by the node's disk and `emptyDir: {medium: Memory}` by
tmpfs; both hold a Unix domain socket. A PersistentVolumeClaim does not qualify
— its backing store is exactly what the requirement above rules out. The Docker
equivalent is `--tmpfs /bondy/run`.

## One runtime directory per node

The socket's filename is fixed, so two nodes pointed at one
`platform_runtime_dir` resolve to the same path. The node that starts second
removes any socket file already there before binding, which means it removes the
first node's live socket; the first node goes on serving a socket nothing can
reach. Nothing detects this.

The defaults avoid it — every container and every release directory has its own
`./run` — so this only arises when the key is set explicitly, for instance to
put the socket on a host path shared by several nodes. Give each node its own
directory.

## See also

- [Listener configuration reference](../configuration/listeners.md) — the
  `admin_local` listener and the permissions on its socket
- [Checking your configuration](../configuration/checking_your_configuration.md)
  — validating `bondy.conf` before a node boots
