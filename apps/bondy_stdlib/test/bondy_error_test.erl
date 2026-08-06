%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_error_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% CATALOGUE
%% =============================================================================

%% Every type listed by types/0 must resolve to its own entry rather than
%% falling through to unknown_error, otherwise the list and the clauses have
%% drifted apart.
catalogue_is_total_test() ->
    Missing = [
        T
     || T <- bondy_error:types(),
        T =/= unknown_error,
        maps:get(uri, bondy_error:catalogue(T)) ==
            maps:get(uri, bondy_error:catalogue(unknown_error))
    ],
    ?assertEqual([], Missing).

%% The handle is what an operator quotes when reporting a problem, so two error
%% types sharing one is a defect.
handles_are_unique_test() ->
    Handles = [maps:get(handle, bondy_error:catalogue(T)) || T <- bondy_error:types()],
    ?assertEqual(lists:sort(Handles), lists:usort(Handles)).

catalogue_fields_are_binaries_test() ->
    [
        begin
            E = bondy_error:catalogue(T),
            ?assert(is_binary(maps:get(uri, E))),
            ?assert(is_binary(maps:get(code, E))),
            ?assert(is_binary(maps:get(handle, E))),
            ?assert(is_binary(maps:get(message, E))),
            ?assert(is_binary(maps:get(description, E))),
            ?assert(lists:member(maps:get(nature, E), [transient, permanent]))
        end
     || T <- bondy_error:types()
    ].

%% Several types may share a URI, but the canonical one must round-trip.
canonical_uri_roundtrip_test() ->
    Bad = [
        {T, Uri, bondy_error:type_of_uri(Uri)}
     || T <- bondy_error:types(),
        #{uri := Uri, canonical := true} <- [bondy_error:catalogue(T)],
        bondy_error:type_of_uri(Uri) =/= T
    ],
    ?assertEqual([], Bad).

type_of_uri_unknown_test() ->
    ?assertEqual(undefined, bondy_error:type_of_uri(~"com.example.nope")).

%% POSIX errors are resolved from OTP's own table, not from a copy of it.
posix_types_resolve_test() ->
    E = bondy_error:catalogue(enoent),
    ?assertEqual(~"bondy.error.enoent", maps:get(uri, E)),
    ?assertEqual(~"no such file or directory", maps:get(message, E)).

non_posix_atom_falls_back_test() ->
    E = bondy_error:catalogue(definitely_not_an_error),
    ?assertEqual(~"bondy.error.unknown_error", maps:get(uri, E)).

%% =============================================================================
%% CONSTRUCTION
%% =============================================================================

new_produces_a_valid_error_test() ->
    ?assert(bondy_error:is_type(bondy_error:new(not_found))).

new_rejects_a_non_atom_type_test() ->
    ?assertError({badarg, {type, <<"nope">>}}, bondy_error:new(<<"nope">>, #{})).

%% causes used to be assigned the result of lists:all/2, i.e. a boolean, which
%% made every error fail its own is_type/1 check.
causes_round_trip_as_a_list_test() ->
    Cause = bondy_error:new(not_found),
    E = bondy_error:new(internal_error, #{causes => [Cause]}),
    ?assert(bondy_error:is_type(E)),
    ?assertMatch([_], maps:get(causes, E)),
    ?assert(bondy_error:is_type(hd(maps:get(causes, E)))).

wrap_prepends_a_cause_test() ->
    E0 = bondy_error:new(internal_error),
    E1 = bondy_error:wrap(E0, {no_such_realm, ~"com.a"}),
    ?assertMatch([#{type := no_such_realm}], maps:get(causes, E1)).

%% A cause given as a raw term is converted, so a chain is always well typed.
wrap_converts_a_raw_cause_test() ->
    E = bondy_error:wrap(bondy_error:new(internal_error), enoent),
    ?assert(lists:all(fun bondy_error:is_type/1, maps:get(causes, E))).

interpolates_details_into_the_description_test() ->
    E = bondy_error:new(missing_required_value, #{details => #{key => ~"match"}}),
    ?assertEqual(~"A value for 'match' is required.", maps:get(description, E)).

%% A missing substitution must be visible, not silently blanked.
leaves_an_unresolved_placeholder_test() ->
    E = bondy_error:new(missing_required_value, #{details => #{}}),
    ?assertEqual(~"A value for '%{key}' is required.", maps:get(description, E)).

%% =============================================================================
%% from_term/1
%% =============================================================================

%% Both of these crashed with function_clause in the previous implementation,
%% which had no binary() clause in its key formatter, and both are reachable
%% from bondy_rbac.
missing_required_value_with_a_binary_key_test() ->
    E = bondy_error:from_term({missing_required_value, ~"match"}),
    ?assertEqual(missing_required_value, maps:get(type, E)),
    ?assertEqual(~"A value for 'match' is required.", maps:get(description, E)).

inconsistency_error_with_binary_keys_test() ->
    E = bondy_error:from_term({inconsistency_error, [~"uri", ~"match"]}),
    ?assertEqual(inconsistency_error, maps:get(type, E)),
    ?assertEqual(
        ~"The values provided for the keys [uri, match] are inconsistent.",
        maps:get(description, E)
    ).

from_term_is_idempotent_test() ->
    E = bondy_error:new(not_found),
    ?assertEqual(E, bondy_error:from_term(E)).

from_term_unwraps_a_doubled_error_test() ->
    ?assertEqual(
        maps:get(type, bondy_error:from_term(not_found)),
        maps:get(type, bondy_error:from_term({error, not_found}))
    ).

from_term_maps_a_posix_atom_test() ->
    ?assertEqual(~"bondy.error.enoent", maps:get(uri, bondy_error:from_term(enoent))).

from_term_maps_a_known_uri_test() ->
    E = bondy_error:from_term(~"wamp.error.no_such_realm"),
    ?assertEqual(no_such_realm, maps:get(type, E)).

%% An unrecognised term must not reach a peer: it becomes an opaque internal
%% error whose raw form is confined to metadata.
from_term_redacts_an_unknown_term_test() ->
    Term = {badmatch, {secret, self()}},
    E = bondy_error:from_term(Term),
    ?assertEqual(internal_error, maps:get(type, E)),
    ?assertEqual(#{}, maps:get(details, E)),
    ?assertEqual(#{reason => Term}, maps:get(metadata, E)),
    ?assert(is_binary(maps:get(trace_id, E))),
    ?assertNot(maps:is_key(~"reason", bondy_error:to_map(E))).

%% A message we did not author cannot be vouched for, so an unknown tag is
%% reported as an internal error rather than echoed back.
from_term_does_not_echo_an_unknown_tag_test() ->
    E = bondy_error:from_term({some_unknown_tag, ~"leaky message"}),
    ?assertEqual(internal_error, maps:get(type, E)),
    ?assertNotEqual(~"leaky message", maps:get(message, E)).

from_term_accepts_a_known_tag_with_a_message_test() ->
    E = bondy_error:from_term({not_found, ~"No such widget."}),
    ?assertEqual(not_found, maps:get(type, E)),
    ?assertEqual(~"No such widget.", maps:get(message, E)).

from_exception_keeps_identity_and_adds_the_stacktrace_test() ->
    Stacktrace = [{m, f, 1, []}],
    E = bondy_error:from_exception(error, {no_such_realm, ~"com.a"}, Stacktrace),
    ?assertEqual(no_such_realm, maps:get(type, E)),
    ?assertEqual(
        #{class => error, stacktrace => Stacktrace}, maps:get(metadata, E)
    ).

%% =============================================================================
%% TRACE ID
%% =============================================================================

%% The trace_id is a W3C Trace Context `trace-id`: 16 bytes as 32 lowercase hex
%% characters, never all-zero. Keeping to that format is what lets Bondy hand
%% the identifier to an OpenTelemetry collector unchanged.
trace_id_is_a_w3c_trace_id_test() ->
    E = bondy_error:internal(error, {badmatch, x}, []),
    TraceId = maps:get(trace_id, E),

    ?assert(is_binary(TraceId)),
    ?assertEqual(32, byte_size(TraceId)),
    ?assertNotEqual(binary:copy(~"0", 32), TraceId),
    ?assert(
        lists:all(
            fun(C) ->
                (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f)
            end,
            binary_to_list(TraceId)
        )
    ).

%% Generated from a UUIDv7, so ids sort chronologically.
%%
%% The ordering is at MILLISECOND granularity: a UUIDv7's leading 48 bits are a
%% millisecond timestamp and everything after them is random, so two ids minted
%% within the same millisecond do NOT compare meaningfully. Only the timestamp
%% prefix - the first 12 hex characters - is ordered.
trace_ids_are_time_ordered_test() ->
    A = maps:get(trace_id, bondy_error:internal(error, a, [])),
    timer:sleep(2),
    B = maps:get(trace_id, bondy_error:internal(error, b, [])),
    ?assert(binary:part(A, 0, 12) < binary:part(B, 0, 12)).

%% internal/3 never adopts the exception's identity, even when from_term/1
%% would recognise the reason.
internal_is_always_opaque_test() ->
    E = bondy_error:internal(error, {no_such_realm, ~"com.a"}, []),
    ?assertEqual(internal_error, maps:get(type, E)),
    ?assertEqual(#{}, maps:get(details, E)),
    ?assertEqual({no_such_realm, ~"com.a"}, maps:get(reason, maps:get(metadata, E))).

%% =============================================================================
%% WIRE COMPATIBILITY
%% =============================================================================

%% These are the `code` values Bondy has emitted historically. Changing one
%% breaks every client that branches on it, so they are pinned here.
legacy_codes_test() ->
    Expected = [
        {{missing_required_value, ~"k"}, ~"missing_required_value"},
        {{invalid_value, ~"k", 1}, ~"invalid_value"},
        {{property_range_limit, ~"k", 3}, ~"property_range_limit"},
        {{inconsistency_error, [~"a", ~"b"]}, ~"invalid_argument"},
        {{no_such_realm, ~"com.a"}, ~"wamp.error.no_such_realm"},
        {{no_such_user, ~"alice"}, ~"wamp.error.no_such_principal"},
        {{badarg, {decoding, json}}, ~"invalid_data"},
        {{badarg, {body_max_bytes_exceeded, 1}}, ~"body_max_bytes_exceeded"},
        {{badarg, ~"nope"}, ~"invalid_argument"},
        {unavailable, ~"unavailable"},
        {too_many_results, ~"too_many_results"},
        {temporarily_unavailable, ~"temporarily_unavailable"},
        {unsupported_token_type, ~"unsupported_token_type"},
        {oauth2_invalid_request, ~"invalid_request"},
        {oauth2_invalid_client, ~"invalid_client"},
        {oauth2_invalid_grant, ~"invalid_grant"},
        {oauth2_unauthorized_client, ~"unauthorized_client"},
        {oauth2_unsupported_grant_type, ~"unsupported_grant_type"},
        {oauth2_invalid_scope, ~"invalid_scope"},
        {invalid_scheme, ~"invalid_client"}
    ],
    [
        ?assertEqual(
            Code, maps:get(~"code", bondy_error:to_map(bondy_error:from_term(Term)))
        )
     || {Term, Code} <- Expected
    ].

to_map_carries_the_documented_keys_test() ->
    Map = bondy_error:to_map(bondy_error:from_term({no_such_realm, ~"com.a"})),
    [
        ?assert(maps:is_key(K, Map))
     || K <- [
            ~"code",
            ~"message",
            ~"description",
            ~"uri",
            ~"handle",
            ~"nature",
            ~"details",
            ~"causes",
            ~"doc_uri"
        ]
    ],
    %% trace_id is present only when one was assigned.
    ?assertNot(maps:is_key(~"trace_id", Map)).

to_map_keys_are_all_binaries_test() ->
    Map = bondy_error:to_map(bondy_error:from_term({invalid_value, k, {a, b}})),
    ?assert(lists:all(fun is_binary/1, maps:keys(Map))),
    ?assert(lists:all(fun is_binary/1, maps:keys(maps:get(~"details", Map)))).

%% An error must survive a round trip through its own projection, e.g. across a
%% relay hop, without losing its identity.
to_map_round_trips_test() ->
    E0 = bondy_error:from_term({no_such_realm, ~"com.a"}),
    E1 = bondy_error:from_term(bondy_error:to_map(E0)),
    ?assertEqual(maps:get(uri, E0), maps:get(uri, E1)),
    ?assertEqual(maps:get(code, E0), maps:get(code, E1)),
    ?assertEqual(maps:get(message, E0), maps:get(message, E1)).

%% =============================================================================
%% LOG PROJECTION
%% =============================================================================

to_log_map_keeps_metadata_test() ->
    E = bondy_error:from_exception(error, {badmatch, x}, [{m, f, 1, []}]),
    Log = bondy_error:to_log_map(E),
    ?assertEqual({badmatch, x}, maps:get(reason, Log)),
    ?assertEqual([{m, f, 1, []}], maps:get(stacktrace, Log)),
    ?assertEqual(error, maps:get(class, Log)),
    ?assert(maps:is_key(trace_id, Log)).

%% The logging convention across the codebase keys the human summary off
%% `description`.
to_log_map_has_a_description_test() ->
    Log = bondy_error:to_log_map(bondy_error:new(not_found)),
    ?assert(is_binary(maps:get(description, Log))).

%% =============================================================================
%% sanitise/1
%% =============================================================================

sanitise_renders_terms_with_no_json_counterpart_test() ->
    ?assert(is_binary(bondy_error:sanitise({a, b}))),
    ?assert(is_binary(bondy_error:sanitise(self()))),
    ?assert(is_binary(bondy_error:sanitise(make_ref()))),
    ?assert(is_binary(bondy_error:sanitise(fun() -> ok end))).

sanitise_preserves_json_natives_test() ->
    ?assertEqual(1, bondy_error:sanitise(1)),
    ?assertEqual(1.5, bondy_error:sanitise(1.5)),
    ?assertEqual(true, bondy_error:sanitise(true)),
    ?assertEqual(false, bondy_error:sanitise(false)),
    ?assertEqual(null, bondy_error:sanitise(null)),
    ?assertEqual(null, bondy_error:sanitise(undefined)),
    ?assertEqual(~"abc", bondy_error:sanitise(abc)),
    ?assertEqual([1, 2], bondy_error:sanitise([1, 2])).

sanitise_binarises_map_keys_test() ->
    ?assertEqual(
        #{~"a" => 1, ~"2" => 2},
        bondy_error:sanitise(#{a => 1, 2 => 2})
    ).

%% A char list is far more useful as text than as an array of code points.
sanitise_renders_a_string_as_text_test() ->
    ?assertEqual(~"hello", bondy_error:sanitise("hello")).

sanitise_handles_an_improper_list_test() ->
    ?assert(is_binary(bondy_error:sanitise([1, 2 | 3]))).

sanitise_bounds_depth_test() ->
    Deep = lists:foldl(fun(_, Acc) -> #{n => Acc} end, leaf, lists:seq(1, 50)),
    ?assert(is_map(bondy_error:sanitise(Deep))).

sanitise_bounds_size_test() ->
    Big = binary:copy(~"x", 100_000),
    ?assert(byte_size(bondy_error:sanitise(Big)) < byte_size(Big)).

%% A JSON encoder rejects a binary that is not valid UTF-8, so one must never
%% survive sanitisation as a binary.
sanitise_renders_non_utf8_binaries_test() ->
    Sanitised = bondy_error:sanitise(<<255, 254, 253>>),
    ?assert(is_binary(Sanitised)),
    ?assert(is_utf8(Sanitised)),
    ?assert(is_utf8(bondy_error:sanitise(<<1:3>>))),

    %% Both sides of a map entry have to be safe, not just the value.
    [{Key, Value}] = maps:to_list(bondy_error:sanitise(#{<<255>> => <<254>>})),
    ?assert(is_utf8(Key)),
    ?assert(is_utf8(Value)).

%% Truncation cuts at a byte offset, which can land inside a multi-byte
%% character; the result must still be valid UTF-8.
truncation_does_not_split_a_character_test() ->
    Big = binary:copy(<<"é"/utf8>>, 50_000),
    ?assert(is_utf8(bondy_error:sanitise(Big))).

%% =============================================================================
%% URI SAFETY
%% =============================================================================

%% A malformed URI cannot go on the wire: bondy_wamp_message validates the error
%% URI, so letting one through would turn a reportable error into a crash.
malformed_uri_falls_back_test() ->
    E = bondy_error:from_term(<<255, 254>>),
    ?assertEqual(~"bondy.error.unknown_error", maps:get(uri, E)),
    ?assert(is_utf8(maps:get(uri, E))).

malformed_uri_in_a_projection_falls_back_test() ->
    E = bondy_error:from_term(#{~"uri" => <<"has spaces">>}),
    ?assertEqual(~"bondy.error.unknown_error", maps:get(uri, E)),
    ?assert(maps:is_key(rejected_uri, maps:get(metadata, E))).

%% Mirrors the historical code_to_uri/1: a bare token is qualified, an
%% already-qualified URI is kept.
bare_code_is_qualified_test() ->
    ?assertEqual(
        ~"bondy.error.something_odd",
        maps:get(uri, bondy_error:from_term(~"something_odd"))
    ).

qualified_uri_is_kept_test() ->
    [
        ?assertEqual(Uri, maps:get(uri, bondy_error:from_term(Uri)))
     || Uri <- [
            ~"wamp.error.some_new_thing",
            ~"bondy.error.some_new_thing",
            ~"com.example.error.custom"
        ]
    ].

%% =============================================================================
%% HELPERS
%% =============================================================================

is_utf8(Bin) ->
    is_binary(unicode:characters_to_binary(Bin, utf8, utf8)).

%% =============================================================================
%% format/1
%% =============================================================================

format_returns_a_binary_test() ->
    ?assert(is_binary(bondy_error:format(bondy_error:new(not_found)))).

format_includes_causes_test() ->
    E = bondy_error:wrap(bondy_error:new(internal_error), enoent),
    ?assertNotEqual(nomatch, binary:match(bondy_error:format(E), ~"<-")).

%% =============================================================================
%% format_error/2
%% =============================================================================

%% The previous implementations did maps:get(cause, ErrorInfo) with no default
%% and crashed whenever error_info carried no cause.
format_error_without_a_cause_test() ->
    Stacktrace = [{m, f, 1, [{error_info, #{module => m}}]}],
    ?assert(is_map(bondy_error:format_error(badarg, Stacktrace))).

format_error_with_a_cause_test() ->
    Cause = #{1 => "bad"},
    Stacktrace = [{m, f, 1, [{error_info, #{module => m, cause => Cause}}]}],
    Formatted = bondy_error:format_error(badarg, Stacktrace),
    ?assertEqual("bad", maps:get(1, Formatted)).

format_error_with_an_empty_stacktrace_test() ->
    ?assert(is_map(bondy_error:format_error(badarg, []))).
