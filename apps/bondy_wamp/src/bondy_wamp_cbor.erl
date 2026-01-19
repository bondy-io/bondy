%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_cbor).

-moduledoc """
A utility module that offers partial encoding/decoding and some customisation
options over the `bondy_cbor` module.
""".

-include("bondy_wamp.hrl").

-define(DEFAULT_ENCODE_OPTS, []).
%% Map both CBOR null and undefined to Erlang undefined for JSON compatibility
-define(DEFAULT_DECODE_OPTS, [{decoders, #{null => undefined, undefined => undefined}}]).
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

%% CBOR major types
-define(CBOR_UINT, 0).
-define(CBOR_NEGINT, 1).
-define(CBOR_BYTES, 2).
-define(CBOR_TEXT, 3).
-define(CBOR_ARRAY, 4).
-define(CBOR_MAP, 5).
-define(CBOR_TAG, 6).
-define(CBOR_SIMPLE, 7).

%% CBOR break code for indefinite-length items
-define(CBOR_BREAK, 16#ff).


-type encode_opt()  ::  {check_duplicate_keys, boolean()}.

-type decode_opt()  ::  {decoders, bondy_cbor:decoders()}.

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
    Opts = bondy_wamp_config:get([cbor, encode_opts], ?DEFAULT_ENCODE_OPTS),
    encode(Term, Opts).


-spec encode(any(), [encode_opt()]) -> iodata() | binary().

encode(Term, Opts) ->
    do_encode(Term, Opts).


-doc """
Encodes a list of elements (WAMP message) together with a tail obtained
previously using `decode_head/2`.
""".
-spec encode_with_tail(Elements :: [term()], Tail :: binary()) -> binary().

encode_with_tail(Elements, TailBin) when is_list(Elements), is_binary(TailBin) ->
    %% For CBOR, we need to:
    %% 1. Count total elements (new elements + elements in tail)
    %% 2. Encode the array header with proper count
    %% 3. Encode the new elements
    %% 4. Append the tail elements (already encoded)

    TailCount = count_cbor_elements(TailBin),
    TotalCount = length(Elements) + TailCount,

    %% Encode array header
    HeaderBin = encode_array_header(TotalCount),

    %% Encode each new element
    EncodedElements = [iolist_to_binary(bondy_cbor:encode(E)) || E <- Elements],

    iolist_to_binary([HeaderBin | EncodedElements] ++ [TailBin]).


-spec decode(binary()) -> term() | no_return().

decode(Term) ->
    Opts = bondy_wamp_config:get([cbor, decode_opts], ?DEFAULT_DECODE_OPTS),
    decode(Term, Opts).


-spec decode(binary(), [decode_opt()]) -> term() | no_return().

decode(Term, Opts) ->
    do_decode(Term, Opts).


-doc """
Decodes only the first N control elements from WAMP messages containing payloads,
keeping the rest as binary.
""".
-spec decode_head(binary(), pos_integer()) ->
    [term()] | {[term()], binary()}.

decode_head(Bin, NumElements)
when is_binary(Bin), is_integer(NumElements), NumElements > 0 ->
    case parse_array_header(Bin) of
        {ok, ArrayLen, Rest} ->
            decode_n_elements(Rest, NumElements, ArrayLen, []);

        {indefinite, Rest} ->
            decode_n_elements_indefinite(Rest, NumElements, []);

        error ->
            error(
                bondy_stdlib_error:new(#{
                    type => badarg,
                    details => #{1 => Bin, 2 => NumElements}
                })
            )
    end;

decode_head(Bin, NumElements) ->
    error(
        bondy_stdlib_error:new(#{
            type => badarg,
            details => #{1 => Bin, 2 => NumElements}
        })
    ).


-spec decode_tail(binary()) -> term() | no_return().

decode_tail(Term) ->
    Opts = bondy_wamp_config:get([cbor, decode_opts], ?DEFAULT_DECODE_OPTS),
    decode_tail(Term, Opts).


-doc "Decode the CBOR tail binary back into Erlang terms.".
-spec decode_tail(binary(), key_value:t()) -> term() | no_return().

decode_tail(<<>>, _) ->
    [];

decode_tail(Bin, Opts) when is_binary(Bin) ->
    %% The tail contains raw CBOR-encoded elements without array wrapper
    %% We need to wrap them in an array and decode
    ElementCount = count_cbor_elements(Bin),

    case ElementCount of
        0 ->
            [];

        N ->
            %% Wrap in CBOR array and decode
            HeaderBin = encode_array_header(N),
            WrappedBin = <<HeaderBin/binary, Bin/binary>>,
            do_decode(WrappedBin, Opts)
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


validate_opt({check_duplicate_keys, Arg} = Term) ->
    is_boolean(Arg) orelse
    error(badarg, {check_duplicate_keys, Arg}),
    Term;

validate_opt({datetime_format, _Opts} = Term) ->
    %% TODO
    Term;

validate_opt(Term) ->
    Term.


%% @private
do_encode(Term, Opts) ->
    ValidatedOpts = validate_opts(Opts),
    Checked = key_value:get(check_duplicate_keys, ValidatedOpts, false),

    Fun = fun
        (undefined, _Encode) ->
            %% Encode undefined as CBOR null for JSON compatibility
            <<16#F6>>;

        ({{Y, M, D}, {H, Mi, S}}, _Encode)
        when ?IS_DATETIME(Y, M, D, H, Mi, S) ->
            %% Encode datetime as ISO8601 text string
            DatetimeBin = iolist_to_binary(encode_datetime({{Y, M, D}, {H, Mi, S}})),
            bondy_cbor:encode_string(DatetimeBin);

        ([{_, _} | _] = Value, Encode) when is_list(Value), Checked == true ->
            bondy_cbor:encode_key_value_list_checked(Value, Encode);

        ([{_, _} | _] = Value, Encode) when is_list(Value), Checked == false ->
            bondy_cbor:encode_key_value_list(Value, Encode);

        (Value, Encode) ->
            bondy_cbor:encode_value(Value, Encode)
    end,

    iolist_to_binary(bondy_cbor:encode(Term, Fun)).


%% @private
do_decode(Term, []) ->
    bondy_cbor:decode(Term);

do_decode(Term, Opts) ->
    Decoders = key_value:get(decoders, Opts, #{}),

    case bondy_cbor:decode(Term, ok, Decoders) of
        {Value, ok, <<>>} ->
            Value;

        Other ->
            error({badarg, Other})
    end.


%% @private
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
%% PRIVATE: CBOR PARSING HELPERS
%% =============================================================================


%% @private
%% Parse CBOR array header and return length and remaining binary
parse_array_header(<<MajorAndInfo, Rest/binary>>) ->
    Major = MajorAndInfo bsr 5,
    Info = MajorAndInfo band 16#1f,

    case Major of
        ?CBOR_ARRAY when Info < 24 ->
            %% Length encoded in info bits
            {ok, Info, Rest};

        ?CBOR_ARRAY when Info =:= 24 ->
            %% 1-byte length follows
            <<Len:8, Rest2/binary>> = Rest,
            {ok, Len, Rest2};

        ?CBOR_ARRAY when Info =:= 25 ->
            %% 2-byte length follows
            <<Len:16, Rest2/binary>> = Rest,
            {ok, Len, Rest2};

        ?CBOR_ARRAY when Info =:= 26 ->
            %% 4-byte length follows
            <<Len:32, Rest2/binary>> = Rest,
            {ok, Len, Rest2};

        ?CBOR_ARRAY when Info =:= 27 ->
            %% 8-byte length follows
            <<Len:64, Rest2/binary>> = Rest,
            {ok, Len, Rest2};

        ?CBOR_ARRAY when Info =:= 31 ->
            %% Indefinite-length array
            {indefinite, Rest};

        _ ->
            error
    end;

parse_array_header(_) ->
    error.


%% @private
%% Encode a CBOR array header for given length
encode_array_header(Len) when Len < 24 ->
    Byte = (?CBOR_ARRAY bsl 5) bor Len,
    <<Byte>>;

encode_array_header(Len) when Len < 256 ->
    Byte = (?CBOR_ARRAY bsl 5) bor 24,
    <<Byte, Len:8>>;

encode_array_header(Len) when Len < 65536 ->
    Byte = (?CBOR_ARRAY bsl 5) bor 25,
    <<Byte, Len:16>>;

encode_array_header(Len) when Len < 4294967296 ->
    Byte = (?CBOR_ARRAY bsl 5) bor 26,
    <<Byte, Len:32>>;

encode_array_header(Len) ->
    Byte = (?CBOR_ARRAY bsl 5) bor 27,
    <<Byte, Len:64>>.


%% @private
%% Decode N elements from a definite-length array
decode_n_elements(Rest, 0, _ArrayLen, Acc) ->
    Elements = lists:reverse(Acc),
    case Rest of
        <<>> ->
            Elements;

        _ ->
            {Elements, Rest}
    end;

decode_n_elements(<<>>, _N, _ArrayLen, Acc) ->
    lists:reverse(Acc);

decode_n_elements(Bin, N, ArrayLen, Acc) when N > 0, ArrayLen > 0 ->
    case decode_single_element(Bin) of
        {ok, Element, Rest} ->
            decode_n_elements(Rest, N - 1, ArrayLen - 1, [Element | Acc]);

        error ->
            error(
                bondy_stdlib_error:new(#{
                    type => badarg,
                    details => #{reason => cbor_decode_error}
                })
            )
    end;

decode_n_elements(Rest, _N, 0, Acc) ->
    %% Array ended before we got N elements
    Elements = lists:reverse(Acc),
    case Rest of
        <<>> ->
            Elements;

        _ ->
            {Elements, Rest}
    end.


%% @private
%% Decode N elements from an indefinite-length array
decode_n_elements_indefinite(<<16#ff, _Rest/binary>>, _N, Acc) ->
    %% Hit break code
    lists:reverse(Acc);

decode_n_elements_indefinite(Rest, 0, Acc) ->
    Elements = lists:reverse(Acc),
    case Rest of
        <<16#ff>> ->
            Elements;

        <<>> ->
            Elements;

        _ ->
            {Elements, Rest}
    end;

decode_n_elements_indefinite(Bin, N, Acc) when N > 0 ->
    case decode_single_element(Bin) of
        {ok, Element, Rest} ->
            decode_n_elements_indefinite(Rest, N - 1, [Element | Acc]);

        error ->
            error(
                bondy_stdlib_error:new(#{
                    type => badarg,
                    details => #{reason => cbor_decode_error}
                })
            )
    end.


%% @private
%% Decode a single CBOR element and return the remaining binary
decode_single_element(Bin) ->
    case skip_cbor_value(Bin) of
        {ok, ValueBin, Rest} ->
            Value = bondy_cbor:decode(ValueBin),
            {ok, Value, Rest};

        error ->
            error
    end.


%% @private
%% Skip over a complete CBOR value and return its binary and the rest
skip_cbor_value(<<>>) ->
    error;

skip_cbor_value(<<MajorAndInfo, Rest/binary>> = Bin) ->
    Major = MajorAndInfo bsr 5,
    Info = MajorAndInfo band 16#1f,

    case Major of
        ?CBOR_UINT ->
            skip_uint(Bin, Info, Rest);

        ?CBOR_NEGINT ->
            skip_uint(Bin, Info, Rest);

        ?CBOR_BYTES ->
            skip_bytes_or_text(Bin, Info, Rest);

        ?CBOR_TEXT ->
            skip_bytes_or_text(Bin, Info, Rest);

        ?CBOR_ARRAY ->
            skip_array(Bin, Info, Rest);

        ?CBOR_MAP ->
            skip_map(Bin, Info, Rest);

        ?CBOR_TAG ->
            skip_tag(Bin, Info, Rest);

        ?CBOR_SIMPLE ->
            skip_simple(Bin, Info, Rest)
    end.


%% @private
skip_uint(Bin, Info, Rest) when Info < 24 ->
    {ok, binary:part(Bin, 0, 1), Rest};

skip_uint(Bin, 24, Rest) ->
    <<_:8, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 2), Rest2};

skip_uint(Bin, 25, Rest) ->
    <<_:16, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 3), Rest2};

skip_uint(Bin, 26, Rest) ->
    <<_:32, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 5), Rest2};

skip_uint(Bin, 27, Rest) ->
    <<_:64, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 9), Rest2};

skip_uint(_, _, _) ->
    error.


%% @private
skip_bytes_or_text(Bin, Info, Rest) when Info < 24 ->
    case Rest of
        <<_:Info/binary, Rest2/binary>> ->
            Len = 1 + Info,
            {ok, binary:part(Bin, 0, Len), Rest2};

        _ ->
            error
    end;

skip_bytes_or_text(Bin, 24, Rest) ->
    <<DataLen:8, Data/binary>> = Rest,
    case Data of
        <<_:DataLen/binary, Rest2/binary>> ->
            Len = 2 + DataLen,
            {ok, binary:part(Bin, 0, Len), Rest2};

        _ ->
            error
    end;

skip_bytes_or_text(Bin, 25, Rest) ->
    <<DataLen:16, Data/binary>> = Rest,
    case Data of
        <<_:DataLen/binary, Rest2/binary>> ->
            Len = 3 + DataLen,
            {ok, binary:part(Bin, 0, Len), Rest2};

        _ ->
            error
    end;

skip_bytes_or_text(Bin, 26, Rest) ->
    <<DataLen:32, Data/binary>> = Rest,
    case Data of
        <<_:DataLen/binary, Rest2/binary>> ->
            Len = 5 + DataLen,
            {ok, binary:part(Bin, 0, Len), Rest2};

        _ ->
            error
    end;

skip_bytes_or_text(Bin, 27, Rest) ->
    <<DataLen:64, Data/binary>> = Rest,
    case Data of
        <<_:DataLen/binary, Rest2/binary>> ->
            Len = 9 + DataLen,
            {ok, binary:part(Bin, 0, Len), Rest2};

        _ ->
            error
    end;

skip_bytes_or_text(_Bin, 31, Rest) ->
    %% Indefinite-length bytes/text - skip chunks until break
    skip_indefinite_chunks(Rest, 1);

skip_bytes_or_text(_, _, _) ->
    error.


%% @private
skip_indefinite_chunks(<<16#ff, Rest/binary>>, _StartPos) ->
    %% Break code - end of indefinite-length item
    %% We need the original binary to extract the value
    %% This is tricky - for now, just error on indefinite chunks
    {ok, <<16#ff>>, Rest};

skip_indefinite_chunks(Bin, _StartPos) ->
    %% Skip each chunk
    case skip_cbor_value(Bin) of
        {ok, _ChunkBin, Rest} ->
            skip_indefinite_chunks(Rest, 0);

        error ->
            error
    end.


%% @private
skip_array(Bin, Info, Rest) when Info < 24 ->
    skip_n_values(Rest, Info, 1, Bin);

skip_array(Bin, 24, Rest) ->
    <<ArrayLen:8, Rest2/binary>> = Rest,
    skip_n_values(Rest2, ArrayLen, 2, Bin);

skip_array(Bin, 25, Rest) ->
    <<ArrayLen:16, Rest2/binary>> = Rest,
    skip_n_values(Rest2, ArrayLen, 3, Bin);

skip_array(Bin, 26, Rest) ->
    <<ArrayLen:32, Rest2/binary>> = Rest,
    skip_n_values(Rest2, ArrayLen, 5, Bin);

skip_array(Bin, 27, Rest) ->
    <<ArrayLen:64, Rest2/binary>> = Rest,
    skip_n_values(Rest2, ArrayLen, 9, Bin);

skip_array(Bin, 31, Rest) ->
    %% Indefinite-length array
    skip_until_break(Rest, 1, Bin);

skip_array(_, _, _) ->
    error.


%% @private
skip_map(Bin, Info, Rest) when Info < 24 ->
    %% Map has Info pairs, so 2*Info values
    skip_n_values(Rest, Info * 2, 1, Bin);

skip_map(Bin, 24, Rest) ->
    <<MapLen:8, Rest2/binary>> = Rest,
    skip_n_values(Rest2, MapLen * 2, 2, Bin);

skip_map(Bin, 25, Rest) ->
    <<MapLen:16, Rest2/binary>> = Rest,
    skip_n_values(Rest2, MapLen * 2, 3, Bin);

skip_map(Bin, 26, Rest) ->
    <<MapLen:32, Rest2/binary>> = Rest,
    skip_n_values(Rest2, MapLen * 2, 5, Bin);

skip_map(Bin, 27, Rest) ->
    <<MapLen:64, Rest2/binary>> = Rest,
    skip_n_values(Rest2, MapLen * 2, 9, Bin);

skip_map(Bin, 31, Rest) ->
    %% Indefinite-length map
    skip_until_break(Rest, 1, Bin);

skip_map(_, _, _) ->
    error.


%% @private
skip_tag(Bin, Info, Rest) ->
    %% Skip the tag number, then skip the tagged value
    {_HeaderLen, Rest2} = case Info of
        I when I < 24 ->
            {1, Rest};

        24 ->
            <<_:8, R/binary>> = Rest,
            {2, R};

        25 ->
            <<_:16, R/binary>> = Rest,
            {3, R};

        26 ->
            <<_:32, R/binary>> = Rest,
            {5, R};

        27 ->
            <<_:64, R/binary>> = Rest,
            {9, R};

        _ ->
            {0, error}
    end,

    case Rest2 of
        error ->
            error;

        _ ->
            case skip_cbor_value(Rest2) of
                {ok, _ValueBin, Rest3} ->
                    TotalLen = byte_size(Bin) - byte_size(Rest3),
                    {ok, binary:part(Bin, 0, TotalLen), Rest3};

                error ->
                    error
            end
    end.


%% @private
skip_simple(Bin, Info, Rest) when Info < 24 ->
    {ok, binary:part(Bin, 0, 1), Rest};

skip_simple(Bin, 24, Rest) ->
    <<_:8, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 2), Rest2};

skip_simple(Bin, 25, Rest) ->
    %% Half-precision float (2 bytes)
    <<_:16, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 3), Rest2};

skip_simple(Bin, 26, Rest) ->
    %% Single-precision float (4 bytes)
    <<_:32, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 5), Rest2};

skip_simple(Bin, 27, Rest) ->
    %% Double-precision float (8 bytes)
    <<_:64, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 9), Rest2};

skip_simple(_, _, _) ->
    error.


%% @private
%% Skip N CBOR values
skip_n_values(Rest, 0, _HeaderLen, OrigBin) ->
    TotalLen = byte_size(OrigBin) - byte_size(Rest),
    {ok, binary:part(OrigBin, 0, TotalLen), Rest};

skip_n_values(Bin, N, HeaderLen, OrigBin) when N > 0 ->
    case skip_cbor_value(Bin) of
        {ok, _ValueBin, Rest} ->
            skip_n_values(Rest, N - 1, HeaderLen, OrigBin);

        error ->
            error
    end.


%% @private
%% Skip values until break code (0xff)
skip_until_break(<<16#ff, Rest/binary>>, _HeaderLen, OrigBin) ->
    TotalLen = byte_size(OrigBin) - byte_size(Rest),
    {ok, binary:part(OrigBin, 0, TotalLen), Rest};

skip_until_break(Bin, HeaderLen, OrigBin) ->
    case skip_cbor_value(Bin) of
        {ok, _ValueBin, Rest} ->
            skip_until_break(Rest, HeaderLen, OrigBin);

        error ->
            error
    end.


%% @private
%% Count the number of CBOR elements in a binary (raw elements, no array wrapper)
count_cbor_elements(<<>>) ->
    0;

count_cbor_elements(Bin) ->
    count_cbor_elements(Bin, 0).

count_cbor_elements(<<>>, Count) ->
    Count;

count_cbor_elements(Bin, Count) ->
    case skip_cbor_value(Bin) of
        {ok, _ValueBin, Rest} ->
            count_cbor_elements(Rest, Count + 1);

        error ->
            Count
    end.
