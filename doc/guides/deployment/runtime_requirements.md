# Runtime requirements

## Erlang/OTP

The release images are built on Erlang/OTP 29.0.5: `deployment/Dockerfile`
builds from `erlang:29.0.5` and `deployment/alpine.Dockerfile` from
`erlang:29.0.5-alpine`. Both build the release with the `docker` profile, which
includes the Erlang runtime (`include_erts`), so an image runs the OTP it was
built with and needs no Erlang on the host.

To build from source you need Erlang/OTP 28 or later: `rebar.config` sets
`minimum_otp_vsn` to `"R28"`.

## TLS

Bondy sets no `supported_groups` and no `signature_algs` on any TLS socket, so
the key-exchange groups and signature algorithms a TLS listener, bridge relay or
cluster connection negotiates are the defaults of the OTP `ssl` application in
the runtime. Running a different OTP release can change them.

## Storage

`platform_data_dir` must be on a filesystem that accepts `fsync` on a directory.
See [Platform directories](platform_directories.md#platform_data_dir).

## See also

- [Platform directories](platform_directories.md)
