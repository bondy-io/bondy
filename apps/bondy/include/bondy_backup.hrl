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
%% PROCEDURE
%% =============================================================================



-define(CREATE_BACKUP, <<"com.leapsight.bondy.backup.create">>).
-define(BACKUP_STATUS, <<"com.leapsight.bondy.backup.status">>).
-define(RESTORE_BACKUP, <<"com.leapsight.bondy.backup.restore">>).



%% =============================================================================
%% EVENTS
%% =============================================================================



-define(BACKUP_STARTED, <<"com.leapsight.bondy.backup.backup_started">>).
-define(BACKUP_FINISHED, <<"com.leapsight.bondy.backup.backup_finished">>).
-define(BACKUP_ERROR, <<"com.leapsight.bondy.backup.backup_error">>).
-define(RESTORE_STARTED, <<"com.leapsight.bondy.backup.restored_started">>).
-define(RESTORE_FINISHED, <<"com.leapsight.bondy.backup.restored_finished">>).
-define(RESTORE_ERROR, <<"com.leapsight.bondy.backup.restore_error">>).