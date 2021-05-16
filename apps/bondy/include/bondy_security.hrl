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



-define(BONDY_AUTH_PROVIDER, <<"com.leapsight.bondy.rbac">>).

-define(WAMP_ANON_AUTH,         <<"anonymous">>).
-define(PASSWORD_AUTH,          <<"password">>).
-define(OAUTH2_AUTH,            <<"oauth2">>).
-define(TRUST_AUTH,             <<"trust">>).
-define(WAMP_COOKIE_AUTH,       <<"cookie">>).
-define(WAMP_CRA_AUTH,          <<"wampcra">>).
-define(WAMP_CRYPTOSIGN_AUTH,   <<"cryptosign">>).
-define(WAMP_OAUTH2_AUTH,       <<"oauth2">>).
-define(WAMP_SCRAM_AUTH,        <<"wamp-scram">>).
-define(WAMP_TICKET_AUTH,       <<"ticket">>).
-define(WAMP_TLS_AUTH,          <<"tls">>).

-define(BONDY_AUTHMETHODS_INFO, #{
    ?WAMP_ANON_AUTH => #{
        callback_mod => bondy_auth_anonymous,
        description => <<"Allows access to clients which connect without credentials assigning them the 'anonymous' group. You can configure the allowed sources for the anonymous user and the permissions assigned to the anonymous group - but you cannot make the anonymous group a member of another group.">>
    },
    ?TRUST_AUTH => #{
        callback_mod => bondy_auth_trust,
        description => <<"Allows access to clients which connect with an existing username (WAMP authid field) but does not request them to provide the password and or performing the authentication challenge. This is to be used in conjunction with source definition e.g. trust only clients within the same network (CIDR).">>
    },
    ?PASSWORD_AUTH => #{
        callback_mod => bondy_auth_password,
        description => <<"Allows access to clients which connect with an existing username (WAMP authid field) and password, where the password is send in clear-text and is therefore vulnerable to password \"sniffing\" attacks, unless the connection is protected by SSL encryption. It should be avoided and replaced by the use of \"wamp-cra\" or \"wamp-scram\" challenge-response methods if possible.">>
    },
    ?OAUTH2_AUTH => #{
        callback_mod => bondy_auth_oauth2
    },
    ?WAMP_COOKIE_AUTH => #{
        callback_mod => undefined
    },
    ?WAMP_CRA_AUTH => #{
        callback_mod => bondy_auth_wamp_cra
    },
    ?WAMP_SCRAM_AUTH => #{
        callback_mod => bondy_auth_wamp_scram
    },
    ?WAMP_CRYPTOSIGN_AUTH => #{
        callback_mod => bondy_auth_wamp_cryptosign
    },
    ?WAMP_TICKET_AUTH => #{
        callback_mod => undefined
    },
    ?WAMP_TLS_AUTH => #{
        callback_mod => undefined
    }
}).


-define(BONDY_AUTH_METHOD_NAMES,
    case persistent_term:get({bondy, '_auth_method_names'}, undefined) of
        undefined ->
            Names = maps:keys(?BONDY_AUTHMETHODS_INFO),
            ok = persistent_term:put({bondy, '_auth_method_names'}, Names),
            Names;
        Names ->
            Names
    end
).

-define(WAMP_PERMISSIONS, [
    <<"wamp.register">>,
    <<"wamp.unregister">>,
    <<"wamp.call">>,
    <<"wamp.cancel">>,
    <<"wamp.subscribe">>,
    <<"wamp.unsubscribe">>,
    <<"wamp.publish">>,
    <<"wamp.disclose_caller">>,
    <<"wamp.disclose_publisher">>,
    <<"wamp.disclose_caller_authroles">>,
    <<"wamp.disclose_publisher_authroles">>,
    <<"wamp.disclose_caller_session">>,
    <<"wamp.disclose_publisher_session">>,
]).

