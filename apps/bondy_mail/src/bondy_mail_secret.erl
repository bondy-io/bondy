%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_secret).

-moduledoc """
An opaque holder for a relay credential.

"Never log the password" is a rule people break. This wraps the value in a
closure, so the term carries no readable copy of it: printing it, putting it in
a log map, in an error payload, or in a telemetry label yields
`{bondy_mail_secret, #Fun<...>}` rather than the credential. Getting the value
out takes a deliberate `expose/1`.

That makes leaking a secret an act rather than an oversight, which is the same
reasoning behind `bondy_error:sanitise/1` and the error catalogue's contract
that stacktraces and internal terms never reach a peer.

A secret is resolved once, when its relay starts, through
`bondy_secret_resolver`. From then on only the resolved value is held, and only
in the relay process's state.

    {ok, Secret} = bondy_mail_secret:resolve(#{provider => env,
                                               var => ~"BONDY_SMTP_PASSWORD"}),
    ok = gen_smtp_client:send(Msg, [{password, bondy_mail_secret:expose(Secret)}]).

Call `expose/1` at the point of use and let the result go out of scope. Do not
bind it into anything that outlives the call.
""".

-include_lib("kernel/include/logger.hrl").

-opaque t() :: {?MODULE, fun(() -> binary())}.

-type ref() ::
    #{provider := none, value := binary()}
    | #{provider := env | aws_sm, atom() => any()}.

-export_type([ref/0]).
-export_type([t/0]).

%% API
-export([expose/1]).
-export([is_type/1]).
-export([new/1]).
-export([resolve/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Wrap a value that is already in hand.

Prefer `resolve/1`: a literal credential means the value was sitting in
`bondy.conf`.
""".
-spec new(Value :: binary()) -> t().

new(Value) when is_binary(Value) ->
    {?MODULE, fun() -> Value end}.

-doc """
Resolve a credential reference into an opaque secret.

`#{provider => none, value => V}` wraps a literal. Anything else is handed to
`bondy_secret_resolver:resolve/1`, which ships `env` and `aws_sm` providers.

The failure reason is whatever the resolver reported. It names the provider and
the missing variable, never a credential.
""".
-spec resolve(Ref :: ref()) -> {ok, t()} | {error, Reason :: any()}.

resolve(#{provider := none, value := Value}) when is_binary(Value) ->
    {ok, new(Value)};
resolve(#{provider := _} = Ref) ->
    case bondy_secret_resolver:resolve(Ref) of
        {ok, Value} ->
            {ok, new(Value)};
        {error, _} = Error ->
            Error
    end.

-doc """
Return the wrapped value.

Use it as an argument and let it go out of scope. Binding it into state, a log
map or an error payload defeats the point of the wrapper.
""".
-spec expose(Secret :: t()) -> binary().

expose({?MODULE, Fun}) when is_function(Fun, 0) ->
    Fun().

-doc "Return `true` if `Term` is a secret.".
-spec is_type(Term :: any()) -> boolean().

is_type({?MODULE, Fun}) when is_function(Fun, 0) ->
    true;
is_type(_) ->
    false.
