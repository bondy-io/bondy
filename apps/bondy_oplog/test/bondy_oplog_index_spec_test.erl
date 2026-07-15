%% =============================================================================
%% EUnit tests for `bondy_oplog_index_spec`.
%%
%% Covers validation, term extraction (scalar / multi-valued / missing /
%% normalised), and column projection (pointer-only + denormalised,
%% deterministic encoding round-trip).
%% =============================================================================

-module(bondy_oplog_index_spec_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_index_spec).

%% =============================================================================
%% validate/1
%% =============================================================================

validate_minimal_spec_test() ->
    ?assertEqual(ok, ?MOD:validate(#{name => by_status, extract => [status]})).

validate_full_spec_test() ->
    Spec = #{
        name => by_status,
        extract => [status],
        normalize => downcase,
        projects => [[name], [status]],
        max_lag => 50
    },
    ?assertEqual(ok, ?MOD:validate(Spec)).

validate_whole_value_extract_test() ->
    ?assertEqual(ok, ?MOD:validate(#{name => by_value, extract => []})).

validate_missing_name_test() ->
    ?assertEqual(
        {error, {missing_key, name}},
        ?MOD:validate(#{extract => [status]})
    ).

validate_missing_extract_test() ->
    ?assertEqual(
        {error, {missing_key, extract}},
        ?MOD:validate(#{name => by_status})
    ).

validate_bad_name_test() ->
    ?assertEqual(
        {error, {invalid_name, <<"x">>}},
        ?MOD:validate(#{name => <<"x">>, extract => []})
    ).

validate_bad_extract_test() ->
    ?assertEqual(
        {error, {invalid_extract, status}},
        ?MOD:validate(#{name => s, extract => status})
    ).

validate_bad_normalize_test() ->
    ?assertEqual(
        {error, {invalid_normalize, upcase}},
        ?MOD:validate(#{name => s, extract => [], normalize => upcase})
    ).

validate_bad_projects_test() ->
    ?assertEqual(
        {error, {invalid_projects, [status]}},
        ?MOD:validate(#{name => s, extract => [], projects => [status]})
    ).

validate_not_a_map_test() ->
    ?assertEqual({error, {not_a_spec, foo}}, ?MOD:validate(foo)).

%% =============================================================================
%% Accessors
%% =============================================================================

name_test() ->
    ?assertEqual(by_status, ?MOD:name(#{name => by_status, extract => []})).

max_lag_defaults_to_infinity_test() ->
    ?assertEqual(infinity, ?MOD:max_lag(#{name => s, extract => []})).

max_lag_test() ->
    ?assertEqual(50, ?MOD:max_lag(#{name => s, extract => [], max_lag => 50})).

projects_defaults_to_empty_test() ->
    ?assertEqual([], ?MOD:projects(#{name => s, extract => []})).

%% =============================================================================
%% terms/2
%% =============================================================================

terms_scalar_field_test() ->
    Spec = #{name => s, extract => [status]},
    ?assertEqual([<<"active">>], ?MOD:terms(Spec, #{status => <<"active">>})).

terms_nested_path_test() ->
    Spec = #{name => s, extract => [user, status]},
    Value = #{user => #{status => <<"on">>}},
    ?assertEqual([<<"on">>], ?MOD:terms(Spec, Value)).

terms_whole_value_test() ->
    Spec = #{name => s, extract => []},
    ?assertEqual([<<"raw">>], ?MOD:terms(Spec, <<"raw">>)).

terms_missing_field_is_empty_test() ->
    Spec = #{name => s, extract => [status]},
    ?assertEqual([], ?MOD:terms(Spec, #{other => 1})).

terms_undefined_leaf_is_empty_test() ->
    Spec = #{name => s, extract => [status]},
    ?assertEqual([], ?MOD:terms(Spec, #{status => undefined})).

terms_path_into_non_map_is_empty_test() ->
    Spec = #{name => s, extract => [status]},
    ?assertEqual([], ?MOD:terms(Spec, <<"not-a-map">>)).

terms_multi_valued_list_field_test() ->
    Spec = #{name => s, extract => [tags]},
    Value = #{tags => [<<"a">>, <<"b">>, <<"c">>]},
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], ?MOD:terms(Spec, Value)).

terms_multi_valued_drops_undefined_test() ->
    Spec = #{name => s, extract => [tags]},
    Value = #{tags => [<<"a">>, undefined, <<"c">>]},
    ?assertEqual([<<"a">>, <<"c">>], ?MOD:terms(Spec, Value)).

terms_downcase_normalize_test() ->
    Spec = #{name => s, extract => [status], normalize => downcase},
    ?assertEqual([<<"active">>], ?MOD:terms(Spec, #{status => <<"ACTIVE">>})).

terms_downcase_passes_integers_through_test() ->
    Spec = #{name => s, extract => [n], normalize => downcase},
    ?assertEqual([7], ?MOD:terms(Spec, #{n => 7})).

terms_integer_term_test() ->
    Spec = #{name => s, extract => [age]},
    ?assertEqual([42], ?MOD:terms(Spec, #{age => 42})).

%% =============================================================================
%% normalize => canonical (structured columns → deterministic binary term)
%% =============================================================================

validate_canonical_normalize_test() ->
    ?assertEqual(
        ok,
        ?MOD:validate(#{
            name => s, extract => [resource], normalize => canonical
        })
    ).

%% A structured leaf (an RBAC resource `{Uri, Strategy}`, the atom `any`) becomes
%% its deterministic `term_to_binary`, which `encode_term` can then encode.
terms_canonical_tuple_test() ->
    Spec = #{name => s, extract => [resource], normalize => canonical},
    Res = {<<"com.example.>">>, <<"prefix">>},
    ?assertEqual(
        [term_to_binary(Res, [deterministic])],
        ?MOD:terms(Spec, #{resource => Res})
    ).

terms_canonical_atom_test() ->
    Spec = #{name => s, extract => [resource], normalize => canonical},
    ?assertEqual(
        [term_to_binary(any, [deterministic])],
        ?MOD:terms(Spec, #{resource => any})
    ).

%% The equality-match invariant: a query term canonicalised by `normalize_term/2`
%% equals the stored term `terms/2` produced for the same value, so `index_get`
%% finds it.
normalize_term_canonical_matches_stored_test() ->
    Spec = #{name => s, extract => [resource], normalize => canonical},
    Res = {<<"a.b.c">>, <<"exact">>},
    [Stored] = ?MOD:terms(Spec, #{resource => Res}),
    ?assertEqual(Stored, ?MOD:normalize_term(Spec, Res)).

%% =============================================================================
%% collation => composite (covering) index
%% =============================================================================

validate_collation_ok_test() ->
    Spec = #{name => pogs, collation => [[p], [o], [g], [s]]},
    ?assertEqual(ok, ?MOD:validate(Spec)).

validate_collation_conflicts_with_extract_test() ->
    Spec = #{name => x, extract => [a], collation => [[a], [b]]},
    ?assertEqual(
        {error, {conflicting_keys, [extract, collation]}}, ?MOD:validate(Spec)
    ).

validate_empty_collation_test() ->
    ?assertEqual(
        {error, {invalid_collation, []}},
        ?MOD:validate(#{name => x, collation => []})
    ).

validate_bad_collation_paths_test() ->
    ?assertEqual(
        {error, {invalid_collation, [a, b]}},
        ?MOD:validate(#{name => x, collation => [a, b]})
    ).

is_composite_and_arity_test() ->
    Comp = #{name => pogs, collation => [[p], [o], [g], [s]]},
    Scalar = #{name => by_g, extract => [g]},
    ?assert(?MOD:is_composite(Comp)),
    ?assertNot(?MOD:is_composite(Scalar)),
    ?assertEqual(4, ?MOD:arity(Comp)),
    ?assertEqual(1, ?MOD:arity(Scalar)).

%% A composite term is ONE tuple of columns in collation order.
terms_collation_tuple_test() ->
    Spec = #{name => pog, collation => [[p], [o], [g]]},
    Value = #{p => <<"P">>, o => <<"O">>, g => <<"G">>, extra => 1},
    ?assertEqual([[<<"P">>, <<"O">>, <<"G">>]], ?MOD:terms(Spec, Value)).

%% A missing column drops the whole tuple (no partial composite entry).
terms_collation_missing_column_test() ->
    Spec = #{name => pog, collation => [[p], [o], [g]]},
    ?assertEqual([], ?MOD:terms(Spec, #{p => <<"P">>, o => <<"O">>})).

%% Per-column normalise applies to both stored and query terms.
collation_normalize_test() ->
    Spec = #{name => pog, collation => [[p], [o]], normalize => downcase},
    ?assertEqual(
        [[<<"p">>, <<"o">>]], ?MOD:terms(Spec, #{p => <<"P">>, o => <<"O">>})
    ),
    ?assertEqual(
        [<<"p">>, <<"o">>], ?MOD:normalize_term(Spec, [<<"P">>, <<"O">>])
    ).

%% =============================================================================
%% project/2 + decode_projection/1
%% =============================================================================

project_pointer_only_is_empty_test() ->
    Spec = #{name => s, extract => [status]},
    ?assertEqual(<<>>, ?MOD:project(Spec, #{status => <<"active">>})).

project_columns_roundtrip_test() ->
    Spec = #{name => s, extract => [status], projects => [[name], [status]]},
    Value = #{name => <<"alice">>, status => <<"active">>, extra => 1},
    Bin = ?MOD:project(Spec, Value),
    ?assert(is_binary(Bin)),
    ?assertEqual(
        #{[name] => <<"alice">>, [status] => <<"active">>},
        ?MOD:decode_projection(Bin)
    ).

project_skips_missing_columns_test() ->
    Spec = #{name => s, extract => [status], projects => [[name], [missing]]},
    Value = #{name => <<"alice">>, status => <<"active">>},
    Bin = ?MOD:project(Spec, Value),
    ?assertEqual(#{[name] => <<"alice">>}, ?MOD:decode_projection(Bin)).

project_is_deterministic_test() ->
    Spec = #{name => s, extract => [status], projects => [[a], [b], [c]]},
    Value = #{a => 1, b => 2, c => 3},
    ?assertEqual(?MOD:project(Spec, Value), ?MOD:project(Spec, Value)).

decode_empty_projection_test() ->
    ?assertEqual(#{}, ?MOD:decode_projection(<<>>)).
