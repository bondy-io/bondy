%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_handler_spec).

-moduledoc """
The handler contract for callees (`INVOCATION`) and subscribers (`EVENT`).

A `handler()` is one of:

- `fun((Args, KWArgs, Details) -> return())` — an anonymous/named fun of arity 3.
- `{Module, Function}` — invoked as `Module:Function(Args, KWArgs, Details)`.
- `{Module, Function, Extra}` — invoked as
  `Module:Function(Args, KWArgs, Details, Extra)`.

For a **callee** the return value must be a `handler_return()`:

- `ok` / `{ok, #{}}` → an empty `YIELD`.
- `{ok, #{args => Args, kwargs => KWArgs}}` (both keys optional) → `YIELD`.
- `{error, #{uri := Uri, args => Args, kwargs => KWArgs}}` (`uri` mandatory,
  `args`/`kwargs` optional) → `ERROR`.

Anything else (including the pre-1.0 `{reply, _}` / `{reply, _, _}` /
`noreply` forms) is malformed and yields
`?BONDY_CONNECT_INTERNAL_ERROR`.

For a **subscriber** the return value is ignored (events have no reply).

`validate/1` checks the *shape* of a `handler()` only (cheap, at
register/subscribe time); `invoke/4` performs the call;
`normalize_return/1` maps a callee's `handler_return()` onto the internal
reply `bondy_connect_dispatch` consumes. This module is pure — it never
spawns; the connection runs `invoke/4` inside an isolated, monitored worker
(`bondy_connect_handler`).
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-type handler() ::
    fun((list(), map(), map()) -> term())
    | {module(), atom()}
    | {module(), atom(), term()}.
-type yield() :: #{args => list(), kwargs => map()}.
-type handler_error() :: #{uri := uri(), args => list(), kwargs => map()}.
-type handler_return() :: ok | {ok, yield()} | {error, handler_error()}.

-export_type([handler/0]).
-export_type([yield/0]).
-export_type([handler_error/0]).
-export_type([handler_return/0]).

-export([validate/1]).
-export([invoke/4]).
-export([normalize_return/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Validate the *shape* of a handler.".
-spec validate(term()) -> ok | {error, {invalid_handler, term()}}.
validate(H) when is_function(H, 3) ->
    ok;
validate({M, F}) when is_atom(M), is_atom(F) ->
    ok;
validate({M, F, _Extra}) when is_atom(M), is_atom(F) ->
    ok;
validate(Other) ->
    {error, {invalid_handler, Other}}.

-doc "Invoke a (already-validated) handler.".
-spec invoke(handler(), list(), map(), map()) -> term().
invoke(H, Args, KWArgs, Details) when is_function(H, 3) ->
    H(Args, KWArgs, Details);
invoke({M, F}, Args, KWArgs, Details) ->
    M:F(Args, KWArgs, Details);
invoke({M, F, Extra}, Args, KWArgs, Details) ->
    M:F(Args, KWArgs, Details, Extra).

-doc """
Map a callee's raw return value onto the internal reply
`bondy_connect_dispatch:invocation_reply/2` consumes, or `invalid` if it is
not a `handler_return()`. Pure — does not log or interpret `invalid`; the
caller (`bondy_connect_handler:invoke_call/4`) decides how to report it.
""".
-spec normalize_return(term()) ->
    {yield, list(), map() | undefined}
    | {error, uri(), list() | undefined, map() | undefined}
    | invalid.
normalize_return(ok) ->
    {yield, [], undefined};
normalize_return({ok, Reply}) when is_map(Reply) ->
    {yield, maps:get(args, Reply, []), maps:get(kwargs, Reply, undefined)};
normalize_return({error, #{uri := Uri} = Err}) when is_binary(Uri) ->
    {error, Uri, maps:get(args, Err, undefined),
        maps:get(kwargs, Err, undefined)};
normalize_return(_Other) ->
    invalid.
