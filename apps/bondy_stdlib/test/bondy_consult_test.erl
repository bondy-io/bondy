%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% =============================================================================
%% `bondy_consult:encode/1` — the round trip through the real
%% `file:consult/1`.
%%
%% Every case here writes the bytes to disk and reads them back with
%% `file:consult/1`. Parsing the bytes in memory with `erl_scan` is NOT the
%% same oracle: `file:consult/1` decodes the file as UTF-8, and the defect
%% class this pins is precisely bytes that are not valid UTF-8.
%%
%% The deterministic cases are the three measured falsifiers, one per
%% mechanism that a plausible "simplification" of the encoder would break:
%%
%%   - a binary of printable latin-1 bytes: `~p` string-renders it and, with
%%     `iolist_to_binary/1`, emits bytes 160..255 raw → `invalid_unicode`
%%     (the production crash-loop of 2026-09-02);
%%   - an atom with a latin-1 character: `~tw` emits it verbatim and, with
%%     `iolist_to_binary/1`, the same bytes → `invalid_unicode` (the case
%%     the `~p` → `~tw` change did NOT close);
%%   - an atom with a character above 255: with `iolist_to_binary/1`,
%%     `badarg` at encode time.
%%
%% The property then covers the whole consultable term space.
%% =============================================================================

-module(bondy_consult_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% DETERMINISTIC FALSIFIERS
%% =============================================================================

falsifiers_test_() ->
    {foreach, fun mk_tmp/0, fun rm_tmp/1, [
        fun(Dir) ->
            {"a binary of printable latin-1 bytes round-trips", fun() ->
                Root = list_to_binary(lists:seq(160, 191)),
                assert_round_trip(Dir, [{current_root, Root}])
            end}
        end,
        fun(Dir) ->
            {"an atom with a latin-1 character round-trips", fun() ->
                assert_round_trip(Dir, [{hash_algo, 'café'}])
            end}
        end,
        fun(Dir) ->
            {"an atom with a character above 255 round-trips", fun() ->
                assert_round_trip(Dir, [{db, '日本'}])
            end}
        end,
        fun(Dir) ->
            {"a string with wide characters round-trips", fun() ->
                assert_round_trip(Dir, [{name, "日本"}])
            end}
        end,
        fun(Dir) ->
            {"one term per line, each terminated by a full stop", fun() ->
                Bin = bondy_consult:encode([{a, 1}, {b, <<1, 2>>}]),
                ?assertEqual(<<"{a,1}.\n{b,<<1,2>>}.\n">>, Bin),
                assert_round_trip(Dir, [{a, 1}, {b, <<1, 2>>}])
            end}
        end,
        fun(_Dir) ->
            {"a wide term stays on one line", fun() ->
                %% The layout half of the contract: `~p` would wrap this
                %% across many lines, which is what makes manifests hard to
                %% diff across versions. One term, one line, one newline.
                Wide = {live_segments, lists:seq(1, 500)},
                Bin = bondy_consult:encode([Wide]),
                ?assertEqual(1, length(binary:matches(Bin, <<"\n">>))),
                ?assertEqual($\n, binary:last(Bin))
            end}
        end
    ]}.

%% =============================================================================
%% PROPERTY
%% =============================================================================

proper_test_() ->
    Opts = [{numtests, 300}, {to_file, user}],
    {setup, fun mk_tmp/0, fun rm_tmp/1, fun(Dir) ->
        [
            {timeout, 60,
                ?_assert(proper:quickcheck(prop_round_trip(Dir), Opts))}
        ]
    end}.

%% A file of up to four terms. The falsifying shapes are leaves (an atom, a
%% binary, a string), not depth or breadth, so the file is kept small: an
%% unbounded `list(consultable())` at PropEr's default sizes hands
%% `file:consult/1` kilobytes of nested terms per case and the property
%% spends its budget in `erl_parse`.
prop_round_trip(Dir) ->
    ?FORALL(
        Terms,
        ?LET(N, choose(0, 4), vector(N, consultable())),
        round_trips(Dir, Terms)
    ).

%% A fixed pool rather than PropEr's atom(), which mints a fresh atom per
%% case and exhausts the atom table on a long run. The pool spans the three
%% character classes `~tw` treats differently: ASCII, latin-1 (160..255) and
%% above 255.
some_atom() ->
    oneof([
        ok,
        undefined,
        true,
        '',
        'a b',
        'with\'quote',
        'café',
        'Ñandú',
        '日本',
        'ünïcödé'
    ]).

%% A list of valid code points, i.e. a string `unicode:characters_to_binary/1`
%% can encode; the latin-1 branch keeps the 160..255 range well represented.
some_string() ->
    oneof([
        ?LET(B, utf8(), unicode:characters_to_list(B)),
        list(choose(160, 255)),
        list(choose(0, 127))
    ]).

some_binary() ->
    oneof([
        binary(),
        utf8(),
        %% The printable latin-1 run `~p` would have string-rendered.
        ?LET(Bytes, list(choose(160, 255)), list_to_binary(Bytes))
    ]).

leaf() ->
    oneof([
        integer(),
        largeint(),
        float(),
        some_atom(),
        some_string(),
        some_binary()
    ]).

%% Nesting is capped at three levels for the same reason.
consultable() ->
    ?SIZED(Size, consultable(min(Size, 3))).

consultable(0) ->
    leaf();
consultable(Depth) ->
    Smaller = consultable(Depth - 1),
    oneof([
        leaf(),
        list(Smaller),
        ?LET({A, B}, {Smaller, Smaller}, {A, B}),
        ?LET({A, B, C}, {Smaller, Smaller, Smaller}, {A, B, C}),
        map(oneof([some_atom(), some_binary(), integer()]), Smaller)
    ]).

%% =============================================================================
%% HELPERS
%% =============================================================================

round_trips(Dir, Terms) ->
    Path = filename:join(Dir, "terms.consult"),
    ok = file:write_file(Path, bondy_consult:encode(Terms)),
    case file:consult(Path) of
        {ok, Terms} ->
            true;
        Other ->
            io:format("wrote ~tp~nread ~tp~n", [Terms, Other]),
            false
    end.

assert_round_trip(Dir, Terms) ->
    ?assert(round_trips(Dir, Terms)).

mk_tmp() ->
    Dir = filename:join(
        "/tmp",
        "bondy_consult_test_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    Dir.

rm_tmp(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.
