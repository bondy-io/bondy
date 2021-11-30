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
    realm_uri               ::  wildcard(uri()),
    node                    ::  node(),
    owner                   ::  owner(),
    entry_id                ::  wildcard(id()),
    type                    ::  entry_type()
}).

-record(entry, {
    key                     ::  key(),
    pid                     ::  wildcard(maybe(pid())),
    uri                     ::  uri() | atom(),
    match_policy            ::  binary(),
    created                 ::  pos_integer() | atom(),
    options                 ::  map(),
    hash                    ::  maybe(integer())
}).


-opaque t()                 ::  #entry{}.
-type key()                 ::  #entry_key{}.
-type t_or_key()            ::  t_or_key().
-type entry_type()          ::  registration | subscription.

%% Owner is either a session (id()), an internal process or a module
-type owner()               ::  wildcard(id() | pid() | module()).
-type wildcard(T)           ::  T | '_'.
-type details_map()         ::  #{
    id => id(),
    created => calendar:date(),
    uri => uri(),
    match => binary()
}.

-export_type([t/0]).
-export_type([key/0]).
-export_type([t_or_key/0]).
-export_type([entry_type/0]).
-export_type([owner/0]).
-export_type([details_map/0]).


-export([callback_mod/1]).
-export([created/1]).
-export([get_option/3]).
-export([id/1]).
-export([is_callback/1]).
-export([is_entry/1]).
-export([is_local/1]).
-export([is_proxy/1]).
-export([is_proxy/2]).
-export([key/1]).
-export([key_pattern/5]).
-export([match_policy/1]).
-export([new/4]).
-export([new/5]).
-export([node/1]).
-export([options/1]).
-export([owner/1]).
-export([pattern/4]).
-export([pattern/5]).
-export([peer_id/1]).
-export([pid/1]).
-export([realm_uri/1]).
-export([session_id/1]).
-export([to_details_map/1]).
-export([to_map/1]).
-export([to_proxy/3]).
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
    RegId = bondy_utils:get_id(global),
    new(Type, RegId, PeerId, Uri, Options).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(entry_type(), id(), peer_id(), uri(), map()) -> t().

new(Type, RegId, {RealmUri, Node, SessionId, Term}, Uri, Options) when
(is_integer(SessionId) andalso is_pid(Term)) orelse
(SessionId == undefined andalso is_pid(Term)) orelse
(SessionId == undefined andalso is_atom(Term)) ->
    %% Term could be undefined for remote?
    %% For registrations we support Term being a pid, callback module or
    %% undefined
    {Owner, Pid} = owner_pid(SessionId, Term),

    Key = #entry_key{
        realm_uri = RealmUri,
        node = Node,
        owner = Owner,
        entry_id = RegId,
        type = Type
    },

    #entry{
        key = Key,
        pid = Pid, % maybe undefined
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
    Owner = maps:get(owner, Extra, '_'),
    Pid = maps:get(pid, Extra, '_'),

    KeyPattern = key_pattern(Type, RealmUri, Node, Owner, EntryId),

    MatchPolicy = validate_match_policy(pattern, Options),

    #entry{
        key = KeyPattern,
        pid = Pid,
        uri = ProcedureOrTopic,
        match_policy = MatchPolicy,
        created = '_',
        options = '_'
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
key_pattern(Type, RealmUri, Node, Owner, EntryId) ->
    Type =:= subscription
        orelse Type =:= registration
        orelse error({badarg, {type, Type}}),

    is_binary(RealmUri)
        orelse RealmUri == '_'
        orelse error({badarg, {realm_uri, RealmUri}}),

    is_atom(Node)
        orelse error({badarg, {node, Node}}),

    Owner =/= undefined
        andalso (
            %% SessionId | Pid | Mod | '_'
            is_integer(Owner) orelse is_pid(Owner) orelse is_atom(Owner)
        )
        orelse error({badarg, {owner, Owner}}),

    is_integer(EntryId)
        orelse EntryId == '_'
        orelse error({badarg, {entry_id, EntryId}}),


    #entry_key{
        realm_uri = RealmUri,
        node = Node,
        owner = Owner,
        entry_id = EntryId,
        type = Type
    }.


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
%% depending on the type of entry.
%% @end
%% -----------------------------------------------------------------------------
-spec owner(t()) -> wildcard(owner()).

owner(#entry{key = Key}) ->
    Key#entry_key.owner;

owner(#entry_key{owner = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the subscription's or registration's realm_uri property.
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(t_or_key()) -> uri().

realm_uri(#entry{key = Key}) ->
    Key#entry_key.realm_uri;

realm_uri(#entry_key{realm_uri = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the subscription's or registration's session_id
%% property.
%% @end
%% -----------------------------------------------------------------------------
-spec node(t_or_key()) -> atom().

node(#entry{key = Key}) ->
    Key#entry_key.node;

node(#entry_key{node = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns true if the entry represents a local peer
%% @end
%% -----------------------------------------------------------------------------
-spec is_local(t_or_key()) -> boolean().

is_local(#entry{key = Key}) ->
    is_local(Key);

is_local(#entry_key{node = Val}) ->
    bondy_peer_service:mynode() =:= Val.


%% -----------------------------------------------------------------------------
%% @doc Returns true if the entry represents a local callback registration
%% @end
%% -----------------------------------------------------------------------------
-spec is_callback(t()) -> boolean().

is_callback(#entry{key = Key}) ->
    is_callback(Key);

is_callback(#entry_key{owner = Val}) ->
    Val =/= '_' andalso Val =/= undefined andalso is_atom(Val).


%% -----------------------------------------------------------------------------
%% @doc Returns true if the entry represents a local callback registration
%% @end
%% -----------------------------------------------------------------------------
-spec callback_mod(t()) -> wildcard(maybe(module())).

callback_mod(#entry{key = Key}) ->
    callback_mod(Key);

callback_mod(#entry_key{owner = Val}) when is_atom(Val) ->
    %% Either a module or '_'
    Val;

callback_mod(#entry_key{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the subscription's or registration's session_id
%% property.
%% @end
%% -----------------------------------------------------------------------------
-spec pid(t_or_key()) -> wildcard(maybe(pid())).

pid(#entry{pid = Val}) ->
    Val;

pid(#entry_key{owner = Val}) when is_pid(Val) orelse Val == '_' ->
    Val;

pid(#entry_key{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the subscription's or registration's session_id
%% property.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(t_or_key()) -> wildcard(maybe(id())).

session_id(#entry{key = Key}) ->
    session_id(Key);

session_id(#entry_key{owner = Val}) when is_integer(Val) orelse Val == '_' ->
    Val;

session_id(#entry_key{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the peer_id() of the subscription or registration
%% @end
%% -----------------------------------------------------------------------------
-spec peer_id(t_or_key()) -> peer_id().

peer_id(#entry{key = Key} = Entry) ->
    PidOrMod = case is_callback(Key) of
        true ->
            Key#entry_key.owner;
        false ->
            Entry#entry.pid
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
%% @doc
%% Converts the entry into a map
%% @end
%% -----------------------------------------------------------------------------
-spec to_map(t()) -> details_map().

to_map(#entry{key = Key} = E) ->
    #{
        id =>  Key#entry_key.entry_id,
        node => Key#entry_key.node,
        session_id => session_id(Key),
        pid => pid_to_binary(E#entry.pid),
        mod => mod_to_binary(callback_mod(Key)),
        uri => E#entry.uri,
        match => E#entry.match_policy,
        options => E#entry.options,
        created => created_format(E#entry.created)
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
-spec to_proxy(Entry :: t(), SessionId :: maybe(id()), Pid :: pid()) -> t().

to_proxy(#entry{} = Entry, SessionId, Pid) ->
    {Owner, Pid} = owner_pid(SessionId, Pid),
    Key = Entry#entry.key,

    Entry#entry{
        key = Key#entry_key{
            node = bondy_peer_service:mynode(),
            owner = Owner
        },
        pid = Pid,
        hash = erlang:phash2(Entry)
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_proxy(Entry :: t()) -> boolean().

is_proxy(#entry{hash = Val}) ->
    Val =/= undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_proxy(Proxy :: t(), Entry :: t()) -> boolean().

is_proxy(#entry{hash = Val}, #entry_key{} = Entry) ->
    Val == erlang:phash2(Entry).




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
-spec owner_pid(SessionId :: maybe(id()), Term :: maybe(pid() | module())) ->
    {owner(), maybe(pid())} | no_return().

owner_pid(SessionId, Pid) when is_integer(SessionId), is_pid(Pid) ->
    {SessionId, Pid};

owner_pid(undefined, Mod) when is_atom(Mod) ->
    {Mod, undefined};

owner_pid(undefined, Pid) when is_pid(Pid) ->
    {Pid, Pid};

owner_pid(_, _) ->
    error(badarg).


%% @private
pid_to_binary(undefined) ->
    <<"undefined">>;

pid_to_binary(Pid) ->
    list_to_binary(pid_to_list(Pid)).


%% @private
mod_to_binary(Mod)->
    atom_to_binary(Mod, utf8).


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