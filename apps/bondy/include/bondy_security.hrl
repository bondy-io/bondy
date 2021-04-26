%% =============================================================================
%%  bondy_security.hrl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
%% SCHEMAS
%% =============================================================================


-define(TRUST_AUTH, <<"trust">>).
-define(PASSWORD_AUTH, <<"password">>).
-define(CERTIFICATE_AUTH, <<"certificate">>).
-define(LDAP_AUTH, <<"ldap">>).


-define(AUTH_METHODS, [
    ?TRUST_AUTH,
    ?PASSWORD_AUTH,
    ?CERTIFICATE_AUTH,
    ?LDAP_AUTH
    | ?BONDY_WAMP_AUTH_METHODS
]).

-define(AUTH_METHODS_ATOM,
    case persistent_term:get({bondy, auth_methods_atom}, undefined) of
        undefined ->
            Val = [binary_to_atom(B, utf8) || B <- ?AUTH_METHODS],
            ok = persistent_term:put({bondy, wamp_auth_methods_atom}, Val),
            Val;
        Val ->
            Val
    end
).

-define(OAUTH2_AUTH, <<"oauth2">>).
-define(ANON_AUTH, <<"anonymous">>).
-define(COOKIE_AUTH, <<"cookie">>).
-define(TICKET_AUTH, <<"ticket">>).
-define(TLS_AUTH, <<"tls">>).
-define(WAMPCRA_AUTH, <<"wampcra">>).

-define(BONDY_WAMP_AUTH_METHODS, [
    ?ANON_AUTH,
    ?OAUTH2_AUTH,
    ?COOKIE_AUTH,
    ?TICKET_AUTH,
    ?TLS_AUTH,
    ?WAMPCRA_AUTH
]).


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
    {in, [<<"all">>, all]},
    {list, binary}
]).

-define(ROLES_VALIDATOR, fun
    (<<"all">>) ->
        {ok, all};
    (all) ->
        true;
    (List) when is_list(List) ->
        A = sets:from_list(List),
        B = sets:from_list([<<"all">>, all]),
        case sets:is_disjoint(A, B) of
            true ->
                L = lists:map(
                    fun(<<"anonymous">>) -> anonymous; (X) -> X end,
                    List
                ),
                {ok, L};
            false ->
                %% Error, "all" is not a role so it cannot
                %% be mixed in a roles list
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
        %% datatype => ?ROLES_DATATYPE,
        validator => ?ROLES_VALIDATOR
    },
    <<"authmethod">> => #{
        alias => authmethod,
        key => <<"authmethod">>,
        required => true,
        allow_null => false,
        datatype => [{in, ?AUTH_METHODS}, {in, ?AUTH_METHODS_ATOM}],
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
        datatype => [binary, {in, [any, all]}],
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
        %% datatype => ?ROLES_DATATYPE,
        validator => ?ROLES_VALIDATOR
    }
}).

