%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_sre_overlay).

-moduledoc """
The MCP overlay document that exposes the alarm and task subsystem to an SRE
agent (design §7.5, §9.4; MCP-D32).

One document, `bondy_sre_read`: the six read procedures of the alarm and task
APIs as **tools**, and the three alarm topics as **resources**. It names the
master realm, because that is the only realm those procedures answer in (D4).

Bondy SHIPS it and does not load it. `mcp.manifest.mode` defaults to
`curated`, so a node exposes no `bondy.*` procedure over MCP until an operator
loads a document, and loading is the operator's deliberate act — the posture
MCP-D31 rests on. `bondy.mcp.overlay.suggested` hands the operator this
document; `bondy.mcp.overlay.load` is what puts it into effect.

## Why there is no shipped ACTION document (MCP-D32)

An earlier build of this module also shipped `bondy_sre_tasks`, one tool per
`bondy_task_catalogue` entry. It was withdrawn before release, and the reason
is worth reading before anyone adds it back.

MCP-D14 makes it a BOOT ERROR for one listener to carry both `mcp` and
`admin_api`, because putting an agent-driven surface on the socket that
administers realms, users and grants is one misconfiguration away from the
wrong audience. A shipped task document reaches that same audience by a route
D14 does not watch: the realm is a path segment, not a listener property
(`bondy_mcp_http_service`), so one MCP listener serves every realm a principal
can authenticate into — the master realm included. The guard never fires,
because nothing has declared `admin_api`.

Three things make that worse than an ordinary privilege question:

- **A tool description is prompt.** Everything in `tools/list` enters a
  model's context. §23's own Q5 already records that a rewritten tool
  description is "a prompt-injection vector rather than a cosmetic problem"
  for an agent-facing surface. An action tool turns every document the agent
  reads into an argument about whether to run it.
- **RBAC would be the only control.** D14's value is that a socket boundary
  does not depend on a grant having been written correctly. §6 and §7.4 rule
  the listener out as an authorization dimension, so the action surface cannot
  have that second control — where the shipped read surface does not need one.
- **The failure modes are asymmetric**, the same asymmetry that made `curated`
  the default. Loading a read document and finding it dull costs an afternoon.
  Loading a shipped action document to see what it does, on a cluster where an
  agent already holds broad grants, is an incident.

So the exposure decision stays with the operator, exactly as the grants do
(§9.4). An agent using this document still plans: `bondy.task.catalogue` tells
it which procedures are sanctioned, what each one's `impact` and
`blast_radius` are, and which arguments each takes, so it can RECOMMEND a
remediation with its consequence stated. Executing it is a human's call, or an
overlay document that operator wrote and can name in a change record.
""".

-include_lib("bondy_router/include/bondy.hrl").
-include_lib("bondy_router/include/bondy_uris.hrl").

-define(READ_ID, ~"bondy_sre_read").
-define(VSN, ~"1.0.0").

-export([documents/0]).
-export([read_document/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Every overlay document Bondy ships, in the shape `bondy.mcp.overlay.suggested`
answers with. A list of one today; the wire shape is a list so that stays true
if a second is ever sanctioned.
""".
-spec documents() -> [map()].

documents() ->
    [read_document()].

-doc """
The read-side overlay document: the alarm and task read APIs as tools, and the
three alarm topics as resources.
""".
-spec read_document() -> map().

read_document() ->
    #{
        ~"id" => ?READ_ID,
        ~"version" => ?VSN,
        ~"entries" =>
            [read_tool(T) || T <- read_tools()] ++
            [read_resource(R) || R <- read_resources()]
    }.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% `{Uri, Args, Kwargs, Description}` — `Args` is one schema per POSITIONAL
%% argument, so `[]` is a procedure taking none; `Kwargs` is the whole KWArgs
%% object schema, or `undefined` for a procedure that takes none.
%%
%% The two are separate because MCP's `arguments` object is not: an agent's
%% `@args` key becomes the positional list and everything else becomes the
%% CALL's KWArgs (`bondy_mcp_wamp:call_args/1`), so a procedure's KWArgs are
%% reachable over MCP with no translation — but only if they are DECLARED,
%% because `tools/list` is the whole of what the agent knows.
read_tools() ->
    [
        {?BONDY_ALARM_LIST, [], undefined, <<
            "List the alarms raised across the cluster. The reply names which "
            "nodes answered and which were silent, so an empty list with a "
            "silent node is not the same answer as an empty list with none."
        >>},
        {?BONDY_ALARM_GET, [wire_alarm_id()], undefined, <<
            "Read one alarm by its wire id, with the trace of the occurrence "
            "that raised it when the raising path carried one."
        >>},
        %% FOUND 2026-09-01: this said "recorded on each node", which was
        %% false — the procedure answered for the serving node only. A tool
        %% description is prompt, so an agent believed it had a cluster-wide
        %% view and would have read a short history as "nothing happened
        %% elsewhere". The procedure is now a cluster-wide paginated walk, and
        %% the description says what a page actually is.
        {?BONDY_ALARM_HISTORY, [], history_kwargs(), <<
            "The most recent alarm transitions, newest first. A restatement "
            "of an alarm already raised is not a transition, so a condition "
            "that has been true for hours appears once. Each transition names "
            "the node that recorded it.\n\n"
            "This is ONE PAGE of a cluster-wide walk that takes the serving "
            "node's transitions first and reaches its peers only if that "
            "node's ring does not fill the page. So a busy node can crowd a "
            "quiet peer out of the page: the absence of a node here is not "
            "evidence that nothing happened on it — the walk may not have "
            "got to that node yet. Use bondy.alarm.list for a cluster-wide "
            "answer in a single reply.\n\n"
            "Every page carries `not_reached`: the nodes this walk ASKED for "
            "history and did not hear from. Read it before you read "
            "`values`, because a page that is short because a node was "
            "unreachable is not the same answer as a page that is short. It "
            "accumulates across pages, so the last page of a walk names "
            "every node the walk missed.\n\n"
            "Page with `limit` and `cursor`: a reply carrying `has_more` true "
            "has a `cursor` to send back for the next page. A page is bounded "
            "in time as well as in size, so a page that stops early is "
            "resumed with its `cursor` rather than retried."
        >>},
        {?BONDY_ALARM_CATALOGUE, [], undefined, <<
            "Every alarm condition this build can raise, with its severity, "
            "whether it affects readiness, what to observe and the "
            "tasks sanctioned against it."
        >>},
        {?BONDY_TASK_CATALOGUE, [], undefined, <<
            "Every procedure sanctioned as an operational task, with its "
            "impact, blast radius and arguments, and the ordered "
            "vocabularies those grade against. Read this to RECOMMEND a "
            "remediation; running one is not part of this surface."
        >>},
        {?BONDY_TASK_DESCRIBE, [task_uri()], undefined, <<
            "Whether one procedure is a sanctioned task, and its catalogue "
            "entry if so. An uncatalogued procedure answers with an empty "
            "list rather than an error."
        >>}
    ].

%% @private
%% The alarm topics (D4: published in the master realm). A resource entry
%% binds a TOPIC, which is what makes these resources where the read
%% procedures above are tools.
read_resources() ->
    [
        {?BONDY_ALARM_RAISED, <<
            "Published when an alarm not currently raised is raised."
        >>},
        {?BONDY_ALARM_UPDATED, <<
            "Published when a raised alarm's content changes. A producer "
            "restating an unchanged alarm publishes nothing."
        >>},
        {?BONDY_ALARM_CLEARED, <<
            "Published when a raised alarm is cleared."
        >>}
    ].

%% @private
%% The MCP name is the procedure URI itself, the same rule `derived` mode
%% uses. An alias would be a second name for one thing, and the agent reading
%% `bondy.task.catalogue` would have to translate between them.
%%
%% Every entry here is read-only, so the three derivable `ToolAnnotations`
%% hints are constant across the set rather than derived from anything.
read_tool({Uri, Args, Kwargs, Description}) ->
    Entry = #{
        ~"realm" => ?MASTER_REALM_URI,
        ~"name" => Uri,
        ~"kind" => ~"tool",
        ~"wamp_procedure" => Uri,
        ~"description" => Description,
        ~"annotations" => #{
            ~"read_only_hint" => true,
            ~"destructive_hint" => false,
            ~"idempotent_hint" => true
        }
    },
    maybe_kwargs(maybe_args(Entry, Args), Kwargs).

%% @private
read_resource({Topic, Description}) ->
    #{
        ~"realm" => ?MASTER_REALM_URI,
        ~"name" => Topic,
        ~"kind" => ~"resource",
        ~"wamp_topic" => Topic,
        ~"description" => Description
    }.

%% @private
%% A procedure taking no positional arguments declares no `args_schema` at
%% all: an empty tuple schema would say "send `@args: []`", and the agent's
%% call is simpler and equally correct without it.
%%
%% Bondy does NOT validate a call against this schema — no code in
%% `bondy_mcp_http_handler` reads `inputSchema` — so it is a description for
%% the agent. Its LENGTH is checked by calling the procedure
%% (`bondy_mcp_gateway_SUITE:sre_read_entries_call_their_procedures`).
maybe_args(Entry, []) ->
    Entry;
maybe_args(Entry, Items) ->
    N = length(Items),
    Entry#{
        ~"args_schema" => #{
            ~"type" => ~"array",
            %% JSON Schema 2020-12 tuple validation, MCP's dialect.
            ~"prefixItems" => Items,
            ~"minItems" => N,
            ~"maxItems" => N
        }
    }.

%% @private
maybe_kwargs(Entry, undefined) ->
    Entry;
maybe_kwargs(Entry, Schema) ->
    Entry#{~"kwargs_schema" => Schema}.

%% @private
%% `bondy.alarm.history` is paginated, and its knobs are KWARGS rather than
%% CALL options: the option form was removed on 2026-09-01 because it never
%% reached a callee at all (`bondy_wamp_api_utils:page_limit/3`). That change
%% is what makes them declarable here — an agent cannot set a CALL option, but
%% every non-`@args` key of its `arguments` object lands in KWArgs.
%%
%% The bounds are READ from the procedure rather than restated, so a schema
%% that disagrees with the clamp is not expressible.
history_kwargs() ->
    #{
        ~"type" => ~"object",
        ~"properties" => #{
            ~"limit" => #{
                ~"type" => ~"integer",
                ~"minimum" => 1,
                ~"maximum" => bondy_alarm_api:history_page_max(),
                ~"description" => <<
                    "How many transitions to return. Out of range or absent "
                    "means ",
                    (integer_to_binary(
                        bondy_alarm_api:history_page_default()
                    ))/binary,
                    "."
                >>
            },
            ~"cursor" => #{
                ~"type" => ~"string",
                ~"description" => <<
                    "The `cursor` of the page before this one. Absent starts "
                    "a new walk. A cursor minted by anything else, or by an "
                    "older release, is REFUSED rather than resumed from the "
                    "wrong position."
                >>
            }
        }
    }.

%% @private
%% An alarm id is an Erlang term rendered for the wire: an atom id becomes a
%% string, a tuple id becomes a list of strings
%% (`bondy_alarm_api:wire_id/1`).
wire_alarm_id() ->
    #{
        ~"description" =>
            ~"An alarm's wire id, as `bondy.alarm.list` renders it.",
        ~"oneOf" => [
            #{~"type" => ~"string"},
            #{~"type" => ~"array", ~"items" => #{~"type" => ~"string"}}
        ]
    }.

%% @private
task_uri() ->
    #{
        ~"type" => ~"string",
        ~"description" => ~"The procedure URI to look up."
    }.
