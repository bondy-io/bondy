%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_app).

-moduledoc """
The `bondy_connect_sdk` application callback module.

Starts the application's top supervisor, `bondy_connect_sup`. The public client
API lives in `bondy_connect_client`.
""".

-behaviour(application).

-export([start/2]).
-export([stop/1]).
-export([ensure_wamp_extensions/0]).

%% =============================================================================
%% APPLICATION CALLBACKS
%% =============================================================================

-spec start(application:start_type(), term()) ->
    {ok, pid()} | {error, term()}.

start(_StartType, _StartArgs) ->
    ok = ensure_wamp_extensions(),
    bondy_connect_sup:start_link().

-spec stop(term()) -> ok.

stop(_State) ->
    ok.

-doc """
Declares the WAMP extensions the client uses, merging them into the
`wamp` application's environment. Idempotent; runs at application start.

The client SENDS extension options — `_deadline` on CALL (the absolute
cap for a progressive call) and the W3C trace-context trio
(`_traceparent`/`_tracestate`/`_baggage`, see `bondy_connect_trace`) on
CALL and PUBLISH — and RECEIVES the trio as INVOCATION and EVENT
extension details. Extensions are validated against the `wamp`
application's environment, which in a router node is populated by
`bondy_config` — but a standalone client deployment has no router: an
undeclared option is silently stripped by the client's own encoder, and
an undeclared detail by its own decoder. Merge (never replace) so this
is safe in either start order when co-located with `bondy_router`.
""".
-spec ensure_wamp_extensions() -> ok.

ensure_wamp_extensions() ->
    ok = bondy_wamp_config:init(),
    Trace = ['_traceparent', '_tracestate', '_baggage'],
    lists:foreach(
        fun({Path, Keys}) ->
            Current = bondy_wamp_config:get(Path, []),
            case [K || K <- Keys, not lists:member(K, Current)] of
                [] ->
                    ok;
                Missing ->
                    bondy_wamp_config:set(Path, Missing ++ Current)
            end
        end,
        [
            {[extended_options, call], ['_deadline' | Trace]},
            {[extended_options, publish], Trace},
            {[extended_details, invocation], Trace},
            {[extended_details, event], Trace}
        ]
    ).
