-module(bondy_wamp_callback).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-export([conforms/1]).
-export([validate_target/1]).
-export([validate_target/2]).


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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec validate_target({M :: module(), F :: atom()}) -> boolean().

validate_target(MF) ->
    validate_target(MF, []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec validate_target({M :: module(), F :: atom()}, A :: maybe([term()])) ->
    boolean().

validate_target({M, F}, A) when is_atom(M), is_atom(F), is_list(A) ->
    Exports =
        sofs:to_external(
            sofs:relation_to_family(
                sofs:restriction(
                    sofs:relation(
                        M:module_info(exports)
                    ),
                    sofs:set([F])
                )
            )
        ),

    ArgsLen = case A of
        undefined -> 0;
        _ -> length(A)
    end,

    case Exports of
        [] ->
            false;

        [{F, Arities0}] ->
            %% All wamp handlers should have at least 1 + ArgsLen
            %% (Details ++ Args)
            Arities = lists:filter(fun(X) -> X >= ArgsLen + 1 end, Arities0),

            length(Arities) >= 1
    end;

validate_target(_, _) ->
    error(badarg).