-module(bondy_wamp_callback).

-include_lib("wamp/include/wamp.hrl").

-export([conforms/1]).


%% =============================================================================
%% CALLBACKS
%% =============================================================================



-callback handle_call(
    M :: wamp_message:call(),
    Ctxt :: bony_context:t()) ->
	ok
    | continue
    | {continue, uri()}
    | {reply, wamp_messsage:result() | wamp_message:error()}.



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Returns true is module `Mod' conforms with this behaviour.
%% @end
%% -----------------------------------------------------------------------------
-spec conforms(Mod :: module()) -> boolean().

conforms(Mod) ->
    erlang:function_exported(Mod, handle_call, 2).



