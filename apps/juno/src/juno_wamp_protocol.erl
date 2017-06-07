%% 
%%  juno_wamp_subprotocol -
%% 
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(juno_wamp_protocol).
-include("juno.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(IS_TRANSPORT(X), (T =:= ws orelse T =:= raw)).

-record(wamp_state, {
    transport               ::  transport(),
    frame_type              ::  frame_type(),
    encoding                ::  encoding(),
    buffer = <<>>           ::  binary(),
    context                 ::  juno_context:context() | undefined
}).

-type frame_type()          ::  text | binary.
-type transport()           ::  ws | raw.
-type encoding()            ::  json 
                                | msgpack 
                                | json_batched 
                                | msgpack_batched
                                | bert.

-type subprotocol()         ::  {transport(), frame_type(), encoding()}.

-type state()               ::  #wamp_state{} | undefined.


-export_type([frame_type/0]).
-export_type([encoding/0]).
-export_type([subprotocol/0]).
-export_type([state/0]).

-export([init/3]).
-export([handle_data/2]).
-export([terminate/2]).
-export([validate_subprotocol/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init(binary() | subprotocol(), juno_session:peer(), map()) -> 
    {ok, state()} | {error, any(), state()}.
init(Term, Peer, Opts) ->
    case validate_subprotocol(Term) of
        {ok, Sub} ->
            do_init(Sub, Peer, Opts);
        {error, Reason} ->
            {error, Reason, undefined}
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec terminate(any(), state()) -> ok.

terminate(_, St) ->
    juno_context:close(St#wamp_state.context).





%% @private
-spec validate_subprotocol(subprotocol()) -> ok | {error, invalid_subprotocol}.

validate_subprotocol(T) when is_binary(T) ->
    {ok, subprotocol(T)};
validate_subprotocol({T, text, json} = S) when ?IS_TRANSPORT(T) ->          
    {ok, S};
validate_subprotocol({T, text, json_batched} = S) when ?IS_TRANSPORT(T) ->  
    {ok, S};
validate_subprotocol({T, binary, msgpack} = S) when ?IS_TRANSPORT(T) ->     
    {ok, S};
validate_subprotocol({T, binary, msgpack_batched} = S) when ?IS_TRANSPORT(T) ->
    {ok, S};
validate_subprotocol({T, binary, bert} = S) when ?IS_TRANSPORT(T) ->        
    {ok, S};
validate_subprotocol({T, binary, bert_batched} = S) when ?IS_TRANSPORT(T) ->
    {ok, S};
validate_subprotocol({T, binary, erl} = S) when ?IS_TRANSPORT(T) ->         
    {ok, S};
validate_subprotocol({T, binary, erl_batched} = S) when ?IS_TRANSPORT(T) -> 
    {ok, S};
validate_subprotocol(_) ->                             
    {error, invalid_subprotocol}.




%% -----------------------------------------------------------------------------
%% @doc
%% Handles wamp frames, decoding 1 or more messages, routing them and replying
%% the client when required.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_data(binary(), state()) ->
    {ok, state()} 
    | {stop, state()}
    | {stop, [binary()], state()}
    | {reply, [binary()], state()}.

handle_data(Data0, #wamp_state{frame_type = T, encoding = E} = St) ->
    Data1 = <<(St#wamp_state.buffer)/binary, Data0/binary>>,
    {Messages, Buffer} = wamp_encoding:decode(Data1, T, E),
    handle_messages(Messages, St#wamp_state{buffer = Buffer}, []).




%% =============================================================================
%% PRIVATE: HANDLING MESSAGES
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Handles one or more messages, routing them and returning a reply
%% when required.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_messages([wamp_message()], state(), Acc :: [wamp_message()]) ->
    {ok, state()} 
    | {stop, state()}
    | {stop, [binary()], state()}
    | {reply, [binary()], state()}.

handle_messages([], St, []) ->
    %% We have no replies
    {ok, St};

handle_messages([], St, Acc) ->
    {reply, lists:reverse(Acc), St};

handle_messages([#goodbye{} = M|_], St, Acc) ->
    %% The client initiated a goodbye, so we will not process
    %% any subsequent messages
   case juno_router:forward(M, St#wamp_state.context) of
        {stop, Ctxt} ->
            {stop, lists:reverse(Acc), update_context(Ctxt, St)};
        {stop, Reply, Ctxt} ->
            Bin = wamp_encoding:encode(Reply, St#wamp_state.encoding),
            {stop, lists:reverse([Bin|Acc]), update_context(Ctxt, St)}
    end;

handle_messages([H|T], St, Acc) ->
    case juno_router:forward(H, St#wamp_state.context) of
        {ok, Ctxt} ->
            handle_messages(T, update_context(Ctxt, St), Acc);
        {reply, M, Ctxt} ->
            Bin = wamp_encoding:encode(M, St#wamp_state.encoding),
            handle_messages(T, update_context(Ctxt, St), [Bin | Acc]);
        {stop, M, Ctxt} ->
            Bin = wamp_encoding:encode(M, St#wamp_state.encoding),
            {stop, [Bin], update_context(Ctxt, St)}
    end.







%% =============================================================================
%% PRIVATE: UTILS
%% =============================================================================


%% @private
do_init({T, FrameType, Enc}, Peer, _Opts) ->
    State = #wamp_state{
        transport = T,
        frame_type = FrameType,
        encoding = Enc,
        context = juno_context:set_peer(juno_context:new(), Peer)
    },
    {ok, State}.


%% @private
update_context(Ctxt, St) ->
    St#wamp_state{context = Ctxt}.


%% @private
maybe_update_state(#result{request_id = CallId}, St) ->
    Ctxt1 = juno_context:remove_awaiting_call_id(St#wamp_state.context, CallId),
    update_context(juno_context:reset(Ctxt1), St);

maybe_update_state(
    #error{request_type = ?CALL, request_id = CallId}, St) ->
    Ctxt1 = juno_context:remove_awaiting_call_id(St#wamp_state.context, CallId),
    update_context(juno_context:reset(Ctxt1), St);

maybe_update_state(_, St) ->
    St.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec subprotocol(binary()) -> juno_wamp_protocol:subprotocol().

subprotocol(?WAMP2_JSON) ->                 {ws, text, json};
subprotocol(?WAMP2_MSGPACK) ->              {ws, binary, msgpack};
subprotocol(?WAMP2_JSON_BATCHED) ->         {ws, text, json_batched};
subprotocol(?WAMP2_MSGPACK_BATCHED) ->      {ws, binary, msgpack_batched};
subprotocol(?WAMP2_BERT) ->                 {ws, binary, bert};
subprotocol(?WAMP2_ERL) ->                  {ws, binary, erl};
subprotocol(?WAMP2_BERT_BATCHED) ->         {ws, binary, bert_batched};
subprotocol(?WAMP2_ERL_BATCHED) ->          {ws, binary, erl_batched};
subprotocol(_) ->                           {error, invalid_subprotocol}. 
