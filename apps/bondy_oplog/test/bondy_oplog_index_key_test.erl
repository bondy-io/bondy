%% =============================================================================
%% EUnit smoke tests for `bondy_oplog_index_key`.
%%
%% Concrete coverage of the order-preserving composite codec: PK
%% round-trip (incl. PKs containing 0x00), the prefix-of-another-term
%% ordering case the escape exists to fix, integer sign-bias ordering,
%% and the equality/range bounds.
%% =============================================================================

-module(bondy_oplog_index_key_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_index_key).

%% =============================================================================
%% encode / decode_pk
%% =============================================================================

encode_decode_pk_binary_term_test() ->
    K = ?MOD:encode(<<"active">>, <<"user/1">>),
    ?assertEqual(<<"user/1">>, ?MOD:decode_pk(K)).

encode_decode_pk_integer_term_test() ->
    K = ?MOD:encode(42, <<"user/1">>),
    ?assertEqual(<<"user/1">>, ?MOD:decode_pk(K)).

%% The primary key itself may contain the 0x00 separator byte; decode_pk
%% must scan to the *first* 0x00 (the separator, never a term byte).
decode_pk_with_null_in_primary_key_test() ->
    PK = <<"a", 0, "b", 0, "c">>,
    K = ?MOD:encode(<<"term">>, PK),
    ?assertEqual(PK, ?MOD:decode_pk(K)).

decode_pk_empty_primary_key_test() ->
    K = ?MOD:encode(<<"term">>, <<>>),
    ?assertEqual(<<>>, ?MOD:decode_pk(K)).

decode_pk_no_separator_is_badarg_test() ->
    ?assertError(badarg, ?MOD:decode_pk(<<1, 2, 3>>)).

%% =============================================================================
%% Ordering — the cases the escape exists to make correct
%% =============================================================================

%% "a" < "a\0" < "ab": a term that is a byte-prefix of another must order
%% before it regardless of the appended primary key.
prefix_term_ordering_test() ->
    Ka = ?MOD:encode(<<"a">>, <<255>>),
    Kz = ?MOD:encode(<<"a", 0>>, <<>>),
    Kab = ?MOD:encode(<<"a", "b">>, <<>>),
    ?assert(Ka < Kz),
    ?assert(Kz < Kab).

%% A term embedding 0x00 still orders correctly against a longer term.
embedded_null_term_ordering_test() ->
    K1 = ?MOD:encode(<<0>>, <<"pk">>),
    K2 = ?MOD:encode(<<0, 0>>, <<"pk">>),
    K3 = ?MOD:encode(<<1>>, <<"pk">>),
    ?assert(K1 < K2),
    ?assert(K2 < K3).

same_term_orders_by_primary_key_test() ->
    Ka = ?MOD:encode(<<"t">>, <<"a">>),
    Kb = ?MOD:encode(<<"t">>, <<"b">>),
    ?assert(Ka < Kb).

integer_terms_order_numerically_test() ->
    Neg = ?MOD:encode_term(-1),
    Zero = ?MOD:encode_term(0),
    One = ?MOD:encode_term(1),
    Big = ?MOD:encode_term(1000000),
    ?assert(Neg < Zero),
    ?assert(Zero < One),
    ?assert(One < Big).

integer_extremes_order_test() ->
    Min = ?MOD:encode_term(-(1 bsl 63)),
    NegOne = ?MOD:encode_term(-1),
    Max = ?MOD:encode_term((1 bsl 63) - 1),
    ?assert(Min < NegOne),
    ?assert(NegOne < Max).

integer_out_of_range_is_badarg_test() ->
    ?assertError(badarg, ?MOD:encode_term(1 bsl 63)),
    ?assertError(badarg, ?MOD:encode_term(-(1 bsl 63) - 1)).

%% =============================================================================
%% Bounds
%% =============================================================================

equality_bounds_cover_exactly_the_term_test() ->
    {Lo, Hi} = ?MOD:equality_bounds(<<"active">>),
    InTerm = ?MOD:encode(<<"active">>, <<"pk">>),
    Other = ?MOD:encode(<<"activf">>, <<>>),
    Before = ?MOD:encode(<<"activd">>, <<255>>),
    ?assert(Lo =< InTerm andalso InTerm < Hi),
    ?assertNot(Lo =< Other andalso Other < Hi),
    ?assertNot(Lo =< Before andalso Before < Hi).

range_bounds_half_open_test() ->
    {Lo, Hi} = ?MOD:range_bounds(<<"b">>, <<"d">>),
    Kb = ?MOD:encode(<<"b">>, <<>>),
    Kc = ?MOD:encode(<<"c">>, <<"x">>),
    Kd = ?MOD:encode(<<"d">>, <<>>),
    Ka = ?MOD:encode(<<"a">>, <<255>>),
    %% [b, d): b and c included, d excluded, a excluded
    ?assert(Lo =< Kb andalso Kb < Hi),
    ?assert(Lo =< Kc andalso Kc < Hi),
    ?assertNot(Lo =< Kd andalso Kd < Hi),
    ?assertNot(Lo =< Ka andalso Ka < Hi).

%% =============================================================================
%% encode_col / decode_col / col_bounds — the type-tagged composite-key column
%% =============================================================================

col_roundtrip_test() ->
    ?assertEqual(<<"alice">>, ?MOD:decode_col(?MOD:encode_col(<<"alice">>))),
    ?assertEqual(all, ?MOD:decode_col(?MOD:encode_col(all))),
    ?assertEqual(anonymous, ?MOD:decode_col(?MOD:encode_col(anonymous))),
    ?assertEqual(42, ?MOD:decode_col(?MOD:encode_col(42))),
    ?assertEqual(-1, ?MOD:decode_col(?MOD:encode_col(-1))).

%% A column is 0x00-free regardless of the value (the separator must stay
%% unambiguous), even when the binary embeds 0x00 / 0x01 (escape path).
col_is_null_free_test() ->
    ?assertEqual(nomatch, binary:match(?MOD:encode_col(<<0, 1, 0>>), <<0>>)),
    ?assertEqual(nomatch, binary:match(?MOD:encode_col(all), <<0>>)),
    ?assertEqual(<<0, 1, 0>>, ?MOD:decode_col(?MOD:encode_col(<<0, 1, 0>>))).

%% The reserved atom `all` and the binary `<<"all">>` must NOT collide.
col_atom_binary_disjoint_test() ->
    ?assertNotEqual(?MOD:encode_col(all), ?MOD:encode_col(<<"all">>)),
    ?assertEqual(all, ?MOD:decode_col(?MOD:encode_col(all))),
    ?assertEqual(<<"all">>, ?MOD:decode_col(?MOD:encode_col(<<"all">>))).

%% col_bounds selects exactly one column's keys: a binary leading column that is
%% a byte-prefix of another (al / ale), an atom column, and a suffix that itself
%% contains the 0x00 separator (the suffix follows the band, never corrupts it).
col_bounds_selects_exactly_the_column_test() ->
    {Lo, Hi} = ?MOD:col_bounds(<<"al">>),
    Compose = fun(V, Suffix) ->
        <<(?MOD:encode_col(V))/binary, 0, Suffix/binary>>
    end,
    In1 = Compose(<<"al">>, <<"r1">>),
    In2 = Compose(<<"al">>, <<0, "x", 0>>),
    Other = Compose(<<"ale">>, <<"r1">>),
    Atom = Compose(all, <<"r1">>),
    ?assert(Lo =< In1 andalso In1 < Hi),
    ?assert(Lo =< In2 andalso In2 < Hi),
    ?assertNot(Lo =< Other andalso Other < Hi),
    ?assertNot(Lo =< Atom andalso Atom < Hi).

%% Integer columns order numerically through their band lower bounds.
col_integer_ordering_test() ->
    {LoNeg, _} = ?MOD:col_bounds(-5),
    {LoZero, _} = ?MOD:col_bounds(0),
    {LoPos, _} = ?MOD:col_bounds(7),
    ?assert(LoNeg < LoZero),
    ?assert(LoZero < LoPos).

%% =============================================================================
%% encode_tuple / decode_tuple — composite (covering-permutation) terms
%% =============================================================================

tuple_roundtrip_test() ->
    Cols = [<<"s">>, <<"p">>, <<"o">>, 42, all],
    ?assertEqual(Cols, ?MOD:decode_tuple(?MOD:encode_tuple(Cols))).

tuple_empty_test() ->
    ?assertEqual(<<>>, ?MOD:encode_tuple([])),
    ?assertEqual([], ?MOD:decode_tuple(<<>>)).

%% A list term routed through encode_term/encode is the tuple; the arity-aware
%% decode_composite recovers both the columns and the primary key (which here
%% itself contains a 0x00 to prove the split stops at the arity-th separator).
composite_term_via_encode_term_test() ->
    Cols = [<<"p">>, <<"o">>],
    ?assertEqual(?MOD:encode_tuple(Cols), ?MOD:encode_term(Cols)),
    PK = <<"k", 0, "v">>,
    K = ?MOD:encode([<<"p">>, <<"o">>], PK),
    ?assertEqual({[<<"p">>, <<"o">>], PK}, ?MOD:decode_composite(K, 2)).

%% A PREFIX of the collation is a bounded band: binding the first 2 of 3 columns
%% selects every fact whose first two columns match, across all 3rd-column values,
%% and excludes a different 2nd column.
tuple_prefix_bounds_test() ->
    {Lo, Hi} = ?MOD:equality_bounds([<<"p1">>, <<"o1">>]),
    F1 = ?MOD:encode([<<"p1">>, <<"o1">>, <<"g1">>], <<"k1">>),
    F2 = ?MOD:encode([<<"p1">>, <<"o1">>, <<"g9">>], <<"k2">>),
    Other = ?MOD:encode([<<"p1">>, <<"o2">>, <<"g1">>], <<"k3">>),
    ?assert(Lo =< F1 andalso F1 < Hi),
    ?assert(Lo =< F2 andalso F2 < Hi),
    ?assertNot(Lo =< Other andalso Other < Hi).

%% Full-tuple equality selects exactly one collation point (any primary key).
tuple_full_equality_test() ->
    {Lo, Hi} = ?MOD:equality_bounds([<<"p1">>, <<"o1">>, <<"g1">>]),
    Match = ?MOD:encode([<<"p1">>, <<"o1">>, <<"g1">>], <<"k1">>),
    Longer = ?MOD:encode([<<"p1">>, <<"o1">>, <<"g1x">>], <<"k2">>),
    ?assert(Lo =< Match andalso Match < Hi),
    ?assertNot(Lo =< Longer andalso Longer < Hi).

%% Facts sort by collation order: (p,o,g) ascending column-by-column.
tuple_collation_ordering_test() ->
    A = ?MOD:encode([<<"p1">>, <<"o1">>, <<"g1">>], <<>>),
    B = ?MOD:encode([<<"p1">>, <<"o1">>, <<"g2">>], <<>>),
    C = ?MOD:encode([<<"p1">>, <<"o2">>, <<"g1">>], <<>>),
    D = ?MOD:encode([<<"p2">>, <<"o1">>, <<"g1">>], <<>>),
    ?assert(A < B),
    ?assert(B < C),
    ?assert(C < D).
