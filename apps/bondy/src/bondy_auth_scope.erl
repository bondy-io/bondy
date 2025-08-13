-module(bondy_auth_scope).

-include("bondy.hrl").

-type t()           ::  #{
                            realm       :=  binary() | all,
                            client_id   :=  binary() | all,
                            device_id   :=  binary() | all
                        }.

-export_type([t/0]).


-export([client_id/1]).
-export([device_id/1]).
-export([matches/2]).
-export([matches_realm/2]).
-export([new/3]).
-export([normalize/1]).
-export([realm/1]).
-export([type/1]).



%% =============================================================================
%% API
%% =============================================================================



-doc """
""".
-spec new(optional(binary()), optional(binary()), optional(binary())) -> t().

new(RealmUri, ClientId, DeviceId)
when (is_binary(RealmUri) orelse RealmUri == all) andalso
(is_binary(ClientId) orelse ClientId == all) andalso
(is_binary(DeviceId) orelse DeviceId == all) ->
    #{
        realm => cast(RealmUri),
        client_id => cast(ClientId),
        device_id => cast(DeviceId)
    }.


-doc """
Returns the access scope type. It can be one of the following atoms:

- `local` -- the user can only access the designated realm via any client.
- `sso` -- the user can access all realms under the session's authrealm (an SSO realm) via any client.
- `client_local` -- the user can only access the designated realm but only via the designated client.
- `client_sso` -- the user can access all realms under the session's authrealm (an SSO realm) but only via the designed client.
""".
-spec type(t()) -> local | client_local | sso | client_sso.

type(#{realm := all, client_id := all}) ->
    sso;

type(#{realm := all, client_id := _}) ->
    client_sso;

type(#{realm := R, client_id := all}) when R =/= all ->
    local;

type(#{realm := R, client_id := _}) when R =/= all ->
    client_local.


-doc """
Returns true is scope A matches B.
""".
-spec matches(A :: t(), B :: t()) -> boolean().

matches(A, B) ->
     type(A) =:= type(B).


-doc """
""".
matches_realm(#{realm := all}, _) ->
    true;

matches_realm(#{realm := Val}, RealmUri) ->
    Val == RealmUri.


-doc """
""".
-spec normalize(map()) -> t().

normalize(Map) when is_map(Map) ->
    Default = #{
        realm => all,
        client_id => all,
        device_id => all
    },
    maps:merge(Default, maps:with([client_id, device_id, realm], Map)).


-doc """
""".
-spec realm(t()) -> binary() | all.

realm(#{realm := Val}) ->
    Val.


-doc """
""".
-spec client_id(t()) -> binary() | all.

client_id(#{client_id := Val}) ->
    Val.


-doc """
""".
-spec device_id(t()) -> binary() | all.

device_id(#{device_id := Val}) ->
    Val.


%% =============================================================================
%% Private
%% =============================================================================


cast("all") -> all;
cast(~"all") -> all;
cast(Val) -> Val.



%% =============================================================================
%% EUNIT
%% =============================================================================


-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% TEST FIXTURES
%% =============================================================================

%% Sample realm URIs for testing
test_realm1() -> <<"com.example.test1">>.
test_realm2() -> <<"com.example.test2">>.

%% Sample client IDs for testing
test_client1() -> <<"client123">>.
test_client2() -> <<"client456">>.

%% Sample device IDs for testing
test_device1() -> <<"device789">>.
test_device2() -> <<"device012">>.

%% =============================================================================
%% TESTS
%% =============================================================================

%% -----------------------------------------------------------------------------
%% new/3 tests
%% -----------------------------------------------------------------------------

new_all_parameters_binary_test() ->
    Realm = test_realm1(),
    ClientId = test_client1(),
    DeviceId = test_device1(),

    Scope = bondy_auth_scope:new(Realm, ClientId, DeviceId),

    ?assertEqual(Realm, maps:get(realm, Scope)),
    ?assertEqual(ClientId, maps:get(client_id, Scope)),
    ?assertEqual(DeviceId, maps:get(device_id, Scope)).

new_all_parameters_all_test() ->
    Scope = bondy_auth_scope:new(all, all, all),

    ?assertEqual(all, maps:get(realm, Scope)),
    ?assertEqual(all, maps:get(client_id, Scope)),
    ?assertEqual(all, maps:get(device_id, Scope)).

new_mixed_parameters_test() ->
    Realm = test_realm1(),

    Scope = bondy_auth_scope:new(Realm, all, test_device1()),

    ?assertEqual(Realm, maps:get(realm, Scope)),
    ?assertEqual(all, maps:get(client_id, Scope)),
    ?assertEqual(test_device1(), maps:get(device_id, Scope)).

new_realm_all_others_binary_test() ->
    ClientId = test_client1(),
    DeviceId = test_device1(),

    Scope = bondy_auth_scope:new(all, ClientId, DeviceId),

    ?assertEqual(all, maps:get(realm, Scope)),
    ?assertEqual(ClientId, maps:get(client_id, Scope)),
    ?assertEqual(DeviceId, maps:get(device_id, Scope)).

%% -----------------------------------------------------------------------------
%% type/1 tests
%% -----------------------------------------------------------------------------

type_sso_test() ->
    %% realm = all, client_id = all
    Scope = bondy_auth_scope:new(all, all, test_device1()),
    ?assertEqual(sso, bondy_auth_scope:type(Scope)).

type_client_sso_test() ->
    %% realm = all, client_id = binary
    Scope = bondy_auth_scope:new(all, test_client1(), test_device1()),
    ?assertEqual(client_sso, bondy_auth_scope:type(Scope)).

type_local_test() ->
    %% realm = binary, client_id = all
    Scope = bondy_auth_scope:new(test_realm1(), all, test_device1()),
    ?assertEqual(local, bondy_auth_scope:type(Scope)).

type_client_local_test() ->
    %% realm = binary, client_id = binary
    Scope = bondy_auth_scope:new(test_realm1(), test_client1(), test_device1()),
    ?assertEqual(client_local, bondy_auth_scope:type(Scope)).

%% Test all combinations to ensure completeness
type_combinations_test() ->
    Realm = test_realm1(),
    ClientId = test_client1(),
    DeviceId = test_device1(),

    %% SSO: realm=all, client_id=all
    Scope1 = bondy_auth_scope:new(all, all, DeviceId),
    ?assertEqual(sso, bondy_auth_scope:type(Scope1)),

    %% Client SSO: realm=all, client_id=binary
    Scope2 = bondy_auth_scope:new(all, ClientId, DeviceId),
    ?assertEqual(client_sso, bondy_auth_scope:type(Scope2)),

    %% Local: realm=binary, client_id=all
    Scope3 = bondy_auth_scope:new(Realm, all, DeviceId),
    ?assertEqual(local, bondy_auth_scope:type(Scope3)),

    %% Client Local: realm=binary, client_id=binary
    Scope4 = bondy_auth_scope:new(Realm, ClientId, DeviceId),
    ?assertEqual(client_local, bondy_auth_scope:type(Scope4)).

%% -----------------------------------------------------------------------------
%% matches/2 tests
%% -----------------------------------------------------------------------------

matches_same_type_sso_test() ->
    Scope1 = bondy_auth_scope:new(all, all, test_device1()),
    Scope2 = bondy_auth_scope:new(all, all, test_device2()),

    ?assert(bondy_auth_scope:matches(Scope1, Scope2)).

matches_same_type_client_sso_test() ->
    Scope1 = bondy_auth_scope:new(all, test_client1(), test_device1()),
    Scope2 = bondy_auth_scope:new(all, test_client2(), test_device2()),

    ?assert(bondy_auth_scope:matches(Scope1, Scope2)).

matches_same_type_local_test() ->
    Scope1 = bondy_auth_scope:new(test_realm1(), all, test_device1()),
    Scope2 = bondy_auth_scope:new(test_realm2(), all, test_device2()),

    ?assert(bondy_auth_scope:matches(Scope1, Scope2)).

matches_same_type_client_local_test() ->
    Scope1 = bondy_auth_scope:new(test_realm1(), test_client1(), test_device1()),
    Scope2 = bondy_auth_scope:new(test_realm2(), test_client2(), test_device2()),

    ?assert(bondy_auth_scope:matches(Scope1, Scope2)).

matches_different_types_sso_vs_client_sso_test() ->
    Scope1 = bondy_auth_scope:new(all, all, test_device1()),
    Scope2 = bondy_auth_scope:new(all, test_client1(), test_device2()),

    ?assertNot(bondy_auth_scope:matches(Scope1, Scope2)).

matches_different_types_local_vs_client_local_test() ->
    Scope1 = bondy_auth_scope:new(test_realm1(), all, test_device1()),
    Scope2 = bondy_auth_scope:new(test_realm1(), test_client1(), test_device2()),

    ?assertNot(bondy_auth_scope:matches(Scope1, Scope2)).

matches_different_types_sso_vs_local_test() ->
    Scope1 = bondy_auth_scope:new(all, all, test_device1()),
    Scope2 = bondy_auth_scope:new(test_realm1(), all, test_device2()),

    ?assertNot(bondy_auth_scope:matches(Scope1, Scope2)).

matches_different_types_client_sso_vs_client_local_test() ->
    Scope1 = bondy_auth_scope:new(all, test_client1(), test_device1()),
    Scope2 = bondy_auth_scope:new(test_realm1(), test_client1(), test_device2()),

    ?assertNot(bondy_auth_scope:matches(Scope1, Scope2)).

matches_identical_scopes_test() ->
    Scope = bondy_auth_scope:new(test_realm1(), test_client1(), test_device1()),

    ?assert(bondy_auth_scope:matches(Scope, Scope)).

%% -----------------------------------------------------------------------------
%% matches_realm/2 tests
%% -----------------------------------------------------------------------------

matches_realm_all_test() ->
    Scope = bondy_auth_scope:new(all, test_client1(), test_device1()),
    RealmUri = test_realm1(),

    ?assert(bondy_auth_scope:matches_realm(Scope, RealmUri)).

matches_realm_all_different_realm_test() ->
    Scope = bondy_auth_scope:new(all, test_client1(), test_device1()),
    RealmUri = test_realm2(),

    ?assert(bondy_auth_scope:matches_realm(Scope, RealmUri)).

matches_realm_specific_matching_test() ->
    RealmUri = test_realm1(),
    Scope = bondy_auth_scope:new(RealmUri, test_client1(), test_device1()),

    ?assert(bondy_auth_scope:matches_realm(Scope, RealmUri)).

matches_realm_specific_not_matching_test() ->
    Scope = bondy_auth_scope:new(test_realm1(), test_client1(), test_device1()),
    RealmUri = test_realm2(),

    ?assertNot(bondy_auth_scope:matches_realm(Scope, RealmUri)).

matches_realm_binary_vs_binary_test() ->
    RealmUri = <<"com.example.specific">>,
    Scope = bondy_auth_scope:new(RealmUri, all, all),

    ?assert(bondy_auth_scope:matches_realm(Scope, RealmUri)),
    ?assertNot(bondy_auth_scope:matches_realm(Scope, <<"com.example.other">>)).

%% -----------------------------------------------------------------------------
%% normalize/1 tests
%% -----------------------------------------------------------------------------

normalize_empty_map_test() ->
    Result = bondy_auth_scope:normalize(#{}),
    Expected = #{
        realm => all,
        client_id => all,
        device_id => all
    },
    ?assertEqual(Expected, Result).

normalize_partial_map_realm_only_test() ->
    Input = #{realm => test_realm1()},
    Result = bondy_auth_scope:normalize(Input),
    Expected = #{
        realm => test_realm1(),
        client_id => all,
        device_id => all
    },
    ?assertEqual(Expected, Result).

normalize_partial_map_client_only_test() ->
    Input = #{client_id => test_client1()},
    Result = bondy_auth_scope:normalize(Input),
    Expected = #{
        realm => all,
        client_id => test_client1(),
        device_id => all
    },
    ?assertEqual(Expected, Result).

normalize_partial_map_device_only_test() ->
    Input = #{device_id => test_device1()},
    Result = bondy_auth_scope:normalize(Input),
    Expected = #{
        realm => all,
        client_id => all,
        device_id => test_device1()
    },
    ?assertEqual(Expected, Result).

normalize_full_map_test() ->
    Input = #{
        realm => test_realm1(),
        client_id => test_client1(),
        device_id => test_device1()
    },
    Result = bondy_auth_scope:normalize(Input),
    ?assertEqual(Input, Result).

normalize_with_extra_fields_test() ->
    Input = #{
        realm => test_realm1(),
        client_id => test_client1(),
        device_id => test_device1(),
        extra_field => <<"ignored">>,
        another_field => 123
    },
    Result = bondy_auth_scope:normalize(Input),
    Expected = #{
        realm => test_realm1(),
        client_id => test_client1(),
        device_id => test_device1()
    },
    ?assertEqual(Expected, Result).

normalize_overrides_defaults_test() ->
    Input = #{
        realm => test_realm1(),
        client_id => test_client1()
        %% device_id not specified, should default to 'all'
    },
    Result = bondy_auth_scope:normalize(Input),
    Expected = #{
        realm => test_realm1(),
        client_id => test_client1(),
        device_id => all
    },
    ?assertEqual(Expected, Result).

normalize_all_values_test() ->
    Input = #{
        realm => all,
        client_id => all,
        device_id => all
    },
    Result = bondy_auth_scope:normalize(Input),
    ?assertEqual(Input, Result).

%% -----------------------------------------------------------------------------
%% realm/1 tests
%% -----------------------------------------------------------------------------

realm_binary_value_test() ->
    RealmUri = test_realm1(),
    Scope = bondy_auth_scope:new(RealmUri, test_client1(), test_device1()),
    ?assertEqual(RealmUri, bondy_auth_scope:realm(Scope)).

realm_all_value_test() ->
    Scope = bondy_auth_scope:new(all, test_client1(), test_device1()),
    ?assertEqual(all, bondy_auth_scope:realm(Scope)).

%% -----------------------------------------------------------------------------
%% client_id/1 tests
%% -----------------------------------------------------------------------------

client_id_binary_value_test() ->
    ClientId = test_client1(),
    Scope = bondy_auth_scope:new(test_realm1(), ClientId, test_device1()),
    ?assertEqual(ClientId, bondy_auth_scope:client_id(Scope)).

client_id_all_value_test() ->
    Scope = bondy_auth_scope:new(test_realm1(), all, test_device1()),
    ?assertEqual(all, bondy_auth_scope:client_id(Scope)).

%% -----------------------------------------------------------------------------
%% device_id/1 tests
%% -----------------------------------------------------------------------------

device_id_binary_value_test() ->
    DeviceId = test_device1(),
    Scope = bondy_auth_scope:new(test_realm1(), test_client1(), DeviceId),
    ?assertEqual(DeviceId, bondy_auth_scope:device_id(Scope)).

device_id_all_value_test() ->
    Scope = bondy_auth_scope:new(test_realm1(), test_client1(), all),
    ?assertEqual(all, bondy_auth_scope:device_id(Scope)).

%% -----------------------------------------------------------------------------
%% Integration tests
%% -----------------------------------------------------------------------------

integration_type_and_matches_test() ->
    %% Create scopes of different types
    SsoScope1 = bondy_auth_scope:new(all, all, test_device1()),
    SsoScope2 = bondy_auth_scope:new(all, all, test_device2()),
    ClientSsoScope = bondy_auth_scope:new(all, test_client1(), test_device1()),
    LocalScope = bondy_auth_scope:new(test_realm1(), all, test_device1()),
    ClientLocalScope = bondy_auth_scope:new(test_realm1(), test_client1(), test_device1()),

    %% Verify types
    ?assertEqual(sso, bondy_auth_scope:type(SsoScope1)),
    ?assertEqual(sso, bondy_auth_scope:type(SsoScope2)),
    ?assertEqual(client_sso, bondy_auth_scope:type(ClientSsoScope)),
    ?assertEqual(local, bondy_auth_scope:type(LocalScope)),
    ?assertEqual(client_local, bondy_auth_scope:type(ClientLocalScope)),

    %% Verify matches work correctly with types
    ?assert(bondy_auth_scope:matches(SsoScope1, SsoScope2)),
    ?assertNot(bondy_auth_scope:matches(SsoScope1, ClientSsoScope)),
    ?assertNot(bondy_auth_scope:matches(LocalScope, ClientLocalScope)),
    ?assertNot(bondy_auth_scope:matches(ClientSsoScope, ClientLocalScope)).

integration_normalize_and_accessors_test() ->
    Input = #{
        realm => test_realm1(),
        client_id => test_client1(),
        extra_field => <<"ignored">>
    },

    Scope = bondy_auth_scope:normalize(Input),

    %% Verify accessors work with normalized scope
    ?assertEqual(test_realm1(), bondy_auth_scope:realm(Scope)),
    ?assertEqual(test_client1(), bondy_auth_scope:client_id(Scope)),
    ?assertEqual(all, bondy_auth_scope:device_id(Scope)),
    ?assertEqual(client_local, bondy_auth_scope:type(Scope)).

integration_new_vs_normalize_consistency_test() ->
    RealmUri = test_realm1(),
    ClientId = test_client1(),
    DeviceId = test_device1(),

    %% Create scope using new/3
    Scope1 = bondy_auth_scope:new(RealmUri, ClientId, DeviceId),

    %% Create scope using normalize/1
    Scope2 = bondy_auth_scope:normalize(#{
        realm => RealmUri,
        client_id => ClientId,
        device_id => DeviceId
    }),

    %% Should be identical
    ?assertEqual(Scope1, Scope2),
    ?assertEqual(bondy_auth_scope:type(Scope1), bondy_auth_scope:type(Scope2)),
    ?assert(bondy_auth_scope:matches(Scope1, Scope2)).

-endif.


