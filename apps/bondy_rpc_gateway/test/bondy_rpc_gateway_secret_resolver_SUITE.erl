-module(bondy_rpc_gateway_secret_resolver_SUITE).

-moduledoc """
Tests for bondy_rpc_gateway_secret_resolver.

Four groups:
- unit_decode_basic_auth: tests for decode_basic_auth/1
- unit_transforms: tests for apply_transform/2
- integration_mocked: full resolve_services/1 with mocked erlcloud
- non_crashing: resolve_service_secrets/2 returns ok/error tuples
""".

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).

%% unit_decode_basic_auth
-export([
    decode_basic_auth_with_prefix/1,
    decode_basic_auth_lowercase_prefix/1,
    decode_basic_auth_without_prefix/1,
    decode_basic_auth_password_with_colon/1,
    decode_basic_auth_invalid/1
]).

%% unit_transforms
-export([
    transform_none/1,
    transform_basic_username/1,
    transform_basic_password/1
]).

%% integration_mocked
-export([
    resolve_services_with_secrets/1,
    resolve_services_without_secrets/1,
    resolve_services_merges_with_existing_vars/1,
    resolve_services_missing_field/1,
    resolve_services_aws_error/1,
    resolve_services_removes_secrets_from_auth_conf/1
]).

%% non_crashing
-export([
    resolve_service_secrets_ok/1,
    resolve_service_secrets_aws_error/1,
    resolve_service_secrets_missing_field/1
]).


%% ===================================================================
%% CT callbacks
%% ===================================================================

all() ->
    [
        {group, unit_decode_basic_auth},
        {group, unit_transforms},
        {group, integration_mocked},
        {group, non_crashing}
    ].

groups() ->
    [
        {unit_decode_basic_auth, [parallel], [
            decode_basic_auth_with_prefix,
            decode_basic_auth_lowercase_prefix,
            decode_basic_auth_without_prefix,
            decode_basic_auth_password_with_colon,
            decode_basic_auth_invalid
        ]},
        {unit_transforms, [parallel], [
            transform_none,
            transform_basic_username,
            transform_basic_password
        ]},
        {integration_mocked, [sequence], [
            resolve_services_with_secrets,
            resolve_services_without_secrets,
            resolve_services_merges_with_existing_vars,
            resolve_services_missing_field,
            resolve_services_aws_error,
            resolve_services_removes_secrets_from_auth_conf
        ]},
        {non_crashing, [sequence], [
            resolve_service_secrets_ok,
            resolve_service_secrets_aws_error,
            resolve_service_secrets_missing_field
        ]}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(Group, Config)
  when Group =:= integration_mocked; Group =:= non_crashing ->
    ok = meck:new(erlcloud_aws, [passthrough]),
    ok = meck:new(erlcloud_sm, [passthrough]),

    meck:expect(erlcloud_aws, default_config, fun() -> mock_config end),
    meck:expect(erlcloud_aws, service_config,
        fun(<<"sm">>, _Region, _AwsConfig) -> mock_sm_config end
    ),

    Config;

init_per_group(_Group, Config) ->
    Config.

end_per_group(Group, _Config)
  when Group =:= integration_mocked; Group =:= non_crashing ->
    catch meck:unload(erlcloud_sm),
    catch meck:unload(erlcloud_aws),
    ok;

end_per_group(_Group, _Config) ->
    ok.


%% ===================================================================
%% Helpers
%% ===================================================================

basic_header(User, Pass) ->
    Encoded = base64:encode(<<User/binary, ":", Pass/binary>>),
    <<"Basic ", Encoded/binary>>.

mock_secret_json() ->
    #{
        <<"IDP_TOKEN_ENDPOINT">> => <<"https://idp.example.com/token">>,
        <<"AUTHORIZATION_HEADER">> => basic_header(<<"myuser">>, <<"mypass">>)
    }.

mock_sm_success(SecretJson) ->
    SecretString = iolist_to_binary(json:encode(SecretJson)),
    meck:expect(erlcloud_sm, get_secret_value,
        fun(_SecretId, [], _SmConfig) ->
            {ok, [{<<"SecretString">>, SecretString}]}
        end
    ).

make_service(Name, SecretsSpec) ->
    #{
        name => Name,
        base_url => <<"https://example.com">>,
        auth_mod => bondy_rpc_gateway_auth_generic,
        auth_conf => #{
            fetch => #{method => post, url => <<"https://idp/token">>,
                       token_path => [<<"access_token">>]},
            apply => #{placement => header, name => <<"Authorization">>},
            vars => #{},
            cache => #{default_ttl => 3600, refresh_margin => 60},
            secrets => SecretsSpec
        },
        timeout => 30000,
        retries => 3
    }.

make_service_no_secrets(Name) ->
    #{
        name => Name,
        base_url => <<"https://example.com">>,
        auth_mod => bondy_rpc_gateway_auth_generic,
        auth_conf => #{
            fetch => #{method => post, url => <<"https://idp/token">>,
                       token_path => [<<"access_token">>]},
            apply => #{placement => header, name => <<"Authorization">>},
            vars => #{client_id => <<"static-id">>},
            cache => #{default_ttl => 3600, refresh_margin => 60}
        },
        timeout => 30000,
        retries => 3
    }.


%% ===================================================================
%% unit_decode_basic_auth
%% ===================================================================

decode_basic_auth_with_prefix(_Config) ->
    Header = basic_header(<<"user">>, <<"pass">>),
    ?assertEqual(
        {<<"user">>, <<"pass">>},
        bondy_rpc_gateway_secret_resolver:decode_basic_auth(Header)
    ).

decode_basic_auth_lowercase_prefix(_Config) ->
    Encoded = base64:encode(<<"user:pass">>),
    Header = <<"basic ", Encoded/binary>>,
    ?assertEqual(
        {<<"user">>, <<"pass">>},
        bondy_rpc_gateway_secret_resolver:decode_basic_auth(Header)
    ).

decode_basic_auth_without_prefix(_Config) ->
    Encoded = base64:encode(<<"user:pass">>),
    ?assertEqual(
        {<<"user">>, <<"pass">>},
        bondy_rpc_gateway_secret_resolver:decode_basic_auth(Encoded)
    ).

decode_basic_auth_password_with_colon(_Config) ->
    Header = basic_header(<<"user">>, <<"pa:ss">>),
    ?assertEqual(
        {<<"user">>, <<"pa:ss">>},
        bondy_rpc_gateway_secret_resolver:decode_basic_auth(Header)
    ).

decode_basic_auth_invalid(_Config) ->
    %% No colon in decoded value should raise an error
    Encoded = base64:encode(<<"nocolon">>),
    Header = <<"Basic ", Encoded/binary>>,
    ?assertError(
        {invalid_basic_auth, Header},
        bondy_rpc_gateway_secret_resolver:decode_basic_auth(Header)
    ).


%% ===================================================================
%% unit_transforms
%% ===================================================================

transform_none(_Config) ->
    ?assertEqual(
        <<"hello">>,
        bondy_rpc_gateway_secret_resolver:apply_transform(<<"hello">>, none)
    ).

transform_basic_username(_Config) ->
    Header = basic_header(<<"alice">>, <<"secret123">>),
    ?assertEqual(
        <<"alice">>,
        bondy_rpc_gateway_secret_resolver:apply_transform(Header, basic_username)
    ).

transform_basic_password(_Config) ->
    Header = basic_header(<<"alice">>, <<"secret123">>),
    ?assertEqual(
        <<"secret123">>,
        bondy_rpc_gateway_secret_resolver:apply_transform(Header, basic_password)
    ).


%% ===================================================================
%% integration_mocked
%% ===================================================================

resolve_services_with_secrets(_Config) ->
    mock_sm_success(mock_secret_json()),

    SecretsSpec = #{
        provider => aws_sm,
        secret_id => <<"/integrations/credentials/test">>,
        region => <<"sa-east-1">>,
        vars => #{
            token_endpoint => #{
                field => <<"IDP_TOKEN_ENDPOINT">>,
                transform => none
            },
            client_id => #{
                field => <<"AUTHORIZATION_HEADER">>,
                transform => basic_username
            },
            client_secret => #{
                field => <<"AUTHORIZATION_HEADER">>,
                transform => basic_password
            }
        }
    },
    Service = make_service(<<"test-svc">>, SecretsSpec),

    [Resolved] = bondy_rpc_gateway_secret_resolver:resolve_services([Service]),

    #{auth_conf := #{vars := Vars}} = Resolved,
    ?assertEqual(<<"https://idp.example.com/token">>,
                 maps:get(token_endpoint, Vars)),
    ?assertEqual(<<"myuser">>, maps:get(client_id, Vars)),
    ?assertEqual(<<"mypass">>, maps:get(client_secret, Vars)).

resolve_services_without_secrets(_Config) ->
    Service = make_service_no_secrets(<<"plain-svc">>),
    [Resolved] = bondy_rpc_gateway_secret_resolver:resolve_services([Service]),
    %% Should pass through unchanged
    ?assertEqual(Service, Resolved).

resolve_services_merges_with_existing_vars(_Config) ->
    mock_sm_success(mock_secret_json()),

    SecretsSpec = #{
        provider => aws_sm,
        secret_id => <<"/integrations/credentials/test">>,
        region => <<"sa-east-1">>,
        vars => #{
            client_id => #{
                field => <<"AUTHORIZATION_HEADER">>,
                transform => basic_username
            }
        }
    },

    %% Start with a service that already has static vars
    Service0 = make_service(<<"merge-svc">>, SecretsSpec),
    #{auth_conf := AuthConf0} = Service0,
    Service = Service0#{
        auth_conf => AuthConf0#{
            vars => #{existing_var => <<"keep-me">>}
        }
    },

    [Resolved] = bondy_rpc_gateway_secret_resolver:resolve_services([Service]),

    #{auth_conf := #{vars := Vars}} = Resolved,
    %% Static var preserved
    ?assertEqual(<<"keep-me">>, maps:get(existing_var, Vars)),
    %% Secret var added
    ?assertEqual(<<"myuser">>, maps:get(client_id, Vars)).

resolve_services_missing_field(_Config) ->
    %% Secret JSON has no "MISSING_FIELD" key
    mock_sm_success(#{<<"OTHER">> => <<"value">>}),

    SecretsSpec = #{
        provider => aws_sm,
        secret_id => <<"/test">>,
        region => <<"us-east-1">>,
        vars => #{
            my_var => #{
                field => <<"MISSING_FIELD">>,
                transform => none
            }
        }
    },
    Service = make_service(<<"missing-svc">>, SecretsSpec),

    ?assertError(
        {secret_field_not_found, <<"missing-svc">>, my_var, <<"MISSING_FIELD">>},
        bondy_rpc_gateway_secret_resolver:resolve_services([Service])
    ).

resolve_services_aws_error(_Config) ->
    meck:expect(erlcloud_sm, get_secret_value,
        fun(_SecretId, [], _SmConfig) ->
            {error, {http_error, 403, <<"Forbidden">>}}
        end
    ),

    SecretsSpec = #{
        provider => aws_sm,
        secret_id => <<"/test">>,
        region => <<"us-east-1">>,
        vars => #{}
    },
    Service = make_service(<<"err-svc">>, SecretsSpec),

    ?assertError(
        {secret_resolution_failed, <<"err-svc">>,
         {http_error, 403, <<"Forbidden">>}},
        bondy_rpc_gateway_secret_resolver:resolve_services([Service])
    ).

resolve_services_removes_secrets_from_auth_conf(_Config) ->
    mock_sm_success(mock_secret_json()),

    SecretsSpec = #{
        provider => aws_sm,
        secret_id => <<"/test">>,
        region => <<"sa-east-1">>,
        vars => #{
            client_id => #{
                field => <<"AUTHORIZATION_HEADER">>,
                transform => basic_username
            }
        }
    },
    Service = make_service(<<"clean-svc">>, SecretsSpec),

    [Resolved] = bondy_rpc_gateway_secret_resolver:resolve_services([Service]),

    #{auth_conf := AuthConf} = Resolved,
    ?assertNot(maps:is_key(secrets, AuthConf)).


%% ===================================================================
%% non_crashing — resolve_service_secrets/2
%% ===================================================================

resolve_service_secrets_ok(_Config) ->
    mock_sm_success(mock_secret_json()),

    SecretsSpec = #{
        provider => aws_sm,
        secret_id => <<"/integrations/credentials/test">>,
        region => <<"sa-east-1">>,
        vars => #{
            token_endpoint => #{
                field => <<"IDP_TOKEN_ENDPOINT">>,
                transform => none
            },
            client_id => #{
                field => <<"AUTHORIZATION_HEADER">>,
                transform => basic_username
            }
        }
    },

    {ok, Vars} = bondy_rpc_gateway_secret_resolver:resolve_service_secrets(
        SecretsSpec, <<"ok-svc">>
    ),
    ?assertEqual(<<"https://idp.example.com/token">>,
                 maps:get(token_endpoint, Vars)),
    ?assertEqual(<<"myuser">>, maps:get(client_id, Vars)).

resolve_service_secrets_aws_error(_Config) ->
    meck:expect(erlcloud_sm, get_secret_value,
        fun(_SecretId, [], _SmConfig) ->
            {error, {http_error, 403, <<"Forbidden">>}}
        end
    ),

    SecretsSpec = #{
        provider => aws_sm,
        secret_id => <<"/test">>,
        region => <<"us-east-1">>,
        vars => #{}
    },

    {error, Reason} =
        bondy_rpc_gateway_secret_resolver:resolve_service_secrets(
            SecretsSpec, <<"err-svc">>
        ),
    ?assertMatch({secret_resolution_failed, <<"err-svc">>, _}, Reason).

resolve_service_secrets_missing_field(_Config) ->
    mock_sm_success(#{<<"OTHER">> => <<"value">>}),

    SecretsSpec = #{
        provider => aws_sm,
        secret_id => <<"/test">>,
        region => <<"us-east-1">>,
        vars => #{
            my_var => #{
                field => <<"MISSING_FIELD">>,
                transform => none
            }
        }
    },

    {error, Reason} =
        bondy_rpc_gateway_secret_resolver:resolve_service_secrets(
            SecretsSpec, <<"missing-svc">>
        ),
    ?assertMatch(
        {secret_field_not_found, <<"missing-svc">>, my_var, <<"MISSING_FIELD">>},
        Reason
    ).
