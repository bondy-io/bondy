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

For a **callee** the return value is mapped by the connection to a `YIELD` or
`ERROR`:

- `{reply, ResultArgs}` / `{reply, ResultArgs, ResultKWArgs}` → `YIELD`.
- `ok` / `noreply` → an empty `YIELD`.
- `{error, Uri}` / `{error, Uri, Args}` / `{error, Uri, Args, KWArgs}` → `ERROR`.

For a **subscriber** the return value is ignored (events have no reply).

`validate/1` checks the *shape* only (cheap, at register/subscribe time);
`invoke/4` performs the call. This module is pure — it never spawns; the
connection runs `invoke/4` inside an isolated, monitored worker
(`bondy_connect_handler`).
""".

-type handler() ::
    fun((list(), map(), map()) -> term())
    | {module(), atom()}
    | {module(), atom(), term()}.

-export_type([handler/0]).

-export([validate/1]).
-export([invoke/4]).

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
