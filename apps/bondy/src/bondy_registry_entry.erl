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


-record(entry_key, {
    realm_uri               ::  uri(),
    node                    ::  node(),
    handler                 ::  wildcard(priv_handler()),
    type                    ::  wildcard(entry_type()),
    entry_id                ::  wildcard(id()),
    is_proxy = false        ::  wildcard(boolean())
}).

-record(entry, {
    key                     ::  key(),
    %% If session_id is defined we also have pid
    session_id              ::  maybe(bondy_session:uuid()),
    %% If defined, session_id might be undefined, callback_mod must be undefined
    pid                     ::  wildcard(maybe(pid())),
    %% If callback_mod is defined then session_id and pid are undefined
    callback_mod            ::  maybe(module()),
    uri                     ::  uri() | atom(),
    match_policy            ::  binary(),
    created                 ::  pos_integer() | atom(),
    options                 ::  map(),
    %% If present this is the binary representation of a bridge|edge node
    originating_node        ::  wildcard(maybe(binary())),
    originating_pid         ::  wildcard(maybe(binpid())),
    originating_handler     ::  wildcard(maybe(priv_handler())),
    originating_id          ::  wildcard(maybe(integer()))
}).


-opaque t()                 ::  #entry{}.
-type key()                 ::  #entry_key{}.
-type t_or_key()            ::  t_or_key().
-type entry_type()          ::  registration | subscription.
%% Handler is either a session (id()), an process or a module
-type handler()             ::  id() | pid() | module().
-type priv_handler()        ::  id() | binpid() | module().
-type binpid()              ::  binary().
-type wildcard(T)           ::  T | '_'.

-type details_map()         ::  #{
    id => id(),
    created => calendar:date(),
    uri => uri(),
    match => binary()
}.

-type external()    ::  #{
    entry_id         :=  id(),
    realm_uri        :=  uri(),
    node             :=  binary(),
    handler          :=  priv_handler(),
    type             :=  entry_type(),
    session_id       :=  maybe(id()),
    callback_mod     :=  maybe(module()),
    pid              :=  binpid(),
    uri              :=  uri(),
    match_policy     :=  binary(),
    created          :=  calendar:date(),
    options          :=  map()
}.

-export_type([t/0]).
-export_type([key/0]).
-export_type([t_or_key/0]).
-export_type([entry_type/0]).
-export_type([handler/0]).
-export_type([details_map/0]).


-export([callback_mod/1]).
-export([created/1]).
-export([get_option/3]).
-export([handler/1]).
-export([id/1]).
-export([is_callback/1]).
-export([is_entry/1]).
-export([is_key/1]).
-export([is_local/1]).
-export([is_proxy/1]).
-export([key/1]).
-export([key_field/1]).
-export([key_pattern/5]).
-export([match_policy/1]).
-export([new/4]).
-export([new/5]).
-export([node/1]).
-export([options/1]).
-export([pattern/4]).
-export([pattern/5]).
-export([peer_id/1]).
-export([pid/1]).
-export([proxy/3]).
-export([proxy_details/1]).
-export([realm_uri/1]).
-export([session_id/1]).
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
-spec new(entry_type(), peer_id(), uri(), map()) -> t().

new(Type, {_, _, _, _} = PeerId, Uri, Options) ->
    %% The WAMP spec defines that the id MUST be drawn randomly from a uniform
    %% distribution over the complete range [1, 2^53], but in a distributed
    %% setting we might have 2 or more nodes generating the same ID.
    %% However, we never use the RegId alone, it is always part of a key that
    %% acts as a context that should help minimise the chances of a collision.
    %% It would be much better is this IDs where 128-bit strings e.g. UUID or
    %% KSUID.

    RegId = bondy_utils:get_id(global),
    new(Type, RegId, PeerId, Uri, Options).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(entry_type(), id(), peer_id(), uri(), map()) -> t().

new(Type, RegId, {RealmUri, Node, SessionId, Term}, Uri, Options) when
(Type == registration orelse Type == subscription)
andalso (
    (is_integer(SessionId) andalso is_pid(Term))
    orelse (SessionId == undefined andalso is_pid(Term))
    orelse (SessionId == undefined andalso is_atom(Term))
) ->
    %% Term could be undefined for remote?
    %% For registrations we support Term being a pid, callback module or
    %% undefined
    {Handler, BinPid, CBMod} = handler_pid_mod(SessionId, Term),

    Key = #entry_key{
        realm_uri = RealmUri,
        node = Node,
        handler = Handler,
        type = Type,
        entry_id = RegId
    },

    #entry{
        key = Key,
        session_id = SessionId,
        pid = BinPid,
        callback_mod = CBMod,
        uri = Uri,
        match_policy = validate_match_policy(Options),
        created = erlang:system_time(seconds),
        options = parse_options(Type, Options)
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

pattern(Type, RealmUri, ProcedureOrTopic, Options, Extra) ->
    Node = maps:get(node, Extra, '_'),
    EntryId = maps:get(entry_id, Extra, '_'),
    Handler = maps:get(handler, Extra, '_'),
    Pid = maybe_pid_to_bin(maps:get(pid, Extra, '_')),

    KeyPattern = key_pattern(Type, RealmUri, Node, Handler, EntryId),

    MatchPolicy = validate_match_policy(pattern, Options),

    #entry{
        key = KeyPattern,
        session_id = '_',
        pid = Pid,
        callback_mod = '_',
        uri = ProcedureOrTopic,
        match_policy = MatchPolicy,
        created = '_',
        options = '_',
        originating_node = '_',
        originating_pid = '_',
        originating_handler = '_',
        originating_id = '_'
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
key_pattern(Type, RealmUri, Node, Handler0, EntryId) ->
    Type =:= subscription
        orelse Type =:= registration
        orelse Type == '_'
        orelse error({badarg, {type, Type}}),

    is_binary(RealmUri)
        orelse RealmUri == '_'
        orelse error({badarg, {realm_uri, RealmUri}}),

    is_atom(Node)
        orelse error({badarg, {node, Node}}),

    Handler0 =/= undefined
        andalso (
            %% SessionId | Pid | Mod | '_'
            is_integer(Handler0)
            orelse is_pid(Handler0)
            orelse is_atom(Handler0)
        )
        orelse error({badarg, {handler, Handler0}}),

    Handler = maybe_pid_to_bin(Handler0),

    is_integer(EntryId)
        orelse EntryId == '_'
        orelse error({badarg, {entry_id, EntryId}}),

    #entry_key{
        realm_uri = RealmUri,
        node = Node,
        handler = Handler,
        entry_id = EntryId,
        type = Type,
        is_proxy = '_'
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
key_field(realm_uri) ->
    #entry_key.realm_uri;

key_field(node) ->
    #entry_key.node;

key_field(handler) ->
    #entry_key.handler;

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
-spec handler(t()) -> wildcard(handler()).

handler(#entry{key = Key}) ->
    handler(Key);

handler(#entry_key{handler = Val}) ->
    maybe_term_to_pid(Val).


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
%% node and false when the handler is located in a cluster peer.
%% @end
%% -----------------------------------------------------------------------------
-spec is_local(t_or_key()) -> boolean().

is_local(#entry{key = Key}) ->
    is_local(Key);

is_local(#entry_key{node = Val}) ->
    bondy_peer_service:mynode() =:= Val.


%% -----------------------------------------------------------------------------
%% @doc Returns true if the entry handler is a callback registration.
%% Callback registrations are only used by Bondy itself to provide some of the
%% admin and meta APIs.
%% @end
%% -----------------------------------------------------------------------------
-spec is_callback(t()) -> boolean().

is_callback(#entry{callback_mod = Val}) ->
    Val =/= undefined;

is_callback(#entry_key{handler = Val}) ->
    Val =/= '_' andalso Val =/= undefined andalso is_atom(Val).


%% -----------------------------------------------------------------------------
%% @doc Returns the callback module when handler is a callback, otherwise
%% returns `undefined' or the wilcard value '_' when the entry was used as a
%% pattern (See {@link pattern/5}).
%% @end
%% -----------------------------------------------------------------------------
-spec callback_mod(t()) -> wildcard(maybe(module())).

callback_mod(#entry{callback_mod = Val}) ->
    Val;

callback_mod(#entry_key{handler = Val}) when is_atom(Val) ->
    %% Either a module or '_'
    Val;

callback_mod(#entry_key{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc Returns the value of the subscription's or registration's pid
%% property when handler is a pid() or a session identifier. Otherwise
%% returns `undefined' or the wilcard value '_' when the entry was used as a
%% pattern (See {@link pattern/5}).
%% @end
%% -----------------------------------------------------------------------------
-spec pid(t_or_key()) -> wildcard(maybe(pid())).

pid(#entry{pid = Val}) ->
    maybe_term_to_pid(Val);

pid(#entry_key{handler = Val}) ->
    maybe_term_to_pid(Val).


%% -----------------------------------------------------------------------------
%% @doc Returns the value of the subscription's or registration's session_id
%% property.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(t_or_key()) -> wildcard(maybe(id())).

session_id(#entry{session_id = Val}) ->
    Val;

session_id(#entry_key{handler = Val}) when is_integer(Val) orelse Val == '_' ->
    Val;

session_id(#entry_key{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc Returns the peer_id() of the subscription or registration
%% @end
%% -----------------------------------------------------------------------------
-spec peer_id(t()) -> peer_id().

peer_id(#entry{key = Key} = Entry) ->
    PidOrMod = case is_callback(Key) of
        true ->
            Key#entry_key.handler;
        false ->
            maybe_term_to_pid(Entry#entry.pid)
    end,

    {
        Key#entry_key.realm_uri,
        Key#entry_key.node,
        session_id(Key),
        PidOrMod
    }.


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
        entry_id => Key#entry_key.entry_id,
        realm_uri => Key#entry_key.realm_uri,
        node => atom_to_binary(Key#entry_key.node, utf8),
        handler => Key#entry_key.handler,
        type => Key#entry_key.type,
        pid => E#entry.pid,
        session_id => E#entry.session_id,
        callback_mod => E#entry.callback_mod,
        uri => E#entry.uri,
        match_policy => E#entry.match_policy,
        created => created_format(E#entry.created),
        options => E#entry.options
    }.


%% -----------------------------------------------------------------------------
%% @doc Returns a copy of the entry where the node component of the peer_id has
%% been replaced with the node of the calling process, the session identifier
%% replaced with `SessionId' and the pid with `Pid'.
%%
%% The entry is used by a router node to create a proxy of an entry originated
%% in an edge router.
%% @end
%% -----------------------------------------------------------------------------
-spec proxy(SessionId :: maybe(id()), Pid :: pid(), Entry :: external()) -> t().

proxy(SessionId, Pid, External) ->
    #{
        entry_id := OriginatingId,
        realm_uri := RealmUri,
        node := OriginatingNode,
        handler := OriginatingHandler,
        type := Type,
        pid := OriginatingPid,
        session_id := _OriginatingSessionId,
        callback_mod := _OriginatingCBMod,
        uri := Uri,
        match_policy := MatchPolicy,
        created := Created,
        options := Options
    } = External,

    Id = bondy_utils:get_id(global),
    {Handler, BinPid, CBMod} = handler_pid_mod(SessionId, Pid),

    #entry{
        key = #entry_key{
            realm_uri = RealmUri,
            node = bondy_peer_service:mynode(),
            handler = Handler,
            type = Type,
            entry_id = Id,
            is_proxy = true
        },
        pid = BinPid,
        session_id = SessionId,
        callback_mod = CBMod,
        uri = Uri,
        match_policy = MatchPolicy,
        created = Created,
        options = Options,
        originating_id = OriginatingId,
        originating_handler = OriginatingHandler,
        originating_pid = OriginatingPid,
        originating_node = OriginatingNode
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
        originating_id => E#entry.originating_id,
        originating_handler => E#entry.originating_handler,
        originating_pid => E#entry.originating_pid,
        originating_node => E#entry.originating_node
    }.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
-spec handler_pid_mod(SessionId :: maybe(id()), Term :: maybe(pid() | module())) ->
    {handler(), maybe(binpid()), maybe(module())} | no_return().

handler_pid_mod(SessionId, Pid) when is_integer(SessionId), is_pid(Pid) ->
    {SessionId, bondy_utils:pid_to_bin(Pid), undefined};

handler_pid_mod(undefined, Mod) when is_atom(Mod) ->
    {Mod, undefined, Mod};

handler_pid_mod(undefined, Pid) when is_pid(Pid) ->
    Bin = bondy_utils:pid_to_bin(Pid),
    {Bin, Bin, undefined};

handler_pid_mod(_, _) ->
    error(badarg).


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
parse_options(subscription, Opts) ->
    parse_subscription_options(Opts);

parse_options(registration, Opts) ->
    parse_registration_options(Opts).


%% @private
parse_subscription_options(Opts) ->
    maps:without([match], Opts).


%% @private
parse_registration_options(Opts) ->
    maps:without([match], Opts).


%% @private
created_format(Secs) ->
    calendar:system_time_to_universal_time(Secs, second).


%% @private
maybe_pid_to_bin(Pid) when is_pid(Pid) ->
    bondy_utils:pid_to_bin(Pid);

maybe_pid_to_bin(Term) ->
    Term.


%% @private
maybe_term_to_pid(Pid) when is_binary(Pid) ->
    bondy_utils:bin_to_pid(Pid);

maybe_term_to_pid(Term) ->
    Term.
