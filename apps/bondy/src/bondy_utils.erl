-module(bondy_utils).
-include_lib("wamp/include/wamp.hrl").

-export([merge_map_flags/2]).
-export([get_id/1]).
-export([get_nonce/0]).
-export([get_random_string/2]).
-export([timeout/1]).
-export([error_http_code/1]).
-export([eval_term/2]).
-export([maybe_encode/2]).
-export([encode/2]).
-export([decode/2]).
-export([uuid/0]).
-export([is_uuid/1]).
-export([to_binary_keys/1]).


%% =============================================================================
%%  API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
to_binary_keys(Map) when is_map(Map) ->
    F = fun
        (K, V, Acc) when is_binary(K) ->
            maps:put(K, V, Acc);
        (K, V, Acc) when is_atom(K) ->
            maps:put(list_to_binary(atom_to_list(K)), V, Acc)
    end,
    maps:fold(F, #{}, Map).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec uuid() -> bitstring().

uuid() ->
    list_to_bitstring(uuid:uuid_to_string(uuid:get_v4())).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_uuid(any()) -> boolean().

is_uuid(Term) when is_bitstring(Term) ->
    uuid:is_v4(uuid:string_to_uuid(bitstring_to_list(Term)));

is_uuid(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
maybe_encode(_, <<>>) ->
    <<>>;

maybe_encode(json, Term) ->
    case jsx:is_json(Term) of
        true ->
            Term;
        false ->
            jsx:encode(Term)
    end;

 maybe_encode(msgpack, Term) ->
     %% TODO see if we can catch error when Term is already encoded
     msgpack:encode(Term).



%% @private
decode(json, <<>>) ->
    <<>>;

decode(json, Term) ->
    jsx:decode(Term, [return_maps]);

decode(msgpack, Term) ->
    Opts = [
        {map_format, map}, 
        {unpack_str, as_binary}
    ],
    {ok, Bin} = msgpack:unpack(Term, Opts),
    Bin.


%% @private
encode(json, Term) ->
    jsx:encode(Term);

encode(msgpack, Term) ->
    Opts = [
        {map_format, map},
        {pack_str, from_binary}
    ],
    msgpack:pack(Term, Opts).

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
%% @doc
%% @end
%% -----------------------------------------------------------------------------

timeout(#{timeout := T}) when is_integer(T), T > 0 ->
    T;
timeout(#{timeout := 0}) ->
    infinity;
timeout(_) ->
    bondy_config:request_timeout().


%% -----------------------------------------------------------------------------
%% @doc
%% The call will fail with a {badkey, any()} exception is any key found in M1
%% is not present in M2.
%% @end
%% -----------------------------------------------------------------------------
merge_map_flags(M1, M2) when is_map(M1) andalso is_map(M2) ->
    maps:fold(fun merge_fun/3, M2, M1).




%% @private
error_http_code(timeout) ->                                     504;
error_http_code(?WAMP_ERROR_AUTHORIZATION_FAILED) ->            403;
error_http_code(?WAMP_ERROR_CANCELLED) ->                       500;
error_http_code(?WAMP_ERROR_CLOSE_REALM) ->                     500;
error_http_code(?WAMP_ERROR_DISCLOSE_ME_NOT_ALLOWED) ->         500;
error_http_code(?WAMP_ERROR_GOODBYE_AND_OUT) ->                 500;
error_http_code(?WAMP_ERROR_INVALID_ARGUMENT) ->                400;
error_http_code(?WAMP_ERROR_INVALID_URI) ->                     502; 
error_http_code(?WAMP_ERROR_NET_FAILURE) ->                     502; 
error_http_code(?WAMP_ERROR_NOT_AUTHORIZED) ->                  401; 
error_http_code(?WAMP_ERROR_NO_ELIGIBLE_CALLE) ->               502; 
error_http_code(?WAMP_ERROR_NO_SUCH_PROCEDURE) ->               501; 
error_http_code(?WAMP_ERROR_NO_SUCH_REALM) ->                   502; 
error_http_code(?WAMP_ERROR_NO_SUCH_REGISTRATION) ->            502;
error_http_code(?WAMP_ERROR_NO_SUCH_ROLE) ->                    400;
error_http_code(?WAMP_ERROR_NO_SUCH_SESSION) ->                 500;
error_http_code(?WAMP_ERROR_NO_SUCH_SUBSCRIPTION) ->            502;
error_http_code(?WAMP_ERROR_OPTION_DISALLOWED_DISCLOSE_ME) ->   500;
error_http_code(?WAMP_ERROR_OPTION_NOT_ALLOWED) ->              400;
error_http_code(?WAMP_ERROR_PROCEDURE_ALREADY_EXISTS) ->        400;
error_http_code(?WAMP_ERROR_SYSTEM_SHUTDOWN) ->                 500;
error_http_code(_) ->                                           500.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec eval_term(any(), map()) -> any().

eval_term(F, Ctxt) when is_function(F, 1) ->
    F(Ctxt);

eval_term(Map, Ctxt) when is_map(Map) ->
    F = fun
        (_, V) ->
            eval_term(V, Ctxt)
    end,
    maps:map(F, Map);

eval_term(L, Ctxt) when is_list(L) ->
    [eval_term(X, Ctxt) || X <- L];

eval_term(T, Ctxt) ->
    mops:eval(T, Ctxt).


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


get_nonce() ->
    list_to_binary(
        get_random_string(
            32, 
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")).



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