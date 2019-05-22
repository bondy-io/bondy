%% =============================================================================
%%  bondy.hrl -
%%
%%  Copyright (c) 2016-2019 Ngineo Limited t/a Leapsight. All rights reserved.
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

-define(BONDY_REALM_URI, <<"com.leapsight.bondy">>).
-define(BONDY_PRIV_REALM_URI, <<"com.leapsight.bondy.private">>).

-define(BONDY_PEER_REQUEST, '$bondy_request').
-define(BONDY_PEER_ACK, '$bondy_ack').

-ifdef(OTP_RELEASE). %% => OTP is 21 or higher
-include_lib("kernel/include/logger.hrl").
-define(EXCEPTION(Class, Reason, Stacktrace), Class:Reason:Stacktrace).
-define(STACKTRACE(Stacktrace), Stacktrace).
-else.
-define(EXCEPTION(Class, Reason, _), Class:Reason).
-define(STACKTRACE(_), erlang:get_stacktrace()).
-endif.


%% In msecs
-define(SEND_TIMEOUT, 20000).



%% =============================================================================
%% FEATURES
%% =============================================================================



-define(DEALER_FEATURES, #{
    call_timeout => true,
    shared_registration => true,
    call_canceling => true,
    pattern_based_registration => true,
    progressive_call_results => false,
    progressive_calls => false,
    caller_identification => false,
    call_trustlevels => false,
    registration_meta_api => false,
    registration_revocation => false,
    session_meta_api => false,
    reflection => false,
    sharded_registration => false
}).

-define(CALLEE_FEATURES, #{
    call_timeout => true,
    call_canceling => true,
    shared_registration => true,
    progressive_call_results => false,
    progressive_calls => false,
    caller_identification => false,
    call_trustlevels => false,
    registration_revocation => false,
    session_meta_api => false,
    pattern_based_registration => true,
    sharded_registration => false
}).

-define(CALLER_FEATURES, #{
    call_timeout => true,
    progressive_call_results => false,
    progressive_calls => false,
    call_canceling => false,
    caller_identification => false
}).

-define(BROKER_FEATURES, #{
    pattern_based_subscription => true,
    publisher_exclusion => true,
    event_history => false,
    publication_trustlevels => false,
    publisher_identification => false,
    session_meta_api => false,
    sharded_subscription => false,
    subscriber_blackwhite_listing => false,
    subscription_meta_api => false,
    reflection => false
}).

-define(SUBSCRIBER_FEATURES, #{
    pattern_based_subscription => true,
    event_history => false,
    publication_trustlevels => false,
    publisher_identification => false,
    sharded_subscription => false
}).

-define(PUBLISHER_FEATURES, #{
    publisher_exclusion => true,
    publisher_identification => false,
    subscriber_blackwhite_listing => false
}).




%% =============================================================================
%% GENERAL
%% =============================================================================


-define(BONDY_ERROR_NOT_IN_SESSION, <<"com.leapsight.bondy.error.not_in_session">>).
-define(BONDY_SESSION_ALREADY_EXISTS, <<"com.leapsight.bondy.error.session_already_exists">>).

-define(BONDY_ERROR_TIMEOUT, <<"com.leapsight.bondy.error.timeout">>).
-define(BONDY_INCONSISTENCY_ERROR, <<"com.leapsight.bondy.error.unknown_error">>).

-type local_peer_id()   ::  {
    Realm       ::  binary(),
    Node        ::  atom(),
    SessionId   ::  integer() | undefined,
    Pid         ::  pid()
}.
-type remote_peer_id()  ::  {
    Realm       ::  binary(),
    Node        ::  atom(),
    SessionId   ::  integer() | undefined,
    Pid         ::  pid() | list() |undefined
}.
-type peer_id()         ::  local_peer_id() | remote_peer_id().





%% =============================================================================
%% UTILS
%% =============================================================================

-define(EOT, '$end_of_table').
-define(CHARS2BIN(Chars), unicode:characters_to_binary(Chars, utf8, utf8)).
-define(CHARS2LIST(Chars), unicode:characters_to_list(Chars, utf8)).
