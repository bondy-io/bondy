%% =============================================================================
%%  bondy_utils.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_utils).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").


-export([bin_to_pid/1]).
-export([decode/2]).
-export([elapsed_time/2]).
-export([foreach/2]).
-export([generate_fragment/1]).
-export([get_id/1]).
-export([get_nonce/0]).
-export([get_nonce/1]).
-export([get_random_string/2]).
-export([is_uuid/1]).
-export([json_consult/1]).
-export([json_consult/2]).
-export([maybe_encode/2]).
-export([maybe_slice/3]).
-export([merge_map_flags/2]).
-export([pid_to_bin/1]).
-export([session_id_to_uri_part/1]).
-export([system_time_to_rfc3339/2]).
-export([tc/3]).
-export([timeout/1]).
-export([to_binary_keys/1]).
-export([to_existing_atom_keys/1]).
-export([uuid/0]).
-export([uuid/1]).



%% =============================================================================
%%  API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec foreach(
    Do :: fun((Elem :: term() | {continue, Cont :: any()}) -> term()),
    ?EOT | {[term()], Cont :: any()} | list()) -> ok.

foreach(_, ?EOT) ->
    ok;

foreach(Fun, {L, Cont}) ->
    ok = lists:foreach(Fun, L),
    foreach(Fun, Fun({continue, Cont}));

foreach(Fun, L) when is_list(L) ->
    lists:foreach(Fun, L).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
pid_to_bin(Pid) ->
    list_to_binary(pid_to_list(Pid)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
bin_to_pid(Bin) ->
    list_to_pid(binary_to_list(Bin)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
to_binary_keys(Map) when is_map(Map) ->
    F = fun
        (K, V, Acc) when is_binary(K) ->
            maps:put(K, maybe_to_binary_keys(V), Acc);
        (K, V, Acc) when is_atom(K) ->
            maps:put(list_to_binary(atom_to_list(K)), maybe_to_binary_keys(V), Acc)
    end,
    maps:fold(F, #{}, Map).



%% @private
maybe_to_binary_keys(T) when is_map(T) ->
    to_binary_keys(T);

maybe_to_binary_keys(T) ->
    T.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
to_existing_atom_keys(Map) when is_map(Map) ->
    F = fun
        (K, V, Acc) when is_binary(K) andalso is_map(V) ->
            maps:put(
                binary_to_existing_atom(K, utf8),
                to_existing_atom_keys(V),
                Acc
            );

        (K, V, Acc) when is_binary(K) ->
            maps:put(binary_to_existing_atom(K, utf8), V, Acc);

        (K, V, Acc) when is_atom(K) andalso is_map(V) ->
            maps:put(K, to_existing_atom_keys(V), Acc);

        (K, V, Acc) when is_atom(K) ->
            maps:put(K, V, Acc)
    end,
    maps:fold(F, #{}, Map).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec uuid() -> binary().

uuid() ->
    list_to_binary(uuid:uuid_to_string(uuid:get_v4())).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec uuid(Prefix :: binary()) -> binary().

uuid(Prefix) ->
    <<Prefix/binary, (uuid())/binary>>.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_uuid(any()) -> boolean().

is_uuid(Term) when is_bitstring(Term) ->
    uuid:is_v4(uuid:string_to_uuid(binary_to_list(Term)));

is_uuid(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
maybe_encode(_, <<>>) ->
    <<>>;

maybe_encode(_, undefined) ->
    <<>>;

maybe_encode(bert, Term) ->
    bert:encode(Term);

maybe_encode(erl, Term) ->
   binary_to_term(Term);

maybe_encode(json, Term) when is_binary(Term) ->
    %% TODO this is wrong, we should be pasing the metadada so that we know in
    %% which encoding the Term is
    case jsone:try_decode(Term) of
        {ok, JSON, _} ->
            JSON;
        {error, _} ->
            jsone:encode(Term, [undefined_as_null, {object_key_type, string}])
    end;

maybe_encode(json, Term) ->
    jsone:encode(Term, [undefined_as_null, {object_key_type, string}]);

maybe_encode(msgpack, Term) ->
     %% TODO see if we can catch error when Term is already encoded
     Opts = [{map_format, map}, {pack_str, from_binary}],
     msgpack:pack(Term, Opts);

maybe_encode(Enc, Term) when is_binary(Enc) ->
    maybe_encode(binary_to_atom(Enc, utf8), Term).


maybe_slice(undefined, _, _) ->
    undefined;

maybe_slice(String, Start, Length) ->
    string:slice(String, Start, Length).


%% @private
decode(bert, Bin) ->
    bert:decode(Bin);

decode(erl, Bin) ->
   binary_to_term(Bin);

decode(json, <<>>) ->
    <<>>;

decode(json, Term) ->
    jsone:decode(Term, [undefined_as_null]);

decode(msgpack, Term) ->
    Opts = [{map_format, map}, {unpack_str, as_binary}],
    {ok, Bin} = msgpack:unpack(Term, Opts),
    Bin;

decode(ContentType, Term) ->
    %% We cannot decode this so create a wrapped data object
    #{<<"type">> => ContentType, <<"content">> => Term}.





%% -----------------------------------------------------------------------------
%% @doc
%% IDs in the _global scope_ MUST be drawn _randomly_ from a _uniform
%% distribution_ over the complete range [0, 2^53]
%% @end
%% -----------------------------------------------------------------------------
-spec get_id(Scope :: global | {router, uri()} | {session, id()}) -> id().

get_id(global) ->
    %% IDs in the _global scope_ MUST be drawn _randomly_ from a _uniform
    %% distribution_ over the complete range [0, 2^53]
    wamp_utils:rand_uniform();

get_id({router, _}) ->
    get_id(global);

get_id({session, SessionId}) when is_integer(SessionId) ->
    %% IDs in the _session scope_ SHOULD be incremented by 1 beginning
    %% with 1 (for each direction - _Client-to-Router_ and _Router-to-
    %% Client_)
    bondy_session:incr_seq(SessionId).


%% -----------------------------------------------------------------------------
%% @doc Converts a session identifier into a 0-padded binary string.
%% @end
%% -----------------------------------------------------------------------------

-spec session_id_to_uri_part(id()) -> binary().

session_id_to_uri_part(SessionId) ->
    list_to_binary(io_lib:format("~16..0B", [SessionId])).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
timeout(#{timeout := T}) when is_integer(T), T > 0 ->
    T;
timeout(#{timeout := 0}) ->
    infinity;
timeout(_) ->
    bondy_config:get(wamp_call_timeout).


%% -----------------------------------------------------------------------------
%% @doc Returns the elapsed time since Timestamp expressed in the
%% desired TimeUnit.
%% @end
%% -----------------------------------------------------------------------------
-spec elapsed_time(Timestamp :: integer(), TimeUnit :: erlang:time_unit()) ->
    integer().

elapsed_time(Timestamp, TimeUnit) ->
    Nsecs = erlang:monotonic_time() - Timestamp,
    erlang:convert_time_unit(Nsecs, nanosecond, TimeUnit).


%% -----------------------------------------------------------------------------
%% @doc
%% The call will fail with a {badkey, any()} exception is any key found in M1
%% is not present in M2.
%% @end
%% -----------------------------------------------------------------------------
merge_map_flags(M1, M2) when is_map(M1) andalso is_map(M2) ->
    maps:fold(fun merge_fun/3, M2, M1).



%% Borrowed from
%% https://github.com/kivra/oauth2/blob/master/src/oauth2_token.erl
-spec generate_fragment(non_neg_integer()) -> binary().

generate_fragment(0) ->
    <<>>;

generate_fragment(N) ->
    Rand = base64:encode(crypto:strong_rand_bytes(N)),
    Frag = << <<C>> || <<C>> <= <<Rand:N/bytes>>, is_alphanum(C) >>,
    <<Frag/binary, (generate_fragment(N - byte_size(Frag)))/binary>>.


%% @doc Returns true for alphanumeric ASCII characters, false for all others.
-spec is_alphanum(char()) -> boolean().

is_alphanum(C) when C >= 16#30 andalso C =< 16#39 -> true;
is_alphanum(C) when C >= 16#41 andalso C =< 16#5A -> true;
is_alphanum(C) when C >= 16#61 andalso C =< 16#7A -> true;
is_alphanum(_)                                    -> false.




%% =============================================================================
%%  PRIVATE
%% =============================================================================



%% @private
merge_fun(K, V, Acc) ->
    case {maps:get(K, Acc, undefined), V} of
        {true, true} -> Acc;
        {false, false} -> Acc;
        _ -> maps:put(K, false, Acc)
    end.

%% -----------------------------------------------------------------------------
%% @doc Returns a base64 encoded random string
%% @end
%% -----------------------------------------------------------------------------
get_nonce() ->
    get_nonce(32).


%% -----------------------------------------------------------------------------
%% @doc Returns a base64 encoded random string
%% @end
%% -----------------------------------------------------------------------------
get_nonce(Len) ->
    base64:encode(enacl:randombytes(Len)).


%% -----------------------------------------------------------------------------
%% @doc
%% borrowed from
%% http://blog.teemu.im/2009/11/07/generating-random-strings-in-erlang/
%% @end
%% -----------------------------------------------------------------------------
get_random_string(Length, AllowedChars) ->
    lists:foldl(
        fun(_, Acc) ->
            [lists:nth(rand:uniform(length(AllowedChars)),
            AllowedChars)]
            ++ Acc
        end,
        [],
        lists:seq(1, Length)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec json_consult(File :: file:name_all()) -> any().

json_consult(File) ->
    json_consult(File, [undefined_as_null]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec json_consult(File :: file:name_all(), Opts :: list()) ->
    {ok, any()} | {error, any()}.

json_consult(File, Opts) when is_list(Opts) ->
    case file:read_file(File) of
        {ok, JSONBin}  ->
            case jsone:try_decode(JSONBin, Opts) of
                {ok, Term, _} ->
                    {ok, Term};
                {error, {Reason, _}} ->
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
system_time_to_rfc3339(Value, Opts) ->
    String = calendar:system_time_to_rfc3339(Value, Opts),
    list_to_binary(String).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
tc(M, F, A) ->
    T1 = erlang:monotonic_time(),
    Val = apply(M, F, A),
    T2 = erlang:monotonic_time(),
    Time = erlang:convert_time_unit(T2 - T1, native, perf_counter),
    {Time, Val}.