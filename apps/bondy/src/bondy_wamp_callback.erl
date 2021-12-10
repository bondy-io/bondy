-module(bondy_wamp_callback).

-include_lib("wamp/include/wamp.hrl").

-export([conforms/1]).


%% =============================================================================
%% CALLBACKS
%% =============================================================================



-callback handle_call(
    M :: wamp_message:call(),
    Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined)
    }
    | {reply, wamp_result() | wamp_error()}.




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
