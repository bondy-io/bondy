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
