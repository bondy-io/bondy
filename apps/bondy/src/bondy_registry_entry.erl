%% =============================================================================
%%  bondy_registry_entry.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
%%
%% @TODO Because entries is replicated (even if only in memmory), changes to
%% the data structure MUST be managed to be able to support rolling cluster
%% updates.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_registry_entry).

-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_registry.hrl").
-include("bondy_plum_db.hrl").


%% The WAMP spec defines that the id MUST be drawn randomly from a uniform
%% distribution over the complete range [1, 2^53], but in a distributed
%% setting we might have 2 or more nodes generating the same ID.
%% However, we never use the RegId alone, it is always part of a key that
%% acts as a context that should help minimise the chances of a collision.
%% It would be much better is this IDs where 128-bit strings e.g. UUID or
%% KSUID.
-record(entry_key, {
    realm_uri           ::  uri(),
    session_id          ::  wildcard(optional(bondy_session_id:t())),
    entry_id            ::  wildcard(id()),
    is_proxy = false    ::  wildcard(boolean())
}).

-record(entry, {
    key                 ::  key(),
    type                ::  wildcard(entry_type()),
    uri                 ::  uri() | atom(),
    match_policy        ::  binary(),
    ref                 ::  bondy_ref:t(),
    callback_args       ::  optional(list(term())),
    created             ::  pos_integer() | atom(),
    options             ::  options(),
    %% If a proxy, this is the registration|subscription id
    %% of the origin client
    origin_id           ::  wildcard(id()),
    %% If a proxy, this is the ref for the origin client
    origin_ref          ::  wildcard(optional(bondy_ref:t()))
}).


-opaque t()             ::  #entry{}.
-type key()             ::  #entry_key{}.
-type t_or_key()        ::  t() | key().
-type entry_type()      ::  registration | subscription.
-type wildcard(T)       ::  T | '_'.
-type mfargs()          ::  {
                                M :: module(),
                                F :: atom(),
                                A :: optional([term()])
                            }.
-type options()         ::  map().
-type match_result()        ::  [t()]
                                | {[t()], continuation_or_eot()}
                                | eot().
-type eot()                 ::  ?EOT.
-type continuation()        ::  plum_db:continuation().
-type continuation_or_eot() ::  eot() | continuation().

-type details_map()     ::  #{
    id => id(),
    created => calendar:date(),
    uri => uri(),
    match => binary()
}.

-type external()         ::  #{
    type             :=  entry_type(),
    realm_uri        :=  uri(),
    entry_id         :=  id(),
    uri              :=  uri(),
    match_policy     :=  binary(),
    ref              :=  bondy_ref:t(),
    callback_args    :=  list(term()),
    created          :=  pos_integer(),
    options          :=  options(),
    origin_id        :=  optional(id()),
    origin_ref       :=  optional(bondy_ref:t())
}.

-export_type([t/0]).
-export_type([key/0]).
-export_type([t_or_key/0]).
-export_type([entry_type/0]).
-export_type([details_map/0]).
-export_type([eot/0]).
-export_type([continuation/0]).

-export([callback/1]).
-export([callback_args/1]).
-export([created/1]).
-export([delete/1]).
-export([delete/2]).
-export([field_index/1]).
-export([find_option/2]).
-export([fold/4]).
-export([fold/5]).
-export([foreach/4]).
-export([get_option/3]).
-export([id/1]).
-export([is_callback/1]).
-export([is_entry/1]).
-export([is_key/1]).
-export([is_local/1]).
-export([is_local/2]).
-export([is_proxy/1]).
-export([key/1]).
-export([key_pattern/4]).
-export([lookup/2]).
-export([lookup/3]).
-export([lookup/4]).
-export([match/1]).
-export([match/2]).
-export([match/3]).
-export([match_policy/1]).
-export([new/5]).
-export([new/6]).
-export([nodestring/1]).
-export([node/1]).
-export([options/1]).
-export([origin_id/1]).
-export([origin_ref/1]).
-export([pattern/4]).
-export([pattern/5]).
-export([pid/1]).
-export([proxy/2]).
-export([proxy_details/1]).
-export([realm_uri/1]).
-export([ref/1]).
-export([session_id/1]).
-export([store/1]).
-export([take/1]).
-export([take/2]).
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
-spec new(entry_type(), uri(), bondy_ref:t(), uri(), map()) -> t().

new(Type, RealmUri, Ref, Uri, Opts) ->
    RegId = bondy_utils:gen_message_id({router, RealmUri}),
    new(Type, RegId, RealmUri, Ref, Uri, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(entry_type(), id(), uri(), bondy_ref:t(), uri(), map()) -> t().

new(Type, RegId, RealmUri, Ref, Uri, Opts0)
when is_binary(Uri) andalso is_map(Opts0) andalso ?IS_ENTRY_TYPE(Type) ->
    SessionId = bondy_ref:session_id(Ref),

    Key = #entry_key{
        realm_uri = RealmUri,
        session_id = SessionId,
        entry_id = RegId
    },

    MatchPolicy = validate_match_policy(Opts0),
    CBArgs = maps:get(callback_args, Opts0, undefined),
    Opts = maps:without([match, callback_args], Opts0),

    #entry{
        key = Key,
        type = Type,
        uri = Uri,
        match_policy = MatchPolicy,
        ref = Ref,
        callback_args = CBArgs,
        created = erlang:system_time(millisecond),
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
    SessionId = maps:get(session_id, Extra, '_'),

    KeyPattern = key_pattern(RealmUri, SessionId, '_', '_'),

    MatchPolicy = validate_match_policy(pattern, Options),

    #entry{
        key = KeyPattern,
        type = Type,
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
-spec key_pattern(
    RealmUri    ::  uri(),
    SessionId   ::  wildcard(bondy_session_id:t()),
    EntryId     ::  wildcard(id()),
    IsProxy     ::  boolean()) -> key().

key_pattern(RealmUri, SessionId, EntryId, IsProxy) when
is_binary(RealmUri) andalso
(is_binary(SessionId) orelse SessionId == '_') andalso
(is_integer(EntryId) orelse EntryId == '_') andalso
(is_boolean(IsProxy) orelse IsProxy == '_') ->

    #entry_key{
        realm_uri = RealmUri,
        session_id = SessionId,
        entry_id = EntryId,
        is_proxy = IsProxy
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
field_index(realm_uri) ->
    #entry_key.realm_uri;

field_index(session_id) ->
    #entry_key.session_id;

field_index(entry_id) ->
    #entry_key.entry_id;

field_index(is_proxy) ->
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
-spec type(t()) -> entry_type().

type(#entry{type = Val}) ->
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
%% depending on the type of entry. I can also return the wildcard '_' when the
%% entry is used as a pattern (See {@link pattern/5}).
%% @end
%% -----------------------------------------------------------------------------
-spec target(t()) -> wildcard(bondy_ref:target()).

target(#entry{ref = Ref}) ->
    bondy_ref:target(Ref).


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
%% Returns the value of the subscription's or registration's nodestring
%% property.
%% This is always the Bondy cluster peer node where the handler exists as a
%% binary
%% @end
%% -----------------------------------------------------------------------------
-spec nodestring(t()) -> wildcard(nodestring()).

nodestring(#entry{ref = '_'}) ->
    '_';

nodestring(#entry{ref = Ref}) ->
    bondy_ref:nodestring(Ref).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the subscription's or registration's node property.
%% This is always the Bondy cluster peer node where the handler exists.
%% @end
%% -----------------------------------------------------------------------------
-spec node(t()) -> wildcard(node()).

node(#entry{ref = '_'}) ->
    '_';

node(#entry{ref = Ref}) ->
    bondy_ref:node(Ref).



%% -----------------------------------------------------------------------------
%% @doc Returns true if the entry represents a handler local to the caller's
%% node and false when the target is located in a cluster peer.
%% @end
%% -----------------------------------------------------------------------------
-spec is_local(t()) -> boolean().

is_local(#entry{ref = Ref}) ->
    bondy_ref:is_local(Ref).


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if the entry represents a handler local to the node
%% represented by `Nodestring'. Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec is_local(t(), nodestring()) -> boolean().

is_local(#entry{ref = Ref}, Nodestring) ->
    bondy_ref:is_local(Ref, Nodestring).


%% -----------------------------------------------------------------------------
%% @doc Returns true if the entry target is a callback registration.
%% Callback registrations are only used by Bondy itself to provide some of the
%% admin and meta APIs.
%% @end
%% -----------------------------------------------------------------------------
-spec is_callback(t()) -> boolean().

is_callback(#entry{ref = Ref}) ->
    callback == bondy_ref:target_type(Ref).


%% -----------------------------------------------------------------------------
%% @doc Returns the callback arguments when target is a callback, otherwise
%% returns `undefined' or the wildcard value '_' when the entry was used as a
%% pattern (See {@link pattern/5}).
%% @end
%% -----------------------------------------------------------------------------
-spec callback_args(t()) -> optional(list(term())).

callback_args(#entry{callback_args = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the callback module when target is a callback, otherwise
%% returns `undefined'.
%% @end
%% -----------------------------------------------------------------------------
-spec callback(t()) -> optional(mfargs()).

callback(#entry{ref = Ref} = E) ->
    case bondy_ref:target(Ref) of
        {callback, MF} ->
            erlang:append_element(MF, E#entry.callback_args);
        _ ->
            undefined
    end.


%% -----------------------------------------------------------------------------
%% @doc Returns the value of the subscription's or registration's pid
%% property when target is a pid() or a session identifier. Otherwise
%% returns `undefined' or the wildcard value '_' when the entry was used as a
%% pattern (See {@link pattern/5}).
%% @end
%% -----------------------------------------------------------------------------
-spec pid(t_or_key()) -> pid().

pid(#entry{ref = Ref}) ->
    bondy_ref:pid(Ref).


%% -----------------------------------------------------------------------------
%% @doc Returns the value of the subscription's or registration's session `key'
%% property.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(t_or_key()) -> wildcard(optional(bondy_session_id:t())).

session_id(#entry{key = Key}) ->
    session_id(Key);

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
-spec origin_ref(t()) -> optional(bondy_ref:t()).

origin_ref(#entry{origin_ref = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the origin ref() of the subscription or registration.
%% This value is only present when the entry is a proxy.
%% @end
%% -----------------------------------------------------------------------------
-spec origin_id(t()) -> optional(id()).

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
%% milliseconds.
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
-spec get_option(any(), t(), any()) -> any().

get_option(Key, #entry{options = Opts}, Default) ->
    maps:get(Key, Opts, Default).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec find_option(any(), t()) -> {ok, any()} | error.

find_option(Key, #entry{options = Opts}) ->
    maps:find(Key, Opts).


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
        type => E#entry.type,
        realm_uri => Key#entry_key.realm_uri,
        entry_id => Key#entry_key.entry_id,
        uri => E#entry.uri,
        match_policy => E#entry.match_policy,
        ref => E#entry.ref,
        callback_args => E#entry.callback_args,
        created => E#entry.created,
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
-spec proxy(Ref :: bondy_ref:bridge_relay(), Entry :: external()) -> t().

proxy(Ref, External) ->
    #{
        type := Type,
        realm_uri := RealmUri,
        entry_id := OriginId,
        ref := OriginRef,
        uri := Uri,
        match_policy := MatchPolicy,
        created := Created,
        options := Options
    } = External,

    SessionId = bondy_ref:session_id(Ref),

    Id = bondy_utils:gen_message_id({router, RealmUri}),

    #entry{
        key = #entry_key{
            realm_uri = RealmUri,
            session_id = SessionId,
            entry_id = Id,
            is_proxy = true
        },
        type = Type,
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


%% -----------------------------------------------------------------------------
%% @doc Inserts the entry in plum_db. This will broadcast the delete amongst
%% the nodes in the cluster.
%% It will also called the `on_update/3' callback if enabled.
%% @end
%% -----------------------------------------------------------------------------
-spec store(Entry :: t()) -> ok.

store(#entry{} = Entry) ->
    PDBPrefix = pdb_prefix(Entry),
    Key = key(Entry),

    plum_db:put(PDBPrefix, Key, Entry).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(Type :: entry_type(), EntryKey :: key()) ->
    {ok, Entry :: t()} | {error, not_found}.

lookup(Type, #entry_key{} = EntryKey) when ?IS_ENTRY_TYPE(Type) ->
    PDBPrefix = pdb_prefix(Type, EntryKey),

    case plum_db:get(PDBPrefix, EntryKey) of
        #entry{} = Entry ->
            {ok, Entry};
        undefined ->
            {error, not_found}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(Type :: entry_type(), EntryKey :: key(), Opts :: map()) ->
    {ok, Entry :: t()} | {error, not_found}.

lookup(Type, #entry_key{} = EntryKey, Opts) when ?IS_ENTRY_TYPE(Type) ->
    PDBPrefix = pdb_prefix(Type, EntryKey),

    case plum_db:get(PDBPrefix, EntryKey, Opts) of
        #entry{} = Entry ->
            {ok, Entry};
        undefined ->
            {error, not_found}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(
    Type :: entry_type(), RealmUri :: uri(), EntryId :: id(), Opts :: map()) ->
    {ok, Entry :: t()} | {error, not_found}.

lookup(Type, RealmUri, EntryId, Opts0) when ?IS_ENTRY_TYPE(Type) ->

    PDBPrefix = pdb_prefix(Type, RealmUri),
    Pattern = key_pattern(RealmUri, '_', EntryId, '_'),
    Default = [{remove_tombstones, true}, {resolver, lww}],
    Opts = lists:keymerge(1, lists:sort(Opts0), Default),

    case plum_db:match(PDBPrefix, Pattern, Opts) of
        [] ->
            {error, not_found};

        [{_, Entry}] ->
            {ok, Entry}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec take(Entry :: t()) -> {ok, StoredEntry :: t()} | {error, not_found}.

take(#entry{} = Entry) ->
    take(type(Entry), key(Entry)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec take(Type :: entry_type(), EntryKey :: key()) ->
    {ok, StoredEntry :: t()} | {error, not_found}.

take(Type, #entry_key{} = EntryKey) when ?IS_ENTRY_TYPE(Type) ->
    PDBPrefix = pdb_prefix(Type, EntryKey),

    case plum_db:take(PDBPrefix, EntryKey) of
        #entry{} = Entry ->
            {ok, Entry};

        undefined ->
            {error, not_found}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(Entry :: t()) -> ok.

delete(#entry{} = Entry) ->
    delete(type(Entry), key(Entry)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(Type :: entry_type(), EntryKey :: key()) -> ok.

delete(Type, #entry_key{} = EntryKey) when ?IS_ENTRY_TYPE(Type) ->
    PDBPrefix = pdb_prefix(Type, EntryKey),
    plum_db:delete(PDBPrefix, EntryKey).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(continuation()) -> match_result().

match(Cont) ->
    match(Cont, [{resolver, lww}]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match
    (entry_type(), key()) -> [t()];
    (continuation(), plum_db:match_opts()) -> match_result().

match(Type, #entry_key{} = Pattern) when ?IS_ENTRY_TYPE(Type) ->
    Opts = [
        {resolver, lww},
        {remove_tombstones, true}
    ],
    match(Type, Pattern, Opts);

match(Cont, Opts) when is_list(Opts) ->
    plum_db:match(Cont, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(entry_type(), key(), plum_db:match_opts()) -> match_result().

match(Type, #entry_key{} = Pattern, Opts) when ?IS_ENTRY_TYPE(Type) ->
    PDBPrefix = pdb_prefix(Type, realm_uri(Pattern)),
    plum_db:match(PDBPrefix, Pattern, Opts).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec fold(
    Type :: entry_type(),
    RealmUri :: wildcard(uri()),
    Fun :: plum_db:fold_fun(),
    Acc :: any(),
    Opts :: plum_db:fold_opts()) -> any() | {any(), continuation_or_eot()}.

fold(Type, RealmUri, Fun, Acc, Opts) when ?IS_ENTRY_TYPE(Type) ->
    PDBPrefix = pdb_prefix(Type, RealmUri),
    plum_db:fold(Fun, Acc, PDBPrefix, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec fold(
    Fun :: plum_db:fold_fun(),
    Acc :: any(),
    Cont :: continuation(),
    Opts :: plum_db:fold_opts()) -> any() | {any(), continuation_or_eot()}.

fold(Fun, Acc, Cont, Opts) ->
    plum_db:fold(Fun, Acc, Cont, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec foreach(
    Type :: entry_type(),
    RealmUri :: uri(),
    Fun :: plum_db:foreach_fun(),
    Opts :: plum_db:fold_opts()) -> ok.

foreach(Type, RealmUri, Fun, Opts) when ?IS_ENTRY_TYPE(Type) ->
    PDBPrefix = pdb_prefix(Type, RealmUri),
    plum_db:foreach(Fun, PDBPrefix, Opts).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
pdb_prefix(#entry{} = Entry) ->
    pdb_prefix(type(Entry), realm_uri(Entry)).


%% @private
pdb_prefix(Type, #entry_key{} = Key) ->
    pdb_prefix(Type, Key#entry_key.realm_uri);

pdb_prefix(registration, RealmUri)
when is_binary(RealmUri) orelse RealmUri == '_' ->
    ?PLUM_DB_REGISTRATION_PREFIX(RealmUri);

pdb_prefix(subscription, RealmUri)
when is_binary(RealmUri) orelse RealmUri == '_' ->
    ?PLUM_DB_SUBSCRIPTION_PREFIX(RealmUri).


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
    calendar:system_time_to_universal_time(Secs, millisecond).
