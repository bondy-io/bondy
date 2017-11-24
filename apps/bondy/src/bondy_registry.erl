%% =============================================================================
%%  bondy_registry.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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
%% An in-memory registry for PubSub subscriptions and RPC registrations,
%% providing pattern matching capabilities including support for WAMP's
%% version 2.0 match policies (exact, prefix and wilcard).
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_registry).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").



-define(ANY, <<"*">>).

%% -define(DEFAULT_LIMIT, 1000).
-define(SUBSCRIPTION_TABLE_NAME, bondy_subscription).
-define(SUBSCRIPTION_INDEX_TABLE_NAME, bondy_subscription_index).
-define(REGISTRATION_TABLE_NAME, bondy_registration).
-define(REGISTRATION_INDEX_TABLE_NAME, bondy_registration_index).
-define(MAX_LIMIT, 10000).
-define(LIMIT(Opts), min(maps:get(limit, Opts, ?MAX_LIMIT), ?MAX_LIMIT)).


%% An entry denotes a registration or a subscription
%% TODO entries should be replicated across the cluster via plumtree
%% maybe using the metadata store directly
-record(entry, {
    key                     ::  entry_key(),
    type                    ::  entry_type(),
    uri                     ::  uri() | atom(),
    match_policy            ::  binary(),
    criteria                ::  [{'=:=', Field :: binary(), Value :: any()}]
                                | atom(),
    created                 ::  calendar:date_time() | atom(),
    options                 ::  map() | atom()
}).

%% TODO indices should be recomputed based on entry creation/deletion but are
%% always local (i.e. they should not be replicated)
-record(index, {
    key                     ::  tuple() | atom(),  % dynamically generated
    entry_key               ::  entry_key()
}).

-type entry_key()           ::  {
                                    RealmUri    ::  uri(),
                                    SessionId   ::  id() | atom(),   % the owner
                                    EntryId     ::  id() | atom()
                                }.
-type entry()               ::  #entry{}.
-type entry_type()          ::  registration | subscription.
-type eot()                 ::  ?EOT.
-type continuation()        ::  {entry_type(), etc:continuation()}.


-type details_map() :: #{
    id => id(),
    created => calendar:date(),
    uri => uri(),
    match => binary()
}.

-type task() :: fun( (details_map(), bondy_context:context()) -> ok).



-export_type([entry/0]).
-export_type([entry_key/0]).
-export_type([entry_type/0]).
-export_type([eot/0]).
-export_type([continuation/0]).
-export_type([details_map/0]).


-export([add/4]).
-export([created/1]).
-export([criteria/1]).
-export([entries/1]).
-export([entries/2]).
-export([entries/3]).
-export([entries/4]).
-export([entry_id/1]).
-export([lookup/3]).
-export([lookup/4]).
-export([match/1]).
-export([match/3]).
-export([match/4]).
-export([match_policy/1]).
-export([options/1]).
-export([realm_uri/1]).
-export([remove/3]).
-export([remove/4]).
-export([remove_all/2]).
-export([remove_all/3]).
-export([session_id/1]).
-export([to_details_map/1]).
-export([type/1]).
-export([uri/1]).


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the subscription's or registration's realm_uri property.
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(entry()) -> uri().
realm_uri(#entry{key = {Val, _, _}}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the subscription's or registration's session_id
%% property.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(entry()) -> id().
session_id(#entry{key = {_, Val, _}}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the subscription's or registration's entry_id
%% property.
%% @end
%% -----------------------------------------------------------------------------
-spec entry_id(entry()) -> id().
entry_id(#entry{key = {_, _, Val}}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the type of the entry, the atom 'registration' or 'subscription'.
%% @end
%% -----------------------------------------------------------------------------
-spec type(entry()) -> entry_type().
type(#entry{type = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the uri this entry is about i.e. either a subscription topic_uri or
%% a registration procedure_uri.
%% @end
%% -----------------------------------------------------------------------------
-spec uri(entry()) -> uri().
uri(#entry{uri = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the match_policy used by this subscription or regitration.
%% @end
%% -----------------------------------------------------------------------------
-spec match_policy(entry()) -> binary().
match_policy(#entry{match_policy = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Not used at the moment
%% @end
%% -----------------------------------------------------------------------------
-spec criteria(entry()) -> list().
criteria(#entry{criteria = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the time when this entry was created.
%% @end
%% -----------------------------------------------------------------------------
-spec created(entry()) -> calendar:date_time().
created(#entry{created = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the value of the 'options' property of the entry.
%% @end
%% -----------------------------------------------------------------------------
-spec options(entry()) -> map().
options(#entry{options = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Converts the entry into a map according to the WAMP protocol Details
%% dictionary format.
%% @end
%% -----------------------------------------------------------------------------
-spec to_details_map(entry()) -> details_map().

to_details_map(#entry{key = {_, _, Id}} = E) ->
    #{
        id => Id,
        created => E#entry.created,
        uri => E#entry.uri,
        match => E#entry.match_policy,
        invoke => maps:get(invoke, E#entry.options, ?INVOKE_SINGLE)
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% Adds an entry to the registry.
%%
%% Adding an already existing entry is treated differently based on whether the
%% entry is a registration or a subscription.
%%
%% According to the WAMP specifictation, in the case of a subscription that was
%% already added before by the same _Subscriber_, the _Broker_ should not fail
%% and answer with a "SUBSCRIBED" message, containing the existing
%% "Subscription|id". So in this case this function returns
%% {ok, details_map(), boolean()}.
%%
%% In case of a registration, as a default, only a single Callee may
%% register a procedure for an URI. However, when shared registrations are
%% supported, then the first Callee to register a procedure for a particular URI
%% MAY determine that additional registrations for this URI are allowed, and
%% what Invocation Rules to apply in case such additional registrations are
%% made.
%%
%% This is configured through the 'invoke' options.
%% When invoke is not 'single', Dealer MUST fail all subsequent attempts to
%% register a procedure for the URI where the value for the invoke option does
%% not match that of the initial registration. Accordingly this function might
%% return an error tuple.
%% @end
%% -----------------------------------------------------------------------------
-spec add(entry_type(), uri(), map(), bondy_context:context()) ->
    {ok, details_map(), IsFirstEntry :: boolean()}
    | {error, {already_exists, id()}}.

add(Type, Uri, Options, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    MatchPolicy = validate_match_policy(Options),

    MaybeAdd = fun
        ({error, _} = Error) ->
            Error;
        (RegId) when is_integer(RegId) ->
            Entry = #entry{
                key = {RealmUri, SessionId, RegId},
                type = Type,
                uri = Uri,
                match_policy = MatchPolicy,
                criteria = [], % TODO Criteria
                created = calendar:local_time(),
                options = parse_options(Type, Options)
            },
            do_add(Type, Entry, Ctxt)
    end,

    Pattern = #entry{
        key = key_pattern(Type, RealmUri, SessionId),
        type = Type,
        uri = Uri,
        match_policy = MatchPolicy,
        criteria = '_', % TODO Criteria
        created = '_',
        options = '_'
    },
    Tab = entry_table(Type, RealmUri),

    case ets:match_object(Tab, Pattern) of
        [] ->
            %% No matching registrations at all exists or
            %% No matching subscriptions for this SessionId exists
            MaybeAdd(bondy_utils:get_id(global));

        [#entry{} = Entry] when Type == subscription ->
            %% In case of receiving a "SUBSCRIBE" message from the same
            %% _Subscriber_ and to already added topic, _Broker_ should
            %% answer with "SUBSCRIBED" message, containing the existing
            %% "Subscription|id".
            {error, {already_exists, Entry}};

        [#entry{options = EOpts} = Entry| _] when Type == registration ->
            SharedEnabled = bondy_context:is_feature_enabled(
                Ctxt, callee, shared_registration),
            NewPolicy = maps:get(invoke, Options, ?INVOKE_SINGLE),
            PrevPolicy = maps:get(invoke, EOpts, ?INVOKE_SINGLE),
            %% As a default, only a single Callee may register a procedure
            %% for an URI.
            %% Shared Registration (RFC 13.3.9)
            %% When shared registrations are supported, then the first
            %% Callee to register a procedure for a particular URI
            %% MAY determine that additional registrations for this URI
            %% are allowed, and what Invocation Rules to apply in case
            %% such additional registrations are made.
            %% When invoke is not 'single', Dealer MUST fail
            %% all subsequent attempts to register a procedure for the URI
            %% where the value for the invoke option does not match that of
            %% the initial registration.
            Flag = SharedEnabled andalso
                NewPolicy =/= ?INVOKE_SINGLE andalso
                NewPolicy =:= PrevPolicy,
            case Flag of
                true ->
                    MaybeAdd(entry_id(Entry));
                false ->
                    MaybeAdd({error, {already_exists, to_details_map(Entry)}})
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Removes all entries matching the context's realm and session_id (if any).
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(entry_type(), bondy_context:context()) -> ok.

remove_all(Type, Ctxt) ->
    remove_all(Type, Ctxt, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% Removes all entries matching the context's realm and session_id (if any).
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(entry_type(), bondy_context:context(), task() | undefined) ->
    ok.

remove_all(Type, #{realm_uri := RealmUri} = Ctxt, Task) ->
    Pattern = #entry{
        key = {RealmUri, bondy_context:session_id(Ctxt), '_'},
        type = Type,
        uri = '_',
        match_policy = '_',
        criteria = '_',
        options = '_',
        created = '_'
    },
    Tab = entry_table(Type, RealmUri),
    case ets:match_object(Tab, Pattern, 1) of
        ?EOT ->
            %% There are no entries for this session
            ok;
        {[First], _} ->
            %% Use iterator to remove each one
            do_remove_all(First, Tab, Ctxt, Task)
    end;

remove_all(_, _, _) ->
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% Lookup an entry by Type, Id (Registration or Subscription Id) and Ctxt
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(entry_type(), id(), bondy_context:context()) ->
    entry() | {error, not_found}.

lookup(Type, EntryId, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    lookup(Type, EntryId, SessionId, RealmUri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(entry_type(), id(), id(), uri()) -> entry() | {error, not_found}.

lookup(Type, EntryId, SessionId, RealmUri) ->
    % TODO Use UserId when there is no SessionId
    Tab = entry_table(Type, RealmUri),
    case ets:take(Tab, {RealmUri, SessionId, EntryId}) of
        [] ->
            %% The session had no entries with EntryId.
            {error, not_found};
        [Entry] ->
            Entry
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(entry_type(), id(), bondy_context:context()) ->
    ok | {error, not_found}.

remove(Type, EntryId, Ctxt) ->
    remove(Type, EntryId, Ctxt, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(entry_type(), id(), bondy_context:context(), task() | undefined) ->
    ok | {error, not_found}.

remove(Type, EntryId, Ctxt, Task) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    % TODO Use UserId when there is no SessionId
    Tab = entry_table(Type, RealmUri),
    Key = {RealmUri, SessionId, EntryId},
    case ets:take(Tab, Key) of
        [] ->
            %% The session had no entries with EntryId.
            {error, not_found};
        [#entry{uri = Uri, match_policy = MP} = Entry] ->
            decr_counter(Tab, {RealmUri, Uri}, 1),
            %% Delete indices for entry
            IdxTab = index_table(Type, RealmUri),
            IdxEntry = index_entry(EntryId, Uri, MP, Ctxt),
            ets:delete_object(IdxTab, IdxEntry),
            maybe_execute(Task, Entry, Ctxt)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the list of entries owned by the the active session.
%%
%% This function is equivalent to calling {@link entries/2} with the RealmUri
%% and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(entry_type(), bondy_context:context()) -> [entry()].

entries(Type, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    entries(Type, RealmUri, SessionId).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of entries owned by a session matching
%% RealmUri and SessionId.
%%
%% Use {@link entries/3} and {@link entries/1} to limit the number
%% of entries returned.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(entry_type(), RealmUri :: uri(), SessionId :: id()) -> [entry()].

entries(Type, RealmUri, SessionId) ->
    Pattern = #entry{
        key = {RealmUri, SessionId, '_'},
        type = Type,
        uri = '_',
        match_policy = '_',
        criteria = '_',
        created = '_',
        options = '_'
    },
    ets:match_object(entry_table(Type, RealmUri), Pattern).




%% -----------------------------------------------------------------------------
%% @doc
%% Works like {@link entries/3}, but only returns a limited (Limit) number of
%% entries. Term Continuation can then be used in subsequent calls to entries/1
%% to get the next chunk of entries.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(
    entry_type(), Realm :: uri(), SessionId :: id(), Limit :: pos_integer()) ->
    {[entry()], continuation() | eot()}.

entries(Type, RealmUri, SessionId, Limit) ->
    Pattern = #entry{
        key = {RealmUri, SessionId, '_'},
        type = Type,
        uri = '_',
        match_policy = '_',
        criteria = '_',
        created = '_',
        options = '_'
    },
    ets:match_object(entry_table(Type, RealmUri), Pattern, Limit).



%% -----------------------------------------------------------------------------
%% @doc
%% Continues returning the list of entries owned by a session started with
%% {@link entries/4}.
%%
%% The next chunk of the size specified in the initial entries/4 call is
%% returned together with a new Continuation, which can be used in subsequent
%% calls to this function.
%%
%% When there are no more objects in the table, {[], '$end_of_table'} is
%% returned.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(continuation()) -> {[entry()], continuation() | eot()}.

entries(?EOT) ->
    {[], ?EOT};

entries({Type, Cont}) when Type == registration orelse Type == subscription ->
    case ets:match_object(Cont) of
        ?EOT ->
            {[], ?EOT};
        {L, NewCont} ->
            {L, {Type, NewCont}}
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% Calls {@link match/4}.
%% @end
%% -----------------------------------------------------------------------------
-spec match(entry_type(), uri(), bondy_context:context()) ->
    {[entry()], continuation()} | eot().

match(Type, Uri, Ctxt) ->
    match(Type, Uri, Ctxt, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the entries matching either a topic or procedure Uri according to
%% each entry's configured match specification.
%%
%% This function is used by the Broker to return all subscriptions that match a
%% topic. And in case of registrations it is used by the Dealer to return all
%% registrations matching a procedure.
%% @end
%% -----------------------------------------------------------------------------
-spec match(entry_type(), uri(), bondy_context:context(), map()) ->
    {[entry()], continuation()} | eot().

match(Type, Uri, Ctxt, #{limit := Limit} = Opts) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    MS = index_ms(RealmUri, Uri, Opts),
    Tab = index_table(Type, RealmUri),
    case ets:select(Tab, MS, Limit) of
        ?EOT ->
            {[], ?EOT};
        Result ->
            lookup_entries(Type, Result)
    end;

match(Type, Uri, Ctxt, Opts) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    MS = index_ms(RealmUri, Uri, Opts),
    Tab = index_table(Type, RealmUri),
    lookup_entries(Type, {ets:select(Tab, MS), ?EOT}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(continuation()) -> {[entry()], continuation()} | eot().

match(?EOT) ->
    {[], ?EOT};

match({Type, Cont}) ->
    case ets:select(Cont) of
        ?EOT ->
            {[], ?EOT};
        Result ->
            lookup_entries(Type, Result)
    end.




%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
maybe_execute(undefined, _, _) ->
    ok;

maybe_execute(Task, Entry, Ctxt) when is_function(Task, 2) ->
    _ = Task(to_details_map(Entry), Ctxt),
    ok.


%% @private
do_remove_all(?EOT, _, _, _) ->
    ok;

do_remove_all(#entry{key = Key, type = Type} = E, ETab, Ctxt, Task) ->
    {RealmUri, _, EntryId} = Key,
    %% We first delete the index entry associated with this Entry
    Uri = E#entry.uri,
    IdxTab = index_table(Type, RealmUri),
    IdxEntry = index_entry(EntryId, Uri, E#entry.match_policy, Ctxt),
    true = ets:delete_object(IdxTab, IdxEntry),
    %% We then delete the Entry and decrement the Uri count
    N = ets:select_delete(ETab, [{E, [], [true]}]),
    decr_counter(ETab, {RealmUri, Uri}, N),
    %% We perform the task
    ok = maybe_execute(Task, E, Ctxt),
    %% We continue traversing the ets table
    do_remove_all(ets:next(ETab, Key), ETab, Ctxt, Task);

do_remove_all({_, Sid, _} = Key, ETab, Ctxt, Task) ->
    case bondy_context:session_id(Ctxt) of
        Sid ->
            case ets:lookup(ETab, Key) of
                [] ->
                    ok;
                [Entry] ->
                    %% We should not be getting more than one
                    %% with ordered_set and the matching semantics
                    %% we are using
                    do_remove_all(Entry, ETab, Ctxt, Task)
            end;
        _ ->
            %% No longer our session
            ok
    end;

do_remove_all(_, _, _, _) ->
    %% No longer our session
    ok.




%% =============================================================================
%% PRIVATE - MATCHING
%% =============================================================================



%% @private
-spec validate_match_policy(map()) -> binary().
validate_match_policy(Options) when is_map(Options) ->
    P = maps:get(match, Options, ?EXACT_MATCH),
    P == ?EXACT_MATCH
    orelse P == ?PREFIX_MATCH
    orelse P == ?WILDCARD_MATCH
    orelse error({invalid_match_policy, P}),
    P.


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


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Uses the tuplespace to locate the ets table name assigned to the Realm
%% @end
%% -----------------------------------------------------------------------------
-spec entry_table(entry_type(), uri()) -> ets:tid().
entry_table(subscription, RealmUri) ->
    tuplespace:locate_table(?SUBSCRIPTION_TABLE_NAME, RealmUri);

entry_table(registration, RealmUri) ->
    tuplespace:locate_table(?REGISTRATION_TABLE_NAME, RealmUri).


%% @private
-spec index_table(entry_type(), uri()) -> ets:tid().
index_table(subscription, RealmUri) ->
    tuplespace:locate_table(?SUBSCRIPTION_INDEX_TABLE_NAME, RealmUri);

index_table(registration, RealmUri) ->
    tuplespace:locate_table(?REGISTRATION_INDEX_TABLE_NAME, RealmUri).



%% @private
-spec do_add(atom(), entry(), bondy_context:context()) ->
    {ok, entry(), IsFirstEntry :: boolean()}.

do_add(Type, Entry, Ctxt) ->
    #entry{
        key = {RealmUri, _, EntryId},
        uri = Uri,
        match_policy = MatchPolicy
    } = Entry,

    SSTab = entry_table(Type, RealmUri),
    true = ets:insert(SSTab, Entry),

    IdxTab = index_table(Type, RealmUri),
    IdxEntry = index_entry(EntryId, Uri, MatchPolicy, Ctxt),
    true = ets:insert(IdxTab, IdxEntry),
    {ok, to_details_map(Entry), incr_counter(SSTab, {RealmUri, Uri}, 1) =:= 1}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Creates an index entry.
%% @end
%% -----------------------------------------------------------------------------
-spec index_entry(id(), uri(), binary(), bondy_context:context()) -> #index{}.

index_entry(EntryId, Uri, Policy, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    Entry = #index{entry_key = {RealmUri, SessionId, EntryId}},
    Cs = [RealmUri | uri_components(Uri)],
    case Policy of
        ?EXACT_MATCH ->
            Entry#index{key = list_to_tuple(Cs)};
        ?PREFIX_MATCH ->
            Entry#index{key = list_to_tuple(Cs ++ [?ANY])};
        ?WILDCARD_MATCH ->
            %% Wildcard-matching allows to provide wildcards for *whole* URI
            %% components.
            Entry#index{key = list_to_tuple(Cs)}
    end.


%% @private
-spec index_ms(uri(), uri(), map()) -> ets:match_spec().

index_ms(RealmUri, Uri, Opts) ->
    Cs = [RealmUri | uri_components(Uri)],
    ExactConds = [{'=:=', '$1', {const, list_to_tuple(Cs)}}],
    PrefixConds = prefix_conditions(Cs),
    WildcardCond = wilcard_conditions(Cs),
    AllConds = list_to_tuple(
        lists:append([['or'], ExactConds, PrefixConds, WildcardCond])),
    Conds = case maps:get(exclude, Opts, []) of
        [] ->
            [AllConds];
        SessionIds ->
            %% We exclude the provided SessionIds
            ExclConds = list_to_tuple([
                'and' |
                [{'=/=', '$2', {const, S}} || S <- SessionIds]
            ]),
            [list_to_tuple(['andalso', AllConds, ExclConds])]
    end,
    MP = #index{
        key = '$1',
        entry_key = {RealmUri, '$2', '$3'}
    },
    Proj = [{{RealmUri, '$2', '$3'}}],

    [
        { MP, Conds, Proj }
    ].


%% @private
-spec prefix_conditions(list()) -> list().

prefix_conditions(L) ->
    prefix_conditions(L, []).


%% @private
-spec prefix_conditions(list(), list()) -> list().

prefix_conditions(L, Acc) when length(L) == 2 ->
    lists:reverse(Acc);

prefix_conditions(L0, Acc) ->
    L1 = lists:droplast(L0),
    C = {'=:=', '$1', {const, list_to_tuple(L1 ++ [?ANY])}},
    prefix_conditions(L1, [C|Acc]).


%% @private
-spec wilcard_conditions(list()) -> list().

wilcard_conditions([H|T] = L) ->
    Ordered = lists:zip(T, lists:seq(2, length(T) + 1)),
    Cs0 = [
        {'or',
            {'=:=', {element, N, '$1'}, {const, E}},
            {'=:=', {element, N, '$1'}, {const, <<>>}}
        } || {E, N} <- Ordered
    ],
    Cs1 = [
        {'=:=', {element, 1, '$1'}, {const, H}},
        {'=:=', {size, '$1'}, {const, length(L)}} | Cs0],
    %% We need to use 'andalso' here and not 'and', otherwise the match spec
    %% will break when the {size, '$1'} /= {const, length(L)}
    %% This happens also because the evaluation order of 'or' and 'and' is
    %% undefined in match specs
    [list_to_tuple(['andalso' | Cs1])].


%% @private
lookup_entries(Type, {Keys, ?EOT}) ->
    {do_lookup_entries(Keys, Type, []), ?EOT};

lookup_entries(Type, {Keys, Cont}) ->
    {do_lookup_entries(Keys, Type, []), {Type, Cont}}.


%% @private
do_lookup_entries([], _, Acc) ->
    lists:reverse(Acc);

do_lookup_entries([{RealmUri, _, _} = Key|T], Type, Acc) ->
    case ets:lookup(entry_table(Type, RealmUri), Key) of
        [] ->
            do_lookup_entries(T, Type, Acc);
        [Entry] ->
            do_lookup_entries(T, Type, [Entry|Acc])
    end.


%% TODO move to wamp library
%% -----------------------------------------------------------------------------
%% @private
%% @doc Returns the components of an URI.
%%
%% Example:
%%
%% <pre lang="erlang">
%% uri_components(&lt;&lt;com.mycompany.foo.bar"&gt;&gt;).
%% [&lt;&lt;com.mycompany"&gt;&gt;, &lt;&lt;foo"&gt;&gt;, &lt;&lt;bar"&gt;&gt;].
%% </pre>
%% @end
%% -----------------------------------------------------------------------------
-spec uri_components(uri()) -> [binary()].

uri_components(<<"wamp.", Rest/binary>>) ->
    L = binary:split(Rest, <<".">>, [global]),
    [<<"wamp">> | L];

uri_components(<<"com.leapsight.bondy.", Rest/binary>>) ->
    L = binary:split(Rest, <<".">>, [global]),
    [<<"com.leapsight.bondy">> | L];

uri_components(Uri) ->
    case binary:split(Uri, <<".">>, [global]) of
        [TopLevelDomain, AppName | Rest] when length(Rest) > 0 ->
            Domain = <<TopLevelDomain/binary, $., AppName/binary>>,
            [Domain | Rest];
        _Other ->
            error({badarg, Uri})
    end.


%% @private
key_pattern(subscription, RealmUri, SessionId) ->
    {RealmUri, SessionId, '$1'};

key_pattern(registration, RealmUri, _) ->
    {RealmUri, '_', '$1'}.


%% @private
incr_counter(Tab, Key, N) ->
    Default = {counter, Key, 0},
    ets:update_counter(Tab, Key, {3, N}, Default).


%% @private
decr_counter(Tab, Key, N) ->
    Default = {counter, Key, 0},
    case ets:update_counter(Tab, Key, {3, -N, 0, 0}, Default) of
        0 ->
            %% Other process might have concurrently incremented the count,
            %% so we do a match delete
            true = ets:match_delete(Tab, Default),
            0;
        Val ->
            Val
    end.


