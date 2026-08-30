%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_task_catalogue).

-moduledoc """
The declared table of **tasks**: the `bondy.*` admin procedures an operator —
human or agent — may be told to run in response to a condition, annotated with
the operational judgement no compiler can infer.

## Why this is code and not data

The design put this in the interface metadata store (`bondy_interface`), which
is loaded from operator- or CI-supplied documents. It lives here instead,
mirroring `bondy_alarm_catalogue`, for one reason: `impact` is a statement
about *Bondy's own* procedures. Whether `bondy.router.bridge.stop` interrupts
clients is not a judgement each operator should have to author, and a catalogue
that is empty on a fresh node cannot be the thing `bondy_alarm_catalogue`
joins against. Operator-declared tasks over an operator's OWN procedures are a
different mechanism and belong in the interface store when they arrive.

## What a task declares, and what it deliberately does not

Only what the code cannot say about itself. What a procedure *touches* — state,
IO, purity — is inference's job. What running it *does to a live system* is not
a property of the code at all, and that is this table's whole subject:

- **`impact`** — `benign | recoverable | disruptive | destructive`, a total
  order. `benign` = no client-visible change. `recoverable` = state changed and
  a named task restores it. `disruptive` = client-visible interruption, no data
  loss. `destructive` = possible data loss or no way back. An agent policy is
  written almost entirely as a bound on this field.
- **`blast_radius`** — `session | realm | node | cluster`. Orthogonal to
  `impact`: stopping a bridge is recoverable *and* cluster-visible.
- **`idempotent`** — may this be retried after a timeout? `true` is a CLAIM and
  is only written where a test pins it; `false` means "not declared safe", not
  "declared unsafe". Read it that way — the field exists so an agent that has
  timed out knows whether retrying is sanctioned, and an unpinned `true` is
  exactly the sanction nobody checked.
- **`args`** — one JSON Schema per positional argument, in order. It is what
  `bondy.task.catalogue` returns, and it is the difference between an agent
  that can RECOMMEND a remediation and one that can only name it: no shipped
  MCP overlay exposes these procedures as tools (MCP-D32), so the catalogue is
  the whole planning surface. Only the LIST LENGTH is verified —
  `bondy_task_catalogue_test:argument_counts_match_the_handlers` reads the
  arity each handler validates out of the compiled abstract code — so the
  schemas themselves are documentation for the caller. Nothing in Bondy
  validates a call against them.
- **`reverses`** — the task that undoes this one. Checked to be catalogued.
- **`observe_with`** — where to look to see whether the task took effect: a
  read-only `bondy.*` procedure, or a metric name. It says where to look, not
  what to expect; stating what to expect needs a condition language, which is a
  separate mechanism.

  `bondy_alarm_catalogue` carries a field of the same name and the same
  `#{kind, ref}` shape, for the same reason — one word for one concept. The
  entry type supplies the difference: on an alarm you observe the CONDITION, on
  a task you observe its EFFECT.

**`rbac_permission` is deliberately absent.** Every CALL is authorized with
`bondy_rbac:authorize(<<"wamp.call">>, Uri, Ctxt)`
(`bondy_dealer.erl:962`), so the permission for a task is `wamp.call` on the
task's own `id` — derivable, uniformly. Declaring it per entry would be a
second source of truth that can only drift.

- **`dry_run`** — whether the procedure accepts `dry_run` in its KWArgs and
  replies with what it WOULD do. This is the one field the router itself reads:
  `bondy_wamp_api` refuses a `dry_run` call to a procedure that does not
  declare it here, so a caller can never silently perform an action it meant to
  simulate.

  `bondy.router.bridge.check_spec` is the older shape of the same idea — a
  separate procedure that validates without acting — and it is why
  `bondy.router.bridge.add` now declares `dry_run` too: two idioms for "what
  would this do" is one too many, and the KWArg is the one that generalises.
  `check_spec` is a published procedure and is not being withdrawn; it parses a
  specification, where the `add` dry run also checks the options and the name.
  New procedures use `dry_run`.

## Coverage is deliberately partial

Unlike `bondy_alarm_catalogue`, this table does NOT cover everything it could.
It carries the incident-response families; the security and identity families
(`user`, `group`, `grant`, `source`, `realm`, `oauth2`) are administration
rather than incident response, and their `impact` grades are security
judgements to be made deliberately rather than in bulk.

What `bondy_task_catalogue_test` enforces instead:

- every `id` names a procedure some `handle_call/3` clause actually matches,
  AND that is not one of the seven stubs that reply `no_such_procedure`;
- every `reverses` and `observe_with` URI is a real procedure, and `reverses`
  names a catalogued task;
- every procedure FAMILY is either represented here or listed in
  `out_of_scope/0` with a reason, so a NEW family cannot appear unnoticed.

It does not require every procedure of a covered family to be a task: a
read-only procedure is a signal, not a task.
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-type impact() :: benign | recoverable | disruptive | destructive.
-type blast_radius() :: session | realm | node | cluster.

-type entry() :: #{
    id := uri(),
    title := binary(),
    summary := binary(),
    impact := impact(),
    blast_radius := blast_radius(),
    idempotent := boolean(),
    dry_run := boolean(),
    args := [map()],
    observe_with := [bondy_alarm_catalogue:observe_ref()],
    reverses => uri()
}.

-export_type([entry/0, impact/0, blast_radius/0]).

-export([impacts/0]).
-export([supports_dry_run/1]).
-export([blast_radii/0]).
-export([list/0]).
-export([lookup/1]).
-export([out_of_scope/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
The `impact` vocabulary, weakest first. The order is total and is what an agent
policy compares against.
""".
-spec impacts() -> [impact()].

impacts() ->
    [benign, recoverable, disruptive, destructive].

-doc """
The `blast_radius` vocabulary, narrowest first.
""".
-spec blast_radii() -> [blast_radius()].

blast_radii() ->
    [session, realm, node, cluster].

-doc """
Every declared task, in id order.
""".
-spec list() -> [entry()].

list() ->
    [
        %% `bondy_listener_manager:suspend/1`: stops accepting NEW connections
        %% on a phase; established connections are unaffected. Disruptive
        %% rather than recoverable because a client trying to connect is
        %% refused, and `node` rather than `cluster` because a phase is this
        %% node's own listeners.
        %%
        %% `idempotent => false` is the absence of a claim, not a warning:
        %% `bondy_listener_api_SUITE` pins `resume_is_idempotent` and says in
        %% its own moduledoc which cases it does not cover — suspend is not
        %% among the pinned ones.
        #{
            id => ~"bondy.listener.suspend",
            title => ~"Suspend a listener phase",
            summary =>
                <<
                    "Stop accepting new connections on a phase's listeners. "
                    "Established connections keep running."
                >>,
            impact => disruptive,
            blast_radius => node,
            idempotent => false,
            dry_run => true,
            args => [
                #{
                    ~"type" => ~"string",
                    ~"enum" => [~"early", ~"normal", ~"all"],
                    ~"description" =>
                        ~"The listener phase to act on."
                }
            ],
            reverses => ~"bondy.listener.resume",
            %% No read procedure in this family reports listener state, so an
            %% agent cannot verify the suspend took effect from the WAMP API.
            observe_with => []
        },
        %% Idempotent is a real claim here: `ranch:resume_listener/1` answers
        %% `ok` for a listener that was never suspended, pinned by
        %% `bondy_listener_api_SUITE:resume_is_idempotent`.
        #{
            id => ~"bondy.listener.resume",
            title => ~"Resume a listener phase",
            summary =>
                <<
                    "Resume accepting new connections on a phase's listeners, "
                    "undoing a suspend."
                >>,
            impact => recoverable,
            blast_radius => node,
            idempotent => true,
            dry_run => true,
            args => [
                #{
                    ~"type" => ~"string",
                    ~"enum" => [~"early", ~"normal", ~"all"],
                    ~"description" =>
                        ~"The listener phase to act on."
                }
            ],
            reverses => ~"bondy.listener.suspend",
            observe_with => []
        },
        %% Validates a bridge specification and returns the parsed form
        %% WITHOUT touching the manager (`bondy_bridge_relay:new/1` only), so
        %% it is the one genuinely benign entry here and the existing shape of
        %% what a `dry_run` convention would generalise.
        #{
            id => ~"bondy.router.bridge.check_spec",
            title => ~"Validate a bridge specification",
            summary =>
                <<
                    "Parse and validate a bridge relay specification without "
                    "adding or starting anything."
                >>,
            impact => benign,
            blast_radius => node,
            idempotent => true,
            dry_run => false,
            args => [
                #{
                    ~"type" => ~"object",
                    ~"description" =>
                        ~"A bridge relay specification."
                }
            ],
            observe_with => []
        },
        #{
            id => ~"bondy.router.bridge.add",
            title => ~"Add a bridge relay",
            summary =>
                ~"Add a bridge relay to the manager, optionally starting it.",
            impact => recoverable,
            blast_radius => cluster,
            idempotent => false,
            dry_run => true,
            args => [
                #{
                    ~"type" => ~"object",
                    ~"description" =>
                        ~"A bridge relay specification."
                }
            ],
            reverses => ~"bondy.router.bridge.remove",
            observe_with => [
                #{kind => procedure, ref => ~"bondy.router.bridge.get"},
                #{kind => procedure, ref => ~"bondy.router.bridge.status"}
            ]
        },
        %% `recoverable` names the SHAPE of the reversal, not its cost: `add`
        %% restores the bridge, but only for a caller that still holds the
        %% specification. Removing a bridge whose spec exists nowhere else is
        %% not reversible, and that is the operator's to know.
        #{
            id => ~"bondy.router.bridge.remove",
            title => ~"Remove a bridge relay",
            summary =>
                <<
                    "Remove a bridge relay from the manager. The specification "
                    "is not retained."
                >>,
            impact => recoverable,
            blast_radius => cluster,
            idempotent => false,
            dry_run => false,
            args => [
                #{
                    ~"type" => ~"string",
                    ~"description" => ~"The bridge relay's name."
                }
            ],
            reverses => ~"bondy.router.bridge.add",
            observe_with => [
                #{kind => procedure, ref => ~"bondy.router.bridge.list"},
                #{kind => procedure, ref => ~"bondy.router.bridge.status"}
            ]
        },
        #{
            id => ~"bondy.router.bridge.start",
            title => ~"Start a bridge relay",
            summary => ~"Start an added bridge relay.",
            impact => recoverable,
            blast_radius => cluster,
            idempotent => false,
            dry_run => false,
            args => [
                #{
                    ~"type" => ~"string",
                    ~"description" => ~"The bridge relay's name."
                }
            ],
            reverses => ~"bondy.router.bridge.stop",
            observe_with => [
                #{kind => procedure, ref => ~"bondy.router.bridge.status"}
            ]
        },
        %% Cross-cluster routing over this bridge stops: calls and events that
        %% crossed it no longer arrive. No data is lost and `start` restores
        %% it, which is `disruptive` rather than `destructive`.
        #{
            id => ~"bondy.router.bridge.stop",
            title => ~"Stop a bridge relay",
            summary =>
                <<
                    "Stop a running bridge relay. Traffic that crossed it stops "
                    "being routed until it is started again."
                >>,
            impact => disruptive,
            blast_radius => cluster,
            idempotent => false,
            dry_run => false,
            args => [
                #{
                    ~"type" => ~"string",
                    ~"description" => ~"The bridge relay's name."
                }
            ],
            reverses => ~"bondy.router.bridge.start",
            observe_with => [
                #{kind => procedure, ref => ~"bondy.router.bridge.status"}
            ]
        },
        %% Loading REPLACES the document of the same id, so it can both add and
        %% withdraw tools an agent currently sees. `realm` because an overlay
        %% document's entries name their realm.
        #{
            id => ~"bondy.mcp.overlay.load",
            title => ~"Load an MCP overlay document",
            summary =>
                <<
                    "Load or replace an MCP overlay document, changing which "
                    "tools and resources the MCP manifest exposes."
                >>,
            impact => recoverable,
            blast_radius => realm,
            idempotent => true,
            dry_run => true,
            args => [
                #{
                    ~"type" => ~"object",
                    ~"description" =>
                        ~"An MCP overlay document."
                }
            ],
            reverses => ~"bondy.mcp.overlay.delete",
            observe_with => [
                #{kind => procedure, ref => ~"bondy.mcp.overlay.get"},
                #{kind => procedure, ref => ~"bondy.mcp.overlay.list"}
            ]
        },
        #{
            id => ~"bondy.mcp.overlay.delete",
            title => ~"Delete an MCP overlay document",
            summary =>
                <<
                    "Remove an MCP overlay document and every manifest entry it "
                    "declared."
                >>,
            impact => recoverable,
            blast_radius => realm,
            idempotent => false,
            dry_run => false,
            args => [
                #{
                    ~"type" => ~"string",
                    ~"description" =>
                        ~"The overlay document's id."
                }
            ],
            reverses => ~"bondy.mcp.overlay.load",
            observe_with => [
                #{kind => procedure, ref => ~"bondy.mcp.overlay.list"}
            ]
        },
        %% Changes nothing in Bondy — but it does send a real message to a real
        %% recipient, which is why the summary says so. `benign` is a statement
        %% about client-visible change, not about the world.
        #{
            id => ~"bondy.mail.test",
            title => ~"Send a test email through a relay",
            summary =>
                <<
                    "Send a test message through a realm's mail relay to a named "
                    "recipient. Changes no Bondy state; the recipient receives a "
                    "real email."
                >>,
            impact => benign,
            blast_radius => node,
            idempotent => true,
            dry_run => false,
            args => [
                #{
                    ~"type" => ~"string",
                    ~"description" =>
                        ~"The realm whose mail relay sends the message."
                },
                #{
                    ~"type" => ~"string",
                    ~"description" => ~"The recipient's email address."
                }
            ],
            observe_with => [
                #{kind => procedure, ref => ~"bondy.mail.status.get"},
                #{kind => procedure, ref => ~"bondy.mail.relay.list"}
            ]
        },
        %% The only `destructive` entry, and the grade is about what the
        %% removal RELEASES rather than about anything the call writes.
        %% Membership is the reclamation authority
        %% (`bondy_oplog_instance:reclamation_members/0`), so once a node is
        %% out, `bondy_oplog_origin_retirement` may reap its origins by
        %% complement — and a node rejoining under the same name is handed a
        %% NEW origin, its former frontier entries gone. There is no task that
        %% undoes that, which is why `reverses` is absent where the bridge and
        %% overlay pairs have one.
        #{
            id => ~"bondy.cluster.leave",
            title => ~"Remove a node from the cluster",
            summary =>
                <<
                    "Remove a node from the Partisan membership. The node "
                    "stops being counted for reclamation, its origins become "
                    "unclaimed, and a node rejoining under the same name is "
                    "handed a new origin."
                >>,
            impact => destructive,
            blast_radius => cluster,
            idempotent => false,
            dry_run => true,
            args => [
                #{
                    ~"type" => ~"string",
                    ~"description" =>
                        ~"The node to remove, as it appears in bondy.cluster.members."
                }
            ],
            observe_with => [
                #{kind => procedure, ref => ~"bondy.cluster.members"},
                #{kind => procedure, ref => ~"bondy.cluster.connections"}
            ]
        }
    ].

-doc """
Whether `Uri` accepts a `dry_run` KWArg.

Read by `bondy_wamp_api` before dispatch, which is what makes the convention
safe rather than merely available: a procedure that does not declare it refuses
a `dry_run` call instead of performing it. An uncatalogued procedure answers
`false` — a procedure nobody has declared cannot be assumed to simulate.
""".
-spec supports_dry_run(uri()) -> boolean().

supports_dry_run(Uri) ->
    case lookup(Uri) of
        {ok, #{dry_run := B}} -> B;
        error -> false
    end.

-doc """
The task declared for `Uri`, or `error`.
""".
-spec lookup(uri()) -> {ok, entry()} | error.

lookup(Uri) when is_binary(Uri) ->
    case [E || #{id := Id} = E <- list(), Id == Uri] of
        [Entry] -> {ok, Entry};
        [] -> error
    end.

-doc """
The procedure families this table deliberately does not cover, each with the
reason. `bondy_task_catalogue_test` asserts that every family in the dispatch
table is either represented in `list/0` or named here, so a new family forces a
decision rather than arriving uncatalogued.
""".
-spec out_of_scope() -> #{binary() => binary()}.

out_of_scope() ->
    #{
        ~"user" => ~"Identity administration, not incident response.",
        ~"group" => ~"Identity administration, not incident response.",
        ~"grant" => ~"Authorization administration, not incident response.",
        ~"source" => ~"Authentication administration, not incident response.",
        ~"realm" => ~"Tenant administration, not incident response.",
        ~"oauth2" => ~"Token administration, not incident response.",
        ~"rbac" => ~"Authorization administration, not incident response.",
        ~"ticket" =>
            <<
                "Delegation is issued by a human operator to an agent; an agent "
                "issuing its own tickets would defeat the delegation model."
            >>,
        ~"http_gateway" =>
            <<
                "Specification deployment is a release activity, not an incident "
                "response."
            >>,
        ~"interface" =>
            <<
                "Interface documents are a release activity, not an incident "
                "response."
            >>,
        ~"export" =>
            <<
                "Export and import move whole datasets; the impact grades want "
                "ruling deliberately rather than in bulk."
            >>,
        ~"backup" => ~"Deprecated alias for the export family.",
        ~"cert_manager" =>
            <<
                "TLS material rotation wants its own review before an agent is "
                "told it may do it."
            >>,
        ~"registration" => ~"Read-only registry reflection.",
        ~"subscription" => ~"Read-only registry reflection.",
        ~"session" => ~"Read-only session reflection.",
        ~"telemetry" => ~"Read-only, and its one procedure is a stub.",
        ~"alarm" => ~"Read-only alarm reflection.",
        ~"task" => ~"This catalogue's own read API.",
        ~"ping" => ~"Liveness probe."
    }.
