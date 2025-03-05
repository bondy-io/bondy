%% =============================================================================
%%  bondy.hrl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
%% DEPENDENCIES INCLUDES
%% =============================================================================

-include_lib("kernel/include/logger.hrl").
-include_lib("plum_db/include/plum_db.hrl").


%% =============================================================================
%% GENERAL
%% =============================================================================


-define(BONDY_REQ, '$bondy_request').
-define(BONDY_ACK, '$bondy_ack').
-define(BONDY_META_KEY, '$bondy_metadata').

-define(CHARS2BIN(Chars), unicode:characters_to_binary(Chars, utf8, utf8)).
-define(CHARS2LIST(Chars), unicode:characters_to_list(Chars, utf8)).

-define(JOBS_POOLNAME, jobs_pool).

-define(SUPERVISOR(Id, Args, Restart, Timeout), #{
    id => Id,
    start => {Id, start_link, Args},
    restart => Restart,
    shutdown => Timeout,
    type => supervisor,
    modules => [Id]
}).

-define(WORKER(Id, Args, Restart, Timeout), #{
    id => Id,
    start => {Id, start_link, Args},
    restart => Restart,
    shutdown => Timeout,
    type => worker,
    modules => [Id]
}).

-define(EVENT_MANAGER(Id, Restart, Timeout), #{
    id => Id,
    start => {gen_event, start_link, [{local, Id}]},
    restart => Restart,
    shutdown => Timeout,
    type => worker,
    modules => [dynamic]
}).

-define(ERROR(Reason, Args, Cause), ?ERROR(Reason, Args, Cause, #{})).

-define(ERROR(Reason, Args, Cause, Meta),
    erlang:error(Reason, Args, ?ERROR_OPTS(Cause, Meta))
).

-define(ERROR_OPTS(Cause), ?ERROR_OPTS(Cause, #{})).

-define(ERROR_OPTS(Cause, Meta),
    [{error_info, #{module => ?MODULE, cause => Cause, meta => Meta}}]
).


-type optional(T)       ::  T | undefined.
-type nodestring()      ::  binary().


%% =============================================================================
%% WAMP
%% =============================================================================



-define(MASTER_REALM_URI, <<"com.leapsight.bondy">>).
-define(CONTROL_REALM_URI, <<"com.leapsight.bondy.internal">>).



%% In msecs
-define(SEND_TIMEOUT, 20000).

-define(WAMP_PPT_ATTRS, [ppt_cipher, ppt_keyid, ppt_scheme, ppt_serializer]).


%% =============================================================================
%% FEATURES
%% =============================================================================

-define(INVOKE_JUMP_CONSISTENT_HASH, <<"jump_consistent_hash">>).
-define(INVOKE_QUEUE_LEAST_LOADED, <<"queue_least_loaded">>).
-define(INVOKE_QUEUE_LEAST_LOADED_SAMPLE, <<"queue_least_loaded_sample">>).

-define(WAMP_CLIENT_ROLES, #{
    caller => ?CALLER_FEATURES,
    callee => ?CALLEE_FEATURES,
    subscriber => ?SUBSCRIBER_FEATURES,
    publisher => ?PUBLISHER_FEATURES
}).

-define(COMMON_RPC_FEATURES, #{
    progressive_call_results => false,
    progressive_calls => false,
    call_timeout => true,
    call_canceling => true,
    caller_identification => true,
    sharded_registration => false,
    payload_passthru_mode => true
}).

-define(DEALER_FEATURES, begin ?COMMON_RPC_FEATURES end#{
    call_reroute => false,
    call_trustlevels => false,
    pattern_based_registration => true,
    shared_registration => true,
    registration_revocation => false,
    testament_meta_api => false,
    session_meta_api => true,
    registration_meta_api => true,
    reflection => false,
    %% BONDY only
    caller_auth_claims => true
}).

-define(CALLEE_FEATURES, begin ?COMMON_RPC_FEATURES end#{
    call_reroute => false,
    call_trustlevels => false,
    pattern_based_registration => true,
    shared_registration => true,
    registration_revocation => false,
    %% BONDY only
    caller_auth_claims => true
}).

-define(CALLER_FEATURES, begin ?COMMON_RPC_FEATURES end#{
}).

-define(COMMON_PUBSUB_FEATURES, #{
    payload_passthru_mode => true,
    publisher_identification => true,
    sharded_subscription => false
}).

-define(BROKER_FEATURES, begin ?COMMON_PUBSUB_FEATURES end#{
    subscriber_blackwhite_listing => true,
    publisher_exclusion => true,
    publication_trustlevels => false,
    pattern_based_subscription => true,
    event_history => false,
    event_retention => true,
    subscription_revocation => false,
    session_meta_api => true,
    subscription_meta_api => false,
    reflection => false,
    %% Non-standard
    acknowledge_event_received => false,
    acknowledge_subscriber_received => false
}).

-define(SUBSCRIBER_FEATURES, begin ?COMMON_PUBSUB_FEATURES end#{
    publication_trustlevels => false,
    pattern_based_subscription => true,
    event_history => false,
    subscription_revocation => false,
    %% Non-standard
    acknowledge_subscriber_received => false
}).

-define(PUBLISHER_FEATURES, begin ?COMMON_PUBSUB_FEATURES end#{
    subscriber_blackwhite_listing => true,
    publisher_exclusion => true,
    %% Non-standard
    acknowledge_event_received => false
}).


%% =============================================================================
%% LISTENERS
%% =============================================================================


-define(SOCKET_OPTS_SPEC, #{
    keepalive => #{
        alias => <<"keepalive">>,
        required => true,
        default => true,
        datatype => boolean
    },
    nodelay => #{
        alias => <<"nodelay">>,
        required => true,
        default => true,
        datatype => boolean
    },
    sndbuf => #{
        alias => <<"sndbuf">>,
        required => false,
        datatype => pos_integer
    },
    recbuf => #{
        alias => <<"recbuf">>,
        required => false,
        datatype => pos_integer
    },
    buffer => #{
        alias => <<"buffer">>,
        required => false,
        datatype => pos_integer
    }
}).