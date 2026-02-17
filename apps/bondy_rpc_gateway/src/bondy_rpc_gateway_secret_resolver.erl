%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_secret_resolver).

-moduledoc """
Resolves secrets from external providers (e.g. AWS Secrets Manager) and
merges them into service auth configuration as variable bindings.

This module is stateless. Two entry points are provided:

- `resolve_services/1` — resolves all services, crashes on failure
- `resolve_service_secrets/2` — resolves a single service's secrets,
  returns `{ok, Vars}` or `{error, Reason}` without crashing. Used by
  the manager for resilient startup with background retry.

## Supported Providers

- `aws_sm` — AWS Secrets Manager via `erlcloud_sm:get_secret_value/3`

## Transforms

Secret fields can be transformed before becoming auth vars:

- `none` — use the raw value
- `basic_username` — decode a `Basic base64(user:pass)` header, return user
- `basic_password` — decode a `Basic base64(user:pass)` header, return pass
""".

-include_lib("kernel/include/logger.hrl").

-export([resolve_services/1]).
-export([resolve_service_secrets/2]).
-export([apply_transform/2]).
-export([decode_basic_auth/1]).



%% =============================================================================
%% API
%% =============================================================================



-doc """
Iterate services and resolve any that have a secrets specification.

Services without `auth_conf.secrets` pass through unchanged.
""".
-spec resolve_services([map()]) -> [map()].

resolve_services(Services) ->
    lists:map(fun resolve_service/1, Services).

-doc """
Resolve secrets for a single service without crashing.

Returns `{ok, ResolvedVars}` on success or `{error, Reason}` on failure.
Used by the manager for resilient startup with retry.
""".
-spec resolve_service_secrets(SecretsSpec :: map(), ServiceName :: binary()) ->
    {ok, ResolvedVars :: map()} | {error, term()}.

resolve_service_secrets(SecretsSpec, ServiceName) ->
    try
        SecretMap = fetch_secret(SecretsSpec, ServiceName),
        VarMappings = maps:get(vars, SecretsSpec, #{}),
        ResolvedVars = resolve_var_mappings(VarMappings, SecretMap, ServiceName),
        {ok, ResolvedVars}
    catch
        error:Reason ->
            {error, Reason}
    end.

-doc """
Apply a transform to a secret field value.

- `none` — return value as-is
- `basic_username` — decode Basic auth header, return username
- `basic_password` — decode Basic auth header, return password
""".
-spec apply_transform(binary(), none | basic_username | basic_password) ->
    binary().
apply_transform(Value, none) ->
    Value;
apply_transform(Value, basic_username) ->
    {Username, _Password} = decode_basic_auth(Value),
    Username;
apply_transform(Value, basic_password) ->
    {_Username, Password} = decode_basic_auth(Value),
    Password.

-doc """
Decode a Basic authentication header value.

Accepts formats:
- `"Basic base64(user:pass)"`
- `"basic base64(user:pass)"` (case-insensitive prefix)
- `"base64(user:pass)"` (no prefix)

Splits only on the first `:` so passwords containing `:` are preserved.
""".
-spec decode_basic_auth(binary()) -> {binary(), binary()}.
decode_basic_auth(Value0) ->
    Value1 = string:trim(Value0),
    Base64 = strip_basic_prefix(Value1),
    Decoded = base64:decode(Base64),
    case binary:split(Decoded, <<":">>) of
        [Username, Password] ->
            {Username, Password};
        [_NoColon] ->
            error({invalid_basic_auth, Value0})
    end.


%% ===================================================================
%% Internal
%% ===================================================================

resolve_service(#{auth_conf := #{secrets := SecretsSpec} = AuthConf} = Service) ->
    ServiceName = maps:get(name, Service, <<"unknown">>),
    SecretMap = fetch_secret(SecretsSpec, ServiceName),
    VarMappings = maps:get(vars, SecretsSpec, #{}),
    ResolvedVars = resolve_var_mappings(VarMappings, SecretMap, ServiceName),

    ExistingVars = maps:get(vars, AuthConf, #{}),
    MergedVars = maps:merge(ExistingVars, ResolvedVars),

    AuthConf1 = maps:remove(secrets, AuthConf),
    AuthConf2 = AuthConf1#{vars => MergedVars},
    Service#{auth_conf => AuthConf2};

resolve_service(Service) ->
    Service.

fetch_secret(#{provider := aws_sm, secret_id := SecretId, region := Region},
             ServiceName) ->
    Config0 = erlcloud_aws:default_config(),
    Config = erlcloud_aws:service_config(
        <<"sm">>, binary_to_list(Region), Config0
    ),
    case erlcloud_sm:get_secret_value(SecretId, [], Config) of
        {ok, Proplist} ->
            SecretString = proplists:get_value(<<"SecretString">>, Proplist),
            json:decode(SecretString);

        {error, Reason} ->
            ?LOG_ERROR(#{
                msg => <<"Failed to fetch secret from AWS Secrets Manager">>,
                service => ServiceName,
                secret_id => SecretId,
                region => Region,
                reason => Reason
            }),
            error({secret_resolution_failed, ServiceName, Reason})
    end.

resolve_var_mappings(VarMappings, SecretMap, ServiceName) ->
    maps:map(
        fun(VarName, #{field := Field} = Mapping) ->
            Transform = maps:get(transform, Mapping, none),
            case maps:find(Field, SecretMap) of
                {ok, RawValue} ->
                    apply_transform(RawValue, Transform);
                error ->
                    error({secret_field_not_found, ServiceName, VarName, Field})
            end
        end,
        VarMappings
    ).

strip_basic_prefix(Value) ->
    case Value of
        <<"Basic ", Rest/binary>> ->
            string:trim(Rest);

        <<"basic ", Rest/binary>> ->
            string:trim(Rest);

        _ ->
            %% Try case-insensitive match for other casings
            Str = binary:part(Value, 0, min(6, byte_size(Value))),

            case string:lowercase(Str) of
                <<"basic ">> ->
                    string:trim(binary:part(Value, 6, byte_size(Value) - 6));

                _ ->
                    string:trim(Value)
            end
    end.
