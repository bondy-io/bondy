%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(juno).
-include_lib("wamp/include/wamp.hrl").

-export([error_dict/1]).
-export([error_dict/2]).
-export([error_dict/3]).
-export([error_uri/1]).
-export([make/0]).
-export([send/2]).
-export([send/3]).
-export([safe_send/3]).
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
-spec send(Message :: message(), Ctxt :: juno_context:context()) ->
    ok | no_return().
send(Message, Ctxt) ->
    Pid = juno_session:pid(juno_context:session(Ctxt)),
    send(Pid, Message, Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% Sends a message to a peer.
%% If the transport is not open it fails with an exception.
%% @end
%% -----------------------------------------------------------------------------
-spec send(pid(), Message :: message(), Ctxt :: juno_context:context()) -> ok.
send(Pid, Message, _Ctxt) when is_pid(Pid) ->
    Pid ! Message,
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% Sends a message to a peer.
%% Returns and error tuple if the process does not exist or if 
%% the remote node is no reachable.
%% @end
%% -----------------------------------------------------------------------------
-spec safe_send(pid(), Message :: message(), Ctxt :: juno_context:context()) ->
    ok | {error, noproc | noconnection}.
safe_send(Pid, Message, Ctxt) when is_pid(Pid) ->
    case node(Pid) =:= node() of
        true ->
            local_safe_send(Pid, Message, Ctxt);
        false ->
            remote_safe_send(Pid, Message, Ctxt)
    end.


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


error_dict(Code) ->
    #{
        <<"code">> => Code
    }.

error_dict(Code, Description) ->
    #{
        <<"code">> => Code,
        <<"description">> => Description
    }.

error_dict(Code, Description, UserInfo) ->
    #{
        <<"code">> => Code,
        <<"description">> => Description,
        <<"userInfo">> => UserInfo
    }.

%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
local_safe_send(Pid, Message, _Ctxt) ->
    case is_process_alive(Pid) of
        true ->
            Pid ! Message,
            ok;
        false ->
            error({unknown_peer, Pid})
    end.


%% @private
remote_safe_send(Pid, Message, _Ctxt) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! Message,
    erlang:demonitor(Ref),
    receive 
        {'DOWN', Ref, process, Pid, Reason} ->
            {error, Reason}
    after 
        0 -> ok
    end.
