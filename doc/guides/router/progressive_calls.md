# Progressive Calls

Bondy implements the WAMP Advanced Profile feature **Progressive Calls**: a
caller can stream the **arguments** of a single call to the callee in any
number of chunks, reusing one request id, before the callee produces its
result. Typical uses are uploading a large payload in pieces, feeding a
long-running computation incrementally, and forwarding a client-side stream
into an RPC without buffering it whole.

This is the mirror image of **Progressive Call Results** (streaming the
*result* from callee to caller), documented in
[`progressive_call_results.md`](progressive_call_results.md). The two features
are independent and can be combined.

## Message flow

```
Caller                Dealer                 Callee
  |  CALL id=7           |                      |
  |  progress=T          |                      |
  |--------------------->|  INVOCATION id=100   |
  |                      |  progress=T          |
  |                      |--------------------->|
  |  CALL id=7           |                      |
  |  progress=T          |  INVOCATION id=100   |
  |--------------------->|  progress=T          |
  |                      |--------------------->|
  |  CALL id=7 (final)   |                      |
  |  (no progress)       |  INVOCATION id=100   |
  |--------------------->|  (no progress)       |
  |                      |--------------------->|
  |                      |            YIELD/final|
  |    RESULT (final)    |<---------------------|
  |<---------------------|                      |
```

- The caller opens the stream with `CALL.Options.progress = true` and keeps
  the **same** `CALL.Request` id for every chunk.
- The dealer forwards each chunk as an `INVOCATION` with the **same**
  `INVOCATION.Request` id and `Details.progress = true`, so the callee sees
  one invocation receiving successive argument chunks.
- The final chunk is a `CALL` for the same request id **without** `progress`;
  the dealer forwards it as an `INVOCATION` without `progress`, so the callee
  learns the input is complete and computes its result.
- The callee replies once, with a single terminal `RESULT`/`ERROR` (or, if it
  also streams results, a progressive result sequence — see the results
  guide).

This holds in a cluster as well: when caller and callee are connected to
different nodes, the chunks are relayed between nodes and arrive at the callee
in send order (Bondy pins each caller/callee pair to a single ordered pipeline
across the cluster connection). The call promise lives on the caller's node
and the invocation promise on the callee's node; each further chunk is
re-forwarded to the callee's node against the open invocation rather than
re-routed.

## Enabling the feature

The dealer feature is **disabled by default** and is enabled per node:

```
wamp.dealer.progressive_calls = on
```

> #### Mixed-version clusters {: .warning}
> Only enable the flag once **every** node in the cluster runs a Bondy
> version that supports it. The flag is read at call time on the node the
> caller is connected to, so it can be flipped without a restart.

While the flag is on, every `CALL` on that node pays a small bounded promise
lookup (to tell a first chunk from a subsequent one). The lookup is a prefixed
`ordered_set` probe, not a scan, so the cost is a low constant per call — but it
is paid by *all* calls on the node, not only progressive ones, which is one more
reason to leave the flag off where the feature is not used.

Toggling the flag **off while a stream is open** is safe but coarse: the node
stops recognising further chunks as continuations, so the caller's in-flight
stream fails rather than completing. Flip the flag during a quiet window, not
mid-stream.

## Semantics and guarantees

- **Strict opt-in, no silent degrade.** Unlike progressive *results* — a callee
  that does not support them simply replies once — a progressive *call* cannot be
  silently downgraded, because the caller has already begun streaming. The first
  chunk is therefore gated at both ends: the caller is checked on its own node,
  and a remote callee is checked at the node that hosts it. If either peer's
  negotiated session role lacks `progressive_calls`, the call fails with
  `wamp.error.option_not_allowed` rather than being reinterpreted as a plain
  call. Both `progressive_calls` and `progressive_call_results` are **strict
  opt-in**: a peer must announce the feature explicitly in `HELLO` to obtain it.
  Unlike ordinary capabilities — which a peer inherits from the router's
  advertised set unless it opts out — a peer that simply *omits* a progressive
  feature does **not** get it. Bridge/edge callees are in scope and gated the
  same way, at the edge node that hosts the callee.
- **`call_canceling` pairing.** Per the WAMP specification, a peer requesting
  `progressive_calls` must also announce `call_canceling`; Bondy enforces
  this at `HELLO` validation.
- **One request id.** Every chunk of a stream reuses the caller's original
  `CALL.Request` id. Reusing a live request id on a call that is **not** a
  progressive-input stream remains a protocol violation
  (`wamp.error.protocol_violation`); the "duplicate id = next chunk" rule is
  scoped strictly to an open progressive-input call.
- **Ordering.** All chunks for one call reach the callee in send order,
  including across cluster nodes. The final (non-`progress`) chunk never
  overtakes an earlier one.
- **Timeout = inactivity window.** As with progressive results,
  `CALL.Options.timeout` is the limit between chunks — each chunk **restarts**
  it, so a stream that keeps flowing can run for longer than the timeout while
  a stream that goes quiet is terminated with `wamp.error.timeout`.
- **`_deadline` = total budget (Bondy extension).** `CALL.Options._deadline`
  (milliseconds) caps the **whole** call, bounding a slowly-dripping stream
  that never stalls long enough to trip the inactivity timeout.
- **Cancellation.** A progressive call can be cancelled like any other call
  (`CANCEL` with mode `skip`, `kill` or `killnowait`), including when the
  callee is on another cluster node — the dealer relays the cancellation to
  the callee's node, which interrupts the callee mid-stream.
- **Caller departure.** If the caller's session ends mid-stream, the dealer
  sends the callee an `INTERRUPT` (mode `killnowait`) so it stops waiting on
  input that will never arrive — for local callees directly, and for callees
  on other nodes by relaying the cancellation to their node.

## Using it from bondy_connect_sdk (Erlang client)

Both RPC roles of the built-in `bondy_connect_sdk` client announce
`progressive_calls`.

**Caller** — open the stream with `call_stream/5`, send further argument
chunks with `send_input/4`, and close it with `finish_input/4`. The reply is
delivered against the returned `Token` exactly like `call_async/5`:

```erlang
{ok, Token} = bondy_connect_client:call_stream(
    Conn, <<"com.example.upload">>, [<<"part-1">>], #{}, #{
        %% inactivity window between chunks (WAMP timeout)
        timeout => 30000,
        %% optional total budget for the whole stream (Bondy extension)
        '_deadline' => 300000
    }
),
ok = bondy_connect_client:send_input(Conn, Token, [<<"part-2">>], #{}),
ok = bondy_connect_client:finish_input(Conn, Token, [<<"part-3">>], #{}),
receive
    {bondy_connect_client, Token, {ok, Final}} -> {done, Final};
    {bondy_connect_client, Token, {error, Reason}} -> {error, Reason}
end.
```

`call_stream/5` sends the first chunk and returns immediately; `send_input/4`
sends a non-final chunk; `finish_input/4` sends the final chunk and closes the
input stream. The result arrives as the single terminal
`{bondy_connect_client, Token, {ok, _} | {error, _}}` message.

**Callee** — when the caller opened a progressive call, the handler receives
an `input` fun in its details. The invocation's own arguments are the first
chunk; calling `input()` **pulls** the next chunk, blocking until it arrives
and returning `{more, Args, KWArgs}` while the stream continues or
`{last, Args, KWArgs}` for the final chunk:

```erlang
Handler = fun(FirstChunk, _KWArgs, Details) ->
    case maps:find(input, Details) of
        {ok, Input} ->
            All = collect([FirstChunk], Input),
            {reply, [process(All)]};
        error ->
            %% Not a progressive call — a single set of arguments.
            {reply, [process([FirstChunk])]}
    end
end,

collect(Acc, Input) ->
    case Input() of
        {more, Args, _KWArgs} -> collect([Args | Acc], Input);
        {last, Args, _KWArgs} -> lists:reverse([Args | Acc])
    end.

{ok, _} = bondy_connect_client:register(Conn, <<"com.example.upload">>, Handler).
```

The `input` fun is only present when `INVOCATION.Details.progress` is `true`,
so handlers must not assume it exists.
