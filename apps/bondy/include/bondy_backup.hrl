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
%% PROCEDURE
%% =============================================================================



-define(CREATE_BACKUP, <<"bondy.backup.create">>).
-define(BACKUP_STATUS, <<"bondy.backup.status">>).
-define(RESTORE_BACKUP, <<"bondy.backup.restore">>).



%% =============================================================================
%% EVENTS
%% =============================================================================



-define(BACKUP_STARTED, <<"bondy.backup.backup_started">>).
-define(BACKUP_FINISHED, <<"bondy.backup.backup_finished">>).
-define(BACKUP_ERROR, <<"bondy.backup.backup_error">>).
-define(RESTORE_STARTED, <<"bondy.backup.restored_started">>).
-define(RESTORE_FINISHED, <<"bondy.backup.restored_finished">>).
-define(RESTORE_ERROR, <<"bondy.backup.restore_error">>).