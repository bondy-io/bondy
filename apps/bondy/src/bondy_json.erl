%% =============================================================================
%%  bondy_json.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc A utility module that offers some customisation options over the jsone
%% module.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_json).

%% For backwards compat with jsx lib used in previous versions
-define(DEFAULT_FLOAT_FORMAT, [{decimals, 16}]).
-define(DEFAULT_ENCODE_OPTS, [{float_format, ?DEFAULT_FLOAT_FORMAT}]).
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

%% idem erlang:float_to_binary/2 options
-type float_format()    ::  {scientific, Decimals :: 0..249}
                            | {decimals, Decimals :: 0..253}
                            | compact
                            | short.

-export([decode/1]).
-export([decode/2]).
-export([encode/1]).
-export([encode/2]).
-export([try_decode/1]).
-export([try_decode/2]).
-export([validate_opts/1]).


%% =============================================================================
%% API
%% =============================================================================
-spec encode(any()) -> binary().

encode(Term) ->
    encode(Term, bondy_config:get(json, ?DEFAULT_ENCODE_OPTS)).


-spec encode(any(), [encode_opt()]) -> iodata() | binary().

encode(Term, Opts) ->
    do_encode(Term, Opts).


decode(Term) ->
    decode(Term, []).


decode(Term, Opts) ->
     do_decode(Term, Opts).


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

do_decode(Term, _Opts) ->
    json:decode(Term).


-if(?OTP_RELEASE >= 27).

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


%% -spec format_tz_(integer()) -> iolist().
%% format_tz_(S) ->
%%     H = S div ?SECONDS_PER_HOUR,
%%     S1 = S rem ?SECONDS_PER_HOUR,
%%     M = S1 div ?SECONDS_PER_MINUTE,
%%     [format2digit(H), $:, format2digit(M)].

-endif.
