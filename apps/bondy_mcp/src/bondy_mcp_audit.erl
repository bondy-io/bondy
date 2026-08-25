%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_audit).

-moduledoc """
Audit record construction and emission (design §14).

One record per tool call, resource read, policy decision and upstream
call, in the fixed v1 shape of `t/0`. Every key is always present
(`undefined` when it does not apply): the record schema is the §14.2
forward-compatibility contract, so `agent`, `delegation`, `derivation`
and `obligation` exist from the first release even though nothing
populates them yet.

## Capture (pure)

`new/2` builds a record at the call site. Argument and result payloads
are handed in as `args_payload` / `result_payload` and NEVER stored: they
are reduced to SHA-256 digests here, after the entry's redaction policy
(§14.3) has removed its declared top-level fields — so a redacted field
influences nothing that is captured, and a digest cannot be used to
confirm a guessed low-entropy value of one. The record carries the policy
that applied, inline.

Digests use `term_to_binary/2` with `deterministic` (the same canonical
byte form as `bondy_mcp_spec:hash/1`): reproducible by anyone holding the
original payload and the same OTP release; an OTP major upgrade may
re-key them, which surfaces as a comparison boundary, never as silent
acceptance.

## Emission

`record/2` constructs the record and emits it in the metadata of the
telemetry event `[bondy, mcp, audit, record]` — the attachment point for
an audit sink. This node persists nothing itself (MCP-D27): durable,
tamper-evident audit storage is Bondy Streams' job, and audit is planned
as its first producer; until that sink attaches, records are observable
to any attached telemetry handler and otherwise discarded.

Emission is fail-open: a construction failure is logged and returned to
the caller, and the MCP response proceeds — refusing service on audit
failure is a policy this module does not impose.
""".

-include_lib("kernel/include/logger.hrl").

-define(IS_TYPE(T),
    (T == tool_call orelse T == resource_read orelse T == policy_decision orelse
        T == upstream_call)
).

%% `upstream_call` is the client direction (§13): a projected procedure's
%% outbound `tools/call` against an upstream MCP server, its `derivation`
%% naming the shared service account the call rode (§13.1).
-type type() :: tool_call | resource_read | policy_decision | upstream_call.
-type status() ::
    success | tool_error | denied | internal_error | input_required.
-type redaction() :: none | #{fields := [binary()]}.
-type decision() :: #{
    verdict := allow | deny,
    rule := undefined | binary(),
    source := rbac | none
}.
-type t() :: #{
    v := 1,
    timestamp := integer(),
    node := binary(),
    type := type(),
    realm := binary(),
    listener := atom(),
    transport := atom(),
    principal := binary(),
    is_anonymous := boolean(),
    agent := undefined | binary(),
    delegation := [binary()],
    name := undefined | binary(),
    uri := undefined | binary(),
    procedure := undefined | binary(),
    entry_hash := undefined | binary(),
    args_digest := undefined | binary(),
    result_digest := undefined | binary(),
    redaction := redaction(),
    decision := decision(),
    derivation := undefined | map(),
    obligation := undefined | map(),
    session_id := undefined | binary() | integer(),
    continuation := undefined | binary(),
    wamp_request_id := undefined | integer(),
    status := status(),
    error_uri := undefined | binary()
}.

-export_type([t/0]).
-export_type([type/0]).
-export_type([redaction/0]).

-export([new/2]).
-export([digest/2]).
-export([record/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Builds an audit record of `Type` from `Fields`, applying the redaction
policy in `Fields` (`redaction`, default `none`) to the `args_payload` /
`result_payload` maps before digesting them. The payloads themselves do
not appear in the result. `realm`, `listener`, `transport`, `principal`
and `status` are required; every other field defaults.
""".
-spec new(type(), map()) -> t().

new(Type, Fields) when ?IS_TYPE(Type) ->
    Redaction = maps:get(redaction, Fields, none),
    #{
        v => 1,
        type => Type,
        timestamp => erlang:system_time(microsecond),
        node => bondy_config:nodestring(),
        realm => maps:get(realm, Fields),
        listener => maps:get(listener, Fields),
        transport => maps:get(transport, Fields),
        principal => maps:get(principal, Fields),
        is_anonymous => maps:get(is_anonymous, Fields, false),
        agent => maps:get(agent, Fields, undefined),
        delegation => maps:get(delegation, Fields, []),
        name => maps:get(name, Fields, undefined),
        uri => maps:get(uri, Fields, undefined),
        procedure => maps:get(procedure, Fields, undefined),
        entry_hash => maps:get(entry_hash, Fields, undefined),
        args_digest => digest(
            maps:get(args_payload, Fields, undefined), Redaction
        ),
        result_digest => digest(
            maps:get(result_payload, Fields, undefined), Redaction
        ),
        redaction => Redaction,
        decision => maps:get(decision, Fields, #{
            verdict => allow, rule => undefined, source => none
        }),
        derivation => maps:get(derivation, Fields, undefined),
        obligation => maps:get(obligation, Fields, undefined),
        session_id => maps:get(session_id, Fields, undefined),
        %% §11: the MRTR continuation id, shared by every audit record of
        %% one logical multi-round-trip call — the initial `input_required`
        %% leg and each resume — and by nothing else. `undefined` on a
        %% single-round-trip record.
        continuation => maps:get(continuation, Fields, undefined),
        wamp_request_id => maps:get(wamp_request_id, Fields, undefined),
        status => maps:get(status, Fields),
        error_uri => maps:get(error_uri, Fields, undefined)
    }.

-doc """
The digest of one flat payload map under a redaction policy: the policy's
top-level fields are removed, then the remainder is hashed to
`<<"sha256:...">>` (lowercase hex) over its deterministic external term
format. `undefined` payloads digest to `undefined` — nothing was
captured.
""".
-spec digest(undefined | map(), redaction()) -> undefined | binary().

digest(undefined, _) ->
    undefined;
digest(Payload, none) when is_map(Payload) ->
    sha256_hex(term_to_binary(Payload, [deterministic]));
digest(Payload, #{fields := Fields}) when is_map(Payload) ->
    sha256_hex(
        term_to_binary(maps:without(Fields, Payload), [deterministic])
    ).

-doc """
Constructs one audit record and emits it as the metadata of the
`[bondy, mcp, audit, record]` telemetry event. Fail-open: a construction
failure is logged and returned, never raised — see the moduledoc.
""".
-spec record(type(), map()) -> ok | {error, any()}.

record(Type, Fields) ->
    try new(Type, Fields) of
        Record ->
            telemetry:execute(
                [bondy, mcp, audit, record],
                #{count => 1},
                #{record => Record}
            )
    catch
        Class:Reason ->
            ?LOG_ERROR(#{
                description => "MCP audit record emission failed",
                class => Class,
                reason => Reason,
                type => Type
            }),
            {error, Reason}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
sha256_hex(Bin) ->
    <<"sha256:",
        (binary:encode_hex(crypto:hash(sha256, Bin), lowercase))/binary>>.
