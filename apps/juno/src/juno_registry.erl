%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

-module(juno_registry).
-include_lib("wamp/include/wamp.hrl").

-define(ANY, <<"*">>).
-define(EXACT_MATCH, <<"exact">>).
-define(PREFIX_MATCH, <<"prefix">>).
-define(WILDCARD_MATCH, <<"wildcard">>).
-define(DEFAULT_LIMIT, 1000).
-define(SUBSCRIPTION_TABLE_NAME, subscription).
-define(SUBSCRIPTION_INDEX_TABLE_NAME, subscription_index).
-define(REGISTRATION_TABLE_NAME, registration).
-define(REGISTRATION_INDEX_TABLE_NAME, registration_index).


-record(entry, {
    key                     ::  {
                                    RealmUri    ::  uri(),
                                    SessionId   ::  id(),
                                    EntryId     ::  id()
                                },
    uri                     ::  uri(),
    match_policy            ::  binary(),
    criteria                ::  [{'=:=', Field :: binary(), Value :: any()}],
    info                    ::  map()

}).

-record(index, {
    key                     ::  tuple(),
    session_id              ::  id(),
    session_pid             ::  pid(),
    entry_id                ::  id()
}).

-type entry()               ::  #entry{}.
-type entry_type()          ::  registration | subscription.

-export_type([entry/0]).
-export_type([entry_type/0]).

-export([about/1]).
-export([add/4]).
-export([criteria/1]).
-export([entries/1]).
-export([entries/2]).
-export([entries/3]).
-export([entries/4]).
-export([id/1]).
-export([info/1]).
-export([match_policy/1]).
-export([match/1]).
-export([match/3]).
-export([match/4]).
-export([realm_uri/1]).
-export([remove_all/2]).
-export([remove/3]).
-export([session_id/1]).



%% =============================================================================
%% API
%% =============================================================================


-spec id(entry()) -> id().
id(#entry{key = {_, _, Val}}) -> Val.


-spec realm_uri(entry()) -> uri().
realm_uri(#entry{key = {Val, _, _}}) -> Val.


-spec session_id(entry()) -> id().
session_id(#entry{key = {_, Val, _}}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the uri this entry is about i.e. either  subscription topic_uri or
%% a registration procedure_uri.
%% @end
%% -----------------------------------------------------------------------------
-spec about(entry()) -> uri().
about(#entry{uri = Val}) -> Val.

-spec match_policy(entry()) -> binary().
match_policy(#entry{match_policy = Val}) -> Val.

-spec criteria(entry()) -> list().
criteria(#entry{criteria = Val}) -> Val.

-spec info(entry()) -> map().
info(#entry{info = Val}) -> Val.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(entry_type(), uri(), map(), juno_context:context()) -> {ok, id()}.
add(Type, Uri, Options, Ctxt) ->
    #{ realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    MatchPolicy = validate_match_policy(Options),
    SSKey = {RealmUri, SessionId, '$1'},
    SS0 = #entry{
        key = SSKey,
        uri = Uri,
        match_policy = MatchPolicy,
        criteria = [],
        info = extract_info(Options)

    },
    Tab = entry_table(Type, RealmUri, SessionId),

    case ets:match(Tab, SS0) of
        [[EntryId]] when Type == subscription ->
            %% In case of receiving a "SUBSCRIBE" message from the same
            %% _Subscriber_ and to already added topic, _Broker_ should
            %% answer with "SUBSCRIBED" message, containing the existing
            %% "Subscription|id".
            {ok, EntryId};
        _ ->
            %% No entry or existing registration entry.
            %% JUNO supports Shared Registration (RFC 13.3.9)
            EntryId = wamp_id:new(global),
            SS1 = SS0#entry{key = setelement(3, SSKey, EntryId)},
            IdxEntry = index_entry(EntryId, Uri, MatchPolicy, Ctxt),
            SSTab = entry_table(Type, RealmUri, SessionId),
            IdxTab = index_table(Type, RealmUri),
            true = ets:insert(SSTab, SS1),
            true = ets:insert(IdxTab, IdxEntry),
            {ok, EntryId}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(entry_type(), juno_context:context()) -> ok.
remove_all(Type, Ctxt) ->
    #{realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    Pattern = #entry{
        key = {RealmUri, SessionId, '_'},
        uri = '_',
        match_policy = '_',
        criteria = '_',
        info = '_'
    },
    Tab = entry_table(Type, RealmUri, SessionId),
    case ets:match_object(Tab, Pattern, 1) of
        '$end_of_table' ->
            %% There are no entries for this session
            ok;
        {[First], _} ->
            do_remove_all(First, Type, Tab, Ctxt)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(entry_type(), id(), juno_context:context()) -> ok.
remove(Type, EntryId, Ctxt) ->
    #{realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    Tab = entry_table(Type, RealmUri, SessionId),
    Key = {RealmUri, SessionId, EntryId},
    case ets:take(Tab, Key) of
        [] ->
            %% The session had no subscription with subsId.
            error(no_such_subscription);
        [#entry{uri = Uri, match_policy = MP}] ->
            IdxTab = index_table(Type, RealmUri),
            IdxEntry = index_entry(EntryId, Uri, MP, Ctxt),
            true = ets:delete_object(IdxTab, IdxEntry),
            ok
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the list of entries for the active session.
%%
%% When called with a juno:context() it is equivalent to calling
%% entries/2 with the RealmUri and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(entry_type(), juno_context:context()) ->
    [#entry{}].
entries(Type, #{realm_uri := RealmUri, session_id := SessionId}) ->
    entries(Type, RealmUri, SessionId).


-spec entries(ets:continuation()) -> [#entry{}].
entries(Cont) ->
    ets:match_object(Cont).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of entries matching the RealmUri
%% and SessionId.
%%
%% Use {@link entries/3} and {@link entries/1} to limit the number
%% of entries returned.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(entry_type(), RealmUri :: uri(), SessionId :: id()) -> [#entry{}].
entries(Type, RealmUri, SessionId) ->
    session_entries(Type, RealmUri, SessionId, infinity).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of entries matching the RealmUri
%% and SessionId.
%%
%% Use {@link entries/3} to limit the number of entries returned.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(
    entry_type(), RealmUri :: uri(), SessionId :: id(), non_neg_integer()) ->
    {[#entry{}], Cont :: '$end_of_table' | term()}.
entries(Type, RealmUri, SessionId, Limit) ->
    session_entries(Type, RealmUri, SessionId, Limit).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(entry_type(), uri(), juno_context:context()) ->
    {[{SessionId :: id(), pid(), SubsId :: id()}], ets:continuation()}
    | '$end_of_table'.
match(Type, Uri, Ctxt) ->
    match(Type, Uri, Ctxt, ?DEFAULT_LIMIT).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(
    entry_type(), uri(), juno_context:context(), non_neg_integer()) ->
    {[{SessionId :: id(), pid(), SubsId :: id()}], ets:continuation()}
    | '$end_of_table'.
match(Type, Uri, Ctxt, Limit) ->
    #{realm_uri := RealmUri} = Ctxt,
    MS = index_ms(RealmUri, Uri),
    Tab = index_table(Type, RealmUri),
    ets:select(Tab, MS, Limit).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(ets:continuation()) ->
    {[SessionId :: id()], ets:continuation()} | '$end_of_table'.
match(Cont) ->
    ets:select(Cont).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_remove_all('$end_of_table', _, _, _) ->
    ok;
do_remove_all([], _, _, _) ->
    ok;
do_remove_all(#entry{} = S, Type, Tab, Ctxt) ->
    {RealmUri, _, SubsId} = Key = S#entry.key,
    Uri = S#entry.uri,
    MatchPolicy = S#entry.match_policy,
    IdxTab = index_table(Type, RealmUri),
    IdxEntry = index_entry(SubsId, Uri, MatchPolicy, Ctxt),
    true = ets:delete_object(Tab, S),
    true = ets:delete_object(IdxTab, IdxEntry),
    do_remove_all(ets:next(Tab, Key), Type, Tab, Ctxt);
do_remove_all({_, Sid, _} = Key, Type, Tab, #{session_id := Sid} = Ctxt) ->
    do_remove_all(ets:lookup(Tab, Key), Type, Tab, Ctxt);
do_remove_all(_, _, _, _) ->
    %% No longer our session
    ok.


%% @private
session_entries(Type, RealmUri, SessionId, Limit) ->
    Pattern = #entry{
        key = {RealmUri, SessionId, '_'},
        uri = '_',
        match_policy = '_',
        criteria = '_',
        info = '_'
    },
    Tab = entry_table(Type, RealmUri, SessionId),
    case Limit of
        infinity ->
            ets:match_object(Tab, Pattern);
        _ ->
            ets:match_object(Tab, Pattern, Limit)
    end.



%% =============================================================================
%% PRIVATE - MATCHING
%% =============================================================================



%% @private
-spec validate_match_policy(map()) -> binary().
validate_match_policy(Options) when is_map(Options) ->
    P = maps:get(<<"match">>, Options, ?EXACT_MATCH),
    P == ?EXACT_MATCH orelse P == ?PREFIX_MATCH orelse P == ?WILDCARD_MATCH
    orelse error({invalid_pattern_match_policy, P}),
    P.

%% @private
extract_info(Options) ->
    maps:without([<<"match">>], Options).


%% @private
-spec entry_table(entry_type(), uri(), id()) -> ets:tid().
entry_table(subscription, RealmUri, SessionId) ->
    tuplespace:locate_table(
        ?SUBSCRIPTION_TABLE_NAME, {RealmUri, SessionId});
entry_table(registration, RealmUri, SessionId) ->
    tuplespace:locate_table(
        ?REGISTRATION_TABLE_NAME, {RealmUri, SessionId}).


%% @private
-spec index_table(entry_type(), uri()) -> ets:tid().
index_table(subscription, RealmUri) ->
    tuplespace:locate_table(?SUBSCRIPTION_INDEX_TABLE_NAME, RealmUri);
index_table(registration, RealmUri) ->
    tuplespace:locate_table(?REGISTRATION_INDEX_TABLE_NAME, RealmUri).


%% @private
%% @doc
%% Example:
%% uri_components(<<"com.mycompany.foo.bar">>) ->
%% {<<"com.mycompany">>, [<<"foo">>, <<"bar">>]}.
%% @end
-spec uri_components(uri()) -> [binary()].
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
-spec index_entry(id(), uri(), binary(), juno_context:context()) ->
    #index{}.
index_entry(EntryId, Uri, Policy, Ctxt) ->
    #{realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    Entry = #index{
        session_id = SessionId,
        session_pid = juno_session:pid(SessionId),
        entry_id = EntryId
    },
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
-spec index_ms(uri(), uri()) -> ets:match_spec().
index_ms(RealmUri, Uri) ->
    Cs = [RealmUri | uri_components(Uri)],
    ExactConds = [{'=:=', '$1', {const, list_to_tuple(Cs)}}],
    PrefixConds = prefix_conditions(Cs),
    WildcardConds = wilcard_conditions(Cs),
    Conds = lists:append([ExactConds, PrefixConds, WildcardConds]),
    MP = #index{
        key = '$1',
        session_id = '$2',
        session_pid = '$3',
        entry_id = '$4'
    },
    Proj = [{{'$2', '$3', '$4'}}],
    [
        { MP, [list_to_tuple(['or' | Conds])], Proj }
    ].


%% @private
-spec prefix_conditions(list()) -> list().
prefix_conditions(L) ->
    prefix_conditions(L, []).


%% @private
-spec prefix_conditions(list(), list()) -> list().
prefix_conditions(L, Acc) when length(L) == 3 ->
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
    Cs1 = [{'=:=',{element, 1, '$1'}, {const, H}}, {'=:=', {size, '$1'}, {const, length(L)}} | Cs0],
    [list_to_tuple(['and' | Cs1])].
