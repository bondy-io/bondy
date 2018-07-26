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
%% An in-memory registry for PubSub subscriptions and Routed RPC registrations,
%% providing pattern matching capabilities including support for WAMP's
%% version 2.0 match policies (exact, prefix and wilcard).
%%
%% This is a temporary solution till we finish our
%% adaptive radix trie implementation. Does no support prefix matching nor
%% wilcard matching.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_registry).
-behaviour(gen_server).

-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").


%% -define(SUBSCRIPTION_DB_full_PREFIX, {global, bondy_subscription}).
%% -define(REGISTRATION_DB_full_PREFIX, {global, bondy_registration}).
-define(ANY, <<"*">>).

-define(PREFIX, registry).
-define(FULLPREFIX(RealmUri), {?PREFIX, RealmUri}).


-define(SUBSCRIPTION_TABLE_NAME, bondy_subscription).
-define(REGISTRATION_TABLE_NAME, bondy_registration).
-define(SUBSCRIPTION_TRIE_NAME, bondy_subscription_trie).
-define(REGISTRATION_TRIE_NAME, bondy_registration_trie).
-define(MAX_LIMIT, 10000).
-define(LIMIT(Opts), min(maps:get(limit, Opts, ?MAX_LIMIT), ?MAX_LIMIT)).



-type eot()                 ::  ?EOT.
-type continuation()        ::  {
    bondy_registry_entry:entry_type(),
    any()
}.


-type task() :: fun(
    (bondy_registry_entry:details_map(), bondy_context:t()) ->
        ok
).


-export_type([eot/0]).
-export_type([continuation/0]).


-export([add/4]).
-export([entries/1]).
-export([entries/2]).
-export([entries/4]).
-export([entries/5]).
-export([lookup/1]).
-export([lookup/3]).
-export([lookup/4]).
-export([match/1]).
-export([match/3]).
-export([match/4]).
-export([remove/1]).
-export([remove/3]).
-export([remove/4]).
-export([remove_all/2]).
-export([remove_all/3]).
-export([remove_all/4]).
-export([start_link/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).




%% =============================================================================
%% API
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc
%% Adds an entry to the registry.
%%
%% Adding an already existing entry is treated differently based on whether the
%% entry is a registration or a subscription.
%%
%% According to the WAMP specification, in the case of a subscription that was
%% already added before by the same _Subscriber_, the _Broker_ should not fail
%% and answer with a "SUBSCRIBED" message, containing the existing
%% "Subscription|id". So in this case this function returns
%% {ok, bondy_registry_entry:details_map(), boolean()}.
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
-spec add(
    bondy_registry_entry:entry_type(), uri(), map(), bondy_context:t()) ->
    {ok, bondy_registry_entry:details_map(), IsFirstEntry :: boolean()}
    | {error, {already_exists, bondy_registry_entry:details_map()}}.


add(Type, Uri, Options, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    PeerId = bondy_context:peer_id(Ctxt),
    %% Pattern = bondy_registry_entry:new(Type, PeerId, Uri, Options),
    Pattern = case Type of
        registration ->
            %% A session can register a procedure multiple times if
            %% shared_registration is enabled
            %% So we do not match SessionId
            bondy_registry_entry:pattern(Type, RealmUri, '_', '_', Uri, '_');
        subscription ->
            {RealmUri, Node, SessionId, _} = PeerId,
            bondy_registry_entry:pattern(
                Type, RealmUri, Node, SessionId, Uri, '_')
    end,
    Tab = partition_table(Type, RealmUri),

    case ets:match_object(Tab, Pattern) of
        [] ->
            %% No matching registrations at all exists or
            %% No matching subscriptions for this SessionId exists
            Entry = bondy_registry_entry:new(Type, PeerId, Uri, Options),
            do_add(Entry);

        [Entry] when Type == subscription ->
            %% In case of receiving a "SUBSCRIBE" message from the same
            %% _Subscriber_ and to already added topic, _Broker_ should
            %% answer with "SUBSCRIBED" message, containing the existing
            %% "Subscription|id".
            Map = bondy_registry_entry:to_details_map(Entry),
            {error, {already_exists, Map}};

        [Entry | _] when Type == registration ->
            EOpts = bondy_registry_entry:options(Entry),
            SharedEnabled = bondy_context:is_feature_enabled(
                Ctxt, callee, shared_registration),
            NewPolicy = maps:get(invoke, Options, ?INVOKE_SINGLE),
            PrevPolicy = maps:get(invoke, EOpts, ?INVOKE_SINGLE),
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
                    NewEntry = bondy_registry_entry:new(
                        Type, PeerId, Uri, Options),
                    do_add(NewEntry);
                false ->
                    Map = bondy_registry_entry:to_details_map(Entry),
                    {error, {already_exists, Map}}
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Removes all entries matching the context's realm and session_id (if any).
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(bondy_registry_entry:entry_type(), bondy_context:t()) ->
    ok.

remove_all(Type, Ctxt) ->
    remove_all(Type, Ctxt, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% Removes all entries matching the context's realm and session_id (if any).
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(
    bondy_registry_entry:entry_type(),
    bondy_context:t(),
    task() | undefined) ->
    ok.

remove_all(Type, #{realm_uri := RealmUri} = Ctxt, Task)
when is_function(Task, 2) orelse Task == undefined ->
    case bondy_context:session_id(Ctxt) of
        undefined ->
            _ = lager:info("Context has no session_id; failed to remove registry contents"),
            ok;
        SessionId ->
            Node = bondy_context:node(Ctxt),
            Pattern = bondy_registry_entry:pattern(
                Type, RealmUri, Node, SessionId, '_', '_'),
            Tab = partition_table(Type, RealmUri),
            MaybeFun = maybe_fun(Task, Ctxt),
            do_remove_all(
                ets:match_object(Tab, Pattern, 100), SessionId, MaybeFun)
    end;

remove_all(_, _, _) ->
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(
    bondy_registry_entry:entry_type(),
    RealmUri :: uri(),
    Node :: atom(),
    SessionId :: id()) -> [bondy_registry_entry:t()].

remove_all(Type, RealmUri, Node, SessionId) ->
    Pattern = bondy_registry_entry:pattern(
        Type, RealmUri, Node, SessionId, '_', #{}),
    Tab = partition_table(Type, RealmUri),
    do_remove_all(ets:match_object(Tab, Pattern, 1), SessionId, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(Key :: bondy_registry_entry:entry_key()) -> any().

lookup(Key) ->
    Type = bondy_registry_entry:type(Key),
    RealmUri = bondy_registry_entry:realm_uri(Key),
    case ets:lookup(partition_table(Type, RealmUri), Key) of
        [] ->
            {error, not_found};
        [Entry] ->
            Entry
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
lookup(Type, EntryId, RealmUri) when is_integer(EntryId) ->
    lookup(Type, EntryId, RealmUri, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
lookup(Type, EntryId, RealmUri, Details) when is_integer(EntryId) ->
    Pattern = bondy_registry_entry:pattern(
        Type, RealmUri, EntryId, Details),
    case ets:match_object(partition_table(Type, RealmUri), Pattern) of
        [] ->
            {error, not_found};
        [Entry] ->
            Entry
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(bondy_registry_entry:t()) -> ok.

remove(Entry) ->
    Key = bondy_registry_entry:key(Entry),
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    _ = take_from_tuplespace(Key),
    plum_db:delete(?FULLPREFIX(RealmUri), Key).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(
    bondy_registry_entry:entry_type(), id(), bondy_context:t()) ->
    ok | {error, not_found}.

remove(Type, EntryId, Ctxt) ->
    remove(Type, EntryId, Ctxt, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(
    bondy_registry_entry:entry_type(),
    id(),
    bondy_context:t(),
    task() | undefined) -> ok.

remove(Type, EntryId, Ctxt, Task)
when is_function(Task, 2) orelse Task == undefined ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Node = bondy_context:node(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    Key = bondy_registry_entry:key_pattern(
        Type, RealmUri, Node, SessionId, EntryId),
    do_remove(Key, Ctxt, Task).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the list of entries owned by the the active session.
%%
%% This function is equivalent to calling {@link entries/2} with the RealmUri
%% and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(bondy_registry_entry:entry_type(), bondy_context:t()) ->
    [bondy_registry_entry:t()].

entries(Type, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Node = bondy_context:node(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    entries(Type, RealmUri, Node, SessionId).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of entries owned by a session matching
%% RealmUri and SessionId.
%%
%% Use {@link entries/3} and {@link entries/1} to limit the number
%% of entries returned.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(
    bondy_registry_entry:entry_type(),
    RealmUri :: uri(),
    Node :: atom(),
    SessionId :: id()) -> [bondy_registry_entry:t()].

entries(Type, RealmUri, Node, SessionId) ->
    Pattern = bondy_registry_entry:pattern(
        Type, RealmUri, Node, SessionId, '_', #{}),
    ets:match_object(partition_table(Type, RealmUri), Pattern).




%% -----------------------------------------------------------------------------
%% @doc
%% Works like {@link entries/3}, but only returns a limited (Limit) number of
%% entries. Term Continuation can then be used in subsequent calls to entries/1
%% to get the next chunk of entries.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(
    bondy_registry_entry:entry_type(),
    Realm :: uri(),
    Node :: atom(),
    SessionId :: id(),
    Limit :: pos_integer()) ->
    {[bondy_registry_entry:t()], continuation() | eot()}.

entries(Type, RealmUri, Node, SessionId, Limit) ->
    Pattern = bondy_registry_entry:pattern(
        Type, RealmUri, Node, SessionId, '_', #{}),
    ets:match_object(partition_table(Type, RealmUri), Pattern, Limit).



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
-spec entries(continuation()) ->
    {[bondy_registry_entry:t()], continuation() | eot()}.

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
-spec match(
    bondy_registry_entry:entry_type(), uri(), RealmUri :: uri()) ->
    {[bondy_registry_entry:t()], continuation()} | eot().

match(Type, Uri, RealmUri) ->
    match(Type, Uri, RealmUri, #{}).


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
-spec match(
    bondy_registry_entry:entry_type(), uri(), RealmUri :: uri(), map()) ->
    {[bondy_registry_entry:t()], continuation()} | eot().

match(Type, Uri, RealmUri, Opts) ->
    try
        Trie = trie(Type),
        Pattern = <<RealmUri/binary, $,, Uri/binary>>,
        MS = trie_ms(Opts),
        Result = art_server:find_matches(Pattern, MS, Trie),
        lookup_entries(Type, {Result, ?EOT})
    catch
        throw:non_eligible_entries ->
            {[], ?EOT}
    end.




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(continuation()) ->
    {[bondy_registry_entry:t()], continuation()} | eot().

match(?EOT) ->
    {[], ?EOT};

match({_, ?EOT}) ->
    {[], ?EOT}.

%% match({Type, Cont}) ->
%%     case ets:select(Cont) of
%%         ?EOT ->
%%             {[], ?EOT};
%%         Result ->
%%             lookup_entries(Type, Result)
%%     end.





%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->

    %% TODO DO NOT DO THIS, LOAD only data from particular node when we get an update from peerservice. Make sure we load before the first Exchange or actually force and exchange and then load.
    %% We tell ourselves to load the registry from the db
    self() ! init_from_db,
    process_flag(trap_exit, true),

    %% We initialise the tries
    _ = art_sup:start_trie(?REGISTRATION_TRIE_NAME),
    _ = art_sup:start_trie(?SUBSCRIPTION_TRIE_NAME),

    %% We subscribe to change notifications in plum_db_events. We get updates
    %% in handle_info so that we can we recompile the Cowboy dispatch tables
    MS = [{ {{{?PREFIX, '_'}, '_'}, '_'}, [], [true] }],
    ok = plum_db_events:subscribe(object_update, MS),

    {ok, undefined}.


handle_call(Event, From, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p, from=~p", [Event, From]),
    {noreply, State}.


handle_cast(Event, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p", [Event]),
    {noreply, State}.

handle_info(init_from_db, State0) ->
    _ = lager:debug("Loading registry from db"),
    State = init_from_db(State0),
    {noreply, State};

handle_info(
    {plum_db_event, object_update, {{{registry, _}, Key}, Object}}, State) ->
    Node = bondy_registry_entry:node(Key),
    _ = case Node =:= bondy_peer_service:mynode() of
        true ->
            %% This should not be happenning as only we can change our
            %% registrations. We do nothing.
            ok;
        false ->
            case maybe_resolve(Object) of
                '$deleted' ->
                    _ = take_from_tuplespace(Key);
                Entry ->
                    add_to_tuplespace(Entry)
            end
    end,
    {noreply, State};

handle_info(Info, State) ->
    _ = lager:debug("Unexpected message, message=~p", [Info]),
    {noreply, State}.


terminate(normal, _State) ->
    ok;
terminate(shutdown, _State) ->
    ok;
terminate({shutdown, _}, _State) ->
    ok;
terminate(_Reason, _State) ->
    %% TODO publish metaevent
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
init_from_db(State) ->
    Opts = [{resolver, lww}],
    Iterator = plum_db:iterator({?PREFIX, undefined}, Opts),
    init_from_db(Iterator, State).

%% @private
init_from_db(Iterator, State) ->
    Now = calendar:local_time(),
    case plum_db:iterator_done(Iterator) of
        true ->
            ok = plum_db:iterator_close(Iterator),
            State;
        false ->
            ok = case plum_db:iterator_key_value(Iterator) of
                {_, '$deleted'} ->
                    ok;
                {_, Entry} ->
                    maybe_add_to_tuplespace(Entry, Now)
            end,
            init_from_db(plum_db:iterate(Iterator), State)
    end.


%% @private
maybe_add_to_tuplespace(Entry, Now) ->
    MyNode = bondy_peer_service:mynode(),
    Node = bondy_registry_entry:node(Entry),
    Created = bondy_registry_entry:created(Entry),
    %% Here we asume nodes keep their names
    case MyNode == Node andalso Created < Now of
        true ->
            %% This entry should have been deleted when node crashed or shutdown
            _ = lager:debug(
                "Removing stale entry from plum_db; entry=~p", [Entry]),
            _ = remove(Entry),
            ok;
        false ->
            _ = add_to_tuplespace(Entry),
            ok
    end.


%% @private
take_from_tuplespace(Key) ->
    RealmUri = bondy_registry_entry:realm_uri(Key),
    Type = bondy_registry_entry:type(Key),
    Tab = partition_table(Type, RealmUri),
    %% We remove the entry from the registry space
    case ets:take(Tab, Key) of
        [] ->
            {error, not_found};
        [Entry] ->
            %% We delete the entry from the registry trie
            TrieKey = trie_key(Entry),
            ok = case art_server:take(TrieKey, trie(Type)) of
                {value, _} ->
                    ok;
                error ->
                    _ = lager:debug(
                        "Failed deleting element from trie; key=~p", [TrieKey]),
                    ok
            end,

            %% We decrement the Uri count
            Uri = bondy_registry_entry:uri(Entry),
            decr_counter(Tab, {RealmUri, Uri}, 1),
            {ok, Entry}
    end.


%% @private
maybe_resolve(Object) ->
    case plum_db_object:value_count(Object) > 1 of
        true ->
            %% Entries are immutable so we either get an Entry or a tombstone
            Resolver = fun
                ('$deleted', _) -> '$deleted';
                (_, '$deleted') -> '$deleted'
            end,
            Resolved = plum_db_object:resolve(Object, Resolver),
            plum_db_object:value(Resolved);
        false ->
            plum_db_object:value(Object)
    end.

%% @private
maybe_fun(undefined, _) ->
    undefined;

maybe_fun(Fun, Ctxt) when is_function(Fun, 2) ->
    fun(Entry) -> Fun(Entry, Ctxt) end.


%% @private
maybe_execute(undefined, _) ->
    ok;

maybe_execute(Fun, Entry) when is_function(Fun, 1) ->
    _ = Fun(bondy_registry_entry:to_details_map(Entry)),
    ok.


%% @private
do_remove(Key, Ctxt, Task) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    case take_from_tuplespace(Key) of
        {ok, Entry} ->
            MaybeFun = maybe_fun(Task, Ctxt),
            maybe_execute(MaybeFun, Entry);
        {error, not_found} ->
            ok
    end,
    %% We delete the entry from plum_db. This will broadcast the delete
    %% amongst the nodes in the cluster
    plum_db:delete(?FULLPREFIX(RealmUri), Key).


%% @private
do_remove_all(?EOT, _, _) ->
    ok;

do_remove_all({[], ?EOT}, _, _) ->
    ok;

do_remove_all({[], Cont}, SessionId, Fun) ->
    do_remove_all(ets:match(Cont), SessionId, Fun);

do_remove_all({[Term|T], Cont}, SessionId, Fun) ->
    Sid = bondy_registry_entry:session_id(Term),
    case SessionId =:= Sid orelse SessionId == '_' of
        true ->
            EntryKey = bondy_registry_entry:key(Term),
            %% Term is entry_key
            RealmUri = bondy_registry_entry:realm_uri(EntryKey),
            case take_from_tuplespace(EntryKey) of
                {ok, Term} ->
                    %% We delete the entry from plum_db.
                    %% This will broadcast the delete
                    %% amongst the nodes in the cluster
                    ok = plum_db:delete(?FULLPREFIX(RealmUri), EntryKey),
                    %% Finally, we perform the Fun if any
                    maybe_execute(Fun, Term);
                {error, not_found} ->
                    _ = lager:debug(
                        "Failed deleting element from space; key=~p",
                        [Term]
                    ),
                    ok
            end,
            %% We continue traversing the ets table
            do_remove_all({T, Cont}, SessionId, Fun);
        false ->
            %% No longer our session
            ok
    end.


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


%% -----------------------------------------------------------------------------
%% @private
%% @doc Locates the tuplespace partition ets table name assigned to the Realm
%% @end
%% -----------------------------------------------------------------------------
-spec partition_table(bondy_registry_entry:entry_type(), uri()) -> ets:tid().
partition_table(subscription, RealmUri) ->
    tuplespace:locate_table(?SUBSCRIPTION_TABLE_NAME, RealmUri);

partition_table(registration, RealmUri) ->
    tuplespace:locate_table(?REGISTRATION_TABLE_NAME, RealmUri).


%% @private
-spec do_add(bondy_registry_entry:t()) ->
    {ok, bondy_registry_entry:t(), IsFirstEntry :: boolean()}.

do_add(Entry) ->
    ok = add_to_db(Entry),
    add_to_tuplespace(Entry).


%% @private
add_to_tuplespace(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    Type = bondy_registry_entry:type(Entry),
    EntryKey = bondy_registry_entry:key(Entry),

    %% We insert the entry in tuplespace
    SSTab = partition_table(Type, RealmUri),
    true = ets:insert(SSTab, Entry),

    %% We add entrye to the trie
    _ = art_server:set(trie_key(Entry), EntryKey, trie(Type)),

    Map = bondy_registry_entry:to_details_map(Entry),
    IsFirstEntry = incr_counter(SSTab, {RealmUri, Uri}, 1) =:= 1,
    {ok, Map, IsFirstEntry}.


%% @private
add_to_db(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    %% We insert the entry in plum_db. This will broadcast the delete
    %% amongst the nodes in the cluster
    Key = bondy_registry_entry:key(Entry),
    plum_db:put(?FULLPREFIX(RealmUri), Key, Entry).


%% @private
trie(registration) -> ?REGISTRATION_TRIE_NAME;
trie(subscription) -> ?SUBSCRIPTION_TRIE_NAME.


-spec trie_key(bondy_registry_entry:t()) -> art:key().
trie_key(Entry) ->
    Policy = bondy_registry_entry:match_policy(Entry),
    trie_key(Entry, Policy).



-spec trie_key(bondy_registry_entry:t(), binary()) -> art:key().
trie_key(Entry, Policy) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Node = list_to_binary(atom_to_list(bondy_registry_entry:node(Entry))),
    SessionId = integer_to_binary(bondy_registry_entry:session_id(Entry)),
    Id = integer_to_binary(bondy_registry_entry:id(Entry)),
    Uri = bondy_registry_entry:uri(Entry),

    %% art uses $\31 for separating the suffixes of the key so we cannot
    %% use it.
    %% WAMP reserves the use of $\s, $#, $. and $, for the broker,
    %% so we could use them but MQTT uses $+ and $# for wilcard patterns
    %% that rules out $#, so we use $,
    Key = <<RealmUri/binary, $,, Uri/binary>>,

    %% We adde Node, SessionId, Id as suffix to disambiguate the entry in the
    %% trie
    case Policy of
        ?PREFIX_MATCH ->
            {<<Key/binary, ?ANY/binary>>, Node, SessionId, Id};
        _ ->
            {Key, Node, SessionId, Id}
    end.


%% @private
-spec trie_ms(map()) -> ets:match_spec() | undefined.

trie_ms(Opts) ->
    %% {{$1, $2, $2, $4}, $5},
    %% {{Key, Node, SessionIdBin, EntryIdBin}, '_'},
    Conds1 = case maps:find(eligible, Opts) of
        {ok, []} ->
            %% Non eligible! Most probably a mistake but we need to
            %% respect the semantics
            throw(non_eligible_entries);
        {ok, EligibleIds} ->
            %% We include the provided SessionIds
            [
                maybe_or(
                    [
                        {'=:=', '$3', {const, integer_to_binary(S)}}
                        || S <- EligibleIds
                    ]
                )
            ];
        error ->
            []
    end,
    Conds2 = case maps:find(exclude, Opts) of
        {ok, []} ->
            Conds1;
        {ok, ExcludedIds} ->
            %% We exclude the provided SessionIds
            ExclConds = maybe_and(
                [
                    {'=/=', '$3', {const, integer_to_binary(S)}}
                    || S <- ExcludedIds
                ]
            ),
            [ExclConds | Conds1];
        error ->
            Conds1
    end,

    case Conds2 of
        [] ->
            undefined;
        [_] ->
            [
                {
                    {{'_', '_', '$3', '_'}, '_'}, Conds2, ['$_']
                }
            ];
        _ ->
            Conds3 = [list_to_tuple(['andalso' | Conds2])],
            [
                {
                    {{'_', '_', '$3', '_'}, '_'}, Conds3, ['$_']
                }
            ]
    end.


maybe_and([Clause]) ->
    Clause;
maybe_and(Clauses) ->
    list_to_tuple(['and' | Clauses]).


maybe_or([Clause]) ->
    Clause;
maybe_or(Clauses) ->
    list_to_tuple(['or' | Clauses]).


%% @private
lookup_entries(Type, {Keys, ?EOT}) ->
    {do_lookup_entries(Keys, Type, []), ?EOT};

lookup_entries(Type, {Keys, Cont}) ->
    {do_lookup_entries(Keys, Type, []), {Type, Cont}}.


%% @private
do_lookup_entries([], _, Acc) ->
    lists:reverse(Acc);

do_lookup_entries([{_TrieKey, EntryKey}|T], Type, Acc) ->
    RealmUri = bondy_registry_entry:realm_uri(EntryKey),
    case ets:lookup(partition_table(Type, RealmUri), EntryKey) of
        [] ->
            do_lookup_entries(T, Type, Acc);
        [Entry] ->
            do_lookup_entries(T, Type, [Entry|Acc])
    end.

