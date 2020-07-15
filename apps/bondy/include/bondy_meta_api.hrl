%% =============================================================================
%%  bondy_security.hrl -
%%
%%  Copyright (c) 2016-2020 Ngineo Limited t/a Leapsight. All rights reserved.
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

-define(REALM_ADDED,        <<"bondy.security.realm_added">>).
-define(REALM_DELETED,      <<"bondy.security.realm_deleted">>).

-define(USER_ADDED,         <<"bondy.security.user_added">>).
-define(USER_UPDATED,       <<"bondy.security.user_updated">>).
-define(USER_DELETED,       <<"bondy.security.user_deleted">>).
-define(PASSWORD_CHANGED,
    <<"bondy.security.password_changed">>
).

-define(GROUP_ADDED,        <<"bondy.security.group_added">>).
-define(GROUP_DELETED,      <<"bondy.security.group_deleted">>).
-define(GROUP_UPDATED,      <<"bondy.security.group_updated">>).

-define(SOURCE_ADDED,       <<"bondy.security.source_added">>).
-define(SOURCE_DELETED,     <<"bondy.security.source_deleted">>).



%% =============================================================================
%% PROCEDURES
%% =============================================================================



-define(LIST_REALMS,        <<"bondy.security.list_realms">>).
-define(CREATE_REALM,       <<"bondy.security.create_realm">>).
-define(UPDATE_REALM,       <<"bondy.security.update_realm">>).
-define(DELETE_REALM,       <<"bondy.security.delete_realm">>).
-define(ENABLE_SECURITY,    <<"bondy.security.enable">>).
-define(DISABLE_SECURITY,   <<"bondy.security.disable">>).
-define(SECURITY_STATUS,    <<"bondy.security.status">>).
-define(IS_SECURITY_ENABLED, <<"bondy.security.is_enabled">>).
-define(CHANGE_PASSWORD,    <<"bondy.security.change_password">>).

-define(LIST_USERS,         <<"bondy.security.list_users">>).
-define(FIND_USER,          <<"bondy.security.find_user">>).
-define(ADD_USER,           <<"bondy.security.add_user">>).
-define(DELETE_USER,        <<"bondy.security.delete_user">>).
-define(UPDATE_USER,        <<"bondy.security.update_user">>).

-define(LIST_GROUPS,        <<"bondy.security.list_groups">>).
-define(FIND_GROUP,         <<"bondy.security.find_group">>).
-define(ADD_GROUP,          <<"bondy.security.add_group">>).
-define(DELETE_GROUP,       <<"bondy.security.delete_group">>).
-define(UPDATE_GROUP,       <<"bondy.security.update_group">>).

-define(LIST_SOURCES,       <<"bondy.security.list_sources">>).
-define(FIND_SOURCE,        <<"bondy.security.find_source">>).
-define(ADD_SOURCE,         <<"bondy.security.add_source">>).
-define(DELETE_SOURCE,      <<"bondy.security.delete_source">>).