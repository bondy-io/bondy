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




-export([ack/2]).
-export([error_map/1]).
-export([error_map/2]).
-export([error_map/3]).
-export([error_uri/1]).
-export([make/0]).
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
%% If the transport is not open it fails with an exception.
%% @end
%% -----------------------------------------------------------------------------
-spec send(peer_id(), wamp_message()) -> ok | no_return().
send(PeerId, M) ->
    send(PeerId, M, #{timeout => 5000}).


%% -----------------------------------------------------------------------------
%% @doc
%% Sends a message to a peer.
%% If the transport is not open it fails with an exception.
%% @end
%% -----------------------------------------------------------------------------
-spec send(peer_id(), wamp_message(), map()) -> ok | no_return().
send({Pid, SessionId}, M, Opts0) when is_pid(Pid) ->
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
    erlang:send(Pid , {?JUNO_PEER_CALL, self(), MonitorRef, M}, [noconnect]),
    receive
        {'DOWN', MonitorRef, process, Pid, Reason} ->
            maybe_enqueue(Enqueue, SessionId, M, Reason);
        {?JUNO_PEER_ACK, MonitorRef} ->
            demonitor(MonitorRef, [flush]),
            ok
    after 
        Timeout ->
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




%% =============================================================================
%% API - CALLEE ROLE
%% =============================================================================




%% =============================================================================
%% API - UTILS
%% =============================================================================

make() ->
    make:all([load]).

error_uri(Reason) when is_atom(Reason) ->
    R = list_to_binary(atom_to_list(Reason)),
    <<"com.leapsight.error.", R/binary>>.


error_map(Code) ->
    #{
        <<"code">> => Code
    }.

error_map(Code, Description) ->
    #{
        <<"code">> => Code,
        <<"description">> => Description
    }.

error_map(Code, Description, UserInfo) ->
    #{
        <<"code">> => Code,
        <<"description">> => Description,
        <<"userInfo">> => UserInfo
    }.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
maybe_enqueue(true, _SessionId, _M, _) ->
    %% TODO Enqueue for session resumption
    ok;

maybe_enqueue(false, _, _, Reason) ->
    exit(Reason).
