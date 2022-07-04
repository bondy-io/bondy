%% =============================================================================
%%  bondy_registry.erl -
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
%% @doc
%% An in-memory registry for PubSub subscriptions and Routed RPC registrations,
%% providing pattern matching capabilities including support for WAMP's
%% version 2.0 match policies (exact, prefix and wildcard).
%%
%% The registry is stored both in an in-memory distributed table (plum_db).
%% Also an in-memory trie-based indexed (materialised vieq) is used for exact
%% and prefix matching.
%%
%% This module also provides a singleton server to perform the initialisation
%% of the trie from the plum_db tables.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_registry).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_plum_db.hrl").


%% PLUM_DB
-define(REG_FULL_PREFIX(RealmUri),
    {?PLUM_DB_REGISTRATION_TAB, RealmUri}
).
-define(SUBS_FULL_PREFIX(RealmUri),
    {?PLUM_DB_SUBSCRIPTION_TAB, RealmUri}
).

%% ART TRIES
-define(SUBSCRIPTION_TRIE, bondy_subscription_trie).
-define(REGISTRATION_TRIE, bondy_registration_trie).
-define(TRIES, [?SUBSCRIPTION_TRIE, ?REGISTRATION_TRIE]).

% -define(REGISTRATION_INDEX, bondy_registration_index).

%% OTHER
% -define(MAX_LIMIT, 10000).
% -define(LIMIT(Opts), min(maps:get(limit, Opts, ?MAX_LIMIT), ?MAX_LIMIT)).

-record(state, {
    start_time = erlang:system_time(second)  :: pos_integer()
}).


-type eot()                 ::  ?EOT.
-type continuation()        ::  {
    bondy_registry_entry:entry_type(),
    plum_db:continuation()
}.
-type continuation_or_eot() :: continuation_or_eot().

-type task() :: fun((bondy_registry_entry:t(), bondy_context:t()) -> ok).


-export_type([eot/0]).
-export_type([continuation/0]).


-export([add/1]).
-export([add/4]).
-export([add/5]).
-export([entries/1]).
-export([entries/2]).
-export([entries/3]).
-export([entries/4]).
-export([info/0]).
-export([info/1]).
-export([init_tries/0]).
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

%% PLUM_DB PREFIX CALLBACKS
-export([on_object_updated/3]).
-export([will_merge/3]).


%% GEN_SERVER CALLBACKS
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Starts the registry server. The server maintains the in-memory tries we
%% use for matching and it is also a subscriber for plum_db broadcast and AAE
%% events in order to keep the trie up-to-date with plum_db.
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
init_tries() ->
    gen_server:call(?MODULE, init_tries, timer:minutes(10)).


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
%% @doc
%% Adds an existing entry to the registry.
%%
%% Adding an already existing entry is treated differently based on whether the
%% entry is a registration or a subscription.
%%
%% According to the WAMP specification, in the case of a subscription that was
%% already added before by the same _Subscriber_, the _Broker_ should not fail
%% and answer with a "SUBSCRIBED" message, containing the existing
%% "Subscription|id". So in this case this function returns
%% {ok, bondy_registry_entry:t(), boolean()}.
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
-spec add(bondy_registry_entry:t()) ->
    {ok, IsFirstEntry :: boolean()} | {error, already_exists} | no_return().

add(Entry) ->
    bondy_registry_entry:is_entry(Entry)
        orelse error(badarg),

    case do_add(Entry) of
        {ok, _, IsFirstEntry} ->
            {ok, IsFirstEntry};

        {error, {already_exists, _}} ->
            {error, already_exists}
    end.


%% -----------------------------------------------------------------------------
%% @doc @see add/5
%% @end
%% -----------------------------------------------------------------------------
-spec add(
    Type :: bondy_registry_entry:entry_type(),
    RegUri :: uri(),
    Opts :: map(),
    Ctxt :: bondy_context:t()) ->
    {ok, Entry :: bondy_registry_entry:t(), IsFirstEntry :: boolean()}
    | {error, {already_exists, bondy_registry_entry:t()} | any()}.

add(Type, Uri, Opts, Ctxt) when is_map(Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Ref = bondy_context:ref(Ctxt),
    add(Type, Uri, Opts, RealmUri, Ref).


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
%% {ok, bondy_registry_entry:t(), boolean()}.
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
    Type :: bondy_registry_entry:entry_type(),
    RegUri :: uri(),
    Opts :: map(),
    RealmUri :: uri(),
    Ref :: bondy_ref:t()) ->
    {ok, Entry :: bondy_registry_entry:t(), IsFirstEntry :: boolean()}
    | {error, {already_exists, bondy_registry_entry:t()} | any()}.

add(registration, Uri, Opts0, RealmUri, Ref) ->
    case bondy_ref:target_type(Ref) of
        callback ->
            add_callback(Uri, Opts0, RealmUri, Ref);
        _ ->
            add_registration(Uri, Opts0, RealmUri, Ref)
    end;

add(subscription = Type, Uri, Opts, RealmUri, Ref) ->
    Target = bondy_ref:target(Ref),
    SessionId = case bondy_ref:session_id(Ref) of
        undefined -> '_';
        Val -> Val
    end,

    %% We do a full match, we should get none or 1 results
    Extra = #{target => Target, session_id => SessionId},
    Pattern = bondy_registry_entry:pattern(Type, RealmUri, Uri, Opts, Extra),
    TrieKey = trie_key(Pattern),

    %% We use the trie to match as we need the Topic Uri in the key
    case art_lookup(TrieKey, ?SUBSCRIPTION_TRIE) of
        [] ->
            %% No matching subscriptions for this SessionId exists
            RegId = subscription_id(RealmUri, Opts),
            Entry = bondy_registry_entry:new(
                Type, RegId, RealmUri, Ref, Uri, Opts
            ),
            do_add(Entry);

        [{_, EntryKey}|_] ->
            %% In case of receiving a "SUBSCRIBE" message from the same
            %% _Subscriber_ and to already added topic, _Broker_ should
            %% answer with "SUBSCRIBED" message, containing the existing
            %% "Subscription|id".
            FullPrefix = full_prefix(Type, RealmUri),
            Entry = plum_db:get(FullPrefix, EntryKey),
            {error, {already_exists, Entry}}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(Key :: bondy_registry_entry:key()) ->
    bondy_registry_entry:t() | {error, not_found}.

lookup(Key) ->
    Type = bondy_registry_entry:type(Key),
    RealmUri = bondy_registry_entry:realm_uri(Key),
    FP = full_prefix(Type, RealmUri),

    case plum_db:get(FP, Key) of
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
        RealmUri, #{entry_id => EntryId}
    ),
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
        StoredEntry ->
            Uri = bondy_registry_entry:uri(StoredEntry),
            ok = delete_from_trie(StoredEntry),
            _ = decr_counter(RealmUri, Uri, 1),
            ok
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(bondy_registry_entry:entry_type(), id(), bondy_context:t()) ->
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
    optional(task())) -> ok.

remove(Type, EntryId, Ctxt, Task)
when Task == undefined orelse is_function(Task, 1)->
    RealmUri = bondy_context:realm_uri(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    Prefix = full_prefix(Type, RealmUri),

    Pattern = bondy_registry_entry:key_pattern(
        RealmUri, #{session_id => SessionId, entry_id => EntryId}
    ),

    MatchOpts = [
        {limit, 1},
        {resolver, lww},
        {remove_tombstones, true}
    ],

    case plum_db:match(Prefix, Pattern, MatchOpts) of
        ?EOT ->
            ok;
        {[{Key, Entry}], _} ->
            %% We delete the entry from plum_db. This will broadcast the delete
            %% amongst the nodes in the cluster
            ok = plum_db:delete(Prefix, Key),
            ok = delete_from_trie(Entry),
            maybe_execute(maybe_fun(Task, Ctxt), Entry)
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

remove_all(Type, Ctxt, Task)
when Task == undefined orelse is_function(Task, 1) ->

    case bondy_context:session_id(Ctxt) of
        undefined ->
            ?LOG_INFO(#{
                description => "Failed to remove registry contents",
                reason => "Context has no session_id"
            }),
            ok;
        SessionId ->
            RealmUri = bondy_context:realm_uri(Ctxt),
            Pattern = bondy_registry_entry:key_pattern(
                RealmUri, #{session_id => SessionId}
            ),
            MaybeFun = maybe_fun(Task, Ctxt),
            MatchOpts = [
                {limit, 100},
                {resolver, lww},
                {allow_put, false},
                {remove_tombstones, true}
            ],
            Matches = plum_db:match(
                full_prefix(Type, RealmUri), Pattern, MatchOpts
            ),
            do_remove_all(Matches, SessionId, MaybeFun)
    end.


%% -----------------------------------------------------------------------------
%% @doc Removes all registry entries of type Type, for a {RealmUri, Node
%% SessionId} relation.
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(
    bondy_registry_entry:entry_type(),
    RealmUri :: uri(),
    SessionId :: id(),
    task() | undefined) -> [bondy_registry_entry:t()].

remove_all(Type, RealmUri, SessionId, Task) ->
    Extra = #{session_id => SessionId},
    Pattern = bondy_registry_entry:key_pattern(RealmUri, Extra),

    MatchOpts = [
        {limit, 100},
        {remove_tombstones, true},
        {resolver, lww},
        {allow_put, false}
    ],
    Matches = plum_db:match(full_prefix(Type, RealmUri), Pattern, MatchOpts),
    do_remove_all(Matches, SessionId, Task).



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
    {[bondy_registry_entry:t()], continuation_or_eot()} | eot().

entries(?EOT) ->
    ?EOT;

entries({_, ?EOT}) ->
    ?EOT;

entries({Type, Cont}) when Type == registration orelse Type == subscription ->
    %% We need to add back the resolver strategy
    case plum_db:match(Cont, [{resolver, lww}]) of
        ?EOT ->
            ?EOT;
        {L, ?EOT} ->
            {[V || {_, V} <- L], ?EOT};
        {L, NewCont} ->
            {[V || {_, V} <- L], {Type, NewCont}}
    end.

%% -----------------------------------------------------------------------------
%% @doc
%% Returns the list of entries owned by the active session.
%%
%% This function is equivalent to calling {@link entries/2} with the RealmUri
%% and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(bondy_registry_entry:entry_type(), bondy_context:t()) ->
    [bondy_registry_entry:t()].

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
-spec entries(
    bondy_registry_entry:entry_type(),
    RealmUri :: uri(),
    SessionId :: id()) -> [bondy_registry_entry:t()].

entries(Type, RealmUri, SessionId) ->
    entries(Type, RealmUri, SessionId, infinity).


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
    SessionId :: id() | '_',
    Limit :: pos_integer() | infinity) ->
    [bondy_registry_entry:t()]
    | {[bondy_registry_entry:t()], continuation_or_eot()}
    | eot().

entries(Type, RealmUri, SessionId, Limit) ->
    Pattern = bondy_registry_entry:key_pattern(
        RealmUri, #{session_id => SessionId}
    ),
    Opts = [
        {limit, Limit},
        {remove_tombstones, true},
        {resolver, lww}
    ],

    case plum_db:match(full_prefix(Type, RealmUri), Pattern, Opts) of
        ?EOT ->
            ?EOT;

        {L, ?EOT} ->
            {[V || {_, V} <- L], ?EOT};

        {L, NewCont} ->
            {[V || {_, V} <- L], {Type, NewCont}};

        L when is_list(L) ->
            [V || {_, V} <- L]
    end.




%% -----------------------------------------------------------------------------
%% @doc
%% Calls {@link match/4}.
%% @end
%% -----------------------------------------------------------------------------
-spec match(
    bondy_registry_entry:entry_type(), uri(), RealmUri :: uri()) ->
    {[bondy_registry_entry:t()], continuation_or_eot()} | eot().

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
        {[bondy_registry_entry:t()], continuation_or_eot()} | eot().

match(Type, Uri, RealmUri, Opts) ->
    try
        Trie = trie(Type),
        Pattern = <<RealmUri/binary, $., Uri/binary>>,
        MS = trie_ms(Opts),

        case art_find_matches(Pattern, MS, Trie) of
            [] ->
                ?EOT;

            Result ->
                lookup_entries(Type, {Result, ?EOT})
        end

    catch
        throw:non_eligible_entries ->
            ?EOT;

        error:Reason:Stacktrace ->
            ?LOG_DEBUG(#{
                description => "Error while searching trie",
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ?EOT
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(continuation()) ->
    {[bondy_registry_entry:t()], continuation()} | eot().

match(?EOT) ->
    ?EOT;

match({_, ?EOT}) ->
    ?EOT.

%%TODO Implement trie match continuation



%% =============================================================================
%% PLUM_DB PREFIX CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc bondy_config
%% @end
%% -----------------------------------------------------------------------------
will_merge(_PKey, _New, _Old) ->
    true.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
on_object_updated(_PKey, _New, _Old) ->
    ok.



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    process_flag(trap_exit, true),

    %% We initialise the tries. art tries survive registry crashes.
    {ok, _} = art_server_sup:start_trie(?REGISTRATION_TRIE),
    {ok, _} = art_server_sup:start_trie(?SUBSCRIPTION_TRIE),

    %% We subscribe to plum_db_events change notifications. We get updates
    %% in handle_info so that we can we update the tries
    MS = [{
        %% {{{_, _} = FullPrefix, Key}, NewObj, ExistingObj}
        {{{'$1', '_'}, '_'}, '_', '_'},
        [
            {'orelse',
                {'=:=', ?PLUM_DB_REGISTRATION_TAB, '$1'},
                {'=:=', ?PLUM_DB_SUBSCRIPTION_TAB, '$1'}
            }
        ],
        [true]
    }],
    ok = plum_db_events:subscribe(object_update, MS),

    %% Every time a node goes up/down we  get an info message
    Me = self(),
    ok = partisan_peer_service:on_up('_', fun(Node) ->
        Me ! {nodeup, Node}
    end),
    ok = partisan_peer_service:on_down('_', fun(Node) ->
        Me ! {nodedown, Node} end
    ),


    {ok, #state{}}.


handle_call(init_tries, _From, State) ->
    Res = init_tries(State),
    {reply, Res, State};

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.


handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.


handle_info(
    {plum_db_event, object_update, {{{_, _}, _Key}, Obj, PrevObj}}, State) ->

    case maybe_resolve(Obj) of
        '$deleted' when PrevObj == undefined ->
            %% We got a delete for an entry we do not know anymore.
            %% This happens when the registry has just been reset
            %% as we do not persist registrations any more
            %%
            %% TODO use the future plum_db:erase instead of delete and avoid
            %% tombstones being resurfaced
            ok;

        '$deleted' when PrevObj =/= undefined ->
            %% We do this since we need to know the Match Policy of the
            %% previous entry in order to generate the trie key and we want to
            %% avoid including yet another element to the entry_key
            Reconciled = plum_db_object:resolve(PrevObj, lww),
            OldEntry = plum_db_object:value(Reconciled),
            %% This works because registry entries are immutable
            _ = delete_from_trie(OldEntry);
        Entry ->
            case bondy_registry_entry:is_local(Entry) of
                true when PrevObj =:= undefined ->
                    %% Another node is telling us we are missing an entry that
                    %% is rooted here, this is an inconsistency issue produced
                    %% by our eventual consistency model. Most probably we
                    %% crashed and we never had the chance to mark this entry
                    %% as deleted or if we did it never reached the peer node.
                    %% We need to mark it as deleted in plum_db so that the
                    %% other nodes get the event and stop trying to re-surface
                    %% it.
                    RealmUri = bondy_registry_entry:realm_uri(Entry),
                    Type = bondy_registry_entry:type(Entry),
                    Key = bondy_registry_entry:key(Entry),
                    Prefix = full_prefix(Type, RealmUri),

                    %% This will mark it as deleted and broadcast the change to
                    %% the cluster peers
                    ok = plum_db:delete(Prefix, Key);

                true when PrevObj =/= undefined ->
                    %% This case should never happen as entries are immutable
                    ok;

                false ->
                    add_to_trie(Entry)

            end
    end,

    {noreply, State};

handle_info({nodeup, _Node} = Event, State) ->
    ?LOG_DEBUG(#{
        event => Event
    }),
    {noreply, State};

handle_info({nodedown, _Node} = Event, State) ->
    %% A connection with node has gone down
    ?LOG_DEBUG(#{
        event => Event
    }),
    %% TODO deactivate (keep a bloomfilter or list) to filter future searches or delete?
    {noreply, State};

handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unexpected_event,
        event => Info
    }),
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
init_tries(State) ->
    ?LOG_NOTICE(#{
        description => "Initialising in-memory registry tries from store."
    }),

    Opts = [{resolver, lww}],

    try
        %% We initialise the registraion trie by reading the data from plum_db
        %% (in-memory tables)
        ok = init_trie(?REG_FULL_PREFIX('_'), Opts, State),

        %% We initialise the subscription trie by reading the data from plum_db
        %% (in-memory tables)
        ok = init_trie(?SUBS_FULL_PREFIX('_'), Opts, State)

    catch
        throw:Reason ->
            {error, Reason}
    end.


%% @private
init_trie(Prefix, Opts, #state{} = State) ->
    Iterator = plum_db:iterator(Prefix, Opts),
    try
        do_init_trie(Iterator, State)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description =>
                    "Error while initilising registry tries from store",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            throw(Reason)
    after
        ok = plum_db:iterator_close(Iterator)
    end.


%% @private
do_init_trie(Iterator, #state{start_time = Now} = State) ->
    case plum_db:iterator_done(Iterator) of
        true ->
            ok;

        false ->
            ok = case plum_db:iterator_key_value(Iterator) of
                {_, '$deleted'} ->
                    ok;
                {_, Entry} ->
                    maybe_add_to_trie(Entry, Now)
            end,
            do_init_trie(plum_db:iterate(Iterator), State)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc In the event of another not terminating properly, the last sessions'
%% registrations will still be in the DB. This function ensures no stale entry
%% is restore from db to memory and that they are removed from the db.
%% @end
%% -----------------------------------------------------------------------------
maybe_add_to_trie(Entry, Now) ->
    MyNode = bondy_config:nodestring(),
    EntryNode = bondy_registry_entry:nodestring(Entry),
    Created = bondy_registry_entry:created(Entry),

    %% IMPORTANT We asume nodes keep their names i.e. there is no renaming
    case MyNode == EntryNode andalso Created < Now of
        true ->
            %% This entry should have been deleted when node crashed or shutdown
            ?LOG_DEBUG(#{
                description => "Removing stale entry from plum_db",
                entry => Entry
            }),
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
    TrieKey = trie_key(Entry),
    delete_from_trie(RealmUri, TrieKey, Type).


%% @private
delete_from_trie(RealmUri, TrieKey, Type) ->
    Procedure = trie_key_realm_procedure(RealmUri, TrieKey),

    try art_delete(TrieKey, trie(Type)) of
        ok ->
            %% Entry should match because entries are immutable
            _ = decr_counter(RealmUri, Procedure, 1),
            ok

    catch
        error:Reason ->
            ?LOG_DEBUG(#{
                description => "Failed deleting entry from trie",
                key => TrieKey,
                reason => Reason
            }),
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

maybe_fun(Fun, _) when is_function(Fun, 1) ->
    Fun;

maybe_fun(Fun, Ctxt) when is_function(Fun, 2) ->
    fun(Entry) -> Fun(Entry, Ctxt) end.


%% @private
maybe_execute(undefined, _) ->
    ok;

maybe_execute(Fun, Entry) when is_function(Fun, 1) ->
    try
        _ = Fun(Entry),
        ok
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while executing user function",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.



%% @private
do_remove_all(Matches, SessionId, Fun) ->
    do_remove_all(Matches, SessionId, Fun, []).


do_remove_all(?EOT, _, Fun, Acc) ->
    _ = [maybe_execute(Fun, Entry) || Entry <- Acc],
    ok;

do_remove_all({[], ?EOT}, _, Fun, Acc) ->
    _ = [maybe_execute(Fun, Entry) || Entry <- Acc],
    ok;

do_remove_all({[], Cont}, SessionId, Fun, Acc) ->
    %% We apply the Fun here as opposed to in every iteration to minimise art
    %% trie concurrency access,
    _ = [maybe_execute(Fun, Entry) || Entry <- Acc],
    do_remove_all(plum_db:match(Cont, [{resolver, lww}]), SessionId, Fun, Acc);

do_remove_all({[{EntryKey, Entry}|T], Cont}, SessionId, Fun, Acc) ->
    Session = bondy_registry_entry:session_id(Entry),

    case SessionId =:= Session orelse SessionId == '_' of
        true ->
            ok = delete_from_trie(Entry),
            %% We delete the entry from plum_db.
            %% This will broadcast the delete
            %% amongst the nodes in the cluster
            ok = plum_db:delete(full_prefix(Entry), EntryKey),
            %% We continue traversing
            do_remove_all({T, Cont}, SessionId, Fun, [Entry|Acc]);
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
add_callback(Uri, Opts0, RealmUri, Ref) ->
    {callback, MF} = bondy_ref:target(Ref),
    Args = maps:get(callback_args, Opts0, []),

    case bondy_wamp_callback:validate_target(MF, Args) of
        true ->
            Opts1 = maps:without([callback_args], Opts0),
            %% In the case of callbacks we do not allow shared
            %% registrations.
            %% This means we cannot have multiple registrations for the
            %% same URI associated to the same Target.
            Opts = Opts1#{
                invoke => ?INVOKE_SINGLE,
                callback_args => Args
            },
            add_registration(Uri, Opts, RealmUri, Ref);
        false ->
            {error, {invalid_callback, erlang:append_element(MF, Args)}}
    end.


%% @private
add_registration(Uri, Opts, RealmUri, Ref) ->
    SessionId = bondy_ref:session_id(Ref),

    %% plum_db prefix to fetch entries
    FullPrefix = full_prefix(registration, RealmUri),

    %% A session can register a procedure even if it is already
    %% registered if shared_registration is enabled.
    %% So we do not match Node nor SessionId to retrieve other session's
    %% registrations
    Pattern = bondy_registry_entry:pattern(registration, RealmUri, Uri, Opts),

    %% We generate a trie key based on pattern
    %% We use the trie as it allows us to match the URI (which is not part of
    %% the key in plum_db)
    %% TODO To be replaced with the upcoming plum_db match specs which when
    %% used with ram tables should be idem to using ets directly.
    TrieKey = trie_key(Pattern),

    %% TODO we should limit the match to 1 result!!!
    case art_lookup(TrieKey, ?REGISTRATION_TRIE) of
        [] ->
            RegId = registration_id(RealmUri, Opts),
            Entry = bondy_registry_entry:new(
                registration, RegId, RealmUri, Ref, Uri, Opts
            ),
            do_add(Entry);

        All ->
            %% TODO here we need to explore all and resolve any inconsistencies
            %% that might have ocurred during a net split. There are two cases:
            %% 1. Multiple invoke == single registrations
            %% 2. Multiple registrations with differring invoke values
            %% If we do we need to decide which registrations to revoke.
            DuplicatedKeys = filter_duplicate_entry_keys(All, SessionId),

            %% We check this callee has not already registered this same
            %% procedure and if it did, we return the same registration Id.
            case DuplicatedKeys of
                [] ->
                    %% No duplicates but there are existing registrations done
                    %% by other calles.
                    %% We take the first one (we should have checked for
                    %% incosistencies above).
                    FirstTrieEntry = hd(All),
                    maybe_add_registration(
                        Uri, Opts, RealmUri, Ref, FullPrefix, FirstTrieEntry
                    );

                _ ->
                    %% The callee has already registered this procedure, we
                    %% return the existing
                    EntryKey = hd(DuplicatedKeys),
                    Entry = plum_db:get(FullPrefix, EntryKey),
                    {ok, Entry, false}
            end
    end.

%% @private
maybe_add_registration(
    Uri, Opts, RealmUri, Ref, FullPrefix, {_, EntryKey} = TrieEntry) ->
    %% The trie stores plum_db keys, so we fetch the entry from
    %% plum_db
    case plum_db:get(FullPrefix, EntryKey) of
        undefined ->
            %% We have an inconsistency between plum_db and the trie!
            ok = resolve_registration_inconsistency(FullPrefix, TrieEntry),
            do_add_registration(Uri, Opts, RealmUri, Ref);
        Entry ->
            EOpts = bondy_registry_entry:options(Entry),
            EPolicy = maps:get(invoke, EOpts, ?INVOKE_SINGLE),
            Policy = maps:get(invoke, Opts, ?INVOKE_SINGLE),

            %% Shared Registration (RFC 13.3.9)
            %% When shared registrations are supported, then the first
            %% Callee to register a procedure for a particular URI
            %% MAY determine that additional registrations for this URI
            %% are allowed, and what Invocation Rules to apply in case
            %% such additional registrations are made.
            %% When invoke is not 'single', Dealer MUST fail
            %% all subsequent attempts to register a procedure for the
            %% URI where the value for the invoke option does not match
            %% that of the initial registration.
            SharedRegAllowed =
                maps:get(shared_registration, Opts, false),

            %% Notice we are allowing a session to register the same URI
            %% multiple times i.e. we are not checking
            Allow =
                SharedRegAllowed
                andalso EPolicy =/= ?INVOKE_SINGLE
                andalso EPolicy =:= Policy,

            case Allow of
                true ->
                    do_add_registration(Uri, Opts, RealmUri, Ref);
                false ->
                    {error, {already_exists, Entry}}
            end
    end.


%% @private
do_add_registration(Uri, Opts, RealmUri, Ref) ->
    NewOpts = maps:without([shared_registration], Opts),
    NewEntry = bondy_registry_entry:new(
        registration, RealmUri, Ref, Uri, NewOpts
    ),
    do_add(NewEntry).


%% @private returns ok
-spec resolve_registration_inconsistency({atom(), binary()}, tuple()) -> ok.

resolve_registration_inconsistency(FullPrefix, {TrieKey, EntryKey}) ->
    Opts = [{remove_tombstones, false}],
    case plum_db:get(FullPrefix, EntryKey, Opts) of
        undefined ->
            %% The registration is not in plum_db! This should never happen
            %% We fix the trie but allow the registration to happen
            ?LOG_WARNING(#{
                description => "Inconsistency found between registry trie and registry store.",
                registry_entry_key => EntryKey
            }),
            ok;

        '$deleted' ->
            %% We fix the trie but allow the registration to happen
            RealmUri = bondy_registry_entry:realm_uri(EntryKey),
            delete_from_trie(RealmUri, TrieKey, registration),
            ok
    end.


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
    _ = art_set(trie_key(Entry), EntryKey, trie(Type)),

    IsFirstEntry = incr_counter(RealmUri, Uri, 1) =:= 1,
    {ok, Entry, IsFirstEntry}.


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
full_prefix(registration, RealmUri) ->
    ?REG_FULL_PREFIX(RealmUri);

full_prefix(subscription, RealmUri) ->
    ?SUBS_FULL_PREFIX(RealmUri).


%% @private
trie(registration) ->
    ?REGISTRATION_TRIE;

trie(subscription) ->
    ?SUBSCRIPTION_TRIE.


%% @private
-spec trie_key(bondy_registry_entry:t_or_key()) -> art:key().

trie_key(Entry) ->
    Policy = bondy_registry_entry:match_policy(Entry),
    trie_key(Entry, Policy).


%% @private
-spec trie_key(bondy_registry_entry:t_or_key(), binary()) -> art:key().

trie_key(Entry, Policy) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    SessionId0 = bondy_registry_entry:session_id(Entry),
    Nodestring = bondy_registry_entry:nodestring(Entry),


    {ProtocolSessionId, SessionId, Id} = case bondy_registry_entry:id(Entry) of
        _ when SessionId0 == '_' ->
            %% As we currently do not support wildcard matching in art:match,
            %% we turn this into a prefix matching query
            %% TODO change when wildcard matching is enabled in art.
            {<<>>, <<>>, <<>>};
        Id0 when SessionId0 == undefined ->
            {<<"undefined">>, <<"undefined">>, term_to_trie_key_part(Id0)};
        Id0 when is_binary(SessionId0) ->
            ProtocolSessionId0 = bondy_session_id:to_external(SessionId0),
            {
                term_to_trie_key_part(ProtocolSessionId0),
                term_to_trie_key_part(SessionId0),
                term_to_trie_key_part(Id0)
            }
    end,

    %% RealmUri is always ground, so we join it with URI using a $. as any
    %% other separator will not work with art:find_matches/2
    Key = <<RealmUri/binary, $., Uri/binary>>,

    %% We add Nodestring for cases where SessionId == <<>>
    case Policy of
        ?PREFIX_MATCH ->
            %% art lib uses the star char to explicitely denote a prefix
            {<<Key/binary, $*>>, Nodestring, ProtocolSessionId, SessionId, Id};
        _ ->
            {Key, Nodestring, ProtocolSessionId, SessionId, Id}
    end.


trie_key_realm_procedure(RealmUri, {Key, _, _, _, _}) ->
    <<RealmUri:(byte_size(RealmUri))/binary, $., Uri/binary>> = Key,
    Uri.

%% @private
term_to_trie_key_part('_') ->
    <<>>;

term_to_trie_key_part(Term) when is_atom(Term) ->
    atom_to_binary(Term, utf8);

term_to_trie_key_part(Term) when is_integer(Term) ->
    integer_to_binary(Term);

term_to_trie_key_part(Term) when is_binary(Term) ->
    Term.


%% @private
-spec trie_ms(map()) -> ets:match_spec() | undefined.

trie_ms(Opts) ->
    %% {{$1, $2, $3, $4, $5}, $6},
    %% {{Key, Node, ProtocolSessionId, SessionId, EntryIdBin}, '_'},
    Node = maps:get(nodestring, Opts, '_'),

    Conds1 = case maps:find(eligible, Opts) of
        {ok, []} ->
            %% Non eligible! Most probably a mistake but we need to
            %% respect the semantics
            throw(non_eligible_entries);

        {ok, EligibleIds} ->
            %% We include the provided ProtocolSessionIds
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
            %% We exclude the provided ProtocolSessionIds
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
            % {Key, Node, ProtocolSessionId, SessionId, EntryIdBin}
            [
                {
                    {{'_', Node, '$3', '_', '_'}, '_'}, Conds2, ['$_']
                }
            ];

        _ ->
            Conds3 = [list_to_tuple(['andalso' | Conds2])],
            [
                {
                    {{'_', Node, '$3', '_', '_'}, '_'}, Conds3, ['$_']
                }
            ]
    end.


%% @private
maybe_and([Clause]) ->
    Clause;

maybe_and(Clauses) ->
    list_to_tuple(['and' | Clauses]).


%% @private
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


%% @private
registration_id(_, #{registration_id := Val}) ->
    Val;

registration_id(Uri, _) ->
    bondy_utils:gen_message_id({router, Uri}).


%% @private
subscription_id(_, #{subscription_id := Val}) ->
    Val;

subscription_id(Uri, _) ->
    bondy_utils:gen_message_id({router, Uri}).


filter_duplicate_entry_keys(_, undefined) ->
    [];

filter_duplicate_entry_keys(Entries, SessionId) ->
    EntryKeys = [
        EKey ||
            {_, EKey} <- Entries,
            %% Proxy entries can have duplicates, this is
            %% because the handler (proxy) is registering
            %% the entries for multiple remote handlers.
            bondy_registry_entry:is_proxy(EKey) == false
    ],

    case EntryKeys of
        [] ->
            [];
        _ ->
            leap_tuples:join(
                EntryKeys,
                [{SessionId}],
                {bondy_registry_entry:key_field(target), 1},
                []
            )
    end.


%% @private
art_lookup(TrieKey, Trie) ->
    %% Always sync at the moment
    art_lookup(TrieKey, Trie, 0).


%% @private
art_lookup(TrieKey, Trie, 0) ->
    %% We do a sync call
    case art_server:lookup(TrieKey, Trie) of
        {error, badarg} ->
            [];
        {error, Reason} ->
            error(Reason);
        Result ->
            Result
    end;

art_lookup(TrieKey, Trie, N) when N > 0 ->
    %% We do an async call
    try
        art:lookup(TrieKey, Trie)
    catch
        error:badarg ->
            art_lookup(TrieKey, Trie, N - 1);
        _:Reason ->
            error(Reason)
    end.


%% @private
art_find_matches(Pattern, MS, Trie) ->
    %% Always sync at the moment
    art_find_matches(Pattern, MS, Trie, 0).


%% @private
art_find_matches(Pattern, MS, Trie, 0) ->
    case art_server:find_matches(Pattern, MS, Trie) of
        {error, badarg} ->
            [];
        {error, Reason} ->
            error(Reason);
        Result ->
            Result
    end;

art_find_matches(Pattern, MS, Trie, N) when N > 0 ->
    try
        art_server:find_matches(Pattern, MS, Trie)
    catch
        error:badarg ->
            art_find_matches(Pattern, MS, Trie, N - 1);
        _:Reason ->
            error(Reason)
    end.



%% @private
art_delete(TrieKey, Trie) ->
    case art_server:delete(TrieKey, Trie) of
        {error, Reason} ->
            error(Reason);
        Result ->
            Result
    end.


%% @private
art_set(K, V, Trie) ->
    case art_server:set(K, V, Trie) of
        {error, Reason} ->
            error(Reason);
        Result ->
            Result
    end.
