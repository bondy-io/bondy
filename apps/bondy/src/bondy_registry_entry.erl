%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_entry).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_plum_db.hrl").

-moduledoc """
An entry is a record of a RPC registration or PubSub subscription. It
is stored in-memory in the Registry {@link bondy_registry} and replicated
globally (for now). Entries are immutable.
""".

-define(IS_TYPE(X), (X == registration orelse X == subscription)).
-define(PDB_MATCH_OPTS, [
    {resolver, lww},
    {remove_tombstones, true}
]).


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
    entry_id            ::  wildcard(id())
}).

-record(entry, {
    key                 ::  key(),
    type                ::  wildcard(entry_type()),
    uri                 ::  uri() | atom(),
    match_policy        ::  match_policy(),
    wildcard_degree     ::  optional([integer()]),
    invocation_policy   ::  optional(invocation_policy()),
    ref                 ::  bondy_ref:t(),
    callback_args       ::  optional(list(term())),
    created             ::  pos_integer(),
    options             ::  options(),
    is_proxy = false    ::  wildcard(boolean()),
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
-type ext()                 ::  default_ext()
                                | wamp_meta_ext()
                                | bridge_relay_ext().
-type default_ext()         ::  #{
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
-type wamp_meta_ext()     ::  #{
    id => id(),
    created => calendar:date(),
    uri => uri(),
    match => binary()
}.
-type bridge_relay_ext()         ::  #{
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

-type comparator()          ::  fun(({t(), t()}) -> boolean()).
-type match_policy()        ::  binary().
-type invocation_policy()   ::  binary().

-export_type([t/0]).
-export_type([key/0]).
-export_type([t_or_key/0]).
-export_type([entry_type/0]).
-export_type([ext/0]).
-export_type([comparator/0]).

-export([callback/1]).
-export([callback_args/1]).
-export([created/1]).
-export([field_index/1]).
-export([find_option/2]).
-export([get_option/3]).
-export([id/1]).
-export([invocation_policy/1]).
-export([invocation_policy_comparator/0]).
-export([invocation_policy_comparator/1]).
-export([is_alive/1]).
-export([is_callback/1]).
-export([is_entry/1]).
-export([is_key/1]).
-export([is_local/1]).
-export([is_local/2]).
-export([is_proxy/1]).
-export([key/1]).
-export([key_pattern/3]).
-export([locality_comparator/0]).
-export([locality_comparator/1]).
-export([match_policy/1]).
-export([mg_comparator/0]).
-export([mg_comparator/1]).
-export([new/5]).
-export([new/6]).
-export([node/1]).
-export([nodestring/1]).
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
-export([target/1]).
-export([time_comparator/0]).
-export([time_comparator/1]).
-export([to_external/1]).
-export([to_external/2]).
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
    RegId = bondy_message_id:router(RealmUri),
    new(Type, RegId, RealmUri, Ref, Uri, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(entry_type(), id(), uri(), bondy_ref:t(), uri(), map()) -> t().

new(Type, RegId, RealmUri, Ref, Uri, Opts0)
when is_binary(Uri) andalso is_map(Opts0) andalso ?IS_TYPE(Type) ->
    SessionId = bondy_ref:session_id(Ref),

    Key = #entry_key{
        realm_uri = RealmUri,
        session_id = SessionId,
        entry_id = RegId
    },

    MatchPolicy = validate_match_policy(Opts0),

    WildcardDegree =
        case MatchPolicy == ?WILDCARD_MATCH of
            true -> wildcard_degree(Uri);
            false -> undefined
        end,

    InvocationPolicy =
        case Type of
            registration ->
                maps:get(invoke, Opts0, ?INVOKE_SINGLE);
            _ ->
                undefined
        end,

    CBArgs = maps:get(callback_args, Opts0, undefined),

    %% We leave invocation_policy and other
    Opts = maps:without([match, callback_args], Opts0),

    #entry{
        key = Key,
        type = Type,
        uri = Uri,
        match_policy = MatchPolicy,
        invocation_policy = InvocationPolicy,
        wildcard_degree = WildcardDegree,
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

    KeyPattern = key_pattern(RealmUri, SessionId, '_'),

    MatchPolicy = validate_match_policy(pattern, Options),

    #entry{
        key = KeyPattern,
        type = Type,
        uri = RegUri,
        match_policy = MatchPolicy,
        invocation_policy = '_',
        wildcard_degree = '_',
        ref = '_',
        callback_args = '_',
        created = '_',
        options = '_',
        is_proxy = '_',
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
    EntryId     ::  wildcard(id())) -> key().

key_pattern(RealmUri, SessionId, EntryId) when
is_binary(RealmUri) andalso
(is_binary(SessionId) orelse SessionId == '_') andalso
(is_integer(EntryId) orelse EntryId == '_')  ->

    #entry_key{
        realm_uri = RealmUri,
        session_id = SessionId,
        entry_id = EntryId
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
    #entry_key.entry_id.


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
%% @doc Returns `false' if the entry is local and its target is a process which
%% is not alive (See `erlang:is_process_alive/1') or if the entry is remote (
%% regardless of its target type) and the remote node is disconnected (See
%% `partisan:is_connected/1). Otherwise returns `true'.
%%
%% Normally entries are removed from the registry once the owner session dies.
%% However that can happen between the session terminated and the time we read
%% the entry and the time of this function call. Or, in the case of a remote
%% entry,when the cluster peer is not connected and the registry has not yet
%% been pruned.
%% @end
%% -----------------------------------------------------------------------------
is_alive(#entry{ref = Ref}) ->
    bondy_ref:is_alive(Ref).



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
%% Returns the match_policy used by this subscription or regitration.
%% @end
%% -----------------------------------------------------------------------------
-spec invocation_policy(t()) -> optional(invocation_policy()).

invocation_policy(#entry{type = subscription}) ->
    undefined;

invocation_policy(#entry{invocation_policy = Val}) ->
    Val.


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

-spec to_external(t()) -> ext().

to_external(Entry) ->
    to_external(Entry, default).


%% -----------------------------------------------------------------------------
%% @doc Converts the entry into a map. Certain values of type atom such as
%% `node' are turned into binaries. This is to avoid exhausting a remote node
%% atoms table for use cases where the entries are replicated e.g. edge-remote
%% connections.
%% Formats:
%% - wamp_meta - a map according to the WAMP protocol Details dictionary format.
%% - default - a map compatible with JSON (Bondy types converted to string)
%% - bridge_relay - a map containing Bondy types
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(t(), Format :: default | bridge_relay | details_map) -> ext().

to_external(#entry{key = Key} = E, wamp_meta) ->
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
    end;

to_external(#entry{key = Key} = E, default) ->
    Ref = bondy_stdlib:and_then(E#entry.ref, fun bondy_ref:to_uri/1),
    ORef = bondy_stdlib:and_then(E#entry.origin_ref, fun bondy_ref:to_uri/1),

    #{
        type => E#entry.type,
        realm_uri => Key#entry_key.realm_uri,
        entry_id => Key#entry_key.entry_id,
        uri => E#entry.uri,
        match_policy => E#entry.match_policy,
        ref => Ref,
        callback_args => E#entry.callback_args,
        created => E#entry.created,
        options => E#entry.options,
        origin_ref => ORef
    };

to_external(#entry{key = Key} = E, bridge_relay) ->
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
-spec proxy(Ref :: bondy_ref:bridge_relay(), Entry :: ext()) -> t().

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

    Id = bondy_message_id:router(RealmUri),

    WildcardDegree =
        case MatchPolicy == ?WILDCARD_MATCH of
            true -> wildcard_degree(Uri);
            false -> undefined
        end,

    InvocationPolicy =
        case Type of
            registration ->
                maps:get(invoke, Options, ?INVOKE_SINGLE);
            _ ->
                undefined
        end,

    #entry{
        key = #entry_key{
            realm_uri = RealmUri,
            session_id = SessionId,
            entry_id = Id
        },
        type = Type,
        ref = Ref,
        uri = Uri,
        match_policy = MatchPolicy,
        invocation_policy = InvocationPolicy,
        wildcard_degree = WildcardDegree,
        created = Created,
        options = Options,
        is_proxy = true,
        origin_ref = OriginRef,
        origin_id = OriginId
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_proxy(Entry :: t()) -> wildcard(boolean()).

is_proxy(#entry{is_proxy = Val}) ->
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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec time_comparator() -> comparator().

time_comparator() ->
    fun(#entry{created = TA}, #entry{created = TB}) ->
        TA =< TB
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec time_comparator(comparator()) -> comparator().

time_comparator(Fun) ->
    fun
        (#entry{created = T} = A, #entry{created = T} = B) ->
            Fun(A, B);

        (#entry{created = TA}, #entry{created = TB}) ->
            TA < TB
    end.



%% -----------------------------------------------------------------------------
%% @doc Most general comparator.
%% An ordering function to sort entries in the WAMP call matching
%% algorithm order.
%%
%% %% [WAMP] 11.8.3] The following algorithm MUST be applied to find a single
%% RPC registration to which a call is routed:
%% <ol>
%% <li>Check for exact matching registration. If this match exists — use
%% it.</li>
%% <li>If there are prefix-based registrations, find the registration with the
%% longest prefix match. Longest means it has more URI components matched, e.g.
%% for call URI `a1.b2.c3.d4' registration `a1.b2.c3` has higher priority than
%% registration `a1.b2'. If this match exists — use it.</li>
%% <li>If there are wildcard-based registrations, find the registration with the
%% longest portion of URI components matched before each wildcard. E.g. for
%% call URI `a1.b2.c3.d4' registration `a1.b2..d4' has higher priority than
%% registration `a1...d4', see below for more complex examples. If this match
%% exists — use it.</li>
%% </ol>
%% @end
%% -----------------------------------------------------------------------------
-spec mg_comparator() -> comparator().

mg_comparator() ->
    mg_comparator(invocation_policy_comparator()).


%% -----------------------------------------------------------------------------
%% @doc Most general comparator.
%% An ordering function to sort entries in the WAMP call matching
%% algorithm order.
%%
%% Meant to work on registration type entries only.
%%
%% %% [WAMP] 11.8.3] The following algorithm MUST be applied to find a single
%% RPC registration to which a call is routed:
%% <ol>
%% <li>Check for exact matching registration. If this match exists — use
%% it.</li>
%% <li>If there are prefix-based registrations, find the registration with the
%% longest prefix match. Longest means it has more URI components matched, e.g.
%% for call URI `a1.b2.c3.d4' registration `a1.b2.c3` has higher priority than
%% registration `a1.b2'. If this match exists — use it.</li>
%% <li>If there are wildcard-based registrations, find the registration with the
%% longest portion of URI components matched before each wildcard. E.g. for
%% call URI `a1.b2.c3.d4' registration `a1.b2..d4' has higher priority than
%% registration `a1...d4', see below for more complex examples. If this match
%% exists — use it.</li>
%% </ol>
%% @end
%% -----------------------------------------------------------------------------
-spec mg_comparator(comparator()) -> comparator().

mg_comparator(Fun) ->
    fun
        (#entry{match_policy = P} = A, #entry{match_policy = P} = B)
        when P == ?EXACT_MATCH ->
            Fun(A, B);

        (#entry{match_policy = ?EXACT_MATCH}, #entry{}) ->
            true;

        (#entry{}, #entry{match_policy = ?EXACT_MATCH}) ->
            false;

        (#entry{match_policy = P} = A ,#entry{match_policy = P} = B)
        when P == ?PREFIX_MATCH ->
            case A#entry.uri == B#entry.uri of
                true ->
                    Fun(A, B);
                false when A#entry.uri > B#entry.uri ->
                    true;
                false ->
                    false
            end;

        (#entry{match_policy = P} = A ,#entry{match_policy = P} = B)
        when P == ?WILDCARD_MATCH ->
            case A#entry.uri == B#entry.uri of
                true ->
                    Fun(A, B);
                false ->
                    A#entry.wildcard_degree >= B#entry.wildcard_degree
            end;

        (#entry{match_policy = ?PREFIX_MATCH}, #entry{}) ->
            true;

        (#entry{}, #entry{match_policy = ?PREFIX_MATCH}) ->
            false

    end.


%% -----------------------------------------------------------------------------
%% @doc Sorts entries based in their invocation_policy in the following order:
%% `single < roundrobin < random < first < last < qll < qlls < jch'.
%% @end
%% -----------------------------------------------------------------------------
-spec invocation_policy_comparator() -> comparator().

invocation_policy_comparator() ->
    invocation_policy_comparator(time_comparator()).


%% -----------------------------------------------------------------------------
%% @doc Sorts entries based in their invocation_policy in the following order:
%% `single < first < jch < last < qll < qlls < random < roundrobin'.
%% Meant to work on registration type entries only.
%% @end
%% -----------------------------------------------------------------------------
-spec invocation_policy_comparator(comparator()) -> comparator().

invocation_policy_comparator(Fun) ->
     fun(
        #entry{invocation_policy = PA} = A,
        #entry{invocation_policy = PB} = B
        ) ->
        case {PA, PB} of
            {?INVOKE_SINGLE, ?INVOKE_SINGLE} ->
                Fun(A, B);
            {?INVOKE_SINGLE, _} ->
                true;
            {_, ?INVOKE_SINGLE} ->
                false;
            {P, P} ->
                Fun(A, B);
            {PA, PB} ->
                PA < PB
        end
    end.


%% -----------------------------------------------------------------------------
%% @doc Orders entries by locality, with local entries first. Then applies
%% `time_comparator/1'.
%% @end
%% -----------------------------------------------------------------------------
-spec locality_comparator() -> fun(({t(), t()}) -> boolean()).

locality_comparator() ->
    locality_comparator(time_comparator()).


%% -----------------------------------------------------------------------------
%% @doc Orders entries by locality, with local entries first. Then applies
%% comparator `Fun'.
%% @end
%% -----------------------------------------------------------------------------
-spec locality_comparator(comparator()) -> comparator().

locality_comparator(Fun) ->
    %% We read the value once
    N = bondy_config:nodestring(),

    fun(#entry{} = A, #entry{} = B) ->
        %% We first sort by locality, then by order of registration
        NA = nodestring(A),
        NB = nodestring(B),

        case {NA, NB} of
            {N, N} ->
                Fun(A, B);
            {N, _} ->
                true;
            {_, N} ->
                false;
            {_, _} ->
                Fun(A, B)
        end
    end.


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
    calendar:system_time_to_universal_time(Secs, millisecond).


%% -----------------------------------------------------------------------------
%% @private
%% @doc Computes an integer value that can be use to determine the most general
%% match between a set of URIs.
%% WAMP proposes the following algorithm to determine which procedure
%% registration to choose when multiple registrations of differing match policy
%% are found.
%%
%% [WAMP] 11.8.3]
%% If there are wildcard-based registrations, find the registration with the
%% longest portion of URI components matched before each wildcard. E.g. for
%% call URI `a1.b2.c3.d4' registration `a1.b2..d4' has higher priority than
%% registration `a1...d4'.
%%
%% This function creates a binary mask were each ground component is assigned 1
%% and each wildcard component is assigned 0. So for URI `a1.b2..d4' returns
%% `2#1101' and for URI `a1...d4' returns `2#1001'.
%% @end
%% -----------------------------------------------------------------------------
-spec wildcard_degree(uri()) -> integer().

wildcard_degree(Uri) ->
    L = binary:split(Uri, <<$.>>, [global]),
    wildcard_degree(L, length(L) - 1, 0).


%% @private
wildcard_degree([], _, Acc) ->
    Acc;

wildcard_degree([<<>>|T], Len, Acc) ->
    wildcard_degree(T, Len - 1, Acc);

wildcard_degree([_|T], Len, Acc) ->
    Val = 1 bsl Len,
    wildcard_degree(T, Len - 1, Acc + Val).



