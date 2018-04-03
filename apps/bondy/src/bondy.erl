%% =============================================================================
%%  bondy.erl -
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
%% =============================================================================


%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(bondy).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(SEND_TIMEOUT, 20000).
-define(CALL_TIMEOUT, 20000).

-type wamp_error_map() :: #{
    error_uri => uri(),
    details => map(),
    arguments => list(),
    arguments_kw => map()
}.

-export_type([wamp_error_map/0]).


-export([ack/2]).
-export([call/5]).
-export([send/2]).
-export([send/3]).
-export([start/0]).



%% =============================================================================
%% API
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% Starts bondy
%% @end
%% -----------------------------------------------------------------------------
start() ->
    application:ensure_all_started(bondy).


%% -----------------------------------------------------------------------------
%% @doc
%% Sends a message to a WAMP peer.
%% It calls `send/3' with a an empty map for Options.
%% @end
%% -----------------------------------------------------------------------------
-spec send(peer_id(), wamp_message()) -> ok.

send(PeerId, M) ->
    send(PeerId, M, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% Sends a message to a local WAMP peer.
%% If the transport is not open it fails with an exception.
%% This function is used by the router (dealer | broker) to send WAMP messages
%% to local peers.
%% Opts is a map with the following keys:
%%
%% * timeout - timeout in milliseconds (defaults to 10000)
%% * enqueue (boolean) - if the peer is not reachable and this value is true,
%% bondy will enqueue the message so that the peer can resume the session and
%% consume all enqueued messages.
%%
%% @end
%% -----------------------------------------------------------------------------
-spec send(peer_id(), wamp_message(), map()) -> ok | no_return().

send({SessionId, Pid} = P, M, Opts)
when is_integer(SessionId), Pid =:= self() ->
    %% This is a sync message so we resolve this sequentially
    wamp_message:is_message(M) orelse error({badarg, [P, M, Opts]}),
    Pid ! {?BONDY_PEER_REQUEST, Pid, make_ref(), M},
    %% We will not get an ack, it is implicit
    ok;

send({SessionId, Pid} = P, M, Opts0) when is_pid(Pid), is_integer(SessionId) ->
    wamp_message:is_message(M) orelse error({badarg, [P, M, Opts0]}),
    Opts1 = maps_utils:validate(Opts0, #{
        timeout => #{
            required => true,
            default => ?SEND_TIMEOUT,
            datatype => timeout
        },
        enqueue => #{
            required => true,
            datatype => boolean,
            default => false
        }
    }),
    Timeout = maps:get(timeout, Opts1),
    Enqueue = maps:get(enqueue, Opts1),
    MonitorRef = monitor(process, Pid),
    %% If the monitor/2 call failed to set up a connection to a
    %% remote node, we don't want the '!' operator to attempt
    %% to set up the connection again. (If the monitor/2 call
    %% failed due to an expired timeout, '!' too would probably
    %% have to wait for the timeout to expire.) Therefore,
    %% use erlang:send/3 with the 'noconnect' option so that it
    %% will fail immediately if there is no connection to the
    %% remote node.
    erlang:send(Pid, {?BONDY_PEER_REQUEST, self(), MonitorRef, M}, [noconnect]),
    receive
        {'DOWN', MonitorRef, process, Pid, Reason} ->
            %% The peer no longer exists
            maybe_enqueue(Enqueue, SessionId, M, Reason);
        {?BONDY_PEER_ACK, MonitorRef} ->
            %% The peer received the message and acked it
            %% using ack/2
            true = demonitor(MonitorRef, [flush]),
            ok
    after
        Timeout ->
            true = demonitor(MonitorRef, [flush]),
            maybe_enqueue(Enqueue, SessionId, M, timeout)
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% Acknowledges the reception of a WAMP message. This function should be used by
%% the peer transport module to acknowledge the reception of a message sent with
%% {@link send/3}.
%% @end
%% -----------------------------------------------------------------------------
-spec ack(pid(), reference()) -> ok.

ack(Pid, _) when Pid =:= self()  ->
    %% We do not need to send an ack (implicit ack send case)
    ok;

ack(Pid, Ref) when is_pid(Pid), is_reference(Ref) ->
    Pid ! {?BONDY_PEER_ACK, Ref},
    ok.


%% =============================================================================
%% API - SESSION
%% =============================================================================




%% =============================================================================
%% API - SUBSCRIBER ROLE
%% =============================================================================



%% =============================================================================
%% API - PUBLISHER ROLE
%% =============================================================================



%% =============================================================================
%% API - CALLER ROLE
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% A blocking call.
%% @end
%% -----------------------------------------------------------------------------
-spec call(
    binary(),
    map(),
    list() | undefined,
    map() | undefined,
    bondy_context:context()) ->
    {ok, map(), bondy_context:context()}
    | {error, wamp_error_map(), bondy_context:context()}.

call(ProcedureUri, Opts, Args, ArgsKw, Ctxt0) ->
    %% @TODO ID should be session scoped and not global
    %% TODO we need to fix the wamp.hrl timeout
    %% TODO also, according to WAMP the default is 0 which deactivates
    %% the Call Timeout Feature
    Timeout = case maps:get(timeout, Opts, ?CALL_TIMEOUT) of
        0 -> ?CALL_TIMEOUT;
        Val -> Val
    end,
    ReqId = bondy_utils:get_id(global),
    M = wamp_message:call(ReqId, Opts, ProcedureUri, Args, ArgsKw),
    case bondy_router:forward(M, Ctxt0) of
        {ok, Ctxt1} ->
            receive
                {?BONDY_PEER_REQUEST, Pid, Ref, #result{} = R} ->
                    ok = bondy:ack(Pid, Ref),
                    Ctxt2 = bondy_context:remove_awaiting_call(
                        Ctxt1, R#result.request_id),
                    {ok, message_to_map(R), Ctxt2};
                {?BONDY_PEER_REQUEST, Pid, Ref, #error{} = R} ->
                    ok = bondy:ack(Pid, Ref),
                    Ctxt2 = bondy_context:remove_awaiting_call(
                        Ctxt1, R#error.request_id),
                    {error, message_to_map(R), Ctxt2}
            after
                Timeout ->
                    Error = #{
                        error_uri => ?BONDY_ERROR_TIMEOUT,
                        details => #{},
                        arguments => [
                            <<"The operation could not be completed in the time specified (~p milliseconds).">>,
                            ?CALL_TIMEOUT
                        ],
                        arguments_kw => #{}
                    },
                    {error, Error, Ctxt1}
            end;
        {reply, #error{} = Error, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            {error, message_to_map(Error), Ctxt1};
        {reply, _, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            Error = #{
                error_uri => ?BONDY_INCONSISTENCY_ERROR,
                details => #{},
                arguments => [<<"Inconsistency error">>],
                arguments_kw => #{}
            },
            {error, Error, Ctxt1};
        {stop, #error{} = Error, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            {error, message_to_map(Error), Ctxt1};
        {stop, _, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            Error = #{
                error_uri => ?BONDY_INCONSISTENCY_ERROR,
                details => #{},
                arguments => [<<"Inconsistency error">>],
                arguments_kw => #{}
            },
            {error, Error, Ctxt1}
    end.



%% =============================================================================
%% API - CALLEE ROLE
%% =============================================================================






%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
maybe_enqueue(true, _SessionId, _M, _) ->
    %% TODO Enqueue for session resumption
    ok;

maybe_enqueue(false, _, _, Reason) ->
    exit(Reason).


%% @private
message_to_map(#result{} = M) ->
    #result{
        details = Details,
        arguments = Args,
        arguments_kw = ArgsKw
    } = M,
    #{
        details => Details,
        arguments => args(Args),
        arguments_kw => args_kw(ArgsKw)
    };

message_to_map(#error{} = M) ->
    #error{
        details = Details,
        error_uri = Uri,
        arguments = Args,
        arguments_kw = ArgsKw
    } = M,
    %% We need these keys to be binaries, becuase we will
    %% inject this in a mops context.
    #{
        details => Details,
        error_uri => Uri,
        arguments => args(Args),
        arguments_kw => args_kw(ArgsKw)
    }.


%% @private
args(undefined) -> [];
args(L) -> L.

%% @private
args_kw(undefined) -> #{};
args_kw(M) -> M.
