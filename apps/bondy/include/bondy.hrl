%% =============================================================================
%%  bondy.hrl -
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
-define(MASTER_REALM_URI, <<"com.leapsight.bondy">>).
-define(CONTROL_REALM_URI, <<"com.leapsight.bondy.internal">>).

-define(BONDY_PEER_REQUEST, '$bondy_request').
-define(BONDY_PEER_ACK, '$bondy_ack').

%% In msecs
-define(SEND_TIMEOUT, 20000).



%% =============================================================================
%% FEATURES
%% =============================================================================

-define(INVOKE_JUMP_CONSISTENT_HASH, <<"jump_consistent_hash">>).
-define(INVOKE_QUEUE_LEAST_LOADED, <<"queue_least_loaded">>).
-define(INVOKE_QUEUE_LEAST_LOADED_SAMPLE, <<"queue_least_loaded_sample">>).

-define(WAMP_DEALER_FEATURES, #{
    call_canceling => true,
    call_timeout => true,
    call_trustlevels => false,
    caller_identification => true,
    pattern_based_registration => true,
    progressive_call_results => false,
    progressive_calls => false,
    reflection => false,
    registration_revocation => false,
    sharded_registration => false,
    shared_registration => true,
    registration_meta_api => true,
    session_meta_api => false
}).
-define(DEALER_FEATURES, ?WAMP_DEALER_FEATURES#{
    caller_auth_claims => true
}).

-define(WAMP_CALLEE_FEATURES, #{
    call_canceling => true,
    call_timeout => true,
    call_trustlevels => false,
    caller_identification => true,
    pattern_based_registration => true,
    progressive_call_results => false,
    progressive_calls => false,
    registration_revocation => false,
    sharded_registration => false,
    shared_registration => true,
    session_meta_api => false
}).
-define(CALLEE_FEATURES, ?WAMP_CALLEE_FEATURES#{
    caller_auth_claims => true
}).

-define(CALLER_FEATURES, #{
    call_canceling => true,
    call_timeout => true,
    caller_identification => true,
    progressive_call_results => false,
    progressive_calls => false
}).

-define(BROKER_FEATURES, #{
    pattern_based_subscription => true,
    publisher_exclusion => true,
    event_history => false,
    publication_trustlevels => false,
    publisher_identification => true,
    sharded_subscription => false,
    subscriber_blackwhite_listing => false,
    reflection => false,
    session_meta_api => false,
    subscription_meta_api => false
}).

-define(SUBSCRIBER_FEATURES, #{
    pattern_based_subscription => true,
    event_history => false,
    publication_trustlevels => false,
    publisher_identification => true,
    sharded_subscription => false
}).

-define(PUBLISHER_FEATURES, #{
    publisher_exclusion => true,
    publisher_identification => true,
    subscriber_blackwhite_listing => false
}).




%% =============================================================================
%% GENERAL
%% =============================================================================

-type callback_peer_id()  ::  {
    Realm       ::  binary(),
    Node        ::  node(),
    SessionId   ::  undefined,
    Mod         ::  module()
}.
-type local_peer_id()   ::  {
    Realm       ::  binary(),
    Node        ::  node(),
    SessionId   ::  maybe(pos_integer()),
    Pid         ::  pid()
}.
-type remote_peer_id()  ::  {
    Realm       ::  binary(),
    Node        ::  node(),
    SessionId   ::  maybe(pos_integer()),
    Pid         ::  maybe(pid() | binary())
}.
-type peer_id()         ::  callback_peer_id()
                            | local_peer_id()
                            | remote_peer_id().

-type maybe(T)          ::  T | undefined.



%% =============================================================================
%% UTILS
%% =============================================================================

-define(EOT, '$end_of_table').
-define(CHARS2BIN(Chars), unicode:characters_to_binary(Chars, utf8, utf8)).
-define(CHARS2LIST(Chars), unicode:characters_to_list(Chars, utf8)).



%% =============================================================================
%% PLUM_DB
%% =============================================================================

-define(TOMBSTONE, '$deleted').
