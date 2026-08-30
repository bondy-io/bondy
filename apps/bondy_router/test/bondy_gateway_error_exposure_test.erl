%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_gateway_error_exposure_test).

-moduledoc """
The publish-time lint on API Gateway response bodies
(`bondy_http_gateway_api_spec_parser:lint_response_exposure/3`).

The hazard is not a malicious specification author — publishing a
specification is control-plane authority already. It is an author DEBUGGING:
`{{action.error}}` is the obvious way to see why an endpoint is failing, it
works, and it survives into production because nothing objects. So what is
tested here is that the reference is RECOGNISED, and — just as important —
that the narrowed forms an author should be using are not, because a lint that
fires on the correct spelling is one people learn to ignore.

The lint reads the author's raw text, BEFORE `mops_eval/2`: an expression that
cannot be resolved at spec time comes back a proxy fun, and a fun cannot be
read.
""".

-include_lib("eunit/include/eunit.hrl").

%% The reference the lint exists for: the whole upstream error map, which
%% carries the WAMP error URI, args and kwargs — or, on a forward action, an
%% upstream service's own response body.
whole_error_map_is_flagged_test() ->
    ?assertEqual(
        [~"action.error"],
        refs(<<"on_error">>, #{~"body" => ~"{{action.error}}"})
    ).

%% The falsifier for the case above, and the more important half: an author who
%% picked ONE field chose what to expose, which is the behaviour the lint is
%% trying to produce. Flagging this too would make the warning noise.
narrowed_error_reference_is_not_flagged_test() ->
    ?assertEqual(
        [],
        refs(<<"on_error">>, #{~"body" => ~"{{action.error.message}}"})
    ),
    ?assertEqual(
        [], refs(<<"on_error">>, #{~"body" => ~"{{action.error.id}}"})
    ).

%% `security` carries the caller's `authid`, `groups` and `meta`. Narrowing
%% does not help here — every leaf is the principal — so any reference counts,
%% on either response.
security_is_flagged_on_both_responses_test() ->
    ?assertEqual(
        [~"security"],
        refs(<<"on_error">>, #{~"body" => ~"{{security.authid}}"})
    ),
    ?assertEqual(
        [~"security"],
        refs(<<"on_result">>, #{~"body" => ~"{{security.groups}}"})
    ).

%% `action.error` is meaningless in an `on_result` body, so it is not linted
%% there. Without this the two responses would be indistinguishable and the
%% `Which` argument would be dead.
whole_error_map_is_not_flagged_on_a_result_test() ->
    ?assertEqual(
        [], refs(<<"on_result">>, #{~"body" => ~"{{action.error}}"})
    ).

%% Only inside `{{ }}`. A body that MENTIONS security in prose is not exposing
%% anything, and a lint that cannot tell the difference gets switched off.
prose_is_not_an_expression_test() ->
    ?assertEqual(
        [],
        refs(<<"on_error">>, #{
            ~"body" => ~"Contact security@example.com about this error"
        })
    ).

%% Response bodies are not always a flat binary — a JSON body is a map, and
%% mops expressions sit at its leaves. A walk that only looked at the top level
%% would pass every realistic specification.
nested_bodies_are_walked_test() ->
    Body = #{
        ~"status" => ~"failed",
        ~"detail" => [~"see:", #{~"raw" => ~"{{action.error}}"}]
    },
    ?assertEqual([~"action.error"], refs(<<"on_error">>, #{~"body" => Body})).

%% The shipped default. A specification that says nothing about errors returns
%% an empty body and must never be warned about — otherwise every API in the
%% tree warns and the signal is gone.
the_default_response_is_clean_test() ->
    ?assertEqual(
        [],
        refs(<<"on_error">>, #{
            ~"headers" => ~"{{defaults.headers}}", ~"body" => <<>>
        })
    ).

%% =============================================================================
%% THE CORRELATION ID
%% =============================================================================

%% The alternative the lint points authors at. `{{action.error.id}}` has to
%% BE something before telling anyone to render it, and before this the error
%% path logged nothing at all — the only way to see why an endpoint was failing
%% was to put the error itself in the response.
the_error_carries_the_request_id_test() ->
    Ctxt = bondy_http_gateway_rest_handler:update_context(
        {error, #{~"status_code" => 500, ~"uri" => ~"com.example.boom"}},
        ctxt(~"req-abc-123")
    ),
    #{~"action" := #{~"error" := Error}} = Ctxt,
    ?assertEqual(~"req-abc-123", maps:get(~"id", Error)).

%% The SAME id the request carries, not a second one minted here: a response,
%% the log record and the request's trace have to name one thing for the id to
%% be traceable at all.
the_error_id_is_not_a_new_identifier_test() ->
    Ctxt0 = ctxt(~"req-abc-123"),
    Ctxt = bondy_http_gateway_rest_handler:update_context(
        {error, #{~"status_code" => 400}}, Ctxt0
    ),
    #{~"action" := #{~"error" := Error}} = Ctxt,
    ?assertEqual(
        maps_utils:get_path([~"request", ~"id"], Ctxt0),
        maps:get(~"id", Error)
    ).

%% The error the upstream produced is otherwise untouched: the lint's advice is
%% to render the id INSTEAD of the map, not to render a map that has quietly
%% lost fields.
the_upstream_error_is_not_narrowed_test() ->
    Upstream = #{
        ~"status_code" => 500,
        ~"uri" => ~"com.example.boom",
        ~"kwargs" => #{~"detail" => ~"connection refused"}
    },
    Ctxt = bondy_http_gateway_rest_handler:update_context(
        {error, Upstream}, ctxt(~"req-1")
    ),
    #{~"action" := #{~"error" := Error}} = Ctxt,
    ?assertEqual(Upstream, maps:remove(~"id", Error)).

%% @private
ctxt(Id) ->
    #{
        ~"request" => #{
            ~"id" => Id,
            ~"method" => ~"GET",
            ~"path" => ~"/things",
            ~"peername" => ~"127.0.0.1:1234"
        }
    }.

%% @private
%% Reaches the private lint through the same path the parser takes. The
%% assertion is on the REFERENCES rather than on the log record: the record is
%% a `?LOG_WARNING` and capturing it would test the logger, not the rule.
refs(Which, Spec) ->
    lists:usort([
        R
     || Expr <- bondy_http_gateway_api_spec_parser:mops_expressions(Spec),
        R <- bondy_http_gateway_api_spec_parser:exposing_refs(Which, Expr)
    ]).
