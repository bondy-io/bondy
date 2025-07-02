%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_uuidv7).

%% UUIDv7 constants
-define(VERSION, 16#7).
%% 10 in binary (RFC 4122 variant)
-define(VARIANT, 16#2).


-type uuid_binary()     :: <<_:128>>.
-type uuid_string()     :: string().
-type timestamp()       :: non_neg_integer().
-type format_opts()     :: #{mode => urlsafe | hex}.

-export_type([uuid_binary/0]).
-export_type([uuid_string/0]).
-export_type([timestamp/0]).

-export([new/0]).
-export([from_timestamp/1]).
-export([timestamp/1]).
-export([is_valid/1]).
-export([format/1]).
-export([format/2]).
-export([parse/1]).



%% =============================================================================
%% API
%% =============================================================================

-doc """
Generate a new UUIDv7 as a binary.
""".
-spec new() -> uuid_binary().

new() ->
    from_timestamp(erlang:system_time(millisecond)).

-doc """
Generate UUIDv7 from specific timestamp in milliseconds.
""".
-spec from_timestamp(timestamp()) -> uuid_binary().

from_timestamp(Ts0) ->
    %% 48-bit timestamp (milliseconds since Unix epoch)
    Ts = Ts0 band 16#FFFFFFFFFFFF,

    %% Generate 10 bytes of random data (80 bits total)
    %% We need 74 bits of randomness (12 + 62), so 10 bytes gives us plenty
    Bytes = crypto:strong_rand_bytes(10),
    <<ABits:12, BBits:62, _:6>> = Bytes,

    %% Construct the UUID according to UUIDv7 specification:
    %% - 48 bits: timestamp (milliseconds)
    %% - 4 bits: version (0111 = 7)
    %% - 12 bits: random data A
    %% - 2 bits: variant (10)
    %% - 62 bits: random data B
    <<Ts:48, ?VERSION:4, ABits:12, ?VARIANT:2, BBits:62>>.


-doc """
Extract timestamp from UUIDv7 binary.
""".
-spec timestamp(uuid_binary()) -> timestamp() | no_return().

timestamp(<<Ts:48, Version:4, _:76>>) when Version =:= ?VERSION ->
    Ts;

timestamp(_) ->
    error(badarg).


-doc """
Check if a binary is a valid UUIDv7.
""".
-spec is_valid(uuid_binary()) -> boolean().

is_valid(<<_Timestamp:48, Version:4, _:12, Variant:2, _:62>>) ->
    Version =:= ?VERSION andalso Variant =:= ?VARIANT;

is_valid(_) ->
    false.


-doc "Format UUID binary as standard string representation.".
-spec format(uuid_binary()) -> uuid_string().

format(Bin) ->
    format(Bin, #{mode => urlsafe}).


-doc "Format UUID binary as standard string representation.".
-spec format(uuid_binary(), format_opts()) -> uuid_string().

format(<<A:32, B:16, C:16, D:16, E:48>> = Bin, Opts) when is_map(Opts) ->
    case maps:get(mode, Opts, hex) of
        hex ->
            io_lib:format(
                "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
                [A, B, C, D, E]
            );
        urlsafe ->
            base64:encode(Bin, #{mode => urlsafe, padding => false})
    end.


-doc "Parse UUID string into binary format.".
-spec parse(uuid_string()) -> uuid_binary() | no_return().

parse(String) when is_list(String) ->
    parse(list_to_binary(String));

parse(Bin) when is_binary(Bin) ->
    %% Remove hyphens and convert to uppercase
    CleanUuid = binary:replace(Bin, <<"-">>, <<>>, [global]),

    case byte_size(CleanUuid) of
        32 ->
            try
                %% Convert hex string to binary
                <<A:64, B:64>> = hex_utils:hexstr_to_bin(CleanUuid),
                <<A:64, B:64>>

            catch
                _:_ ->
                    error(badarg)
            end;
        _ ->
            error(badarg)
    end.


