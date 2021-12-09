%% =============================================================================
%%  bondy_peer_message -
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

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_peer_message).

-include_lib("wamp/include/wamp.hrl").

-record(peer_message, {
    id              ::  binary(),
    realm_uri       ::  uri(),
    %% Supporting process identifiers in Partisan, without changing the
    %% internal implementation of Erlang’s process identifiers, is not
    %% possible without allowing nodes to directly connect to every
    %% other node.
    %% We use the pid-to-bin trick since we will be using the pid to generate
    %% an ACK.
    from            ::  bondy_ref:t(),
    to              ::  bondy_ref:t(),
    payload         ::  wamp_invocation()
                        | wamp_error()
                        | wamp_result()
                        | wamp_interrupt()
                        | wamp_publish(),
    options         ::  map()
}).


-opaque t()     ::  #peer_message{}.

-export_type([t/0]).


-export([from/1]).
-export([id/1]).
-export([is_message/1]).
-export([new/4]).
-export([node/1]).
-export([options/1]).
-export([payload/1]).
-export([payload_type/1]).
-export([to/1]).
-export([realm_uri/1]).


%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% ----------------------------------------------------------------------------
new(From, To, Payload0, Opts) ->
    bondy_ref:is_type(From)
        andalso bondy_ref:is_local(From)
        orelse error({badarg, From}),

    bondy_ref:is_type(To)
        andalso not bondy_ref:is_local(To)
        orelse error({badarg, To}),

    RealmUri = bondy_ref:realm_uri(From),

    RealmUri =:= bondy_ref:realm_uri(To) orelse
        error(not_same_realm),


    #peer_message{
        id = ksuid:gen_id(millisecond),
        realm_uri = RealmUri,
        to = To,
        from = From,
        payload = validate_payload(Payload0),
        options = Opts
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_message(#peer_message{}) -> true;
is_message(_) -> false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
id(#peer_message{id = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
realm_uri(#peer_message{realm_uri = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
node(#peer_message{to = Ref}) ->
    bondy_ref:node(Ref).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
from(#peer_message{from = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
to(#peer_message{to = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
payload(#peer_message{payload = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
payload_type(#peer_message{payload = Val}) ->
    element(1, Val).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
options(#peer_message{options = Val}) ->
    Val.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
validate_payload(#call{} = M) ->
    M;

validate_payload(#error{request_type = Type} = M)
when Type == ?CALL orelse Type == ?INVOCATION orelse Type == ?INTERRUPT ->
    M;

validate_payload(#interrupt{} = M) ->
    M;

validate_payload(#invocation{} = M) ->
    M;

validate_payload(#yield{} = M) ->
    M;

validate_payload(#publish{} = M) ->
    M;

validate_payload(M) ->
    error({badarg, [M]}).
