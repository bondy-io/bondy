%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% -----------------------------------------------------------------------------
%% @doc
%% An in-memory registry for PubSub subscriptions and RPC registrations,
%% providing pattern matching capbilities including support for WAMP's
%% version 2.0 match policies (exact, prefix and wilcard).
%% @end
%% -----------------------------------------------------------------------------
-module(juno_registry).
-include_lib("wamp/include/wamp.hrl").

-define(ANY, <<"*">>).

%% -define(DEFAULT_LIMIT, 1000).
-define(SUBSCRIPTION_TABLE_NAME, juno_subscription).
-define(SUBSCRIPTION_INDEX_TABLE_NAME, juno_subscription_index).
-define(REGISTRATION_TABLE_NAME, juno_registration).
-define(REGISTRATION_INDEX_TABLE_NAME, juno_registration_index).
-define(MAX_LIMIT, 100000).
-define(LIMIT(Opts), min(maps:get(limit, Opts, ?MAX_LIMIT), ?MAX_LIMIT)).


-define(ENTRY_KEY(RealmUri, SessionId, EntryId), 
    {RealmUri, SessionId, EntryId}
).

%% An entry denotes a registration or a subscription
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
-type continuation()        ::  {entry_type(), etc:continuation()} 
                                | ets:continuation().


-export_type([entry/0]).
-export_type([entry_key/0]).
-export_type([entry_type/0]).


-export([add/4]).
-export([created/1]).
-export([criteria/1]).
-export([entries/1]).
-export([entries/2]).
-export([entries/3]).
-export([entries/4]).
-export([entry_id/1]).
-export([id/1]).
-export([lookup/3]).
-export([lookup/4]).
-export([match/1]).
-export([match/3]).
-export([match/4]).
-export([match_policy/1]).
-export([options/1]).
-export([realm_uri/1]).
-export([remove/3]).
-export([remove_all/2]).
-export([session_id/1]).
-export([to_details_map/1]).
-export([type/1]).
-export([uri/1]).


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec id(entry()) -> id().
id(#entry{key = {_, _, Val}}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(entry()) -> uri().
realm_uri(#entry{key = {Val, _, _}}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(entry()) -> id().
session_id(#entry{key = {_, Val, _}}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec entry_id(entry()) -> id().
entry_id(#entry{key = {_, _, Val}}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
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
%% @end
%% -----------------------------------------------------------------------------
-spec match_policy(entry()) -> binary().
match_policy(#entry{match_policy = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec criteria(entry()) -> list().
criteria(#entry{criteria = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec created(entry()) -> calendar:date_time().
created(#entry{created = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec options(entry()) -> map().
options(#entry{options = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec to_details_map(entry()) -> any().

to_details_map(#entry{key = {_, _, Id}} = E) ->
    #{
        <<"id">> => Id,
        <<"created">> => E#entry.created,
        <<"uri">> => E#entry.uri,
        <<"match">> => E#entry.match_policy
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% Add a registry entry
%% @end
%% -----------------------------------------------------------------------------
-spec add(entry_type(), uri(), map(), juno_context:context()) -> 
    {ok, map(), IsFirstEntry :: boolean()}
    | {error, {already_exists, id()}}.
add(Type, Uri, Options, Ctxt) ->
    RealmUri = juno_context:realm_uri(Ctxt),
    SessionId = juno_context:session_id(Ctxt),
    MatchPolicy = validate_match_policy(Options),
    
    Pattern = #entry{
        key = key_pattern(Type, RealmUri, SessionId),
        type = Type,
        uri = Uri,
        match_policy = MatchPolicy,
        criteria = [], % TODO Criteria
        created = '_',
        options = '_'
    },
    Tab = entry_table(Type, RealmUri),

    MaybeAdd = fun
        (true) ->
            Entry = #entry{
                key = ?ENTRY_KEY(
                    RealmUri, SessionId, juno_utils:get_id(global)),
                type = Type,
                uri = Uri,
                match_policy = MatchPolicy,
                criteria = [], % TODO Criteria
                created = calendar:local_time(),
                options = parse_options(Type, Options)
            },
            do_add(Type, Entry, Ctxt);
        (Entry) ->
            {error, {already_exists, to_details_map(Entry)}}
    end,

    case ets:match_object(Tab, Pattern) of
        [] ->
            %% No matching registrations at all exists or
            %% No matching subscriptions for this SessionId exists
            MaybeAdd(true);

        [#entry{} = Entry] when Type == subscription ->
            %% In case of receiving a "SUBSCRIBE" message from the same
            %% _Subscriber_ and to already added topic, _Broker_ should
            %% answer with "SUBSCRIBED" message, containing the existing
            %% "Subscription|id".
            {error, {already_exists, Entry}};

        [#entry{options = EOpts} = Entry| _] when Type == registration ->
            SharedEnabled = juno_context:is_feature_enabled(
                Ctxt, <<"callee">>, <<"shared_registration">>),
            NewPolicy = maps:get(<<"invoke">>, Options, <<"single">>),
            PrevPolicy = maps:get(<<"invoke">>, EOpts, <<"single">>),
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
                NewPolicy =/= <<"single">> andalso
                NewPolicy == PrevPolicy,

            MaybeAdd(Flag orelse Entry)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Removes all entries matching the context's realm and session_id (if any).
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(entry_type(), juno_context:context()) -> ok.
remove_all(Type, #{realm_uri := RealmUri} = Ctxt) ->
    Pattern = #entry{
        key = {RealmUri, juno_context:session_id(Ctxt), '_'},
        type = Type,
        uri = '_',
        match_policy = '_',
        criteria = '_',
        options = '_',
        created = '_'
    },
    Tab = entry_table(Type, RealmUri),
    case ets:match_object(Tab, Pattern, 1) of
        '$end_of_table' ->
            %% There are no entries for this session
            ok;
        {[First], _} ->
            %% Use iterator to remove each one
            do_remove_all(First, Tab, Ctxt)
    end;
    
remove_all(_, _) ->
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% Lookup an entry by Type, Id and Ctxt
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(entry_type(), id(), juno_context:context()) -> entry() | not_found.
lookup(Type, EntryId, Ctxt) ->
    RealmUri = juno_context:realm_uri(Ctxt),
    SessionId = juno_context:session_id(Ctxt),
    lookup(Type, EntryId, SessionId, RealmUri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(entry_type(), id(), id(), uri()) -> entry() | not_found.
lookup(Type, EntryId, SessionId, RealmUri) ->
    % TODO Use UserId when there is no SessionId
    Tab = entry_table(Type, RealmUri),
    case ets:take(Tab, ?ENTRY_KEY(RealmUri, SessionId, EntryId)) of
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
-spec remove(entry_type(), id(), juno_context:context()) -> 
    ok | {error, not_found}.
remove(Type, EntryId, Ctxt) ->
    RealmUri = juno_context:realm_uri(Ctxt),
    SessionId = juno_context:session_id(Ctxt),
    % TODO Use UserId when there is no SessionId
    Tab = entry_table(Type, RealmUri),
    Key = ?ENTRY_KEY(RealmUri, SessionId, EntryId),
    case ets:take(Tab, Key) of
        [] ->
            %% The session had no entries with EntryId.
            {error, not_found};
        [#entry{uri = Uri, match_policy = MP}] ->
            decr_counter(Tab, {RealmUri, Uri}, 1),
            %% Delete indices for entry
            IdxTab = index_table(Type, RealmUri),
            IdxEntry = index_entry(EntryId, Uri, MP, Ctxt),
            ets:delete_object(IdxTab, IdxEntry),
            ok
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the list of entries for the active session.
%%
%% When called with a juno:context() it is equivalent to calling
%% {@link entries/2} with the RealmUri and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(entry_type(), juno_context:context()) -> [entry()].
entries(Type, Ctxt) ->
    RealmUri = juno_context:realm_uri(Ctxt),
    SessionId = juno_context:session_id(Ctxt),
    entries(Type, RealmUri, SessionId).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of entries matching the RealmUri
%% and SessionId.
%%
%% Use {@link entries/3} and {@link entries/1} to limit the number
%% of entries returned.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(entry_type(), RealmUri :: uri(), SessionId :: id()) -> [entry()].
entries(Type, RealmUri, SessionId) ->
    Pattern = #entry{
        key = {RealmUri, SessionId, '_'},
        uri = '_',
        match_policy = '_',
        criteria = '_',
        created = '_',
        options = '_'
    },
    ets:match_object(entry_table(Type, RealmUri), Pattern).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec entries(continuation()) -> 
    {[entry()], continuation()} | '$end_of_table'.
entries(Cont) ->
    ets:match_object(Cont).



%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of entries matching the RealmUri
%% and SessionId.
%%
%% Use {@link entries/3} to limit the number of entries returned.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(
    entry_type(), Realm :: uri(), SessionId :: id(), Limit :: pos_integer()) ->
    {[entry()], continuation()} | '$end_of_table'.
entries(Type, RealmUri, SessionId, infinity) ->
    entries(Type, RealmUri, SessionId);

entries(Type, RealmUri, SessionId, Limit) ->
    Pattern = #entry{
        key = {RealmUri, SessionId, '_'},
        uri = '_',
        match_policy = '_',
        criteria = '_',
        created = '_',
        options = '_'
    },
    ets:match_object(entry_table(Type, RealmUri), Pattern, Limit).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(entry_type(), uri(), juno_context:context()) ->
    {[entry()], continuation()} | '$end_of_table'.
match(Type, Uri, Ctxt) ->
    match(Type, Uri, Ctxt, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(entry_type(), uri(), juno_context:context(), map()) ->
    {[entry()], continuation()} | '$end_of_table'.
match(Type, Uri, Ctxt, #{limit := Limit} = Opts) ->
    RealmUri = juno_context:realm_uri(Ctxt),
    MS = index_ms(RealmUri, Uri, Opts),
    Tab = index_table(Type, RealmUri),
    lookup_entries(Type, ets:select(Tab, MS, Limit));

match(Type, Uri, Ctxt, Opts) ->
    RealmUri = juno_context:realm_uri(Ctxt),
    MS = index_ms(RealmUri, Uri, Opts),
    % io:format("MS ~p~n", [MS]),
    Tab = index_table(Type, RealmUri),
    lookup_entries(Type, {ets:select(Tab, MS), '$end_of_table'}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(continuation()) -> {[entry()], continuation()} | '$end_of_table'.
match({Type, Cont}) when Type == registration orelse Type == subscription ->
    lookup_entries(Type, ets:select(Cont)).




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_remove_all('$end_of_table', _, _) ->
    ok;

do_remove_all([], _, _) ->
    ok;

do_remove_all(#entry{key = Key, type = Type} = S, Tab, Ctxt) ->
    {RealmUri, _, EntryId} = Key,
    Uri = S#entry.uri,
    MatchPolicy = S#entry.match_policy,
    IdxTab = index_table(Type, RealmUri),
    IdxEntry = index_entry(EntryId, Uri, MatchPolicy, Ctxt),
    N = ets:select_delete(Tab, [{S, [], [true]}]),
    decr_counter(Tab, {RealmUri, Uri}, N),
    true = ets:delete_object(IdxTab, IdxEntry),
    do_remove_all(ets:next(Tab, Key), Tab, Ctxt);

do_remove_all({_, Sid, _} = Key, Tab, Ctxt) ->
    case juno_context:session_id(Ctxt) of
        Sid ->
            do_remove_all(ets:lookup(Tab, Key), Tab, Ctxt);
        _ ->
            ok
    end;

do_remove_all(_, _, _) ->
    %% No longer our session
    ok.




%% =============================================================================
%% PRIVATE - MATCHING
%% =============================================================================



%% @private
-spec validate_match_policy(map()) -> binary().
validate_match_policy(Options) when is_map(Options) ->
    P = maps:get(<<"match">>, Options, <<"exact">>),
    P == <<"exact">> orelse P == <<"prefix">> orelse P == <<"wildcard">>
    orelse error({invalid_pattern_match_policy, P}),
    P.


%% @private
parse_options(subscription, Opts) ->
    parse_subscription_options(Opts);
parse_options(registration, Opts) ->
    parse_registration_options(Opts).


%% @private
parse_subscription_options(Opts) ->
    maps:without([<<"match">>], Opts).


%% @private
parse_registration_options(Opts) ->
    maps:without([<<"match">>], Opts).


%% @private
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
-spec do_add(atom(), entry(), juno_context:context()) -> 
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


%% @private
-spec index_entry(
    id(), uri(), binary(), juno_context:context()) -> #index{}.
index_entry(EntryId, Uri, Policy, Ctxt) ->
    RealmUri = juno_context:realm_uri(Ctxt),
    SessionId = juno_context:session_id(Ctxt),
    Entry = #index{entry_key = {RealmUri, SessionId, EntryId}},
    Cs = [RealmUri | uri_components(Uri)],
    case Policy of
        <<"exact">> ->
            Entry#index{key = list_to_tuple(Cs)};
        <<"prefix">> ->
            Entry#index{key = list_to_tuple(Cs ++ [?ANY])};
        <<"wildcard">> ->
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
lookup_entries(_Type, '$end_of_table') ->
    '$end_of_table';

lookup_entries(Type, {Keys, '$end_of_table'}) ->
    {do_lookup_entries(Type, Keys), '$end_of_table'};

lookup_entries(Type, {Keys, Cont}) ->
    {do_lookup_entries(Type, Keys), {Type, Cont}}.


%% @private
do_lookup_entries(Type, Keys) ->
    do_lookup_entries(Keys, Type, []).


%% @private
do_lookup_entries([], _, Acc) ->
    lists:reverse(Acc);

do_lookup_entries([{RealmUri, _, _} = Key|T], Type, Acc) ->
    case ets:lookup(entry_table(Type, RealmUri), Key) of
        [] -> do_lookup_entries(T, Type, Acc);
        [Entry] -> do_lookup_entries(T, Type, [Entry|Acc])
    end.


%% TODO move to wamp library
%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Example:
%% uri_components(<<"com.mycompany.foo.bar">>) ->
%% [<<"com.mycompany">>, <<"foo">>, <<"bar">>].
%% @end
%% -----------------------------------------------------------------------------
-spec uri_components(uri()) -> [binary()].
uri_components(<<"wamp.", Rest/binary>>) ->
    L = binary:split(Rest, <<".">>, [global]),
    [<<"wamp">> | L];
uri_components(<<"juno.", Rest/binary>>) ->
    L = binary:split(Rest, <<".">>, [global]),
    [<<"juno">> | L];
uri_components(Uri) ->
    case binary:split(Uri, <<".">>, [global]) of
        [TopLevelDomain, AppName | Rest] when length(Rest) > 0 ->
            Domain = <<TopLevelDomain/binary, $., AppName/binary>>,
            [Domain | Rest];
        _Other ->
            %% Invalid Uri
            error({badarg, Uri})
    end.


%% @private
key_pattern(subscription, RealmUri, SessionId) -> 
    {RealmUri, SessionId, '$1'};

key_pattern(registration, RealmUri, _) -> 
    {RealmUri, '_', '$1'}.


%% @private
incr_counter(Tab, Key, N) ->
    ets:update_counter(Tab, Key, {2, N}, {Key, 1}).


%% @private
decr_counter(Tab, Key, N) ->
    Default = {Key, 0},
    case ets:update_counter(Tab, Key, {2, -N, 0, 0}, Default) of
        0 ->
            %% Other process might have incremented the count, 
            %% so we do a match delete
            true = ets:match_delete(Tab, Default),
            0;
        N -> 
            N
    end.


