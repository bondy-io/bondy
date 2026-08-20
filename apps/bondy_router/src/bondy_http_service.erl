%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_service).

-moduledoc """
Behaviour for a carrier's contribution to an HTTP listener's dispatch table.

A *carrier* is a way of reaching Bondy over HTTP — WebSocket, SSE, long poll, the
API Gateway — and it is the carrier, not the service name, that owns a path.
Several services may name the same carrier while carrying different protocols
(`wamp_ws` and `bamp_ws` both mount `/ws`), so the callback receives that
carrier's resolved entry, protocol union included, and is called once.

In-tree carriers are implemented by `bondy_http_services`. This behaviour exists
so an application outside `bondy_router` can supply its own. Registering one
takes two entries, because they answer different questions: which carrier a
service rides (`bondy_router.http_services`, read by
`bondy_listener_config:service_spec/1`) and which module serves that carrier
(`bondy_router.http_carriers`).
""".

%% A Cowboy host match and one host's worth of route rules. Named locally
%% because `cowboy_router` defines the equivalent types but exports neither.
-type host_match() :: '_' | iodata().
-type route_rule() :: {
    host_match(), [{Path :: string(), module(), State :: map()}]
}.

-export_type([host_match/0, route_rule/0]).

-doc """
Returns the Cowboy route rules `Carrier` contributes to `Listener`.

`Spec` is the carrier's resolved entry: the union of the protocols the
listener's services named for it — `[]` for a carrier that carries no wire
protocol, such as the API Gateway, admin or metrics — and its resolved
configuration. It is passed whole rather than looked up again from `Listener`,
so a carrier's identity, protocols, module and configuration are read from one
place.

Rules are grouped BY HOST, the shape `cowboy_router:compile/1` takes. A carrier
whose routes apply to every host returns a single `'_'` group, which every
in-tree carrier except the two API Gateway ones does; those two return whatever
host each specification declared. `bondy_http_services:dispatch/1` replicates the
`'_'` group into each named host, so a carrier need not know which hosts the
listener's other carriers declared.
""".
-callback routes(
    Carrier :: atom(),
    Spec :: bondy_listener_config:carrier(),
    Listener :: bondy_listener_config:t()
) -> [route_rule()].
