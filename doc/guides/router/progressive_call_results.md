# Progressive Call Results

Bondy implements the WAMP Advanced Profile feature **Progressive Call
Results**: a callee can stream any number of partial results for a single
call before delivering the final result, and the caller receives them in
order as they are produced. Typical uses are paging large result sets,
streaming file chunks, and long-running computations that report partial
output.

The related feature *Progressive Calls* (streaming call **arguments** from
caller to callee) is **not** implemented.

## Message flow

```
Caller                Dealer                 Callee
  |  CALL                |                      |
  |  receive_progress=T  |                      |
  |--------------------->|  INVOCATION          |
  |                      |  receive_progress=T  |
  |                      |--------------------->|
  |                      |     YIELD progress=T |
  |    RESULT progress=T |<---------------------|
  |<---------------------|     YIELD progress=T |
  |    RESULT progress=T |<---------------------|
  |<---------------------|     YIELD (final)    |
  |    RESULT (final)    |<---------------------|
  |<---------------------|                      |
```

- The caller opts in per call with `CALL.Options.receive_progress = true`.
- The dealer forwards the request to the callee as
  `INVOCATION.Details.receive_progress = true`.
- Each partial result is a `YIELD` with `Options.progress = true`, which
  the dealer forwards as a `RESULT` with `Details.progress = true` without
  settling the call.
- The first `YIELD` without the flag (or an `ERROR`) is the **terminal**
  message: it settles the call, and the caller receives exactly one
  terminal `RESULT`/`ERROR` after all progressive results.

This holds in a cluster as well: when caller and callee are connected to
different nodes, progressive results are relayed between nodes and arrive
at the caller in yield order (Bondy pins each caller/callee pair to a
single ordered pipeline across the cluster connection).

## Enabling the feature

The dealer feature is **disabled by default** and is enabled per node:

```
wamp.dealer.progressive_call_results = on
```

> #### Mixed-version clusters {: .warning}
> Only enable the flag once **every** node in the cluster runs a Bondy
> version that supports it. A node without support settles a call on the
> first progressive result, so a stream crossing that node would be
> truncated. The flag is read at call time on the node the caller is
> connected to, so it can be flipped without a restart.

## Semantics and guarantees

- **Opt-in end to end.** `receive_progress` is honoured only when (a) the
  dealer feature is enabled, (b) the caller announced
  `progressive_call_results` in `HELLO`, and (c) the callee announced it
  too. If any of these fail the option is removed: the callee sees a plain
  invocation, replies once, and the caller receives a single final result.
  Degradation is silent by design — the call still succeeds.
- **`call_canceling` pairing.** Per the WAMP specification, a peer
  requesting `progressive_call_results` must also announce
  `call_canceling`; Bondy enforces this at `HELLO` validation.
- **Ordering.** All progressive results for one call arrive in yield
  order, before the terminal result. Nothing is delivered for a call after
  its terminal message.
- **Timeout = inactivity window.** Per the WAMP specification, for a
  progressive call `CALL.Options.timeout` is "the time limit between the
  initial call and the first result, and between results thereafter" —
  each progressive result **restarts** it. A stream that goes quiet for
  longer than the timeout is terminated with `wamp.error.timeout`; a
  stream that keeps producing results can run for longer than the timeout.
- **`_deadline` = total budget (Bondy extension).** Because the timeout
  only bounds gaps, a slowly-dripping stream is otherwise unbounded.
  `CALL.Options._deadline` (milliseconds) caps the **whole** call: the
  stream is terminated with `wamp.error.timeout` when the deadline is
  reached, no matter how healthy it is.
- **Cancellation.** A progressive call can be cancelled like any other
  call (`CANCEL` with mode `skip`, `kill` or `killnowait`), including when
  the callee is on another cluster node — the dealer relays the
  cancellation to the callee's node, which interrupts the callee.
- **Caller departure.** If the caller's session ends mid-stream, the
  dealer sends the callee an `INTERRUPT` (mode `killnowait`) so it stops
  producing results nobody will consume — for local callees directly, and
  for callees on other nodes by relaying the cancellation to their node.
- **Protocol violations.** A progressive `YIELD` for a call that did not
  request progressive results is a protocol violation: the callee's
  session is closed with `wamp.error.protocol_violation` and the caller's
  call fails fast with `wamp.error.no_eligible_callee`.

## Using it from bondy_connect (Erlang client)

Both RPC roles of the built-in `bondy_connect` client announce
`progressive_call_results`.

**Caller** — progressive results require `call_async/5` (a synchronous
`call/5` cannot represent a stream and rejects the option):

```erlang
{ok, Token} = bondy_connect:call_async(
    Conn, <<"com.example.stream">>, [], #{}, #{
        receive_progress => true,
        %% inactivity window between results (WAMP timeout)
        timeout => 30000,
        %% optional total budget for the whole stream (Bondy extension)
        '_deadline' => 300000
    }
),
receive_loop(Token).

receive_loop(Token) ->
    receive
        {bondy_connect, Token, {progress, #{args := Chunk}}} ->
            handle_chunk(Chunk),
            receive_loop(Token);
        {bondy_connect, Token, {ok, Final}} ->
            {done, Final};
        {bondy_connect, Token, {error, Reason}} ->
            {error, Reason}
    end.
```

Each progressive result is delivered as
`{bondy_connect, Token, {progress, Result}}`; the `{ok, _}` or
`{error, _}` delivery remains the single terminal message.

**Callee** — when the caller requested progressive results, the handler
receives a `progress` fun in its details; each call emits one progressive
`YIELD`, and the handler's return value is the final result:

```erlang
Handler = fun(_Args, _KWArgs, Details) ->
    case maps:find(progress, Details) of
        {ok, Progress} ->
            ok = Progress([<<"chunk-1">>], #{}),
            ok = Progress([<<"chunk-2">>], #{}),
            {reply, [<<"final">>]};
        error ->
            %% Caller did not ask for progressive results.
            {reply, [<<"final">>]}
    end
end,
{ok, _} = bondy_connect:register(Conn, <<"com.example.stream">>, Handler).
```

The `progress` fun is only present when
`INVOCATION.Details.receive_progress` is `true`, so handlers must not
assume it exists.
