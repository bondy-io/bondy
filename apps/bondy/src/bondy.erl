%% =============================================================================
%%  bondy.erl -
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
-module(bondy).
-include("bondy.hrl").
-include("bondy_uris.hrl").
-include_lib("wamp/include/wamp.hrl").

-type wamp_error_map() :: #{
    error_uri => uri(),
    details => map(),
    arguments => list(),
    arguments_kw => map()
}.

-export_type([wamp_error_map/0]).


-export([ack/2]).
-export([call/5]).
-export([publish/5]).
-export([subscribe/3]).
-export([subscribe/4]).
-export([send/2]).
-export([send/3]).
-export([send/4]).
-export([start/0]).
-export([aae_exchanges/0]).
-export([is_remote_peer/1]).



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
%% @end
%% -----------------------------------------------------------------------------
aae_exchanges() ->
    plumtree_broadcast:exchanges().


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

send({RealmUri, Node, SessionId, Pid} = PeerId, M, Opts0)
when is_binary(RealmUri)
andalso is_integer(SessionId)
andalso is_pid(Pid) ->
    %% We validate the message failing with exception
    wamp_message:is_message(M) orelse error(invalid_wamp_message),

    %% We validate the opts failing with exception
    Opts1 = validate_send_opts(Opts0),

    case Node =:= bondy_peer_service:mynode() of
        true ->
            do_send(PeerId, M, Opts1);
        false ->
            error(not_my_node)
    end.


-spec send(peer_id(), peer_id(), wamp_message(), map()) -> ok | no_return().

send({RealmUri, _, _, _} = From, {RealmUri, Node, _, _} = To, M, Opts0)
when is_binary(RealmUri) ->
    %% We validate the message failing with exception
    wamp_message:is_message(M) orelse error(invalid_wamp_message),

    %% We validate the opts failing with exception
    Opts1 = validate_send_opts(Opts0),

    case Node =:= bondy_peer_service:mynode() of
        true ->
            do_send(To, M, Opts1);
        false ->
            bondy_peer_wamp_forwarder:forward(From, To, M, Opts1)
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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_remote_peer({_, Node, _, _}) ->
    Node =/= bondy_peer_service:mynode().


%% =============================================================================
%% API - SESSION
%% =============================================================================




%% =============================================================================
%% API - SUBSCRIBER ROLE
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Calls bondy_broker:subscribe/3.
%% @end
%% -----------------------------------------------------------------------------
subscribe(RealmUri, Opts, TopicUri) ->
    bondy_broker:subscribe(RealmUri, Opts, TopicUri).


%% -----------------------------------------------------------------------------
%% @doc Calls bondy_broker:subscribe/4.
%% @end
%% -----------------------------------------------------------------------------
subscribe(RealmUri, Opts, TopicUri, Fun) ->
    bondy_broker:subscribe(RealmUri, Opts, TopicUri, Fun).



%% =============================================================================
%% API - PUBLISHER ROLE
%% =============================================================================



publish(Opts, TopicUri, Args, ArgsKw, CtxtOrRealm) ->
    bondy_broker:publish(Opts, TopicUri, Args, ArgsKw, CtxtOrRealm).



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
    bondy_context:t()) ->
    {ok, map(), bondy_context:t()}
    | {error, wamp_error_map(), bondy_context:t()}.

call(ProcedureUri, Opts, Args, ArgsKw, Ctxt0) ->
    %% @TODO ID should be session scoped and not global
    %% FIXME we need to fix the wamp.hrl timeout
    %% TODO also, according to WAMP the default is 0 which deactivates
    %% the Call Timeout Feature
    Timeout = case maps:find(timeout, Opts) of
        {ok, 0} -> bondy_config:get(wamp_call_timeout);
        {ok, Val} -> Val;
        error -> bondy_config:get(wamp_call_timeout)
    end,
    ReqId = bondy_utils:get_id(global),

    M = wamp_message:call(ReqId, Opts, ProcedureUri, Args, ArgsKw),

    case bondy_router:forward(M, Ctxt0) of
        {ok, Ctxt1} ->
            receive
                {?BONDY_PEER_REQUEST, Pid, Ref, #result{} = R} ->
                    ok = bondy:ack(Pid, Ref),
                    {ok, message_to_map(R), Ctxt1};
                {?BONDY_PEER_REQUEST, Pid, Ref, #error{} = R} ->
                    ok = bondy:ack(Pid, Ref),
                    {error, message_to_map(R), Ctxt1}
            after
                Timeout ->
                    Mssg = iolist_to_binary(
                        io_lib:format(
                            "The operation could not be completed in time"
                            " (~p milliseconds).",
                            [Timeout]
                        )
                    ),
                    ErrorDetails = maps:new(),
                    ErrorArgs = [Mssg],
                    ErrorArgsKw = #{
                        procedure_uri => ProcedureUri,
                        timeout => Timeout
                    },
                    Error = wamp_message:error(
                        ?CALL,
                        ReqId,
                        ErrorDetails,
                        ?BONDY_ERROR_TIMEOUT,
                        ErrorArgs,
                        ErrorArgsKw
                    ),
                    ok = bondy_event_manager:notify({wamp, Error, Ctxt1}),
                    {error, message_to_map(Error), Ctxt1}
            end;
        {reply, #error{} = Error, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            {error, message_to_map(Error), Ctxt1};
        {reply, _, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            Error = wamp_message:error(
                ?CALL, ReqId, #{}, ?BONDY_ERROR_INCONSISTENCY_ERROR,
                [<<"Inconsistency error">>]
            ),
            ok = bondy_event_manager:notify({wamp, Error, Ctxt1}),
            {error, message_to_map(Error), Ctxt1};
        {stop, #error{} = Error, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            ok = bondy_event_manager:notify({wamp, Error, Ctxt1}),
            {error, message_to_map(Error), Ctxt1};
        {stop, _, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            Error = wamp_message:error(
                ?CALL, ReqId, #{}, ?BONDY_ERROR_INCONSISTENCY_ERROR,
                [<<"Inconsistency error">>]
            ),
            ok = bondy_event_manager:notify({wamp, Error, Ctxt1}),
            {error, message_to_map(Error), Ctxt1}
    end.



%% =============================================================================
%% API - CALLEE ROLE
%% =============================================================================






%% =============================================================================
%% PRIVATE
%% =============================================================================



validate_send_opts(Opts) ->
    maps_utils:validate(Opts, #{
        timeout => #{
            required => true,
            datatype => timeout,
            default => ?SEND_TIMEOUT
        },
        enqueue => #{
            required => true,
            datatype => boolean,
            default => false
        }
    }).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
do_send({_, _, _SessionId, Pid}, M, _Opts) when Pid =:= self() ->
    Pid ! {?BONDY_PEER_REQUEST, Pid, make_ref(), M},
    %% This is a sync message so we resolve this sequentially
    %% so we will not get an ack, the ack is implicit
    ok;

do_send({_, _, SessionId, Pid}, M, Opts) ->
    Timeout = maps:get(timeout, Opts),

    %% Should we enqueue the message in case the process representing
    %% the WAMP peer no longer exists?
    Enqueue = maps:get(enqueue, Opts),

    MonitorRef = monitor(process, Pid),

    %% The following no longer applies, as the process should be local
    %% However, we keep it as it still is the right thing to do.
    %% ----------------------
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
            %% The peer received the message and acked it using ack/2
            true = demonitor(MonitorRef, [flush]),
            ok
    after
        Timeout ->
            true = demonitor(MonitorRef, [flush]),
            maybe_enqueue(Enqueue, SessionId, M, timeout)
    end.


%% @private
maybe_enqueue(true, _SessionId, _M, _) ->
    %% TODO Enqueue for session resumption
    ok;

maybe_enqueue(false, SessionId, M, Reason) ->
    _ = lager:info(
        "Could not deliver message to WAMP peer; "
        "reason=~p, session_id=~p, message_type=~p",
        [Reason, SessionId, element(1, M)]
    ),
    ok.


%% @private
message_to_map(#result{} = M) ->
    #result{
        request_id = Id,
        details = Details,
        arguments = Args,
        arguments_kw = ArgsKw
    } = M,
    #{
        request_id => Id,
        details => Details,
        arguments => args(Args),
        arguments_kw => args_kw(ArgsKw)
    };

message_to_map(#error{} = M) ->
    #error{
        request_type = Type,
        request_id = Id,
        details = Details,
        error_uri = Uri,
        arguments = Args,
        arguments_kw = ArgsKw
    } = M,
    %% We need these keys to be binaries, becuase we will
    %% inject this in a mops context.
    #{
        request_type => Type,
        request_id => Id,
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
