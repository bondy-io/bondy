%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_handler).

-moduledoc """
A short-lived, **isolated** worker that runs exactly one user handler — a callee
`INVOCATION` or a subscriber `EVENT` — and then exits.

It is a `temporary` child of the per-connection `bondy_connect_handler_sup`
(`simple_one_for_one`), so it is *linked to the supervisor* but only
**monitored** by the connection — a crashing user fun can never take the
connection down. The handler runs under `try/catch`: a crash or unexpected
return is turned into a WAMP `ERROR` (for invocations) and reported back to the
connection, which keeps servicing other requests.

Result protocol back to the connection (`Conn`):

- invocation → `{handler_done, ReqId, Reply}` where `Reply` is
  `{yield, Args, KWArgs}` or `{error, Uri, Args, KWArgs}`.
- invocation progress → `{handler_progress, ReqId, Args, KWArgs}`, emitted
  while the handler runs via the `progress` fun injected into the details
  when the caller requested progressive results.
- event → `{event_done, SubId, self()}` (always sent, even on handler error, so
  the connection's per-subscription FIFO can advance).
""".

-include_lib("kernel/include/logger.hrl").
-include("bondy_connect.hrl").

-export([start_link/1]).
-export([run/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Start a worker for a single job (called by the `simple_one_for_one` sup).".
-spec start_link(map()) -> {ok, pid()}.
start_link(Job) when is_map(Job) ->
    {ok, proc_lib:spawn_link(?MODULE, run, [Job])}.

%% =============================================================================
%% INTERNAL (spawned entry point)
%% =============================================================================

-doc false.
-spec run(map()) -> ok.
run(#{kind := invocation, conn := Conn, req_id := ReqId} = Job) ->
    #{handler := H, args := Args, kwargs := KWArgs, details := Details0} = Job,
    Started = erlang:monotonic_time(millisecond),
    Details1 = maybe_progress_fun(Details0, Conn, ReqId),
    Details = maybe_input_fun(Details1),
    Reply = invoke_call(H, Args, KWArgs, Details),
    Conn ! {handler_done, ReqId, Reply},
    %% After the reply so the emission seat cannot delay or break the
    %% data path (this worker's own DOWN after handler_done is a no-op
    %% in the dispatch).
    ok = notify_span(Job, Started, Reply),
    ok;
run(#{kind := event, conn := Conn, sub_id := SubId} = Job) ->
    #{handler := H, args := Args, kwargs := KWArgs, details := Details} = Job,
    _ = invoke_event(H, Args, KWArgs, Details),
    Conn ! {event_done, SubId, self()},
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% When the caller asked for progressive results
%% (`INVOCATION.Details.receive_progress`), hand the user handler a
%% `progress` fun alongside the WAMP details: calling it emits a
%% progressive YIELD through the connection while the handler keeps
%% running; the handler's return value remains the final result. Without
%% the flag the details are passed through untouched, so a handler must
%% check for the fun before using it.
maybe_progress_fun(#{receive_progress := true} = Details, Conn, ReqId) ->
    Details#{
        progress => fun(Args, KWArgs) ->
            Conn ! {handler_progress, ReqId, Args, KWArgs},
            ok
        end
    };
maybe_progress_fun(Details, _, _) ->
    Details.

%% @private
%% Mirror of `maybe_progress_fun/3` for the INPUT direction. For a
%% progressive-INPUT invocation (`INVOCATION.Details.progress => true`, more
%% argument chunks arriving), inject an `input` fun the handler calls to PULL the
%% next chunk: `Input()` blocks on the chunk the connection forwards to this
%% worker and returns `{more, Args, KWArgs}` while the stream continues or
%% `{last, Args, KWArgs}` for the final chunk. The invocation's own args are the
%% first chunk; the handler pulls the rest until `{last, _, _}`. Without the flag
%% the details are untouched, so a handler must check for the key.
maybe_input_fun(#{progress := true} = Details) ->
    Details#{input => fun pull_input/0};
maybe_input_fun(Details) ->
    Details.

%% @private
%% Block until the connection forwards the next argument chunk to this worker.
%% A stalled stream is bounded by the router's inter-chunk deadline, which
%% INTERRUPTs the invocation and kills this worker.
pull_input() ->
    receive
        {handler_input, Args, KWArgs, true} ->
            {last, Args, KWArgs};
        {handler_input, Args, KWArgs, false} ->
            {more, Args, KWArgs}
    end.

%% @private Emit the `[bondy_connect, rpc, latency]` event (kind
%% `invocation`) for a finished handler run — including a caught handler
%% crash (invoke_call/4 turns it into an error reply). A worker killed
%% by an INTERRUPT never reaches this and emits nothing. Bondy always
%% discloses the concrete procedure in `INVOCATION.Details.procedure`;
%% the WAMP spec only guarantees it for pattern-based registrations, so
%% the registration's own URI is the fallback.
notify_span(#{details := Details, uri := Uri}, Started, Reply) ->
    Duration = erlang:monotonic_time(millisecond) - Started,
    %% `Reply` is the normalized internal reply this worker just sent to
    %% the connection: `{error, Uri, Args, KWArgs}` (a business error, an
    %% invalid return or a caught handler crash — all of which the caller
    %% receives as a WAMP ERROR) or `{yield, Args, KWArgs}`.
    Outcome =
        case Reply of
            {error, _, _, _} -> error;
            _ -> success
        end,
    bondy_connect_telemetry:rpc_latency(
        invocation,
        maps:get(procedure, Details, Uri),
        Duration,
        bondy_connect_telemetry:trace_meta(Details),
        Outcome
    ).

%% @private
invoke_call(H, Args, KWArgs, Details) ->
    try bondy_connect_handler_spec:invoke(H, Args, KWArgs, Details) of
        Return ->
            case bondy_connect_handler_spec:normalize_return(Return) of
                invalid ->
                    ?LOG_WARNING(#{
                        description =>
                            "Callee handler returned an unexpected value.",
                        return => Return
                    }),
                    {error, ?BONDY_CONNECT_INTERNAL_ERROR, undefined,
                        undefined};
                Reply ->
                    Reply
            end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Callee handler raised an exception.",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, ?BONDY_CONNECT_INTERNAL_ERROR, undefined, undefined}
    end.

%% @private
invoke_event(H, Args, KWArgs, Details) ->
    try
        _ = bondy_connect_handler_spec:invoke(H, Args, KWArgs, Details),
        ok
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Subscriber handler raised an exception.",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.
