%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_ct).

-moduledoc """
The transport swap for the conformance suite.

A WAMP session behaves the same whichever transport carries it, so a case that
exercises a WAMP use case should be written once and run on every transport.
This module is what makes that possible: it turns a transport name into a
connect spec, so a case can say `connect(Config)` and never name a transport.

## What actually varies

Only three things, which is why the swap is small. Every spec carries the same
`realm`, `auth` and `serializers`; the transports differ in

- `transport` — the name the SDK maps to a transport module
- `endpoint` — a `{Host, Port}`, a `{local, Path}`, or the atom `local`
- one option apiece for the TLS-bearing and in-VM transports

The paths (`ws_path`, `longpoll_path`, `sse_path`) are deliberately NOT set
here: `bondy_connect_connection:endpoint/1` defaults them to the paths Bondy
mounts, so stating them would only let this module drift from the router.

## The listeners

Every transport below is already mounted by `bondy_ct:start_bondy/0` on one
node, so a suite using this module needs no listener of its own:

- 18082 `wamp_tcp`, 18085 `wamp_tls`, `wamp_uds` at a pid-suffixed path
- 18080 `api_gateway_http` and 18083 `api_gateway_https`, both mounting
  `wamp_ws`, `wamp_sse` and `wamp_longpoll`
- `local` opens a session in-VM and dials no socket at all

## Realms

One realm per transport, named after it. Per-transport realms mean a
registration or subscription left behind by one group cannot serve another
group's call — the isolation is structural rather than a matter of choosing
distinct URIs.

The credential methods get three more realms per transport, one per method, for
the same structural reason: a realm offering exactly one `authmethod` is what
makes establishing on it evidence *about that method*. A single realm offering
all four would let a client that fell back to another method still establish,
and the case would pass.
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-define(HOST, "127.0.0.1").
-define(PORT_TCP, 18082).
-define(PORT_TLS, 18085).
-define(PORT_HTTP, 18080).
-define(PORT_HTTPS, 18083).

-export([transports/0]).
-export([realm/1]).
-export([add_realm/1]).
-export([auth_realm/2]).
-export([add_auth_realms/2]).
-export([unsupported/2]).
-export([drop_sessions/1]).
-export([user/0]).
-export([password/0]).
-export([issue_ticket/1]).
-export([spec/2]).
-export([spec/3]).
-export([connect/1]).
-export([connect/2]).
-export([cacertfile/0]).
-export([echo_handler/0]).
-export([event_handler/1]).
-export([drain_events/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
The transports the conformance suite runs on, one CT group each.

`longpolls` and `sses` (the TLS variants, mounted on 18083) are valid SDK
transport names and are not in this list.
""".
transports() ->
    [tcp, tls, uds, local, ws, wss, longpoll, sse].

-doc "The realm for a transport's group.".
realm(Transport) ->
    Name = atom_to_binary(Transport, utf8),
    <<"com.example.bondy_connect.conformance.", Name/binary>>.

-doc """
Create a transport's realm: anonymous auth from any IP, and every WAMP
permission over every URI.
""".
add_realm(Transport) ->
    create(#{
        uri => realm(Transport),
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        grants => [grant([<<"anonymous">>])],
        sources => [source([<<"anonymous">>], ?WAMP_ANON_AUTH)]
    }).

-doc """
The realm a credential method's cases authenticate against.

One per transport per method, so `Method` is `cra`, `cryptosign` or `ticket`.
Anonymous has no realm of its own: it authenticates against `realm/1`, which is
the realm every other case already uses.
""".
auth_realm(Transport, Method) ->
    Base = realm(Transport),
    Suffix = atom_to_binary(Method, utf8),
    <<Base/binary, ".", Suffix/binary>>.

-doc """
Create a transport's three credential realms, each offering one `authmethod`
and each holding the same user.

`Config` must carry a `keypair` from `bondy_wamp_cryptosign:generate_key/0`;
its public half becomes the user's only authorized key, so a cryptosign case
can only establish by signing with the matching secret.
""".
add_auth_realms(Transport, Config) ->
    #{public := PubKey} = proplists:get_value(keypair, Config),
    ok = add_cra_realm(auth_realm(Transport, cra)),
    ok = add_cryptosign_realm(auth_realm(Transport, cryptosign), PubKey),
    ok = add_ticket_realm(auth_realm(Transport, ticket)),
    ok.

-doc """
Why a transport cannot carry a capability, or `false` if it can.

This is the only place a case is allowed to not run. A case that a transport
cannot support is skipped with the reason rather than omitted from its group,
so the report shows the hole and says why; a clause here is a statement about
the transport, not about the case, and its reason is the evidence.

Note what is NOT here: a transport that *should* carry a capability and does
not is a defect, and a defect belongs in a failing case, not in a clause that
turns the report green.
""".
unsupported(_, none) ->
    false;
unsupported(local, {serializer, _}) ->
    {true,
        "The in-VM transport exchanges records, never bytes. Its module says "
        "so: there is no transport handshake, the router delivers straight to "
        "the connection process's mailbox, and nothing is encoded on the way. "
        "A serializer is not something it can negotiate."};
unsupported(longpoll, {serializer, _}) ->
    {true,
        "The long-poll handler advertises wamp.2.json and nothing else "
        "(bondy_http_longpoll_handler:?SUPPORTED_PROTOCOLS), so the SDK "
        "refuses any other serializer at handshake rather than on the wire."};
unsupported(sse, {serializer, _}) ->
    {true,
        "The SSE handler advertises wamp.2.json.sse and nothing else "
        "(bondy_http_sse_handler:?SUPPORTED_PROTOCOLS), so the SDK refuses "
        "any other serializer at handshake rather than on the wire."};
unsupported(Transport, router_pong) when
    Transport == longpoll; Transport == sse; Transport == local
->
    {true,
        "This transport answers its own ping: ping/2 loops a pong straight "
        "back into the connection's mailbox rather than putting anything on "
        "the wire (deliberately -- for the HTTP pair the poll loop and the "
        "stream are the liveness evidence, and in-VM keepalive is "
        "meaningless). A keepalive case would therefore pass here without the "
        "router having been involved at all, which is worse than not running "
        "it."};
unsupported(local, transport_drop) ->
    {true,
        "The in-VM transport's session owner IS the client's own connection "
        "process (bondy_connect_local_handler runs in it, so the session ref "
        "targets it). There is nothing to drop that is not the client, so a "
        "drop cannot be staged independently of killing the peer under test."};
unsupported(local, credential_auth) ->
    {true,
        "The in-VM transport opens the session anonymously. Its handler "
        "(bondy_connect_local_handler) documents this: an in-VM peer is "
        "already inside the trusted BEAM, so the WAMP challenge methods do "
        "not apply. Realm grants and sources are still enforced."};
unsupported(_, _) ->
    false.

-doc """
Kill the router-side owner of every session in a transport's realm, abruptly.

The transport-independent way to stage a drop. Every transport's session names
an owner process — the connection handler for a socket, the
`bondy_http_transport_session` gen_server for the HTTP pair — and killing it is
the closest thing to a cable being pulled: no GOODBYE, no ABORT, nothing on the
wire. Reaching for the router side rather than the transport's own socket is
what makes one helper serve all of them.

Every session in the realm, not one, because a case cannot name its own: two
connections in the same realm are indistinguishable from here, and a session
left over from an earlier case is already orphaned, so killing it costs
nothing.

Returns how many were killed, so a case can assert it actually dropped
something. Without that, a helper that silently found no sessions would leave
the case passing on a link that was never broken — which is the one way a
reconnect case can be green and mean nothing.

Not usable for the in-VM transport, where the session's owner IS the client's
connection process — see `unsupported/2`.
""".
drop_sessions(Transport) ->
    Pids = [
        P
     || S <- sessions(realm(Transport)),
        is_pid(P = bondy_session:pid(S))
    ],
    _ = [exit(P, kill) || P <- Pids],
    length(Pids).

-doc "The user the credential realms hold.".
user() ->
    <<"alice">>.

-doc "That user's password, used by both `cra` and ticket issuance.".
password() ->
    <<"secret-password-123">>.

-doc """
Issue a real ticket for a transport's ticket realm.

`bondy_ticket:issue/2` reads the issuing session from its table, so the session
is registered rather than merely built. It is a `wampcra` session because a
realm's ticket policy names the methods allowed to issue, and `ticket` issuing
`ticket` is not one of them.
""".
issue_ticket(Transport) ->
    RealmUri = auth_realm(Transport, ticket),
    Session = bondy_session:new(RealmUri, #{
        peer => {{127, 0, 0, 1}, 0},
        authrealm => RealmUri,
        authid => user(),
        authmethod => ?WAMP_CRA_AUTH,
        security_enabled => true,
        authroles => [],
        roles => #{caller => #{}}
    }),
    true = ets:insert(
        bondy_session:table(bondy_session:external_id(Session)), Session
    ),
    {ok, Ticket, _} = bondy_ticket:issue(Session, #{}),
    Ticket.

-doc "The connect spec for a transport, as `spec/3` with no overrides.".
spec(Transport, Config) ->
    spec(Transport, Config, #{}).

-doc """
The connect spec for a transport, with `Extra` merged over it.

`Config` is the CT config; the TLS transports read the CA bundle from it, so a
suite using them must have put it there with `cacertfile/0`.
""".
spec(Transport, Config, Extra) ->
    Base = #{
        realm => realm(Transport),
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    },
    maps:merge(maps:merge(Base, endpoint(Transport, Config)), Extra).

-doc "Open an established connection on the group's transport.".
connect(Config) ->
    connect(Config, #{}).

-doc "As `connect/1`, with `Extra` merged over the spec.".
connect(Config, Extra) ->
    Transport = proplists:get_value(transport, Config),
    {ok, Conn} = bondy_connect_client:connect(
        spec(Transport, Config, Extra)
    ),
    Conn.

-doc """
The test CA bundle, resolved absolutely.

Called from `init_per_suite`, where the cwd is still the project root, so the
path stays valid after any later cwd change.
""".
cacertfile() ->
    File = filename:absname("./etc/ssl/server/cacert.pem"),
    true = filelib:is_regular(File),
    File.

-doc "A callee handler echoing its positional arguments back to the caller.".
echo_handler() ->
    fun(Args, _, _) -> {ok, #{args => Args}} end.

-doc "A subscriber handler forwarding each event's arguments to `Pid`.".
event_handler(Pid) ->
    fun(Args, _, _) ->
        Pid ! {event, Args},
        ok
    end.

-doc "Discard any events already delivered to this process.".
drain_events() ->
    receive
        {event, _} -> drain_events()
    after 0 -> ok
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private Every session in a realm, drained across the match's pages.
sessions(RealmUri) ->
    collect(bondy_session:match(#{realm_uri => RealmUri}, #{return => object})).

%% @private `'$end_of_table'` spelled out rather than pulled in as `?EOT` from
%% `bondy_router/include/bondy_db_tables.hrl`: that header is private to the
%% router app, and including router headers here is how this module would start
%% colliding with `bondy_connect.hrl` over shared macro names.
collect('$end_of_table') ->
    [];
collect(L) when is_list(L) ->
    L;
collect({L, '$end_of_table'}) ->
    L;
collect({L, Cont}) ->
    L ++ collect(bondy_session:match(Cont)).

%% @private
add_cra_realm(RealmUri) ->
    create(#{
        uri => RealmUri,
        authmethods => [?WAMP_CRA_AUTH],
        security_enabled => true,
        grants => [grant(<<"all">>)],
        users => [
            #{
                username => user(),
                password => password(),
                groups => [],
                meta => #{}
            }
        ],
        sources => [source([user()], ?WAMP_CRA_AUTH)]
    }).

%% @private
add_cryptosign_realm(RealmUri, PubKey) ->
    create(#{
        uri => RealmUri,
        authmethods => [?WAMP_CRYPTOSIGN_AUTH],
        security_enabled => true,
        grants => [grant(<<"all">>)],
        users => [
            #{
                username => user(),
                authorized_keys => [PubKey],
                groups => [],
                meta => #{}
            }
        ],
        sources => [source([user()], ?WAMP_CRYPTOSIGN_AUTH)]
    }).

%% @private A ticket realm is the one that cannot offer a single authmethod:
%% the ticket has to be issued by an already-authenticated session, so the realm
%% must also accept the method that issues it. `issue_ticket/1' builds that
%% session directly rather than dialling, so no case ever authenticates here
%% with `wampcra' -- the method under test remains the only one used over the
%% wire.
%%
%% `[security, ticket, authmethods]' is node-global, not per-realm: it is the
%% set of methods a session may have used to be allowed to issue at all.
add_ticket_realm(RealmUri) ->
    ok = bondy_config:set(
        [security, ticket, authmethods],
        [<<"wampcra">>, <<"password">>, <<"ticket">>, <<"cryptosign">>]
    ),
    create(#{
        uri => RealmUri,
        authmethods => [?WAMP_CRA_AUTH, ?WAMP_TICKET_AUTH],
        security_enabled => true,
        grants => [
            grant(<<"all">>),
            #{
                permissions => [<<"bondy.issue">>],
                resources => [
                    #{
                        uri => <<"bondy.ticket.scope.local">>,
                        match => <<"exact">>
                    }
                ],
                roles => <<"all">>
            }
        ],
        users => [
            #{
                username => user(),
                password => password(),
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            source([user()], ?WAMP_CRA_AUTH),
            source([user()], ?WAMP_TICKET_AUTH)
        ]
    }).

%% @private Every WAMP permission Bondy enforces, over every URI.
%%
%% The seven were derived by grepping the `bondy_rbac:authorize/3' call sites
%% rather than taken from the `?WAMP_PERMISSIONS' macro in
%% `bondy_security.hrl': that macro is unused by `src' and lists three
%% `disclose_*' entries no `authorize/3' call ever checks, so it would grant
%% more than exists while still being able to omit something real.
%%
%% Grants are validated only as loose URIs, so an under-grant is not reported
%% at create time -- it surfaces much later as `wamp.error.not_authorized' from
%% the operation itself. `wamp.cancel' is the one most easily missed, being its
%% own permission distinct from `wamp.call'.
grant(Roles) ->
    #{
        permissions => [
            <<"wamp.register">>,
            <<"wamp.unregister">>,
            <<"wamp.call">>,
            <<"wamp.cancel">>,
            <<"wamp.subscribe">>,
            <<"wamp.unsubscribe">>,
            <<"wamp.publish">>
        ],
        uri => <<"">>,
        match => <<"prefix">>,
        roles => Roles
    }.

%% @private
source(Usernames, AuthMethod) ->
    #{
        usernames => Usernames,
        authmethod => AuthMethod,
        cidr => <<"0.0.0.0/0">>
    }.

%% @private Realm creation is idempotent across groups only in the sense that
%% the second call returns the existing realm; the result is discarded either
%% way.
create(Cfg) ->
    _ = bondy_realm:create(Cfg),
    ok.

%% @private The transport-specific half of a spec: the name, where to dial, and
%% the one option the TLS and in-VM transports need.
endpoint(tcp, _Config) ->
    #{transport => tcp, endpoint => {?HOST, ?PORT_TCP}};
endpoint(tls, Config) ->
    #{
        transport => tls,
        endpoint => {?HOST, ?PORT_TLS},
        tls => tls_opts(Config)
    };
endpoint(uds, _Config) ->
    {ok, #{bind := {path, Path}}} = bondy_listener_manager:listener(wamp_uds),
    #{transport => uds, endpoint => {local, Path}};
endpoint(local, _Config) ->
    #{transport => local, endpoint => local};
endpoint(ws, _Config) ->
    #{transport => ws, endpoint => {?HOST, ?PORT_HTTP}};
endpoint(wss, Config) ->
    #{
        transport => wss,
        endpoint => {?HOST, ?PORT_HTTPS},
        tls => tls_opts(Config)
    };
endpoint(longpoll, _Config) ->
    #{transport => longpoll, endpoint => {?HOST, ?PORT_HTTP}};
endpoint(sse, _Config) ->
    #{transport => sse, endpoint => {?HOST, ?PORT_HTTP}}.

%% @private Validate the server's chain against the test CA. Hostname checking
%% is off because the server cert's SAN is `host.example.com', not the dialed
%% loopback address.
tls_opts(Config) ->
    #{
        verify => verify_peer,
        cacertfile => proplists:get_value(cacertfile, Config),
        server_name_indication => disable
    }.
