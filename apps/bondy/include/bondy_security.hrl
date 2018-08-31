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
