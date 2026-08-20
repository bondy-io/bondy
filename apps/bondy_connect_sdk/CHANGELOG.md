# CHANGELOG

## Unreleased
### Changes:
- Pre-1.0 API normalisation onto `{ok, _}` / `{error, _}` across the callee
  handler contract, `call*`, `publish`, and `bondy_connect_dispatch:worker_pid/2`:
  - Callee handler returns collapse from seven forms
    (`{reply, _}` / `{reply, _, _}` / `ok` / `noreply` / `{error, _}` /
    `{error, _, _}` / `{error, _, _, _}`) to three:
    `ok` | `{ok, #{args => _, kwargs => _}}` | `{error, #{uri := _, args => _,
    kwargs => _}}`. `noreply` is removed (it was a synonym for `ok`).
  - `call/2..5`, `call_async/3..5`, `call_stream/5`, `register/3,4`,
    `unregister/2`, `subscribe/3,4`, `unsubscribe/2` and the new
    `publish_ack/3,4,5` now return a discriminated `{error, #{kind := wamp,
    uri := _, ...} | #{kind := client, reason := _}}` instead of a union of
    a WAMP-error map and a bare atom.
  - `publish/3,4,5` stays fire-and-forget only (`ok | {error, term()}`) and
    now rejects an explicit `acknowledge => true` in `Opts` with
    `{error, badarg}`; `publish_ack/3,4,5` is the new acknowledged-publish
    API, returning `{ok, PublicationId}`.
  - `bondy_connect_dispatch:worker_pid/2` returns `{error, not_found}`
    instead of a bare `error`.
