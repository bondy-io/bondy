%% =============================================================================
%%  bondy_security.hrl -
%%
%%  Copyright (c) 2016-2018 Ngineo Limited t/a Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

%% =============================================================================
%% EVENTS
%% =============================================================================

-define(REALM_ADDED,        <<"com.leapsight.bondy.security.realm_added">>).
-define(REALM_DELETED,      <<"com.leapsight.bondy.security.realm_deleted">>).

-define(USER_ADDED,         <<"com.leapsight.bondy.security.user_added">>).
-define(USER_UPDATED,       <<"com.leapsight.bondy.security.user_updated">>).
-define(USER_DELETED,       <<"com.leapsight.bondy.security.user_deleted">>).
-define(PASSWORD_CHANGED,
    <<"com.leapsight.bondy.security.password_changed">>
).

-define(GROUP_ADDED,        <<"com.leapsight.bondy.security.group_added">>).
-define(GROUP_DELETED,      <<"com.leapsight.bondy.security.group_deleted">>).
-define(GROUP_UPDATED,      <<"com.leapsight.bondy.security.group_updated">>).

-define(SOURCE_ADDED,       <<"com.leapsight.bondy.security.source_added">>).
-define(SOURCE_DELETED,     <<"com.leapsight.bondy.security.source_deleted">>).



%% =============================================================================
%% PROCEDURES
%% =============================================================================



-define(LIST_REALMS,        <<"com.leapsight.bondy.security.list_realms">>).
-define(CREATE_REALM,       <<"com.leapsight.bondy.security.create_realm">>).
-define(UPDATE_REALM,       <<"com.leapsight.bondy.security.update_realm">>).
-define(DELETE_REALM,       <<"com.leapsight.bondy.security.delete_realm">>).
-define(ENABLE_SECURITY,    <<"com.leapsight.bondy.security.enable">>).
-define(DISABLE_SECURITY,   <<"com.leapsight.bondy.security.disable">>).
-define(SECURITY_STATUS,    <<"com.leapsight.bondy.security.status">>).
-define(IS_SECURITY_ENABLED, <<"com.leapsight.bondy.security.is_enabled">>).
-define(CHANGE_PASSWORD,    <<"com.leapsight.bondy.security.change_password">>).

-define(LIST_USERS,         <<"com.leapsight.bondy.security.list_users">>).
-define(FIND_USER,          <<"com.leapsight.bondy.security.find_user">>).
-define(ADD_USER,           <<"com.leapsight.bondy.security.add_user">>).
-define(DELETE_USER,        <<"com.leapsight.bondy.security.delete_user">>).
-define(UPDATE_USER,        <<"com.leapsight.bondy.security.update_user">>).

-define(LIST_GROUPS,        <<"com.leapsight.bondy.security.list_groups">>).
-define(FIND_GROUP,         <<"com.leapsight.bondy.security.find_group">>).
-define(ADD_GROUP,          <<"com.leapsight.bondy.security.add_group">>).
-define(DELETE_GROUP,       <<"com.leapsight.bondy.security.delete_group">>).
-define(UPDATE_GROUP,       <<"com.leapsight.bondy.security.update_group">>).

-define(LIST_SOURCES,       <<"com.leapsight.bondy.security.list_sources">>).
-define(FIND_SOURCE,        <<"com.leapsight.bondy.security.find_source">>).
-define(ADD_SOURCE,         <<"com.leapsight.bondy.security.add_source">>).
-define(DELETE_SOURCE,      <<"com.leapsight.bondy.security.delete_source">>).





%% =============================================================================
%% SCHEMAS
%% =============================================================================


-define(TRUST_AUTH, <<"trust">>).
-define(PASSWORD_AUTH, <<"password">>).
-define(CERTIFICATE_AUTH, <<"certificate">>).
-define(LDAP_AUTH, <<"ldap">>).

-define(AUTH_METHODS_BIN, [
    ?TRUST_AUTH,
    ?PASSWORD_AUTH,
    ?CERTIFICATE_AUTH,
    ?LDAP_AUTH | ?WAMP_AUTH_METHODS
]).

-define(AUTH_METHODS_ATOM, [
    trust,
    password,
    certificate,
    ldap | ?WAMP_AUTH_METHODS_ATOM
]).

-define(WAMP_AUTH_METHODS_ATOM, [
    anonymous,
    cookie,
    ticket,
    tls,
    wampcra
]).


-define(BONDY_REALM, #{
    description => <<"The Bondy administrative realm.">>,
    authmethods => [?WAMPCRA_AUTH, ?TICKET_AUTH, ?TLS_AUTH, ?ANON_AUTH],
    grants => [
        #{
            permissions => [
                <<"wamp.register">>,
                <<"wamp.unregister">>,
                <<"wamp.subscribe">>,
                <<"wamp.unsubscribe">>,
                <<"wamp.call">>,
                <<"wamp.cancel">>,
                <<"wamp.publish">>
            ],
            uri => <<"*">>,
            roles => [<<"anonymous">>]
        }
    ],
    sources => [
        #{
            usernames => <<"anonymous">>,
            authmethod => <<"trust">>,
            cidr => <<"0.0.0.0/0">>,
            meta => #{}
        }
    ]
}).

-define(REALM_SPEC, #{
    <<"uri">> => #{
        alias => uri,
        key => <<"uri">>,
        required => true,
        datatype => binary
    },
    <<"description">> => #{
        alias => description,
        key => <<"description">>,
        required => true,
        datatype => binary,
        default => <<>>
    },
    <<"authmethods">> => #{
        alias => authmethods,
        key => <<"authmethods">>,
        required => true,
        datatype => {list, {in, ?WAMP_AUTH_METHODS}},
        default => ?WAMP_AUTH_METHODS
    },
    <<"security_enabled">> => #{
        alias => security_enabled,
        key => <<"security_enabled">>,
        required => true,
        datatype => boolean,
        default => true
    },
    <<"users">> => #{
        alias => users,
        key => <<"users">>,
        required => true,
        default => [],
        datatype => list,
        validator => {list, ?USER_SPEC}
    },
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>,
        required => true,
        default => [],
        datatype => list,
        validator => {list, ?GROUP_SPEC}
    },
    <<"sources">> => #{
        alias => sources,
        key => <<"sources">>,
        required => true,
        default => [],
        datatype => list,
        validator => {list, ?SOURCE_SPEC}
    },
    <<"grants">> => #{
        alias => grants,
        key => <<"grants">>,
        required => true,
        default => [],
        datatype => list,
        validator => {list, ?GRANT_SPEC}
    },
    <<"private_keys">> => #{
        alias => private_keys,
        key => <<"private_keys">>,
        required => true,
        allow_undefined => false,
        allow_null => false,
        datatype => {list, binary},
        default => [
            jose_jwk:generate_key({namedCurve, secp256r1})
            || _ <- lists:seq(1, 3)
        ],
        validator => fun
            ([]) ->
                Keys = [
                    jose_jwk:generate_key({namedCurve, secp256r1})
                    || _ <- lists:seq(1, 3)
                ],
                {ok, Keys};
            (Pems) when length(Pems) < 3 ->
                false;
            (Pems) ->
                try
                    Keys = lists:map(
                        fun(Pem) ->
                            case jose_jwk:from_pem(Pem) of
                                {jose_jwk, _, _, _} = Key -> Key;
                                _ -> false
                            end
                        end,
                        Pems
                    ),
                    {ok, Keys}
                catch
                    ?EXCEPTION(_, _, _) ->
                        false
                end
        end
    }
}).

%% Override to make private_keys not required on update
-define(UPDATE_REALM_SPEC, ?REALM_SPEC#{
    <<"private_keys">> => #{
        alias => private_keys,
        key => <<"private_keys">>,
        required => false,
        allow_undefined => false,
        allow_null => false,
        datatype => {list, binary},
        validator => fun
            ([]) ->
                Keys = [
                    jose_jwk:generate_key({namedCurve, secp256r1})
                    || _ <- lists:seq(1, 3)
                ],
                {ok, Keys};
            (Pems) when length(Pems) < 3 ->
                false;
            (Pems) ->
                try
                    Keys = lists:map(
                        fun(Pem) ->
                            case jose_jwk:from_pem(Pem) of
                                {jose_jwk, _, _, _} = Key -> Key;
                                _ -> false
                            end
                        end,
                        Pems
                    ),
                    {ok, Keys}
                catch
                    ?EXCEPTION(_, _, _) ->
                        false
                end
        end
    }
}).


-define(VALIDATE_USERNAME, fun
        (<<"all">>) ->
            false;
        ("all") ->
            false;
        (all) ->
            false;
        (_) ->
            true
    end
).

-define(USER_SPEC, #{
    <<"username">> => #{
        alias => username,
        key => <<"username">>,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary,
        validator => ?VALIDATE_USERNAME
    },
    <<"password">> => #{
        alias => password,
        key => <<"password">>,
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>, %% bondy_security requirement
        allow_null => false,
        allow_undefined => false,
        required => true,
        default => [],
        datatype => {list, binary}
    },
    <<"meta">> => #{
        alias => meta,
        key => <<"meta">>,
        allow_null => false,
        allow_undefined => false,
        required => true,
        datatype => map,
        default => #{}
    }
}).

-define(USER_UPDATE_SPEC, #{
    <<"password">> => #{
        alias => password,
        key => <<"password">>,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>, %% bondy_security requirement
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => {list, binary}
    },
    <<"meta">> => #{
        alias => meta,
        key => <<"meta">>,
        allow_null => false,
        allow_undefined => false,
        required => false,
        datatype => map
    }
}).

-define(GROUP_SPEC, ?GROUP_UPDATE_SPEC#{
    <<"name">> => #{
        alias => name,
        key => <<"name">>,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>, %% bondy_security requirement
        allow_null => false,
        allow_undefined => false,
        required => true,
        datatype => {list, binary},
        default => []
    },
    <<"meta">> => #{
        alias => meta,
        key => <<"meta">>,
        allow_null => false,
        allow_undefined => false,
        required => true,
        datatype => map,
        default => #{}
    }
}).

-define(GROUP_UPDATE_SPEC, #{
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>, %% bondy_security requirement
        allow_null => false,
        allow_undefined => false,
        required => false,
        datatype => {list, binary}
    },
    <<"meta">> => #{
        alias => meta,
        key => <<"meta">>,
        allow_null => false,
        allow_undefined => false,
        required => false,
        datatype => map
    }
}).

-define(ROLES_DATATYPE, [
    {in, [<<"all">>, all,  <<"anonymous">>, anonymous]},
    {list, binary}
]).

-define(ROLES_VALIDATOR, fun
    (<<"anonymous">>) ->
        {ok, anonymous};
    (<<"all">>) ->
        {ok, all};
    (all) ->
        true;
    (anonymous) ->
        true;
    (List) when is_list(List) ->
        A = sets:from_list(List),
        B = sets:from_list([<<"all">>]),
        case sets:is_disjoint(A, B) of
            true ->
                L = lists:map(
                    fun(<<"anonymous">>) -> anonymous; (X) -> X end,
                    List
                ),
                {ok, L};
            false ->
                false
        end
end).

-define(SOURCE_SPEC, #{
    <<"usernames">> => #{
        alias => usernames,
        key => <<"usernames">>,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => ?ROLES_DATATYPE,
        %% all cannot be mixed anonymous or with custom usernames
        %% in the same rule
        validator => ?ROLES_VALIDATOR
    },
    <<"authmethod">> => #{
        alias => authmethod,
        key => <<"authmethod">>,
        required => true,
        allow_null => false,
        datatype => [{in, ?AUTH_METHODS_BIN}, {in, ?AUTH_METHODS_ATOM}],
        validator => fun
            (Bin) when is_binary(Bin) ->
                try
                    %% We turn auth method binary to atom format
                    {ok, list_to_existing_atom(binary_to_list(Bin))}
                catch
                    ?EXCEPTION(_, _, _) ->
                        false
                end;
            (_) ->
                true
        end
    },
    <<"cidr">> => #{
        alias => cidr,
        key => <<"cidr">>, %% bondy_security requirement
        allow_null => false,
        allow_undefined => false,
        required => true,
        default => [],
        datatype => [binary, tuple],
        validator => fun
            (Bin) when is_binary(Bin) ->
                case re:split(Bin, "/", [{return, list}, {parts, 2}]) of
                    [Prefix, LenStr] ->
                        {ok, Addr} = inet:parse_address(Prefix),
                        {PrefixLen, _} = string:to_integer(LenStr),
                        {ok, {Addr, PrefixLen}};
                    _ ->
                        false
                end;
            ({IP, PrefixLen}) when PrefixLen >= 0 ->
                case inet:ntoa(IP) of
                    {error, einval} -> false;
                    _ -> true
                end;
            (_) ->
                false
        end
    },
    <<"meta">> => #{
        alias => meta,
        key => <<"meta">>,
        allow_null => false,
        allow_undefined => false,
        required => true,
        datatype => map,
        default => #{}
    }
}).



-define(GRANT_SPEC, #{
    <<"permissions">> => #{
        alias => permissions,
        key => <<"permissions">>,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => {list,
            {in, [
                <<"wamp.register">>,
                <<"wamp.unregister">>,
                <<"wamp.call">>,
                <<"wamp.cancel">>,
                <<"wamp.subscribe">>,
                <<"wamp.unsubscribe">>,
                <<"wamp.publish">>
            ]}
        }
    },
    <<"uri">> => #{
        alias => uri,
        key => <<"uri">>,
        required => true,
        allow_null => false,
        datatype => binary,
        validator => fun
            (<<"*">>) ->
                {ok, any};
            (<<"all">>) ->
                {ok, all};
            (any) ->
                true;
            (all) ->
                true;
            (Uri) when is_binary(Uri) ->
                Len = byte_size(Uri) - 1,
                case binary:matches(Uri, [<<$*>>]) of
                    [] -> true;
                    [{Len, 1}] -> true; % a prefix match
                    [_|_] -> false % illegal
                end
        end
    },
    <<"roles">> => #{
        alias => roles,
        key => <<"roles">>,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => ?ROLES_DATATYPE,
        validator => ?ROLES_VALIDATOR
    }
}).

