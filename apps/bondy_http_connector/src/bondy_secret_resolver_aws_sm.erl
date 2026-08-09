%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_secret_resolver_aws_sm).
-moduledoc """
AWS Secrets Manager provider for `bondy_secret_resolver`.

Resolved by convention: `bondy_secret_resolver` dispatches provider `aws_sm` to
`bondy_secret_resolver_<aws_sm>` = this module's `fetch/1`. It lives here (rather
than in the dependency-light `bondy_stdlib` core) because it carries the
`erlcloud` dependency.

Returns the raw `SecretString` bytes. A caller that stores several values in one
JSON secret (e.g. the HTTP Connector service secrets) decodes and field-maps on top;
a caller wanting a single JSON field passes `field => <<"...">>`.
""".

-include_lib("kernel/include/logger.hrl").

-export([ensure_transport/0]).
-export([fetch/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Fetches a secret from AWS Secrets Manager.

`Ref` requires `secret_id` and `region`; an optional `field` extracts a single
key from a JSON `SecretString`. Returns the raw bytes (or the field's value) as a
`binary()`.
""".
-spec fetch(bondy_secret_resolver:ref()) ->
    {ok, binary()} | {error, term()}.

fetch(#{secret_id := SecretId, region := Region} = Ref) ->
    try
        ok = ensure_transport(),
        {ok, Config0} = erlcloud_aws:auto_config(),
        Config = erlcloud_aws:service_config(
            <<"sm">>, to_list(Region), Config0
        ),
        case erlcloud_sm:get_secret_value(SecretId, [], Config) of
            {ok, Proplist} ->
                SecretString = proplists:get_value(
                    <<"SecretString">>, Proplist
                ),
                extract(SecretString, maps:get(field, Ref, undefined));
            {error, Reason} ->
                ?LOG_ERROR(#{
                    description =>
                        <<"Failed to fetch secret from AWS Secrets Manager">>,
                    secret_id => SecretId,
                    region => Region,
                    reason => Reason
                }),
                %% Return the raw provider reason; callers add their own context
                %% (e.g. `{secret_resolution_failed, Service, Reason}`).
                {error, Reason}
        end
    catch
        Class:CatchReason:Stacktrace ->
            ?LOG_ERROR(#{
                description => <<"Error resolving AWS Secrets Manager secret">>,
                secret_id => SecretId,
                region => Region,
                class => Class,
                reason => CatchReason,
                stacktrace => Stacktrace
            }),
            {error, {aws_sm, CatchReason}}
    end;
fetch(Ref) ->
    {error, {invalid_ref, Ref}}.

-doc """
Give `lhttpc` usable TLS defaults, if nothing else has.

`erlcloud` talks to AWS over `lhttpc`, which sends `{verify, verify_peer}` with
no CA certificates unless its application environment says otherwise -- and
since OTP 26 `ssl` rejects that pair outright with
`{options, incompatible, [{verify, verify_peer}, {cacerts, undefined}]}`. So
every AWS call fails, at the transport, before any credential is even offered.

This lives here, beside the only code in Bondy that makes such a call, because
it is a precondition of *this* provider rather than of whatever happens to have
started first. It used to live in `bondy_http_connector_config:init/0`, which
meant the AWS secret provider worked only on a node where that application had
already started: `bondy_secret_resolver` is in `bondy_stdlib` and is reached
from realm key encryption, the master key and outbound mail, none of which have
any reason to know that. The failure it produced named TLS options and no part
of the actual cause.

Idempotent, and never overrides a configured value: an operator who has set
`lhttpc`'s `ssl_options` has said something more specific than this can.
""".
-spec ensure_transport() -> ok.

ensure_transport() ->
    case application:get_env(lhttpc, ssl_options) of
        undefined ->
            application:set_env(
                lhttpc, ssl_options, bondy_cert_manager:ssl_opts()
            );
        {ok, _} ->
            ok
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
extract(SecretString, undefined) when is_binary(SecretString) ->
    {ok, SecretString};
extract(SecretString, Field) when is_binary(SecretString) ->
    case json:decode(SecretString) of
        #{Field := Value} when is_binary(Value) ->
            {ok, Value};
        #{} ->
            {error, {secret_field_not_found, Field}}
    end;
extract(_Other, _Field) ->
    {error, secret_string_missing}.

%% @private
to_list(V) when is_list(V) -> V;
to_list(V) when is_binary(V) -> binary_to_list(V).
