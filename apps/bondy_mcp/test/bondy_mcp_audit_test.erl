%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Falsifiers for the §14 audit capture seam:
%%
%% - the v1 record schema is TOTAL — every §14.1 field plus §14.2's
%%   `derivation`/`obligation`/`agent`/`delegation` present on every record
%%   (the MCP-D07 pin: the shape must not change when those populate);
%% - §14.3 redaction at capture: a redacted field influences nothing the
%%   digest captures, in both directions;
%% - `record/2` emits the constructed record in the metadata of
%%   `[bondy, mcp, audit, record]` — the attachment point the future
%%   Streams sink rides (MCP-D27) — and is fail-open: a construction
%%   failure returns an error and emits nothing, it never raises.
-module(bondy_mcp_audit_test).

-include_lib("eunit/include/eunit.hrl").

-define(REALM, <<"com.test.audit">>).
-define(EVENT, [bondy, mcp, audit, record]).

fields() ->
    #{
        realm => ?REALM,
        listener => test_listener,
        transport => tcp,
        principal => <<"alice">>,
        status => success
    }.

schema_is_total_test() ->
    ok = ensure_node(),
    R = bondy_mcp_audit:new(tool_call, fields()),
    ?assertEqual(
        lists:sort([
            v,
            timestamp,
            node,
            type,
            realm,
            listener,
            transport,
            principal,
            is_anonymous,
            agent,
            delegation,
            name,
            uri,
            procedure,
            entry_hash,
            args_digest,
            result_digest,
            redaction,
            decision,
            derivation,
            obligation,
            session_id,
            continuation,
            wamp_request_id,
            status,
            error_uri
        ]),
        lists:sort(maps:keys(R))
    ),
    %% The forward-compatible fields exist and are empty — nothing
    %% populates them yet, and the schema must not change when it does.
    ?assertEqual(undefined, maps:get(agent, R)),
    ?assertEqual([], maps:get(delegation, R)),
    ?assertEqual(undefined, maps:get(derivation, R)),
    ?assertEqual(undefined, maps:get(obligation, R)),
    ?assertEqual(1, maps:get(v, R)).

redaction_digest_test() ->
    ok = ensure_node(),
    Full = #{<<"customer">> => <<"x">>, <<"ssn">> => <<"123-45-6789">>},
    Policy = #{fields => [<<"ssn">>]},
    %% A redacted field influences NOTHING captured: the digest equals the
    %% digest of a payload that never carried the field at all...
    ?assertEqual(
        bondy_mcp_audit:digest(#{<<"customer">> => <<"x">>}, none),
        bondy_mcp_audit:digest(Full, Policy)
    ),
    %% ...and differs from the unredacted digest, so the policy really
    %% applied.
    ?assertNotEqual(
        bondy_mcp_audit:digest(Full, none),
        bondy_mcp_audit:digest(Full, Policy)
    ),
    ?assertEqual(undefined, bondy_mcp_audit:digest(undefined, none)).

emission_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    ok = ensure_node(),
    Self = self(),
    Id = {?MODULE, make_ref()},
    ok = telemetry:attach(
        Id,
        ?EVENT,
        fun(?EVENT, Meas, Meta, _) -> Self ! {audit, Meas, Meta} end,
        undefined
    ),
    try
        ok = bondy_mcp_audit:record(tool_call, (fields())#{
            name => <<"t">>,
            args_payload => #{<<"a">> => 1}
        }),
        Record =
            receive
                {audit, #{count := 1}, #{record := R}} -> R
            after 1000 -> error(no_emission)
            end,
        ?assertEqual(tool_call, maps:get(type, Record)),
        ?assertEqual(?REALM, maps:get(realm, Record)),
        %% The payload was digested at capture, never shipped.
        ?assertEqual(
            bondy_mcp_audit:digest(#{<<"a">> => 1}, none),
            maps:get(args_digest, Record)
        ),
        ?assertNot(maps:is_key(args_payload, Record)),

        %% Fail-open: a required field missing is a caller bug, reported
        %% as an error and emitting nothing — never raised into the MCP
        %% response path.
        ?assertMatch(
            {error, _},
            bondy_mcp_audit:record(tool_call, #{realm => ?REALM})
        ),
        receive
            {audit, _, _} = Unexpected -> error({emitted, Unexpected})
        after 100 -> ok
        end
    after
        telemetry:detach(Id)
    end.

ensure_node() ->
    bondy_config:set(nodestring, <<"eunit@nohost">>).
