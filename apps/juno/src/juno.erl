%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(juno).
-include("juno.hrl").
-include_lib("wamp/include/wamp.hrl").

-import(juno_error, [error_uri/1, error_map/1]).


-export([ack/2]).
-export([call/5]).
-export([send/2]).
-export([send/3]).
-export([start/0]).



%% =============================================================================
%% API
%% =============================================================================


start() ->
    application:ensure_all_started(juno).


%% -----------------------------------------------------------------------------
%% @doc
%% Sends a message to a peer.
%% It calls `send/3' with a timeout option set to 5 secs.
%% @end
%% -----------------------------------------------------------------------------
-spec send(peer_id(), wamp_message()) -> ok | no_return().
send(PeerId, M) ->
    send(PeerId, M, #{timeout => 5000}).


%% -----------------------------------------------------------------------------
%% @doc
%% Sends a message to a peer.
%% If the transport is not open it fails with an exception.
%% This function is used by the router (dealer | broker) to send wamp messages 
%% to peers.
%% @end
%% -----------------------------------------------------------------------------
-spec send(peer_id(), wamp_message(), map()) -> ok | no_return().

send({_, Pid}, M, _) when Pid =:= self() ->
    Pid ! {?JUNO_PEER_CALL, Pid, M},
    ok;

send({SessionId, Pid}, M, Opts0) when is_pid(Pid) ->
    Opts1 = maps_utils:validate(Opts0, #{
        timeout => #{
            required => true,
            default => 5000,
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
    erlang:send(Pid, {?JUNO_PEER_CALL, self(), MonitorRef, M}, [noconnect]),
    receive
        {'DOWN', MonitorRef, process, Pid, Reason} ->
            io:format("Process down ~p error=~p~n", [Pid, Reason]),
            maybe_enqueue(Enqueue, SessionId, M, Reason);
        {?JUNO_PEER_ACK, MonitorRef} ->
            demonitor(MonitorRef, [flush]),
            ok
    after 
        Timeout ->
            io:format("Timeout~n"),
            demonitor(MonitorRef, [flush]),
            maybe_enqueue(Enqueue, SessionId, M, timeout)
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec ack(pid(), reference()) -> ok.
ack(Pid, Ref) ->
    Pid ! {?JUNO_PEER_ACK, Ref},
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
-spec call(map(), binary(), list(), map(), juno_context:context()) -> 
    {ok, map(), juno_context:context()} 
    | {error, map(), juno_context:context()}.

call(Opts, ProcedureUri, Args, Payload, Ctxt0) ->
    ReqId = juno_utils:get_id(global),
    M = wamp_message:call(ReqId, Opts, ProcedureUri, Args, Payload),
    case juno_router:forward(M, Ctxt0) of
        {ok, Ctxt1} ->
            Timeout = juno_utils:timeout(Opts),
            receive
                {?JUNO_PEER_CALL, Pid, Ref, #result{} = M} ->
                    ok = juno:ack(Pid, Ref),
                    {ok, to_map(M), Ctxt1};
                {?JUNO_PEER_CALL, Pid, Ref, #error{} = M} ->
                    ok = juno:ack(Pid, Ref),
                    {error, to_map(M), Ctxt1}
            after 
                Timeout ->
                    Error = {timeout, <<"The operation could not be completed in the time specified.">>},
                    {error, error_map(Error), Ctxt1}
            end;
        {reply, #error{} = Error, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            {error, error_map(Error), Ctxt1};
        {reply, _, Ctxt1} -> 
            %% A sync reply (should not ever happen with calls)
            {error, error_map(inconsistency_error), Ctxt1};
        {stop, #error{} = Error, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            {error, error_map(Error), Ctxt1}
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
to_map(#result{} = M) ->
    #result{
        details = Details,
        arguments = Args,
        payload = ArgsKw
    } = M,
    #{
        <<"details">> => Details,
        <<"arguments">> => args(Args),
        <<"arguments_kw">> => args_kw(ArgsKw)
    };

to_map(#error{} = M) ->
    error_map(M).


%% @private
args(undefined) -> [];
args(L) -> L.

%% @private
args_kw(undefined) -> #{};
args_kw(M) -> M.