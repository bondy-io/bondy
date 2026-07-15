%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_utils).

-type hash() :: binary().

-export_type([hash/0]).

-export([behaviours/1]).
-export([ensure_loaded/1]).
-export([hash/2]).
-export([implementations/2]).
-export([implements_behaviour/2]).
-export([implements_callback/3]).
-export([apply_lazy/3]).
-export([apply_lazy/5]).

%% =============================================================================
%% API
%% =============================================================================

-spec hash(Term :: term(), Algo :: sha256 | sha512) -> Digest :: binary().

hash(Term, Algo) when Algo == sha256 orelse Algo == sha512 ->
    crypto:hash(
        Algo,
        erlang:term_to_binary(Term, [deterministic, {minor_version, 2}])
    ).

%% -----------------------------------------------------------------------------
%% @doc Ensures a module is loaded.
%% @end
%% -----------------------------------------------------------------------------
ensure_loaded(Mod) when is_atom(Mod) ->
    erlang:function_exported(Mod, module_info, 0) orelse
        code:ensure_loaded(Mod),
    ok.

%% -----------------------------------------------------------------------------
%% @doc Lists the behaviours implemented by a module.
%% Raises an exception if the module is not loaded.
%% @end
%% -----------------------------------------------------------------------------
-spec behaviours(atom()) -> [atom()] | no_return().

behaviours(Mod) when is_atom(Mod) ->
    ok = ensure_loaded(Mod),
    Attributes = Mod:module_info(attributes),
    lists:flatten(proplists:get_all_values(behaviour, Attributes)).

%% -----------------------------------------------------------------------------
%% @doc Returns `true' if module `module' implements behaviour `behaviour'.
%% Otherwise, it returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec implements_behaviour(atom(), atom()) -> boolean().

implements_behaviour(Mod, Behaviour) when is_atom(Mod), is_atom(Behaviour) ->
    lists:member(Behaviour, behaviours(Mod)).

-spec implements_callback(
    Module :: module(), FunctionName :: atom(), Arity :: non_neg_integer()
) ->
    boolean().

implements_callback(Mod, FunctionName, Arity) when is_atom(Mod) ->
    ok = ensure_loaded(Mod),
    erlang:function_exported(Mod, FunctionName, Arity).

%% -----------------------------------------------------------------------------
%% @doc Returns the list of modules implementing `Behaviour' in application
%% `Application'.
%% @end
%% -----------------------------------------------------------------------------
-spec implementations(atom(), atom()) -> [atom()].

implementations(Application, Behaviour) ->
    case application:get_key(Application, modules) of
        {ok, Mods} ->
            lists:filter(
                fun(Mod) -> implements_behaviour(Mod, Behaviour) end,
                Mods
            );
        _ ->
            []
    end.

-spec apply_lazy(module(), atom(), fun(() -> any())) -> any().

apply_lazy(Module, FunctionName, Fun) when is_function(Fun, 0) ->
    apply_lazy(Module, FunctionName, 0, [], Fun).

-spec apply_lazy(module(), atom(), integer(), list(), term()) -> term().

apply_lazy(Module, FunctionName, Arity, Args, Fun) when is_function(Fun, 0) ->
    case implements_callback(Module, FunctionName, Arity) of
        true ->
            erlang:apply(Module, FunctionName, Args);
        false ->
            Fun()
    end.
