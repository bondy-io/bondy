%% =============================================================================
%%  bondy_registry_backend.erl -
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
%% @doc An entry is a record of a RPC registration or PubSub subscription. It
%% is stored in-memory in the Registry {@link bondy_registry} and replicated
%% globally and is immutable.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_registry_entry).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

%% The WAMP spec defines that the id MUST be drawn randomly from a uniform
%% distribution over the complete range [1, 2^53], but in a distributed
%% setting we might have 2 or more nodes generating the same ID.
%% However, we never use the RegId alone, it is always part of a key that
%% acts as a context that should help minimise the chances of a collision.
%% It would be much better is this IDs where 128-bit strings e.g. UUID or
%% KSUID.
-record(entry_key, {
    realm_uri           ::  uri(),
    node                ::  node(),
    target              ::  wildcard(bondy_ref:target()),
    session_id          ::  wildcard(maybe(id())),
    type                ::  wildcard(entry_type()),
    entry_id            ::  wildcard(id()),
    is_proxy = false    ::  wildcard(boolean())
}).

-record(entry, {
    key                 ::  key(),
    uri                 ::  uri() | atom(),
    match_policy        ::  binary(),
    ref                 ::  bondy_ref:t(),
    callback_args       ::  list(term()),
    created             ::  pos_integer() | atom(),
    options             ::  map(),
    origin_id           ::  wildcard(id()),
    origin_ref          ::  wildcard(maybe(bondy_ref:t()))
}).


-opaque t()             ::  #entry{}.
-type key()             ::  #entry_key{}.
-type t_or_key()        ::  t_or_key().
-type entry_type()      ::  registration | subscription.
-type wildcard(T)       ::  T | '_'.
-type mfargs()          ::  {M :: module(), F :: atom(), A :: maybe([term()])}.

-type details_map()     ::  #{
    id => id(),
    created => calendar:date(),
    uri => uri(),
    match => binary()
}.

-type external()         ::  #{
    type             :=  entry_type(),
    entry_id         :=  id(),
    uri              :=  uri(),
    match_policy     :=  binary(),
    ref              :=  bondy_ref:t(),
    callback_args    :=  list(term()),
    created          :=  calendar:date(),
    options          :=  map(),
    origin_id        :=  maybe(id()),
    origin_ref       :=  maybe(bondy_ref:t())
}.

-export_type([t/0]).
-export_type([key/0]).
-export_type([t_or_key/0]).
-export_type([entry_type/0]).
-export_type([details_map/0]).


-export([callback/1]).
-export([callback_args/1]).
-export([created/1]).
-export([get_option/3]).
-export([id/1]).
-export([is_callback/1]).
-export([is_entry/1]).
-export([is_key/1]).
-export([is_local/1]).
-export([is_proxy/1]).
-export([key/1]).
-export([key_field/1]).
-export([key_pattern/2]).
-export([key_pattern/4]).
-export([match_policy/1]).
-export([new/4]).
-export([new/5]).
-export([node/1]).
-export([options/1]).
-export([origin_id/1]).
-export([origin_ref/1]).
-export([pattern/4]).
-export([pattern/5]).
-export([pid/1]).
-export([proxy/3]).
-export([proxy_details/1]).
-export([realm_uri/1]).
-export([ref/1]).
-export([session_id/1]).
-export([target/1]).
-export([to_details_map/1]).
-export([to_external/1]).
-export([type/1]).
-export([uri/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(entry_type(), bondy_ref:t(), uri(), map()) -> t().

new(Type, Ref, Uri, Options) ->
    RealmUri = bondy_ref:realm_uri(Ref),
    RegId = bondy_utils:get_id({router, RealmUri}),
    new(Type, RegId, Ref, Uri, Options).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(entry_type(), id(), bondy_ref:t(), uri(), map()) -> t().

new(Type, RegId, Ref, Uri, Opts0)
when Type == registration orelse Type == subscription ->
    RealmUri = bondy_ref:realm_uri(Ref),
    Target = bondy_ref:target(Ref),
    Node = bondy_ref:node(Ref),
    SessionId = bondy_ref:session_id(Ref),

    Key = #entry_key{
        realm_uri = RealmUri,
        node = Node,
        target = Target,
        session_id = SessionId,
        type = Type,
        entry_id = RegId
    },

    MatchPolicy = validate_match_policy(Opts0),
    CBArgs = maps:get(callback_args, Opts0, []),
    Opts = maps:without([match, callback_args], Opts0),

    #entry{
        key = Key,
        uri = Uri,
        match_policy = MatchPolicy,
        ref = Ref,
        callback_args = CBArgs,
        created = erlang:system_time(seconds),
        options = Opts
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec pattern(
    Type :: entry_type(),
    RealmUri :: uri(),
    ProcedureOrTopic :: uri(),
    Options :: map()) -> t().

pattern(Type, RealmUri, ProcedureOrTopic, Options) ->
    pattern(Type, RealmUri, ProcedureOrTopic, Options, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec pattern(
    Type :: entry_type(),
    RealmUri :: uri(),
    ProcedureOrTopic :: uri(),
    Options :: map(),
    Extra :: map()) -> t().

pattern(Type, RealmUri, RegUri, Options, Extra) ->
    Node = maps:get(node, Extra, '_'),
    SessionId = maps:get(session_id, Extra, '_'),
    Target0 = maps:get(target, Extra, '_'),

    PatternRef = bondy_ref:pattern('_', RealmUri, Target0, SessionId, Node),
    Target = bondy_ref:target(PatternRef),

    KeyPattern = key_pattern(Type, RealmUri, Node, Extra#{target => Target}),

    MatchPolicy = validate_match_policy(pattern, Options),

    #entry{
        key = KeyPattern,
        uri = RegUri,
        match_policy = MatchPolicy,
        ref = '_',
        callback_args = '_',
        created = '_',
        options = '_',
        origin_id = '_',
        origin_ref = '_'
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec key_pattern(entry_type(), Ref :: bondy_ref:t()) -> key().

key_pattern(Type, Ref) ->
    bondy_ref:is_type(Ref)
        orelse error({badarg, {ref, Ref}}),

    RealmUri = bondy_ref:realm_uri(Ref),
    Node = bondy_ref:node(Ref),
    SessionId = bondy_ref:session_id(Ref),
    Target = bondy_ref:target(Ref),

    Extra = #{
        target => Target,
        session_id => SessionId
    },

    key_pattern(Type, RealmUri, Node, Extra).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
key_pattern(Type, RealmUri, Node, Extra) ->
    SessionId = maps:get(session_id, Extra, '_'),
    Target = maps:get(target, Extra, '_'),
    EntryId = maps:get(entry_id, Extra, '_'),
    IsProxy = maps:get(is_proxy, Extra, '_'),

    Type =:= subscription
        orelse Type =:= registration
        orelse Type == '_'
        orelse error({badarg, {type, Type}}),

    is_binary(RealmUri)
        orelse RealmUri == '_'
        orelse error({badarg, {realm_uri, RealmUri}}),

    is_atom(Node)
        orelse error({badarg, {node, Node}}),

    is_integer(EntryId)
        orelse EntryId == '_'
        orelse error({badarg, {entry_id, EntryId}}),

    #entry_key{
        realm_uri = RealmUri,
        node = Node,
        target = Target,
        session_id = SessionId,
        type = Type,
        entry_id = EntryId,
        is_proxy = IsProxy
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
key_field(realm_uri) ->
    #entry_key.realm_uri;

key_field(node) ->
    #entry_key.node;

key_field(target) ->
    #entry_key.target;

key_field(session_id) ->
    #entry_key.session_id;

key_field(entry_id) ->
    #entry_key.entry_id;

key_field(type) ->
    #entry_key.type;

key_field(is_proxy) ->
    #entry_key.is_proxy.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_entry(#entry{}) ->
    true;

is_entry(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_key(#entry_key{}) ->
    true;

is_key(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the subscription's or registration's id
%% property.
%% @end
%% -----------------------------------------------------------------------------
-spec id(t_or_key()) -> wildcard(id()).

id(#entry{key = Key}) ->
    Key#entry_key.entry_id;

id(#entry_key{entry_id = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the type of the entry, the atom 'registration' or 'subscription'.
%% @end
%% -----------------------------------------------------------------------------
-spec type(t_or_key()) -> entry_type().

type(#entry{key = Key}) ->
    Key#entry_key.type;

type(#entry_key{type = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the subscription's or registration's realm_uri property.
%% @end
%% -----------------------------------------------------------------------------
-spec key(t()) -> key().

key(#entry{key = Key}) ->
    Key.


%% -----------------------------------------------------------------------------
%% @doc Returns either a session identifier, a pid() or a callback module
%% depending on the type of entry. I can also return the wilcard '_' when the
%% entry is used as a pattern (See {@link pattern/5}).
%% @end
%% -----------------------------------------------------------------------------
-spec target(t()) -> wildcard(bondy_ref:target()).

target(#entry{ref = Ref}) ->
    bondy_ref:target(Ref);

target(#entry_key{target = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the value of the subscription's or registration's realm_uri
%% property.
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(t_or_key()) -> uri().

realm_uri(#entry{key = Key}) ->
    Key#entry_key.realm_uri;

realm_uri(#entry_key{realm_uri = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the subscription's or registration's node property.
%% This is always the Bondy cluster peer node where the handler exists.
%% @end
%% -----------------------------------------------------------------------------
-spec node(t_or_key()) -> atom().

node(#entry{key = Key}) ->
    Key#entry_key.node;

node(#entry_key{node = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns true if the entry represents a handler local to the caller's
%% node and false when the target is located in a cluster peer.
%% @end
%% -----------------------------------------------------------------------------
-spec is_local(t_or_key()) -> boolean().

is_local(#entry{key = Key}) ->
    is_local(Key);

is_local(#entry_key{node = Val}) ->
    bondy_peer_service:mynode() =:= Val.


%% -----------------------------------------------------------------------------
%% @doc Returns true if the entry target is a callback registration.
%% Callback registrations are only used by Bondy itself to provide some of the
%% admin and meta APIs.
%% @end
%% -----------------------------------------------------------------------------
-spec is_callback(t()) -> boolean().

is_callback(#entry_key{target = {callback, _}}) ->
    true;

is_callback(#entry_key{}) ->
    false;

is_callback(#entry{key = Key}) ->
    is_callback(Key).


%% -----------------------------------------------------------------------------
%% @doc Returns the callback arguments when target is a callback, otherwise
%% returns `undefined' or the wilcard value '_' when the entry was used as a
%% pattern (See {@link pattern/5}).
%% @end
%% -----------------------------------------------------------------------------
-spec callback_args(t()) -> list(term()).

callback_args(#entry{callback_args = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the callback module when target is a callback, otherwise
%% returns `undefined' or the wilcard value '_' when the entry was used as a
%% pattern (See {@link pattern/5}).
%% @end
%% -----------------------------------------------------------------------------
-spec callback(t()) -> wildcard(maybe(mfargs())).

callback(#entry{key = #entry_key{target = {callback, MF}}} = E) ->
    erlang:append_element(MF, E#entry.callback_args);

callback(#entry{key = #entry_key{target = '_'}}) ->
    '_';

callback(#entry{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc Returns the value of the subscription's or registration's pid
%% property when target is a pid() or a session identifier. Otherwise
%% returns `undefined' or the wilcard value '_' when the entry was used as a
%% pattern (See {@link pattern/5}).
%% @end
%% -----------------------------------------------------------------------------
-spec pid(t_or_key()) -> wildcard(maybe(pid())).

pid(#entry{ref = Ref}) ->
    bondy_ref:pid(Ref);

pid(#entry_key{target = {pid, Bin}}) ->
    bondy_utils:bin_to_pid(Bin);

pid(#entry_key{target = '_'}) ->
    '_';

pid(#entry_key{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc Returns the value of the subscription's or registration's session_id
%% property.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(t_or_key()) -> wildcard(maybe(id())).

session_id(#entry{ref = '_'}) ->
    '_';

session_id(#entry{ref = Ref}) ->
    bondy_ref:session_id(Ref);

session_id(#entry_key{session_id = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the ref() of the subscription or registration
%% @end
%% -----------------------------------------------------------------------------
-spec ref(t()) -> bondy_ref:t().

ref(#entry{ref = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the origin ref() of the subscription or registration
%% This value is only present when the entry is a proxy.
%% @end
%% -----------------------------------------------------------------------------
-spec origin_ref(t()) -> maybe(bondy_ref:t()).

origin_ref(#entry{origin_ref = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the origin ref() of the subscription or registration.
%% This value is only present when the entry is a proxy.
%% @end
%% -----------------------------------------------------------------------------
-spec origin_id(t()) -> maybe(id()).

origin_id(#entry{origin_id = Val}) ->
    Val.



%% -----------------------------------------------------------------------------
%% @doc
%% Returns the uri this entry is about i.e. either a subscription topic_uri or
%% a registration procedure_uri.
%% @end
%% -----------------------------------------------------------------------------
-spec uri(t()) -> uri().

uri(#entry{uri = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the match_policy used by this subscription or regitration.
%% @end
%% -----------------------------------------------------------------------------
-spec match_policy(t()) -> binary().

match_policy(#entry{match_policy = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the time when this entry was created. Its value is a timestamp in
%% seconds.
%% @end
%% -----------------------------------------------------------------------------
-spec created(t()) -> pos_integer().

created(#entry{created = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the 'options' property of the entry.
%% @end
%% -----------------------------------------------------------------------------
-spec options(t()) -> map().
options(#entry{options = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_option(t(), any(), any()) -> any().

get_option(#entry{options = Opts}, Key, Default) ->
    maps:get(Key, Opts, Default).


%% -----------------------------------------------------------------------------
%% @doc
%% Converts the entry into a map according to the WAMP protocol Details
%% dictionary format.
%% @end
%% -----------------------------------------------------------------------------
-spec to_details_map(t()) -> details_map().

to_details_map(#entry{key = Key} = E) ->
    Details = #{
        id =>  Key#entry_key.entry_id,
        created => created_format(E#entry.created),
        uri => E#entry.uri,
        match => E#entry.match_policy
    },
    case type(E) of
        registration ->
            Details#{
                invoke => maps:get(invoke, E#entry.options, ?INVOKE_SINGLE)
            };
        _ ->
            Details
    end.


%% -----------------------------------------------------------------------------
%% @doc Converts the entry into a map. Certain values of type atom such as
%% `node' are turned into binaries. This is to avoid exhausting a remote node
%% atoms table for use cases where the entries are replicated e.g. edge-remote
%% connections.
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(t()) -> external().

to_external(#entry{key = Key} = E) ->
    #{
        type => Key#entry_key.type,
        entry_id => Key#entry_key.entry_id,
        uri => E#entry.uri,
        match_policy => E#entry.match_policy,
        ref => E#entry.ref,
        callback_args => E#entry.callback_args,
        created => created_format(E#entry.created),
        options => E#entry.options,
        origin_ref => E#entry.origin_ref
    }.



%% -----------------------------------------------------------------------------
%% @doc Returns a copy of the entry where the node component of the ref has
%% been replaced with the node of the calling process, the session identifier
%% replaced with `SessionId' and the pid with `Pid'.
%%
%% The entry is used by a router node to create a proxy of an entry originated
%% in an edge router.
%% @end
%% -----------------------------------------------------------------------------
-spec proxy(
    SessionId :: maybe(id()),
    Target :: pid() | bondy_ref:mfargs() | bondy_ref:name(),
    Entry :: external()) -> t().

proxy(SessionId, Target0, External) ->
    #{
        type := Type,
        entry_id := OriginId,
        ref := OriginRef,
        uri := Uri,
        match_policy := MatchPolicy,
        created := Created,
        options := Options
    } = External,

    RealmUri = bondy_ref:realm_uri(OriginRef),
    Node = bondy_peer_service:mynode(),

    Ref = bondy_ref:new(relay, RealmUri, Target0, SessionId, Node),

    Target = bondy_ref:target(Ref),

    Id = bondy_utils:get_id({router, RealmUri}),

    #entry{
        key = #entry_key{
            realm_uri = RealmUri,
            node = Node,
            target = Target,
            type = Type,
            session_id = SessionId,
            entry_id = Id,
            is_proxy = true
        },
        ref = Ref,
        uri = Uri,
        match_policy = MatchPolicy,
        created = Created,
        options = Options,
        origin_ref = OriginRef,
        origin_id = OriginId
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_proxy(Entry :: t_or_key()) -> boolean().

is_proxy(#entry{key = Key}) ->
    is_proxy(Key);

is_proxy(#entry_key{is_proxy = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec proxy_details(t()) -> map().

proxy_details(#entry{} = E) ->
    #{
        origin_id => E#entry.origin_id,
        origin_ref => E#entry.origin_ref
    }.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
validate_match_policy(Options) ->
    validate_match_policy(key, Options).


%% @private
validate_match_policy(pattern, '_') ->
    '_';

validate_match_policy(_, Options) when is_map(Options) ->
    case maps:get(match, Options, ?EXACT_MATCH) of
        ?EXACT_MATCH = P ->
            P;
        ?PREFIX_MATCH = P ->
            P;
        ?WILDCARD_MATCH = P ->
            P;
        P ->
            error({invalid_match_policy, P})
    end.


%% @private
created_format(Secs) ->
    calendar:system_time_to_universal_time(Secs, second).
