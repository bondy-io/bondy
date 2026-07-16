%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_secret_resolver).
-moduledoc """
A small, provider-pluggable facility for resolving secret material from an
external source, shared across Bondy (RPC Gateway service secrets, realm
signing-key encryption, WAL body-encryption keys).

A secret is named by a `ref()` map whose `provider` selects how it is fetched.
Two providers are shipped:

- `env` — read an environment variable (built in; no dependencies).
- `aws_sm` — AWS Secrets Manager, served by `bondy_secret_resolver_aws_sm`
  (lives in an app that carries the `erlcloud` dependency, so this core module
  stays dependency-light).

## Provider dispatch

Providers are resolved **by convention**: provider `P` is served by the module
`bondy_secret_resolver_<P>` exporting `fetch/1`. The lookup is a dynamic module
call, so this module gains no compile-time edge to provider dependencies (e.g.
`erlcloud`). An explicit `register_provider/2` override is available for tests
and for pinning a non-conventional module.

Every provider returns the **raw secret bytes** (a `binary()`); the optional
`encoding => base64` decodes base64 material (e.g. a base64-encoded 32-byte
key). Callers layer their own interpretation (JSON field extraction, key
derivation) on top.
""".

-type ref() ::
    #{
        provider := atom(),
        encoding => raw | base64,
        _ => _
    }.
-type reason() ::
    {provider_unavailable, atom()}
    | {missing_env, string() | binary()}
    | {invalid_base64, atom()}
    | {invalid_ref, term()}
    | term().

-export_type([ref/0]).
-export_type([reason/0]).

%% API
-export([register_provider/2]).
-export([resolve/1]).

%% Built-in provider (exposed so it dispatches by the same convention).
-export([fetch_env/1]).

-define(PROVIDER_KEY(Name), {?MODULE, provider, Name}).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Registers `Module` as the provider for `Name`, overriding the
`bondy_secret_resolver_<Name>` naming convention. Used by tests and to pin a
non-conventional provider module. `Module` must export `fetch/1`.
""".
-spec register_provider(Name :: atom(), Module :: module()) -> ok.

register_provider(Name, Module) when is_atom(Name) andalso is_atom(Module) ->
    persistent_term:put(?PROVIDER_KEY(Name), Module),
    ok.

-doc """
Resolves the secret named by `Ref`, returning the raw secret bytes.

Dispatches on `Ref.provider`; applies the optional `encoding` transform
(`base64` decodes). Returns `{error, {provider_unavailable, P}}` when no module
serves provider `P`.
""".
-spec resolve(Ref :: ref()) -> {ok, binary()} | {error, reason()}.

resolve(#{provider := Provider} = Ref) when is_atom(Provider) ->
    Encoding = maps:get(encoding, Ref, raw),
    maybe_decode(fetch(Provider, Ref), Encoding, Ref);
resolve(Ref) ->
    {error, {invalid_ref, Ref}}.

%% =============================================================================
%% BUILT-IN PROVIDER — env
%% =============================================================================

-doc """
Built-in `env` provider: reads the environment variable named by `Ref.var`.
Returns the raw string bytes; `resolve/1` applies any `encoding` transform.
""".
-spec fetch_env(Ref :: ref()) -> {ok, binary()} | {error, reason()}.

fetch_env(#{var := Var}) ->
    Name = to_list(Var),
    case os:getenv(Name) of
        false ->
            {error, {missing_env, Var}};
        "" ->
            {error, {missing_env, Var}};
        Value ->
            {ok, list_to_binary(Value)}
    end;
fetch_env(Ref) ->
    {error, {invalid_ref, Ref}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Dispatch a provider fetch. `env` is built in; any other provider is served by
%% a registered override or the conventional `bondy_secret_resolver_<Name>`
%% module exporting `fetch/1`.
fetch(env, Ref) ->
    case persistent_term:get(?PROVIDER_KEY(env), undefined) of
        undefined -> fetch_env(Ref);
        Module -> Module:fetch(Ref)
    end;
fetch(Name, Ref) ->
    case provider_module(Name) of
        {ok, Module} -> Module:fetch(Ref);
        {error, _} = Error -> Error
    end.

%% @private
provider_module(Name) ->
    case persistent_term:get(?PROVIDER_KEY(Name), undefined) of
        undefined ->
            Module = conventional_module(Name),
            case ensure_loaded(Module) of
                true -> {ok, Module};
                false -> {error, {provider_unavailable, Name}}
            end;
        Module ->
            {ok, Module}
    end.

%% @private
conventional_module(Name) ->
    list_to_atom("bondy_secret_resolver_" ++ atom_to_list(Name)).

%% @private
ensure_loaded(Module) ->
    erlang:function_exported(Module, fetch, 1) orelse
        (code:ensure_loaded(Module) =:= {module, Module} andalso
            erlang:function_exported(Module, fetch, 1)).

%% @private
maybe_decode({ok, Bin}, raw, _Ref) ->
    {ok, Bin};
maybe_decode({ok, Bin}, base64, #{provider := Provider}) ->
    try
        {ok, base64:decode(Bin)}
    catch
        _:_ ->
            {error, {invalid_base64, Provider}}
    end;
maybe_decode({error, _} = Error, _Encoding, _Ref) ->
    Error.

%% @private
to_list(V) when is_list(V) -> V;
to_list(V) when is_binary(V) -> binary_to_list(V).
