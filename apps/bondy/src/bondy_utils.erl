%% =============================================================================
%%  bondy_utils.erl -
%%
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
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
-export([external_session_id/1]).
-export([foreach/2]).
-export([gen_message_id/1]).
-export([generate_fragment/1]).
-export([get_ipaddr/2]).
-export([get_nonce/0]).
-export([get_nonce/1]).
-export([get_random_string/2]).
-export([groups_from_list/2]).
-export([groups_from_list/3]).
-export([is_uuid/1]).
-export([json_consult/1]).
-export([json_consult/2]).
-export([maybe_encode/2]).
-export([maybe_slice/3]).
-export([peername/2]).
-export([pid_to_bin/1]).
-export([rebase_object/1]).
-export([rebase_object/2]).
-export([session_id_to_uri_part/1]).
-export([system_time_to_rfc3339/2]).
-export([tc/3]).
-export([timed_mac/3]).
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
    %% TODO this is wrong, we should be passing the metadada so that we know in
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
-spec gen_message_id(Scope :: global | {router, uri()} | {session, id()}) ->
    id().

gen_message_id(global) ->
    %% IDs in the _global scope_ MUST be drawn _randomly_ from a _uniform
    %% distribution_ over the complete range [0, 2^53]
    wamp_utils:rand_uniform();

gen_message_id({router, _}) ->
    gen_message_id(global);

gen_message_id({session, SessionOrId}) ->
    %% IDs in the _session scope_ SHOULD be incremented by 1 beginning
    %% with 1 (for each direction - _Client-to-Router_ and _Router-to-
    %% Client_)
    %% This is the router-to-client direction
    bondy_session:gen_message_id(SessionOrId).


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
-spec external_session_id(optional(bondy_session_id:t())) -> optional(id()).

external_session_id(Term) when is_binary(Term) ->
    bondy_session_id:to_external(Term);

external_session_id(undefined) ->
    undefined.

%% -----------------------------------------------------------------------------
%% @doc It returns the timeout in ms.
%% - Provided timeout if it is greater than 0
%% - wamp_max_call_timeout if the provided timeout is equals to 0
%% - wamp_call_timeout if no timeout is provided
%% @end
%% -----------------------------------------------------------------------------
timeout(#{timeout := T}) when is_integer(T), T > 0 ->
    T;
timeout(#{timeout := 0}) ->
    bondy_config:get(wamp_max_call_timeout);
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



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peername(
    Transport :: atom(), Socket :: gen_tcp:socket() | ssl:socket()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, any()}.

%% @private
peername(Transport, Socket) when Transport == ranch_tcp; Transport == tcp ->
    inet:peername(Socket);

peername(Transport, Socket) when Transport == ranch_ssl; Transport == ssl ->
    ssl:peername(Socket).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
get_ipaddr(localhost, IPVersion) ->
    {ok, IP} = inet:getaddr("localhost", IPVersion),
    IP;

get_ipaddr(hostname, IPVersion) ->
    {ok, Hostname} = inet:gethostname(),
    {ok, IP} = inet:getaddr(Hostname, IPVersion),
    IP;

get_ipaddr(partisan, _) ->
    #{listen_addrs := [Addr|_]} = partisan:node_spec(),
    maps:get(ip, Addr);

get_ipaddr(IP0, IPVersion) ->
    case inet:getaddr(IP0, IPVersion) of
        {ok, IP} ->
            IP;
        {error, _} ->
            exit({badarg, [IP0, IPVersion]})
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec rebase_object(Value :: term()) -> plum_db_object:t().

rebase_object(Value) ->
    rebase_object(Value, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec rebase_object(Value :: term(), Actor :: term()) -> plum_db_object:t().

rebase_object(Value, undefined) ->
    rebase_object(Value, '$bondy');

rebase_object(Value, Actor) ->
    Timestamp = {0, 0, 0},
    NewRecord = plum_db_dvvset:new({Value, Timestamp}),
    {object, plum_db_dvvset:update(NewRecord, Actor)}.



%% =============================================================================
%%  PRIVATE
%% =============================================================================



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


%% -----------------------------------------------------------------------------
%% @doc Creates a time-dependent Message Authentication Code with byte length
%% `Len' duration in seconds `Duration' and secret `Secret'.
%% @end
%% -----------------------------------------------------------------------------
-spec timed_mac(Secret :: binary(), Duration :: integer(), Len :: integer()) ->
    binary().

timed_mac(Secret, Duration, Len) ->
    {MegaSecs, Secs, _} = os:timestamp(),
    Interval = trunc((MegaSecs * 1000000 + (Secs + Duration)) / Duration),
    Msg = <<Interval:8/big-unsigned-integer-unit:8>>,
    crypto:macN(hmac, sha, Secret, Msg, Len).





%% -----------------------------------------------------------------------------
%% @doc
%% Borrowed from https://github.com/erlang/otp/blob/master/lib/stdlib/src/
%% maps.erl
%% @end
%% -----------------------------------------------------------------------------
-spec groups_from_list(Fun, List) -> MapOut when
    Fun :: fun((Elem :: T) -> Selected),
    MapOut :: #{Selected => List},
    Selected :: term(),
    List :: [T],
    T :: term().

groups_from_list(Fun, List0) when is_function(Fun, 1) ->
    try lists:reverse(List0) of
        List ->
            groups_from_list_1(Fun, List, #{})
    catch
        error:_ ->
            badarg_with_info([Fun, List0])
    end;

groups_from_list(Fun, List) ->
    badarg_with_info([Fun, List]).



%% -----------------------------------------------------------------------------
%% @doc
%% Borrowed from https://github.com/erlang/otp/blob/master/lib/stdlib/src/
%% maps.erl
%% @end
%% -----------------------------------------------------------------------------
-spec groups_from_list(Fun, ValueFun, List) -> MapOut when
    Fun :: fun((Elem :: T) -> Key),
    ValueFun :: fun((Elem :: T) -> ValOut),
    MapOut :: #{Key := ListOut},
    Key :: term(),
    ValOut :: term(),
    List :: [T],
    ListOut :: [ValOut],
    T :: term().

groups_from_list(Fun, ValueFun, List0) when is_function(Fun, 1),
                                            is_function(ValueFun, 1) ->
    try lists:reverse(List0) of
        List ->
            groups_from_list_2(Fun, ValueFun, List, #{})
    catch
        error:_ ->
            badarg_with_info([Fun, ValueFun, List0])
    end;

groups_from_list(Fun, ValueFun, List) ->
    badarg_with_info([Fun, ValueFun, List]).





%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
groups_from_list_1(Fun, [H | Tail], Acc) ->
    K = Fun(H),
    NewAcc = case Acc of
                 #{K := Vs} -> Acc#{K := [H | Vs]};
                 #{} -> Acc#{K => [H]}
             end,
    groups_from_list_1(Fun, Tail, NewAcc);
groups_from_list_1(_Fun, [], Acc) ->
    Acc.


%% @private
groups_from_list_2(Fun, ValueFun, [H | Tail], Acc) ->
    K = Fun(H),
    V = ValueFun(H),
    NewAcc = case Acc of
                 #{K := Vs} -> Acc#{K := [V | Vs]};
                 #{} -> Acc#{K => [V]}
             end,
    groups_from_list_2(Fun, ValueFun, Tail, NewAcc);

groups_from_list_2(_Fun, _ValueFun, [], Acc) ->
    Acc.


%% @private
badarg_with_info(Args) ->
    erlang:error(badarg, Args, [{error_info, #{module => erl_stdlib_errors}}]).
