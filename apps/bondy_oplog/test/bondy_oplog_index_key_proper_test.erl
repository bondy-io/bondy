%% =============================================================================
%% PropEr properties for `bondy_oplog_index_key`.
%%
%% The composite `(Term, PrimaryKey)` codec MUST be order-preserving and
%% self-delimiting for arbitrary primary keys, including keys that embed
%% `0x00`, `0x01`, and `0xFF` bytes. These properties pin:
%%
%%   - primary-key round-trip (`decode_pk(encode(T, PK)) =:= PK`);
%%   - term order preservation for binary and integer terms;
%%   - composite-key order = `{Term, PK}` order (term dominates, then PK);
%%   - equality / range bound correctness.
%% =============================================================================

-module(bondy_oplog_index_key_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_index_key).
-define(DEFAULT_NUMTESTS, 300).

-define(INT_MIN, -(1 bsl 63)).
-define(INT_MAX, ((1 bsl 63) - 1)).

-export([prop_pk_roundtrip_binary_term/0]).
-export([prop_pk_roundtrip_integer_term/0]).
-export([prop_binary_term_order/0]).
-export([prop_integer_term_order/0]).
-export([prop_composite_order_binary/0]).
-export([prop_composite_order_integer/0]).
-export([prop_equality_bounds_contains/0]).
-export([prop_equality_bounds_excludes_other/0]).
-export([prop_range_bounds/0]).

%% =============================================================================
%% Generators
%% =============================================================================

bin_term_gen() ->
    %% arbitrary bytes, including 0x00 / 0x01 / 0xFF
    binary().

int_term_gen() ->
    frequency([
        {7, integer(-100000, 100000)},
        {3, elements([?INT_MIN, ?INT_MAX, -1, 0, 1, 255, 256])}
    ]).

pk_gen() ->
    %% primary keys may themselves contain the separator byte 0x00
    binary().

%% =============================================================================
%% Properties
%% =============================================================================

prop_pk_roundtrip_binary_term() ->
    ?FORALL(
        {T, PK},
        {bin_term_gen(), pk_gen()},
        ?MOD:decode_pk(?MOD:encode(T, PK)) =:= PK
    ).

prop_pk_roundtrip_integer_term() ->
    ?FORALL(
        {T, PK},
        {int_term_gen(), pk_gen()},
        ?MOD:decode_pk(?MOD:encode(T, PK)) =:= PK
    ).

prop_binary_term_order() ->
    ?FORALL(
        {A, B},
        {bin_term_gen(), bin_term_gen()},
        (?MOD:encode_term(A) < ?MOD:encode_term(B)) =:= (A < B)
    ).

prop_integer_term_order() ->
    ?FORALL(
        {A, B},
        {int_term_gen(), int_term_gen()},
        (?MOD:encode_term(A) < ?MOD:encode_term(B)) =:= (A < B)
    ).

prop_composite_order_binary() ->
    ?FORALL(
        {T1, P1, T2, P2},
        {bin_term_gen(), pk_gen(), bin_term_gen(), pk_gen()},
        (?MOD:encode(T1, P1) < ?MOD:encode(T2, P2)) =:=
            ({T1, P1} < {T2, P2})
    ).

prop_composite_order_integer() ->
    ?FORALL(
        {T1, P1, T2, P2},
        {int_term_gen(), pk_gen(), int_term_gen(), pk_gen()},
        (?MOD:encode(T1, P1) < ?MOD:encode(T2, P2)) =:=
            ({T1, P1} < {T2, P2})
    ).

prop_equality_bounds_contains() ->
    ?FORALL(
        {T, PK},
        {bin_term_gen(), pk_gen()},
        begin
            {Lo, Hi} = ?MOD:equality_bounds(T),
            K = ?MOD:encode(T, PK),
            Lo =< K andalso K < Hi
        end
    ).

prop_equality_bounds_excludes_other() ->
    ?FORALL(
        {T1, T2, PK},
        {bin_term_gen(), bin_term_gen(), pk_gen()},
        ?IMPLIES(
            T1 =/= T2,
            begin
                {Lo, Hi} = ?MOD:equality_bounds(T1),
                K = ?MOD:encode(T2, PK),
                not (Lo =< K andalso K < Hi)
            end
        )
    ).

prop_range_bounds() ->
    ?FORALL(
        {X, Y, T, PK},
        {bin_term_gen(), bin_term_gen(), bin_term_gen(), pk_gen()},
        begin
            Lo = min(X, Y),
            Hi = max(X, Y),
            {L, H} = ?MOD:range_bounds(Lo, Hi),
            K = ?MOD:encode(T, PK),
            InWindow = L =< K andalso K < H,
            InRange = Lo =< T andalso T < Hi,
            InWindow =:= InRange
        end
    ).

%% =============================================================================
%% Runner
%% =============================================================================

properties_test_() ->
    {timeout, 180, fun() ->
        Opts = [{to_file, user}, {numtests, ?DEFAULT_NUMTESTS}],
        Props = [
            prop_pk_roundtrip_binary_term(),
            prop_pk_roundtrip_integer_term(),
            prop_binary_term_order(),
            prop_integer_term_order(),
            prop_composite_order_binary(),
            prop_composite_order_integer(),
            prop_equality_bounds_contains(),
            prop_equality_bounds_excludes_other(),
            prop_range_bounds()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            Props
        )
    end}.
