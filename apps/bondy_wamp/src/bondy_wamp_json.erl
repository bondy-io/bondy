%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_wamp_json).

-moduledoc """
A utility module that offers partial encoding/decoding and some customisation
options over the Erlang `json` module.
""".

-include("bondy_wamp.hrl").

%% For backwards compat with jsx lib used in previous versions
-define(DEFAULT_FLOAT_FORMAT, [{decimals, 16}]).
-define(DEFAULT_ENCODE_OPTS, [{float_format, ?DEFAULT_FLOAT_FORMAT}]).
-define(DEFAULT_DECODE_OPTS, [{decoders, #{null => undefined}}]).
-define(IS_UINT(X), (is_integer(X) andalso X >= 0)).
-define(IS_PNUM(X), (is_number(X) andalso X >= 0)).
-define(IS_DATETIME(Y, M, D, H, Mi, S),
    (
        ?IS_UINT(Y) andalso
        ?IS_UINT(M) andalso
        ?IS_UINT(D) andalso
        ?IS_UINT(H) andalso
        ?IS_UINT(Mi) andalso
        ?IS_PNUM(S)
    )
).
-define(SECONDS_PER_MINUTE, 60).
-define(SECONDS_PER_HOUR, 3600).


-type encode_opt()  ::  {float_format, [float_format()]}
                        | {check_duplicate_keys, boolean()}.

-type decode_opt()  ::  {decoders, json:decoders()}.

%% idem erlang:float_to_binary/2 options
-type float_format()    ::  {scientific, Decimals :: 0..249}
                            | {decimals, Decimals :: 0..253}
                            | compact
                            | short.

-export([decode/1]).
-export([decode/2]).
-export([decode_head/2]).
-export([decode_tail/1]).
-export([decode_tail/2]).
-export([encode/1]).
-export([encode/2]).
-export([encode_with_tail/2]).
-export([try_decode/1]).
-export([try_decode/2]).
-export([validate_opts/1]).


%% =============================================================================
%% API
%% =============================================================================


-spec encode(any()) -> binary().

encode(Term) ->
    Opts = bondy_wamp_config:get([json, encode_opts], ?DEFAULT_ENCODE_OPTS),
    encode(Term, Opts).


-spec encode(any(), [encode_opt()]) -> iodata() | binary().

encode(Term, Opts) ->
    do_encode(Term, Opts).


-doc """
Encodes a list of elements (WAMP message) together with a tail obtained
previously using `decode_partial/1`.
""".
-spec encode_with_tail(Elements :: [term()], Tail :: binary()) -> binary().

%% Encode new elements and concatenate with the preserved tail
encode_with_tail(Elements, TailBin) when is_list(Elements), is_binary(TailBin) ->
    IOList0 = json:encode(Elements),

    %% Remove the closing bracket from the encoded elements
    IOList1 = lists:droplast(IOList0),

    %% Concatenate, ensuring proper comma placement
    IOList = case TailBin of
        <<",", _/binary>> ->
            %% Tail already has comma
            [IOList1, TailBin];

        <<"]", _/binary>> ->
            %% Tail is just the closing bracket
            [IOList1, TailBin];

        _ ->
            %% Need to add comma
            [IOList1, ",", TailBin]
    end,
    iolist_to_binary(IOList).


-spec decode(binary()) -> term() | no_return().

decode(Term) ->
    Opts = bondy_wamp_config:get([json, decode_opts], ?DEFAULT_DECODE_OPTS),
    decode(Term, Opts).


-spec decode(binary(), [decode_opt()]) -> term() | no_return().

decode(Term, Opts) ->
    do_decode(Term, Opts).


-doc """
Decodes only the first N control elements WAMP messages containing payloads,
keeping the rest as binary.
""".
decode_head(<<"[", Rest/binary>>, NumElements)
when is_integer(NumElements), NumElements > 0 ->
    case extract_elements(Rest, NumElements, []) of
        {Elements, <<"]">>} ->
            %% Closing bracket, end of JSON term
            Elements;

        {_, _} = Term ->
            Term
    end;

decode_head(Term, NumElements) ->
    error(
        bondy_stdlib_error:new(#{
            type => badarg,
            details => #{1 => Term, 2 => NumElements}
        })
    ).

-spec decode_tail(binary()) -> term() | no_return().

decode_tail(Term) ->
    Opts = bondy_wamp_config:get([json, decode_opts], ?DEFAULT_DECODE_OPTS),
    decode_tail(Term, Opts).


-doc "Decode the JSON tail binary back into Erlang terms.".
-spec decode_tail(binary(), key_value:t()) -> term() | no_return().

decode_tail(Bin0, Opts) when is_binary(Bin0) ->
    %% The tail might be one of:
    %% 1. `, elem1, elem2, ...]`  (with leading comma)
    %% 2. `]` (just closing bracket)
    %% 3. `elem1, elem2, ...]` (without comma)

    case skip_whitespace(Bin0) of
        %% <<"]">> ->
        %%     %% Empty tail, no more elements
        %%     {ok, []};

        <<",", Rest/binary>> ->
            %% Has leading comma, make it a valid JSON array
            Bin = <<"[", Rest/binary>>,
            do_decode(Bin, Opts);

        Bin ->
            %% No leading comma, should already have elements
            %% Wrap in array brackets if needed
            case binary:match(Bin, <<"]">>) of
                {Pos, 1} when Pos == byte_size(Bin) - 1 ->
                    %% Already has closing bracket
                    do_decode(<<"[", Bin/binary>>, Opts);

                nomatch ->
                    %% No closing bracket, add both brackets
                    do_decode(<<"[", Bin/binary, "]">>, Opts)
            end
    end.


try_decode(Term) ->
    try_decode(Term, []).


try_decode(Term, Opts) ->
    try
        {ok, decode(Term, Opts)}
    catch
        _:Reason ->
            {error, Reason}
    end.


validate_opts(List) when is_list(List) ->
    lists:map(fun validate_opt/1, List).


%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
float_opts(Opts) ->
    case lists:keyfind(float_format, 1, Opts) of
        {float_format, FloatOpts} when is_list(FloatOpts) ->
            FloatOpts;
        false ->
            ?DEFAULT_FLOAT_FORMAT
    end.


validate_opt({float_format, Opts}) ->
    {float_format, validate_float_opts(Opts)};

validate_opt({check_duplicate_keys, Arg} = Term) ->
    is_boolean(Arg) orelse
    error(badarg, {check_duplicate_keys, Arg}),
    Term;

validate_opt({datetime_format, _Opts} = Term) ->
    %% TODO
    Term.


validate_float_opts(Opts) ->
    lists:map(fun validate_float_opt/1, Opts).

validate_float_opt({scientific, Decimals} = Term)
when is_integer(Decimals), Decimals >= 0, Decimals =< 249 ->
    Term;

validate_float_opt({scientific, Decimals})
when is_integer(Decimals), Decimals >= 0 ->
    %% Coerce to max
    {scientific, 249};

validate_float_opt({decimals, Decimals} = Term)
when is_integer(Decimals), Decimals >= 0, Decimals =< 253 ->
    Term;

validate_float_opt(compact = Term) ->
    Term;

validate_float_opt(short = Term) ->
    Term;

validate_float_opt(Arg) ->
    error(badarg, {float_format, Arg}).


%% @private
do_encode(Term, Opts) ->
    FloatOpts = float_opts(validate_opts(Opts)),
    Checked = key_value:get(check_duplicate_keys, Opts, false),

    Fun =  fun
        (undefined, _Encode) ->
            <<"null">>;

        (Value, _Encode) when is_float(Value) ->
            float_to_binary(Value, FloatOpts);

        ({{Y, M, D}, {H, Mi, S}}, _Encode)
        when ?IS_DATETIME(Y, M, D, H, Mi, S) ->
            encode_datetime({{Y, M, D}, {H, Mi, S}});

        ([{_, _} | _] = Value, Encode) when is_list(Value), Checked == true ->
            json:encode_key_value_list_checked(Value, Encode);

        ([{_, _} | _] = Value, Encode) when is_list(Value), Checked == false ->
            json:encode_key_value_list(Value, Encode);

        (Value, Encode) ->
            json:encode_value(Value, Encode)
    end,

    iolist_to_binary(json:encode(Term, Fun)).

%% @private
do_decode(Term, []) ->
    json:decode(Term);

do_decode(Term, Opts) ->
    Decoders =  key_value:get(decoders, Opts, #{}),

    case json:decode(Term, ok, Decoders) of
        {Value, ok, <<>>} ->
            Value;

        Other ->
            error({badarg, Other})
    end.


%% =============================================================================
%% PRIVATE - BORROWED FROM JSONE LIBRARY
%%
%% Copyright (c) 2013-2016, Takeru Ohta <phjgt308@gmail.com>
%%
%% The MIT License
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%%
%% =============================================================================

-spec encode_datetime(calendar:datetime()) -> iodata().

encode_datetime({{Y, M, D}, {H, Mi, S}}) ->
    [
        format_year(Y), $-,
        format2digit(M), $-,
        format2digit(D), $T,
        format2digit(H), $:,
        format2digit(Mi), $:,
        format_seconds(S), $Z
    ].


-spec format_year(non_neg_integer()) -> iodata().

format_year(Y) when Y > 999 ->
    integer_to_binary(Y);

format_year(Y) ->
    B = integer_to_binary(Y),
    [lists:duplicate(4 - byte_size(B), $0) | B].


-spec format2digit(non_neg_integer()) -> iolist().

format2digit(0) ->
    "00";
format2digit(1) ->
    "01";
format2digit(2) ->
    "02";
format2digit(3) ->
    "03";
format2digit(4) ->
    "04";
format2digit(5) ->
    "05";
format2digit(6) ->
    "06";
format2digit(7) ->
    "07";
format2digit(8) ->
    "08";
format2digit(9) ->
    "09";
format2digit(X) ->
    integer_to_list(X).


-spec format_seconds(non_neg_integer() | float()) -> iolist().

format_seconds(S) when is_integer(S) ->
    format2digit(S);

format_seconds(S) when is_float(S) ->
    io_lib:format("~6.3.0f", [S]).



%% =============================================================================
%% PRIVATE: PARTIAL DECODING/ENCODING
%% =============================================================================



%% Extract N elements from the JSON array
extract_elements(Bin, 0, Acc) ->
    %% We've extracted enough elements, find where to cut
    {lists:reverse(Acc), find_tail_position(Bin)};

extract_elements(Bin, N, Acc) ->
    %% Skip whitespace
    Bin1 = skip_whitespace(Bin),

    %% Find the end of this JSON element
    case find_element_end(Bin1) of
        {ok, ElementBin, Rest} ->
            %% Decode this element
            Element = json:decode(ElementBin),

            %% Skip comma if present
            Rest1 = skip_whitespace(Rest),
            Rest2 = case Rest1 of
                <<",", R/binary>> -> R;
                R -> R
            end,

            extract_elements(Rest2, N - 1, [Element | Acc]);

        error ->
            {lists:reverse(Acc), Bin1}
    end.

%% Find where the current JSON element ends
find_element_end(Bin) ->
    find_element_end(Bin, 0, 0, false, <<>>).

find_element_end(<<>>, _, _, _, _) ->
    error;

find_element_end(<<"\"", Rest/binary>>, BraceDepth, BracketDepth, InString, Acc) ->
    %% Toggle string state (simplified - doesn't handle escapes)
    find_element_end(
        Rest, BraceDepth, BracketDepth, not InString, <<Acc/binary, "\"">>
    );

find_element_end(<<"\\", C, Rest/binary>>, BraceDepth, BracketDepth, true, Acc) ->
    %% Handle escaped character in string
    find_element_end(
        Rest, BraceDepth, BracketDepth, true, <<Acc/binary, "\\", C>>
    );

find_element_end(<<"{", Rest/binary>>, BraceDepth, BracketDepth, false, Acc) ->
    find_element_end(
        Rest, BraceDepth + 1, BracketDepth, false, <<Acc/binary, "{">>
    );

find_element_end(<<"}", Rest/binary>>, BraceDepth, BracketDepth, false, Acc)
when BraceDepth > 0 ->
    NewDepth = BraceDepth - 1,
    NewAcc = <<Acc/binary, "}">>,
    case {NewDepth, BracketDepth} of
        {0, 0} ->
            {ok, NewAcc, Rest};

        _ ->
            find_element_end(Rest, NewDepth, BracketDepth, false, NewAcc)
    end;

find_element_end(<<"[", Rest/binary>>, BraceDepth, BracketDepth, false, Acc) ->
    find_element_end(
        Rest, BraceDepth, BracketDepth + 1, false, <<Acc/binary, "[">>
    );

find_element_end(<<"]", Rest/binary>>, BraceDepth, BracketDepth, false, Acc)
when BracketDepth > 0 ->
    NewDepth = BracketDepth - 1,
    NewAcc = <<Acc/binary, "]">>,

    case {BraceDepth, NewDepth} of
        {0, 0} ->
            {ok, NewAcc, Rest};
        _ ->
            find_element_end(Rest, BraceDepth, NewDepth, false, NewAcc)
    end;

find_element_end(<<",", Rest/binary>>, 0, 0, false, Acc) ->
    %% Found element boundary at top level
    {ok, Acc, <<",", Rest/binary>>};

find_element_end(<<"]", Rest/binary>>, 0, 0, false, Acc) ->
    %% Found array end at top level
    {ok, Acc, <<"]", Rest/binary>>};

find_element_end(<<C, Rest/binary>>, BraceDepth, BracketDepth, InString, Acc) ->
    find_element_end(
        Rest, BraceDepth, BracketDepth, InString, <<Acc/binary, C>>
    ).

%% Find the position where the tail starts (including comma)
find_tail_position(Bin) ->
    Bin1 = skip_whitespace(Bin),
    case Bin1 of
        <<",", Rest/binary>> ->
            %% Include the comma in the tail for later joining
            <<",", Rest/binary>>;

        _ ->
            Bin1
    end.


%% Skip whitespace characters
skip_whitespace(<<" ", Rest/binary>>) ->
    skip_whitespace(Rest);

skip_whitespace(<<"\t", Rest/binary>>) ->
    skip_whitespace(Rest);

skip_whitespace(<<"\n", Rest/binary>>) ->
    skip_whitespace(Rest);

skip_whitespace(<<"\r", Rest/binary>>) ->
    skip_whitespace(Rest);

skip_whitespace(Bin) ->
    Bin.

