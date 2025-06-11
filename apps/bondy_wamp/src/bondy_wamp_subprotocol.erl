-module(bondy_wamp_subprotocol).
-include("bondy_wamp.hrl").


-define(IS_WAMP_TRANSPORT(X), (T =:= ws orelse T =:= raw)).

-export([from_binary/1]).
-export([validate/1]).





%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec from_binary(binary()) -> subprotocol() | {error, invalid_subprotocol}.

from_binary(?WAMP2_JSON) ->                 {ws, text, json};
from_binary(?WAMP2_MSGPACK) ->              {ws, binary, msgpack};
from_binary(?WAMP2_JSON_BATCHED) ->         {ws, text, json_batched};
from_binary(?WAMP2_MSGPACK_BATCHED) ->      {ws, binary, msgpack_batched};
from_binary(?WAMP2_BERT) ->                 {ws, binary, bert};
from_binary(?WAMP2_ERL) ->                  {ws, binary, erl};
from_binary(?WAMP2_BERT_BATCHED) ->         {ws, binary, bert_batched};
from_binary(?WAMP2_ERL_BATCHED) ->          {ws, binary, erl_batched};
from_binary(_) ->                           {error, invalid_subprotocol}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec validate(binary() | subprotocol()) ->
    {ok, subprotocol()} | {error, invalid_subprotocol}.

validate(T) when is_binary(T) ->
    case from_binary(T) of
        {error, _} = Error -> Error;
        Subprotocol -> {ok, Subprotocol}
    end;
validate({ws, text, json} = S) ->
    {ok, S};
validate({ws, text, json_batched} = S) ->
    {ok, S};
validate({ws, binary, msgpack_batched} = S) ->
    {ok, S};
validate({ws, binary, bert_batched} = S) ->
    {ok, S};
validate({ws, binary, erl_batched} = S) ->
    {ok, S};
validate({raw, binary, json} = S) ->
    {ok, S};
validate({T, binary, erl} = S) when ?IS_WAMP_TRANSPORT(T) ->
    {ok, S};
validate({T, binary, msgpack} = S) when ?IS_WAMP_TRANSPORT(T) ->
    {ok, S};
validate({T, binary, bert} = S) when ?IS_WAMP_TRANSPORT(T) ->
    {ok, S};
validate(_) ->
    {error, invalid_subprotocol}.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% is_transport(ws) -> true;
%% is_transport(wss) -> true;
%% is_transport(raw) -> true;
%% is_transport(raws) -> true;
%% is_transport(tcp) -> true;
%% is_transport(tls) -> true;
%% is_transport(ssl) -> false.
