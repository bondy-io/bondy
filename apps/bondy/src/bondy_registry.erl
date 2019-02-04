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
%% The registry is stored both in memory (tuplespace) and disk (plum_db).
%% Also a trie-based indexed is used for exact and prefix matching currently
%% while support for wilcard matching is soon to be supported.
%%
%% This module also provides a singleton server to perform the initialisation
%% of the tuplespace from the plum_db copy.
%% The tuplespace library protects the ets tables that constitute the in-memory
%% store while the art library also protectes the ets tables behind the trie,
%% so they can survive in case the singleton dies.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_registry).
-behaviour(gen_server).

-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").


%% PLUM_DB
-define(REG_PREFIX, registry_registrations).
-define(SUBS_PREFIX, registry_subscriptions).
-define(PREFIXES, [?REG_PREFIX, ?SUBS_PREFIX]).
-define(REG_FULL_PREFIX(RealmUri), {?REG_PREFIX, RealmUri}).
-define(SUBS_FULL_PREFIX(RealmUri), {?SUBS_PREFIX, RealmUri}).
%% ART TRIES
-define(ANY, <<"*">>).
-define(SUBSCRIPTION_TRIE, bondy_subscription_trie).
-define(REGISTRATION_TRIE, bondy_registration_trie).
-define(TRIES, [?SUBSCRIPTION_TRIE, ?REGISTRATION_TRIE]).
%% OTHER
-define(MAX_LIMIT, 10000).
-define(LIMIT(Opts), min(maps:get(limit, Opts, ?MAX_LIMIT), ?MAX_LIMIT)).

-record(state, {
    start_time = calendar:local_time()  :: calendar:datetime()
}).


-type eot()                 ::  ?EOT.
-type continuation()        ::  {
    bondy_registry_entry:entry_type(),
    plum_db:continuation()
}.


-type task() :: fun(
    (bondy_registry_entry:details_map(), bondy_context:t()) ->
        ok
).


-export_type([eot/0]).
-export_type([continuation/0]).


-export([add/4]).
-export([add_local_subscription/4]).
-export([entries/1]).
-export([entries/2]).
-export([entries/4]).
-export([entries/5]).
-export([info/0]).
-export([info/1]).
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
-export([init/0]).


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
%% @end
%% -----------------------------------------------------------------------------
init() ->
    %% We first validate the config
    [
        begin
            case plum_db:prefix_type(Prefix) of
                disk ->
                    Message = iolist_to_binary(io_lib:format(
                        "Registry prefix ~p should be configured as ram or ram_disk in plum_db",
                        [Prefix]
                    )),
                    exit(Message);
                _ ->
                    ok
            end
        end || Prefix <- ?PREFIXES
    ],
    gen_server:call(?MODULE, init_tries, 10*60*1000).



%% -----------------------------------------------------------------------------
%% @doc Returns information about the registry
%% @end
%% -----------------------------------------------------------------------------
info() ->
    [{Trie, art:info(Trie)} || Trie <- ?TRIES].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
info(?REGISTRATION_TRIE) ->
    art:info(?REGISTRATION_TRIE);

info(?SUBSCRIPTION_TRIE) ->
    art:info(?SUBSCRIPTION_TRIE).



%% -----------------------------------------------------------------------------
%% @doc A function used internally by Bondy to register local subscribers
%% and callees.
%% @end
%% -----------------------------------------------------------------------------
-spec add_local_subscription(uri(), uri(), map(), pid()) ->
    {ok, bondy_registry_entry:details_map(), IsFirstEntry :: boolean()}
    | {error, {already_exists, bondy_registry_entry:details_map()}}.


add_local_subscription(RealmUri, Uri, Opts, Pid) ->
    Node = bondy_peer_service:mynode(),
    Type = subscription,

    Pattern = bondy_registry_entry:pattern(
        Type, RealmUri, Node, undefined, Uri, Opts),
    TrieKey = trie_key(Pattern),
    Trie = trie(Type),

    case art_server:match(TrieKey, Trie) of
        [] ->
            PeerId = {RealmUri, Node, undefined, Pid},
            RegId = case maps:find(subscription_id, Opts) of
                {ok, N} -> N;
                error -> bondy_utils:get_id(global)
            end,
            Entry = bondy_registry_entry:new(Type, RegId, PeerId, Uri, Opts),
            %% REVIEW this  will broadcast the local subscription to other nodes
            %% se we need to be sure not to duplicate events
            do_add(Entry);

        [{_, EntryKey}] ->
            %% In case of receiving a "SUBSCRIBE" message from the same
            %% _Subscriber_ and to already added topic, _Broker_ should
            %% answer with "SUBSCRIBED" message, containing the existing
            %% "Subscription|id".
            FullPrefix = full_prefix(Type, RealmUri),
            Entry =  plum_db:get(FullPrefix, EntryKey),
            Map = bondy_registry_entry:to_details_map(Entry),
            {error, {already_exists, Map}}
    end.


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
    {RealmUri, Node, SessionId, _} = PeerId,
    Pattern = case Type of
        registration ->
            %% A session can register a procedure multiple times if
            %% shared_registration is enabled
            %% So we do not match SessionId
            bondy_registry_entry:pattern(
                Type, RealmUri, '_', '_', Uri, Options);

        subscription ->
            bondy_registry_entry:pattern(
                    Type, RealmUri, Node, SessionId, Uri, Options)
    end,
    TrieKey = trie_key(Pattern),
    Trie = trie(Type),

    case art_server:match(TrieKey, Trie) of
        [] ->
            %% No matching registrations at all exists or
            %% No matching subscriptions for this SessionId exists
            Entry = bondy_registry_entry:new(Type, PeerId, Uri, Options),
            do_add(Entry);

        [{_, EntryKey}] when Type == subscription ->
            %% In case of receiving a "SUBSCRIBE" message from the same
            %% _Subscriber_ and to already added topic, _Broker_ should
            %% answer with "SUBSCRIBED" message, containing the existing
            %% "Subscription|id".
            FullPrefix = full_prefix(Type, RealmUri),
            Entry =  plum_db:get(FullPrefix, EntryKey),
            Map = bondy_registry_entry:to_details_map(Entry),
            {error, {already_exists, Map}};

        [{_, EntryKey} | _] when Type == registration ->
            EOpts = bondy_registry_entry:options(EntryKey),
            SharedEnabled = bondy_context:is_feature_enabled(
                Ctxt, callee, shared_registration),
            NewPolicy = maps:get(invoke, Options, ?INVOKE_SINGLE),
            PrevPolicy = maps:get(invoke, EOpts, ?INVOKE_SINGLE),
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
                    FullPrefix = full_prefix(Type, RealmUri),
                    Entry =  plum_db:get(FullPrefix, EntryKey),
                    Map = bondy_registry_entry:to_details_map(Entry),
                    {error, {already_exists, Map}}
            end
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% Removes all entries matching the context's realm and session_id (if any).
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(bondy_registry_entry:entry_type(), bondy_context:t()) -> ok.

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
            Pattern = bondy_registry_entry:key_pattern(
                Type, RealmUri, Node, SessionId, '_'),
            MaybeFun = maybe_fun(Task, Ctxt),
            MatchOpts = [
                {limit, 100},
                {resolver, lww},
                {allow_put, false},
                {remove_tombstones, true}
            ],
            Matches = plum_db:match(
                full_prefix(Type, RealmUri), Pattern, MatchOpts),
            do_remove_all(Matches, SessionId, MaybeFun)
    end;

remove_all(_, _, _) ->
    ok.


%% -----------------------------------------------------------------------------
%% @doc Removes all registry entries of type Type, for a {RealmUri, Node
%% SessionId} relation.
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(
    bondy_registry_entry:entry_type(),
    RealmUri :: uri(),
    Node :: atom(),
    SessionId :: id()) -> [bondy_registry_entry:t()].

remove_all(Type, RealmUri, Node, SessionId) ->
    Pattern = bondy_registry_entry:key_pattern(
        Type, RealmUri, Node, SessionId, '_'),
    MatchOpts = [
        {limit, 100},
        {remove_tombstones, true},
        {resolver, lww},
        {allow_put, false}
    ],
    Matches = plum_db:match(full_prefix(Type, RealmUri), Pattern, MatchOpts),
    do_remove_all(Matches, SessionId, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(Key :: bondy_registry_entry:entry_key()) -> any().

lookup(Key) ->
    Type = bondy_registry_entry:type(Key),
    RealmUri = bondy_registry_entry:realm_uri(Key),
    case plum_db:get(full_prefix(Type, RealmUri), Key) of
        undefined ->
            {error, not_found};
        Entry ->
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
lookup(Type, EntryId, RealmUri, _Details) when is_integer(EntryId) ->
    Pattern = bondy_registry_entry:key_pattern(
        Type, RealmUri, '_', '_', EntryId),
    MatchOpts = [{remove_tombstones, true}, {resolver, lww}],
    %% TODO match Details
    case plum_db:match(full_prefix(Type, RealmUri), Pattern, MatchOpts) of
        [] ->
            {error, not_found};
        [{_, Entry}] ->
            Entry
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(bondy_registry_entry:t()) -> ok.

remove(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Key = bondy_registry_entry:key(Entry),
    case plum_db:take(full_prefix(Entry), Key) of
        undefined ->
            ok;
        Entry ->
            Uri = bondy_registry_entry:uri(Entry),
            ok = delete_from_trie(Entry),
            _ = decr_counter(RealmUri, Uri, 1),
            ok
    end.


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
    Pattern = bondy_registry_entry:key_pattern(
        Type, RealmUri, Node, SessionId, '_'),
    Opts = [{remove_tombstones, true}, {resolver, lww}],
    Matches = plum_db:match(full_prefix(Type, RealmUri), Pattern, Opts),
    [V || {_, V} <- Matches].




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
    Pattern = bondy_registry_entry:key_pattern(
        Type, RealmUri, Node, SessionId, '_'),
    Opts = [{limit, Limit}, {remove_tombstones, true}, {resolver, lww}],
    Matches = plum_db:match(full_prefix(Type, RealmUri), Pattern, Opts),
    [V || {_, V} <- Matches].



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
    case plum_db:match(Cont) of
        ?EOT ->
            {[], ?EOT};
        {L, NewCont} ->
            {[V || {_, V} <- L], {Type, NewCont}}
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



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    %% TODO DO NOT DO THIS, LOAD only data from particular node when we get an update from peerservice. Make sure we load before the first Exchange or actually force and exchange and then load.
    process_flag(trap_exit, true),

    %% We initialise the tries
    {ok, _} = art_server_sup:start_trie(?REGISTRATION_TRIE),
    {ok, _} = art_server_sup:start_trie(?SUBSCRIPTION_TRIE),

    %% We subscribe to plum_db_events change notifications. We get updates
    %% in handle_info so that we can we update the tries
    MS = [{
        %% {{{_, _} = FullPrefix, Key}, NewObj, ExistingObj}
        {{{'$1', '_'}, '_'}, '_', '_'},
        [
            {'orelse',
                {'=:=', ?REG_PREFIX, '$1'},
                {'=:=', ?SUBS_PREFIX, '$1'}
            }
        ],
        [true]
    }],
    ok = plum_db_events:subscribe(object_update, MS),

    {ok, #state{}}.


handle_call(init_tries, _From, State0) ->
    _ = lager:info("Initialising registry trie from store."),
    State = init_tries(State0),
    {reply, ok, State};

handle_call(Event, From, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p, from=~p", [Event, From]),
    {noreply, State}.


handle_cast(Event, State) ->
    _ = lager:error(
        "Error handling call, reason=unsupported_event, event=~p", [Event]),
    {noreply, State}.


handle_info(
    {plum_db_event, object_update, {{{_, _}, Key}, Obj, PrevObj}},
    State) ->
    _ = lager:debug(
        "Object update notification; object=~p, previous=~p",
        [Obj, PrevObj]
    ),
    Node = bondy_registry_entry:node(Key),
    _ = case Node =:= bondy_peer_service:mynode() of
        true ->
            %% This should not be happenning as only we can change our
            %% registrations. We do nothing.
            ok;
        false ->
            case maybe_resolve(Obj) of
                '$deleted' when PrevObj =/= undefined ->
                    %% We do this since we need to know the Match Policy of the
                    %% entry in order to generate the trie key and we want to
                    %% avoid including yet another element to the entry_key
                    Reconciled = plum_db_object:resolve(PrevObj, lww),
                    OldEntry = plum_db_object:value(Reconciled),
                    %% This works because registry entries are immutable
                    _ = delete_from_trie(OldEntry);
                '$deleted' when PrevObj == undefined ->
                    %% We got a delete for an entry we do not know anymore.
                    %% This happens when the registry has just been reset
                    %% as we do not persist registrations any more
                    ok;
                Entry ->
                    %% We only add to trie
                    add_to_trie(Entry)
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
init_tries(State0) ->
    Opts = [{resolver, lww}],
    Iterator0 = plum_db:iterator(?REG_FULL_PREFIX('_'), Opts),
    {ok, State1} = init_tries(Iterator0, State0),
    Iterator1 = plum_db:iterator(?SUBS_FULL_PREFIX('_'), Opts),
    init_tries(Iterator1, State1).


%% @private
init_tries(Iterator, #state{start_time = Now} = State) ->
    case plum_db:iterator_done(Iterator) of
        true ->
            ok = plum_db:iterator_close(Iterator),
            {ok, State};
        false ->
            ok = case plum_db:iterator_key_value(Iterator) of
                {_, '$deleted'} ->
                    ok;
                {_, Entry} ->
                    maybe_add_to_trie(Entry, Now)
            end,
            init_tries(plum_db:iterate(Iterator), State)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc In the event of Bondy not terminating properly, the last sessions'
%% registrations will still be in the DB. This function ensures no stale entry
%% is restore from db to memory and that they are removed from the db.
%% @end
%% -----------------------------------------------------------------------------
maybe_add_to_trie(Entry, Now) ->
    MyNode = bondy_peer_service:mynode(),
    Node = bondy_registry_entry:node(Entry),
    Created = bondy_registry_entry:created(Entry),
    %% Here we asume nodes keep their names
    case MyNode == Node andalso Created < Now of
        true ->
            %% This entry should have been deleted when node crashed or shutdown
            _ = lager:debug(
                "Removing stale entry from plum_db; entry=~p", [Entry]),
            _ = delete_from_trie(Entry),
            ok;
        false ->
            _ = add_to_trie(Entry),
            ok
    end.


%% @private
delete_from_trie(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Type = bondy_registry_entry:type(Entry),
    EntryKey = bondy_registry_entry:key(Entry),
    TrieKey = trie_key(Entry),

    case art_server:take(TrieKey, trie(Type)) of
        {value, EntryKey} ->
            %% Entry should match because entries are immutable
            Uri = bondy_registry_entry:uri(Entry),
            _ = decr_counter(RealmUri, Uri, 1),
            ok;
        error ->
            _ = lager:debug(
                "Failed deleting element from trie; key=~p", [TrieKey]),
            ok
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
    Type = bondy_registry_entry:type(Key),
    %% We delete the entry from plum_db. This will broadcast the delete
    %% amongst the nodes in the cluster
    case plum_db:take(full_prefix(Type, RealmUri), Key) of
        undefined ->
            ok;
        Entry ->
            ok = delete_from_trie(Entry),
            maybe_execute(maybe_fun(Task, Ctxt), Entry)
    end.


%% @private
do_remove_all(?EOT, _, _) ->
    ok;

do_remove_all({[], ?EOT}, _, _) ->
    ok;

do_remove_all({[], Cont}, SessionId, Fun) ->
    do_remove_all(plum_db:match(Cont), SessionId, Fun);

do_remove_all({[{_, Entry}|T], Cont}, SessionId, Fun) ->
    Sid = bondy_registry_entry:session_id(Entry),
    case SessionId =:= Sid orelse SessionId == '_' of
        true ->
            EntryKey = bondy_registry_entry:key(Entry),
            ok = delete_from_trie(Entry),
            %% We delete the entry from plum_db.
            %% This will broadcast the delete
            %% amongst the nodes in the cluster
            ok = plum_db:delete(full_prefix(Entry), EntryKey),
            %% Finally, we perform the Fun if any
            ok = maybe_execute(Fun, Entry),
            %% We continue traversing
            do_remove_all({T, Cont}, SessionId, Fun);
        false ->
            %% No longer our session
            ok
    end.


%% @private
incr_counter(RealmUri, Uri,  N) ->
    Tab = tuplespace:locate_table(bondy_registry_state, RealmUri),
    Default = {counter, Uri, 0},
    ets:update_counter(Tab, Uri, {3, N}, Default).


%% @private
decr_counter(RealmUri, Uri, N) ->
    Tab = tuplespace:locate_table(bondy_registry_state, RealmUri),
    Default = {counter, Uri, 0},
    case ets:update_counter(Tab, Uri, {3, -N, 0, 0}, Default) of
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
-spec prefix(bondy_registry_entry:entry_type(), uri() | '_') ->
    term().
prefix(subscription, RealmUri) ->
    ?SUBS_FULL_PREFIX(RealmUri);

prefix(registration, RealmUri) ->
    ?REG_FULL_PREFIX(RealmUri).


%% @private
-spec do_add(bondy_registry_entry:t()) ->
    {ok, bondy_registry_entry:t(), IsFirstEntry :: boolean()}.

do_add(Entry) ->
    ok = add_to_db(Entry),
    add_to_trie(Entry).


%% @private
add_to_trie(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    Type = bondy_registry_entry:type(Entry),
    EntryKey = bondy_registry_entry:key(Entry),

    %% We add entry to the trie
    _ = art_server:set(trie_key(Entry), EntryKey, trie(Type)),

    Map = bondy_registry_entry:to_details_map(Entry),
    IsFirstEntry = incr_counter(RealmUri, Uri, 1) =:= 1,
    {ok, Map, IsFirstEntry}.


%% @private
add_to_db(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    %% We insert the entry in plum_db. This will broadcast the delete
    %% amongst the nodes in the cluster
    Type = bondy_registry_entry:type(Entry),
    Key = bondy_registry_entry:key(Entry),
    plum_db:put(full_prefix(Type, RealmUri), Key, Entry).


%% @private
full_prefix(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Type = bondy_registry_entry:type(Entry),
    full_prefix(Type, RealmUri).

%% @private
full_prefix(registration, RealmUri) -> ?REG_FULL_PREFIX(RealmUri);
full_prefix(subscription, RealmUri) -> ?SUBS_FULL_PREFIX(RealmUri).

trie(registration) -> ?REGISTRATION_TRIE;
trie(subscription) -> ?SUBSCRIPTION_TRIE.


-spec trie_key(bondy_registry_entry:t() | bondy_registry_entry:key()) ->
    art:key().
trie_key(Entry) ->
    Policy = bondy_registry_entry:match_policy(Entry),
    trie_key(Entry, Policy).


%% @private
-spec trie_key(
    bondy_registry_entry:t() | bondy_registry_entry:key(), binary()) ->
    art:key().

trie_key(Entry, Policy) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Node = list_to_binary(atom_to_list(bondy_registry_entry:node(Entry))),
    SessionId = case bondy_registry_entry:session_id(Entry) of
        '_' ->
            <<>>;
        undefined ->
            <<"undefined">>;
        X ->
            integer_to_binary(X)
    end,
    Id = case bondy_registry_entry:id(Entry) of
        '_' ->
            %% This will act as a pattern
            <<>>;
        _ when SessionId == <<>> ->
            %% As we currently do not support wilcard matching in art, we turn
            %% this into a prefix matching query
            <<>>;
        Y ->
            integer_to_binary(Y)
    end,
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
    case plum_db:get(prefix(Type, RealmUri), EntryKey) of
        undefined ->
            do_lookup_entries(T, Type, Acc);
        Entry ->
            do_lookup_entries(T, Type, [Entry|Acc])
    end.


%% maybe_trigger_exchange(_) ->
%%     PeerService = bondy_peer_service:peer_service(),
%%     case PeerService:members() of
%%         {ok, []} ->
%%             ok;
%%         {ok, _} ->
%%             %% We give plumtree_broadcast time to process the event
%%             %% and update its state
%%             timer:sleep(1000),
%%             %% We manually force an exchange
%%             plumtree_broadcast ! exchange_tick,
%%             ok
%%     end.