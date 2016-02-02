-module(ramp).
-include ("ramp.hrl").

-export([error_dict/1]).
-export([error_dict/2]).
-export([error_dict/3]).
-export([error_uri/1]).
-export([send/2]).
-export([start/0]).
-export([make/0]).


%% =============================================================================
%% API
%% =============================================================================


start() ->
    application:ensure_all_started(ramp).


%% @doc Sends a messageto a peer. If the transport is not open it fails with an exception.
-spec send(Message :: message(), To :: pid()) -> ok.
send(Message, To) ->
    case is_process_alive(To) of
        true ->
            To ! Message,
            ok;
        false ->
            error({unknown_peer, To})
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
    <<"com.williamhill.error.", R/binary>>.


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
