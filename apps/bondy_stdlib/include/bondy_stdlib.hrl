%% =============================================================================
%%  bondy_stdlib.hrl -
%%
%%  Copyright (c) 2016-2025 Leapsight. All rights reserved.
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
%% ERLANG VERSION MIGRATION SUPPORT
%% =============================================================================


-if(?OTP_RELEASE >= 27).
    -define(MODULEDOC(Str), -moduledoc(Str)).
    -define(DOC(Str), -doc(Str)).
-else.
    -define(MODULEDOC(Str), -compile([])).
    -define(DOC(Str), -compile([])).
-endif.


%% =============================================================================
%% TYPES
%% =============================================================================

-type optional(T)       ::  T | undefined.



