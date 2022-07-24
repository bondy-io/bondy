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
-include("bondy_registry.hrl").
-include("bondy_plum_db.hrl").

-record(state, {
    start_ts  :: pos_integer()
}).

-type task() :: fun((entry(), bondy_context:t()) -> ok).

%% Aliases
-type entry()                   ::  bondy_registry_entry:t().
-type entry_type()              ::  bondy_registry_entry:entry_type().
-type entry_key()               ::  bondy_registry_entry:key().
-type trie_continuation()       ::  bondy_registry_trie:continuation().
-type store_continuation()      ::  bondy_registry_entry:continuation().
-type eot()                     ::  bondy_registry_trie:eot().
-type trie()                    ::  bondy_registry_trie:t().


%% API
-export([add/1]).
-export([add/4]).
-export([add/5]).
-export([entries/1]).
-export([entries/2]).
-export([entries/3]).
-export([entries/4]).
-export([format_error/2]).
-export([info/0]).
-export([init_trie/0]).
-export([lookup/2]).
-export([lookup/3]).
-export([match/1]).
-export([match/3]).
-export([match/4]).
-export([match_exact/1]).
-export([match_exact/4]).
-export([match_pattern/1]).
-export([match_pattern/4]).
-export([remove/1]).
-export([remove/3]).
-export([remove/4]).
-export([remove_all/2]).
-export([remove_all/3]).
-export([remove_all/4]).
-export([start_link/0]).
-export([trie/1]).


%% PLUM_DB PREFIX CALLBACKS
-export([will_merge/3]).
-export([on_merge/3]).
-export([on_update/3]).
-export([on_delete/2]).
-export([on_erase/2]).


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
%% @doc Starts the registry server. The server subscribes to plum_db broadcast
%% and AAE events in order to keep the bondy_registry_trie up-to-date with
%% plum_db.
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
init_trie() ->
    gen_server:call(?MODULE, init_trie, timer:minutes(10)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec trie(Arg :: integer() | uri()) -> trie() | undefined.

trie(Arg) ->
    bondy_registry_partition:trie(Arg).


%% -----------------------------------------------------------------------------
%% @doc Returns information about the registry
%% @end
%% -----------------------------------------------------------------------------
info() ->
    N = bondy_config:get([registry, partitions]),
    {Size, Mem} = lists:foldl(
        fun(Index, {S, M}) ->
            Trie = trie(Index),

            #{
                size := Size,
                memory := Mem
            } = bondy_registry_trie:info(Trie),

            {S + Size, M + Mem}
        end,
        {0, 0},
        lists:seq(1, N)
    ),
    #{size => Size, memory => Mem}.


%% -----------------------------------------------------------------------------
%% @doc Used for adding proxy entries only as it skips all checks.
%% @end
%% -----------------------------------------------------------------------------
-spec add(entry()) ->
    {ok, IsFirstEntry :: boolean()} | {error, already_exists} | no_return().

add(Entry) ->
    bondy_registry_entry:is_entry(Entry)
        orelse ?ERROR(badarg, [Entry], #{
            1 => "is not a entry()"
        }),

    ok = bondy_registry_entry:store(Entry),

    case trie_add(Entry) of
        {ok, _, IsFirstEntry} ->
            {ok, IsFirstEntry};

        {error, {already_exists, _}} ->
            {error, already_exists};

        {error, _} = Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc @see add/5
%% @end
%% -----------------------------------------------------------------------------
-spec add(
    Type :: entry_type(),
    RegUri :: uri(),
    Opts :: map(),
    Ctxt :: bondy_context:t()) ->
    {ok, Entry :: entry(), IsFirstEntry :: boolean()}
    | {error, {already_exists, entry()} | any()}.

add(Type, Uri, Opts, Ctxt) when is_map(Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Ref = bondy_context:ref(Ctxt),
    add(Type, RealmUri, Uri, Opts, Ref).


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
%% {ok, entry(), boolean()}.
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
    Type :: entry_type(),
    RealmUri :: uri(),
    Uri :: uri(),
    Opts :: map(),
    Ref :: bondy_ref:t()) ->
    {ok, Entry :: entry(), IsFirstEntry :: boolean()}
    | {error, {already_exists, entry()} | any()}.

add(Type, RealmUri, Uri, Opts, Ref) ->
    case ?CONCURRENT_ADD(Type) of
        true ->
            %% This is executed on the calling process, so we get the trie for
            %% the partition assigned to RealmUri
            Trie = trie(RealmUri),
            add(Type, RealmUri, Uri, Opts, Ref, Trie);

        false ->
            %% We serialise the operations by sending the work to one of the
            %% partitions.
            Pid = bondy_registry_partition:pick(RealmUri),
            Args = [Type, RealmUri, Uri, Opts, Ref], % ++ [Trie]
            bondy_registry_partition:execute(Pid, fun add/6, Args, 5000)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(entry()) -> ok.

remove(Entry) ->
    ok = trie_delete(Entry),
    ok = bondy_registry_entry:delete(Entry).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(entry_type(), id(), bondy_context:t()) ->
    ok | {error, not_found}.

remove(Type, EntryId, Ctxt) ->
    remove(Type, EntryId, Ctxt, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(
    Type :: entry_type(),
    EntryId :: id(),
    Ctxt :: bondy_context:t(),
    Task :: optional(task())) -> ok.

remove(Type, EntryId, Ctxt, Task)
when Task == undefined orelse is_function(Task, 1) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    Pattern = bondy_registry_entry:key_pattern(
        RealmUri, SessionId, EntryId, '_'
    ),

    MatchOpts = [
        {limit, 1},
        {resolver, lww},
        {remove_tombstones, true}
    ],

    %% We should match at most one entry for the {RealmUri, SessionId, EntryId}
    %% combination.
    case bondy_registry_entry:match(Type, Pattern, MatchOpts) of
        ?EOT ->
            ok;
        {[{_Key, Entry}], _Cont} ->
            %% We delete entry from the trie first
            ok = trie_delete(Entry),
            %% We delete the entry from plum_db. This will broadcast the delete
            %% amongst the nodes in the cluster
            ok = bondy_registry_entry:delete(Entry),
            %% If Task is a fun, execute it
            maybe_execute(maybe_fun(Task, Ctxt), Entry)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Removes all entries matching the context's realm and session_id (if any).
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(entry_type(), bondy_context:t()) -> ok.

remove_all(Type, Ctxt) ->
    remove_all(Type, Ctxt, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% Removes all entries matching the context's realm and session_id (if any).
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(entry_type(), bondy_context:t(), task() | undefined) -> ok.

remove_all(Type, Ctxt, Task)
when Task == undefined orelse is_function(Task, 1) ->

    case bondy_context:session_id(Ctxt) of
        undefined ->
            ?LOG_DEBUG(#{
                description => "Failed to remove registry contents",
                reason => no_session_id
            }),
            ok;

        SessionId ->
            RealmUri = bondy_context:realm_uri(Ctxt),
            Pattern = bondy_registry_entry:key_pattern(
                RealmUri, SessionId, '_', '_'
            ),
            MaybeFun = maybe_fun(Task, Ctxt),
            MatchOpts = [
                {limit, 100},
                {resolver, lww},
                {allow_put, false},
                {remove_tombstones, true}
            ],
            Matches = bondy_registry_entry:match(Type, Pattern, MatchOpts),
            do_remove_all(Matches, SessionId, MaybeFun)
    end.


%% -----------------------------------------------------------------------------
%% @doc Removes all registry entries of type Type, for a {RealmUri, Node
%% SessionId} relation.
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(
    Type :: entry_type(),
    RealmUri :: uri(),
    SessionId :: id(),
    Task :: task() | undefined) -> [entry()].

remove_all(Type, RealmUri, SessionId, Task) ->
    Pattern = bondy_registry_entry:key_pattern(RealmUri, SessionId, '_', '_'),

    MatchOpts = [
        {limit, 100},
        {remove_tombstones, true},
        {resolver, lww},
        {allow_put, false}
    ],
    Matches = bondy_registry_entry:match(Type, Pattern, MatchOpts),
    do_remove_all(Matches, SessionId, Task).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(Type :: entry_type(), Key ::  entry_key()) ->
    {ok, entry()} | {error, not_found}.

lookup(Type, Key) ->
    bondy_registry_entry:lookup(Type, Key).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
lookup(Type, RealmUri, EntryId) when is_integer(EntryId) ->
    bondy_registry_entry:lookup(Type, RealmUri, EntryId, []).


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
-spec entries(store_continuation()) ->
    {[entry()], store_continuation() | eot()} | eot().

entries(?EOT) ->
    ?EOT;

entries(Cont0) ->
    %% We need to add back the resolver strategy
    case bondy_registry_entry:match(Cont0) of
        ?EOT ->
            ?EOT;

        {L, ContOrEOT} ->
            {[V || {_, V} <- L], ContOrEOT}
    end.


%% -----------------------------------------------------------------------------
%% @doc Returns the list of entries owned by the active session.
%%
%% This function is equivalent to calling {@link entries/2} with the RealmUri
%% and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(entry_type(), bondy_context:t()) -> [entry()].

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
    Type :: entry_type(),
    RealmUri :: uri(),
    SessionId :: id()) -> [entry()].

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
    Type :: entry_type(),
    Realm :: uri(),
    SessionId :: id() | '_',
    Limit :: pos_integer() | infinity) ->
    [entry()] | {[entry()], store_continuation() | eot()} | eot().

entries(Type, RealmUri, SessionId, Limit) ->
    Pattern = bondy_registry_entry:key_pattern(RealmUri, SessionId, '_', '_'),
    Opts = [
        {limit, Limit},
        {remove_tombstones, true},
        {resolver, lww}
    ],

    case bondy_registry_entry:match(Type, Pattern, Opts) of
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
%% @end
%% -----------------------------------------------------------------------------
-spec match(trie_continuation() | eot()) ->
    {[entry()], trie_continuation() | eot()} | eot().

match(?EOT) ->
    ?EOT;

match(Cont0) ->
    try

        project_trie_match_res(trie_match(Cont0))

    catch
        throw:non_eligible_entries ->
            ?EOT;

        error:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while searching trie",
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ?EOT
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Calls {@link match/4}.
%% @end
%% -----------------------------------------------------------------------------
-spec match(Type :: entry_type(), RealmUri :: uri(), Uri :: uri()) ->
    {[entry()], trie_continuation() | eot()} | eot().

match(Type, RealmUri, Uri) ->
    match(Type, RealmUri, Uri, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the entries matching either a topic or procedure Uri according to
%% each entry's configured match specification.
%%
%% This function is used by the Broker to return all subscriptions that match a
%% topic. And in case of registrations it is used by the Dealer to return all
%% registrations matching a procedure.
%%
%% This function uses the bondy_registry_trie.
%% @end
%% -----------------------------------------------------------------------------
-spec match(Type :: entry_type(), RealmUri :: uri(), uri(), map()) ->
    {[entry()], trie_continuation() | eot()} | eot().

match(Type, RealmUri, Uri, Opts) ->
    try
        FN = ?FUNCTION_NAME,
        project_trie_match_res(trie_match(Type, RealmUri, Uri, Opts, FN))

    catch
        throw:non_eligible_entries ->
            ?EOT;

        error:Reason:Stacktrace ->
            ?LOG_ERROR(#{
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
-spec match_exact(trie_continuation() | eot()) ->
    {[entry()], trie_continuation() | eot()} | eot().

match_exact(?EOT) ->
    ?EOT;

match_exact(Cont0) ->
    try
        FN = ?FUNCTION_NAME,
        project_trie_match_res(trie_match(Cont0, FN))

    catch
        throw:non_eligible_entries ->
            ?EOT;

        error:Reason:Stacktrace ->
            ?LOG_ERROR(#{
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
-spec match_exact(
    Type :: entry_type(), RealmUri :: uri(), Uri :: uri(), Opts :: map()
    ) -> {[entry()], trie_continuation() | eot()} | eot().

match_exact(Type, RealmUri, Uri, Opts) ->
    try
        FN = ?FUNCTION_NAME,
        project_trie_match_res(trie_match(Type, RealmUri, Uri, Opts, FN))

    catch
        throw:non_eligible_entries ->
            ?EOT;

        error:Reason:Stacktrace ->
            ?LOG_ERROR(#{
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
-spec match_pattern(trie_continuation() | eot()) ->
    {[entry()], trie_continuation() | eot()} | eot().

match_pattern(?EOT) ->
    ?EOT;

match_pattern(Cont0) ->
    try
        FN = ?FUNCTION_NAME,
        project_trie_match_res(trie_match(Cont0, FN))

    catch
        throw:non_eligible_entries ->
            ?EOT;

        error:Reason:Stacktrace ->
            ?LOG_ERROR(#{
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
-spec match_pattern(
    Type :: entry_type(), RealmUri :: uri(), Uri :: uri(), Opts :: map()
    ) -> {[entry()], trie_continuation() | eot()} | eot().

match_pattern(Type, RealmUri, Uri, Opts) ->
    try
        FN = ?FUNCTION_NAME,
        project_trie_match_res(trie_match(Type, RealmUri, Uri, Opts, FN))

    catch
        throw:non_eligible_entries ->
            ?EOT;

        error:Reason:Stacktrace ->
            ?LOG_ERROR(#{
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
format_error(Reason, [{_M, _F, _As, Info} | _]) ->
    ErrorInfo = proplists:get_value(error_info, Info, #{}),
    ErrorMap = maps:get(cause, ErrorInfo),
    ErrorMap#{
        %% general => "optional general information",
        reason => io_lib:format("~p: ~p", [?MODULE, Reason])
    }.



%% =============================================================================
%% PLUM_DB PREFIX CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
will_merge(_PKey, _New, _Old) ->
    %% ?LOG_DEBUG(#{
    %%     description => "Will merge called", new => New, old => Old
    %% }),
    true.


%% -----------------------------------------------------------------------------
%% @doc This function needs to return immediately
%% @end
%% -----------------------------------------------------------------------------
on_merge(PKey, New, Old) ->
    %% ?LOG_DEBUG(#{description => "On merge called", new => New, old => Old}),
    trie_on_merge(PKey, New, Old).


%% -----------------------------------------------------------------------------
%% @doc A local update
%% @end
%% -----------------------------------------------------------------------------
on_update(_PKey, _New, _Old) ->
    %% ?LOG_DEBUG(#{description => "On update called", new => New, old => Old}),
    ok.


%% -----------------------------------------------------------------------------
%% @doc A local delete
%% @end
%% -----------------------------------------------------------------------------
on_delete(_PKey, _Old) ->
    ok.


%% -----------------------------------------------------------------------------
%% @doc A local erase
%% @end
%% -----------------------------------------------------------------------------
on_erase(_PKey, _Old) ->
    ok.




%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([]) ->
    process_flag(trap_exit, true),

    %% We subscribe to plum_db_events change notifications. We get updates
    %% in handle_info so that we can we update the tries
    %% MS = [{
    %%     %% {{{_, _} = FullPrefix, Key}, NewObj, ExistingObj}
    %%     {{{'$1', '_'}, '_'}, '_', '_'},
    %%     [
    %%         {'orelse',
    %%             {'=:=', ?PLUM_DB_REGISTRATION_TAB, '$1'},
    %%             {'=:=', ?PLUM_DB_SUBSCRIPTION_TAB, '$1'}
    %%         }
    %%     ],
    %%     [true]
    %% }],
    %% ok = plum_db_events:subscribe(object_update, MS),

    %% Every time a node goes up/down we get an info message
    ok = partisan:monitor_nodes(true),

    State = #state{
        start_ts = erlang:system_time(millisecond)
    },

    {ok, State}.


handle_call(init_trie, _From, State) ->
    Res = init_trie(State),
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
    {plum_db_event, object_update, {PK, New, Old}}, State) ->
    ok = trie_on_merge(PK, New, Old),
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
    %% TODO deactivate node entries
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



%% -----------------------------------------------------------------------------
%% @private
%% @doc Adds an entry to the registry.
%%
%% Adding an already existing entry is treated differently based on whether the
%% entry is a registration or a subscription.
%%
%% According to the WAMP specification, in the case of a subscription that was
%% already added before by the same _Subscriber_, the _Broker_ should not fail
%% and answer with a "SUBSCRIBED" message, containing the existing
%% "Subscription|id". So in this case this function returns
%% {ok, entry(), boolean()}.
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
%%
%% IMPORTANT: This function must be safe to call by
%% bondy_registry_partition instances. As a result it MUST NEVER make a call to
%% bondy_registry_partition itself.
%%
%% @end
%% -----------------------------------------------------------------------------
add(registration, RealmUri, Uri, Opts, Ref, Trie) ->
    case bondy_ref:target_type(Ref) of
        callback ->
            add_callback_registration(RealmUri, Uri, Opts, Ref, Trie);
        _ ->
            maybe_add_registration(RealmUri, Uri, Opts, Ref, Trie)
    end;

add(subscription = Type, RealmUri, Uri, Opts, Ref, Trie) ->
    SessionId = bondy_ref:session_id(Ref),
    MP = maps:get(match, Opts, ?EXACT_MATCH),

    Fun = fun({_, E} = KV, none) ->
        %% It is valid for a subscriber to subscribe to both
        %% {foo, exact} and {foo, prefix}.
        Matches =
            Uri == bondy_registry_entry:uri(E)
            andalso MP == bondy_registry_entry:match_policy(E),

        case Matches of
            false ->
                %% We continue
                none;

            true when SessionId == undefined ->
                %% Internal process subscribing w/o session, we check it is not
                %% the same process reference
                Ref =/= bondy_registry_entry:ref(E) orelse throw({break, KV}),
                none;

            true ->
                throw({break, KV})
        end
    end,

    Acc = none,
    KeyPattern = bondy_registry_entry:key_pattern(
        RealmUri, SessionId, '_', '_'
    ),
    FoldOpts = [
        {match, KeyPattern},
        {remove_tombstones, true},
        %% TODO maybe use FWW and check node (ActorID)?
        {resolver, lww}
    ],

    case bondy_registry_entry:fold(Type, RealmUri, Fun, Acc, FoldOpts) of
        none ->
            %% No matching subscriptions for this SessionId exists
            RegId = subscription_id(RealmUri, Opts),
            Entry = bondy_registry_entry:new(
                Type, RegId, RealmUri, Ref, Uri, Opts
            ),
            ok = bondy_registry_entry:store(Entry),
            bondy_registry_trie:add(Entry, Trie);

        {EntryKey, Entry} ->
            %% In case of receiving a "SUBSCRIBE" message from the same
            %% _Subscriber_ and to already added topic, _Broker_ should
            %% answer with "SUBSCRIBED" message, containing the existing
            %% "Subscription|id".
            {ok, Entry} = bondy_registry_entry:lookup(Type, EntryKey),
            {error, {already_exists, Entry}}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%%
%% IMPORTANT: This function must be safe to call by
%% bondy_registry_partition instances. As a result it MUST NEVER make a call to
%% bondy_registry_partition itself.
%%
%% @end
%% -----------------------------------------------------------------------------
add_callback_registration(RealmUri, Uri, Opts0, Ref, Trie) ->
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
            maybe_add_registration(RealmUri, Uri, Opts, Ref, Trie);
        false ->
            {error, {invalid_callback, erlang:append_element(MF, Args)}}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%%
%% IMPORTANT: This function must be safe to call by
%% bondy_registry_partition instances. As a result it MUST NEVER make a call to
%% bondy_registry_partition itself.
%%
%% @end
%% -----------------------------------------------------------------------------
maybe_add_registration(RealmUri, Uri, Opts, Ref, Trie) ->
    Invoke = maps:get(invoke, Opts, ?INVOKE_SINGLE),
    Shared = maps:get(shared_registration, Opts, false),

    case Shared == true orelse Invoke == ?INVOKE_SINGLE of
        true ->
            add_registration(RealmUri, Uri, Opts, Ref, Trie);
        false ->
            {error, shared_registration_disabled}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%%
%% IMPORTANT: This function must be safe to call by
%% bondy_registry_partition instances. As a result it MUST NEVER make a call to
%% bondy_registry_partition itself.
%%
%% @end
%% -----------------------------------------------------------------------------
add_registration(RealmUri, Uri, Opts, Ref, Trie) ->
    Type = registration,
    Match = maps:get(match, Opts, ?EXACT_MATCH),

    MOpts = #{
        match => Match,
        invoke => '_'
    },

    Results = bondy_registry_trie:match(Type, RealmUri, Uri, MOpts, Trie),

    case Results of
        [] ->
            %% No existing registrations for this URI
            Entry = new_registration(RealmUri, Ref, Uri, Opts),
            ok = bondy_registry_entry:store(Entry),
            bondy_registry_trie:add(Entry, Trie);

        L ->
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

            SessionId = bondy_ref:session_id(Ref),
            Invoke = maps:get(invoke, Opts, ?INVOKE_SINGLE),

            %% TODO extract this so that it is implemented as a funcion that
            %% the dealer will send.

            case resolve_inconsistencies(L, Invoke, SessionId) of
                ok ->
                    Entry = new_registration(RealmUri, Ref, Uri, Opts),
                    ok = bondy_registry_entry:store(Entry),
                    bondy_registry_trie:add(Entry, Trie);

                {error, {already_exists, _}} = Error ->
                    Error
            end
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc We might have inconsistencies that might have ocurred during a net
%% split.
%%
%% There are two cases:
%% 1. Multiple registrations w/invoke == single
%% 2. Multiple registrations with differring invoke strategies
%% @end
%% -----------------------------------------------------------------------------
-spec resolve_inconsistencies(
    [bondy_registration_trie:registration_match()],
    Invoke :: binary(),
    SessionId :: optional(bondy_session_id:t())
    ) -> ok | {error, any()}.

resolve_inconsistencies([], _, _) ->
    ok;

resolve_inconsistencies(All, Invoke, SessionId) ->
    Type = registration,
    Project = [1, 2, 3],
    Grouped = leap_tuples:summarize(
        All, {2, {function, collect, Project}}, #{}
    ),

    case Grouped of
        [] ->
            %% No existing registrations
            ok;

        [{?INVOKE_SINGLE, [L]}] ->
            %% Result is 'ok' iff entry is missing from main store
            %% (due to inconsistency). Otherwise is the already_exists
            %% error.
            resolve_existing(registration, L);

        [{?INVOKE_SINGLE, L0}] ->
            %% Multiple registrations w/invoke == single
            %% We need to revoke all but the first one registered, so we sort
            KeyPairs = sort_registrations(L0),

            %% Result is 'ok' iff all entries are missing from main store
            %% (due to inconsistency). Otherwise is the already_exists
            %% error with the first entry alive.
            resolve_duplicates(KeyPairs);

        [{Group, L0}] when Group == Invoke ->
            %% The registrations are consistent (all using the same invocation
            %% policy). However, we still need to check for duplicates within
            %% the same session.
            L = find_registration_duplicates(L0, SessionId),
            resolve_duplicates(L);

        [{_Group, L}] ->
            %% The caller is trying to register using an invocation policy
            %% that does not match the one being used so far for this procedure
            resolve_existing(Type, L);

        _  ->
            %% The worse case: 2 or more groups
            case resolve_existing(Type, sort_registrations(All)) of
                ok ->
                    ok;
                {error, {already_exists, _Entry}} = Error ->
                    %% TODO if INVOKE_SINGLE, revoke all other registrations
                    %% if other policy, revoke all registrations for other
                    %% policies
                    Error
            end

    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Sort registration `proc()' index entries by time
%% @end
%% -----------------------------------------------------------------------------
-spec sort_registrations([bondy_registration_trie:registration_match()]) ->
    [bondy_registration_trie:registration_match()].

sort_registrations(L) ->
    lists:sort(
        fun ({_, _, A}, {_, _, B}) ->
            bondy_registry_entry:created(A)
                =< bondy_registry_entry:created(B)
        end,
        L
    ).


%% @private
-spec find_registration_duplicates(
    Triples :: [bondy_registration_trie:registration_match()],
    SessionId :: bondy_session_id:t()
    ) -> Duplicates :: [bondy_registration_trie:registration_match()].

find_registration_duplicates([], _) ->
    [];

find_registration_duplicates(_, undefined) ->
    %% Undefined is used for internal callees and we allow duplicates
    [];

find_registration_duplicates(Triples, SessionId) ->
    [
        Triple
        || {_, _, EntryKey} = Triple <- Triples,
            %% Proxy entries can have duplicates, this is
            %% because the handler (proxy) is registering
            %% the entries for multiple remote handlers,
            %% so we filter them out
            false == bondy_registry_entry:is_proxy(EntryKey),
            SessionId == bondy_registry_entry:session_id(EntryKey)
    ].


%% @private
revoke(_) ->
    %% TODO
    ok.


%% @private
-spec resolve_duplicates([bondy_registration_trie:registration_match()]) ->
    ok | {error, {already_exists, entry()}}.

resolve_duplicates([H|T]) ->
    case resolve_existing(registration, H) of
        ok ->
            %% This means we had an inconsistency between the trie and the main
            %% store and the entry doesn't exist, so we try with the next
            resolve_duplicates(T);

        {error, {already_exists, _}} = Error ->
            %% H is active and earlieast registered single, we need to revoke
            %% all others.
            ok = revoke(T),
            %% And return the existing one
            Error
    end;

resolve_duplicates([]) ->
    %% No duplicates or all the entries were inconsistent (trie vs plum_db).
    ok.


%% @private
-spec resolve_existing(
    entry_type(),
    bondy_registration_trie:registration_match()
        | [bondy_registration_trie:registration_match()]
    ) -> ok | {error, {already_exists, entry()}}.

resolve_existing(_, []) ->
    ok;

resolve_existing(Type, [H|T]) ->
    case resolve_existing(Type, H) of
        {error, {already_exists, _}} = Error ->
            Error;
        ok ->
            resolve_existing(Type, T)
    end;

resolve_existing(Type, {_TrieKey, _, EntryKey}) ->
    case bondy_registry_entry:lookup(Type, EntryKey) of
        {ok, Entry} ->
            {error, {already_exists, Entry}};

        {error, not_found} ->
            %% We found an inconsistency between the trie and plum_db.
            %% This is very rare, but we need to cater for it.
            %% Use fww instead?
            Opts = [{remove_tombstones, false}, {resolver, lww}],

            case bondy_registry_entry:lookup(Type, EntryKey, Opts) of
                {ok, ?TOMBSTONE} ->
                    %% We fix the trie but allow the registration to happen
                    %% TODO
                    %% delete_from_trie(registration, RealmUri, TrieKey),
                    %% TODO maybe revoke registration (but the client might
                    %% crash if it doesn't know it)
                    %% NOTICE
                    %% FIXME
                    ok;

                {error, not_found} ->
                    ?LOG_WARNING(#{
                        description =>
                            "Inconsistency found in registry. "
                            "An entry found in the trie "
                            "could not be found on the main store.",
                        reason => not_found,
                        registry_entry_key => EntryKey
                    }),
                    ok
            end
    end.


%% @private
new_registration(RealmUri, Ref, Uri, Opts) ->
    RegId = registration_id(RealmUri, Opts),
    bondy_registry_entry:new(
        registration, RegId, RealmUri, Ref, Uri, Opts
    ).


%% @private
registration_id(_, #{registration_id := Val}) ->
    Val;

registration_id(RealmUri, _) ->
    bondy_utils:gen_message_id({router, RealmUri}).


%% @private
subscription_id(_, #{subscription_id := Val}) ->
    Val;

subscription_id(Uri, _) ->
    bondy_utils:gen_message_id({router, Uri}).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
trie_on_merge({{_, RealmUri}, _} = PKey, New, Old) ->
    Pid = bondy_registry_partition:pick(RealmUri),
    Args = [PKey, New, Old],
    bondy_registry_partition:async_execute(Pid, fun trie_on_merge/4, Args).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% WARNING: This function must be only be called by trie_on_merge/3 as it
%% assumes it is executing in a registry partition process
%% @end
%% -----------------------------------------------------------------------------
trie_on_merge(_PKey, New, Old, Trie) ->
    case maybe_resolve(New) of
        '$deleted' when Old == undefined ->
            %% We got a delete for an entry we do not know anymore.
            %% This happens when the registry has just been reset
            %% as we do not persist registrations any more
            %%
            %% TODO use the future plum_db:erase instead of delete and avoid
            %% tombstones being resurfaced
            ok;

        '$deleted' when Old =/= undefined ->
            %% We do this since we need to know the Match Policy of the
            %% previous entry in order to generate the trie key and we want to
            %% avoid including yet another element to the entry_key
            Reconciled = plum_db_object:resolve(Old, lww),
            OldEntry = plum_db_object:value(Reconciled),
            %% This works because registry entries are immutable
            bondy_registry_trie:delete(OldEntry, Trie);

        Entry ->
            case bondy_registry_entry:is_local(Entry) of
                true when Old =:= undefined ->
                    %% Another node is telling us we are missing an entry that
                    %% is rooted here, this is an inconsistency issue produced
                    %% by our eventual consistency model. Most probably we
                    %% crashed and we never had the chance to mark this entry
                    %% as deleted or if we did it never reached the peer node.
                    %% We need to mark it as deleted in plum_db so that the
                    %% other nodes get the event and stop trying to re-surface
                    %% it.

                    %% This will mark it as deleted and broadcast the change to
                    %% all cluster nodes.
                    ok = bondy_registry_entry:delete(Entry);

                true when Old =/= undefined ->
                    %% This case should never happen as entries are immutable
                    ok;

                false ->
                    bondy_registry_trie:add(Entry, Trie),
                    ok

            end
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


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
trie_add(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Type = bondy_registry_entry:type(Entry),

    case ?CONCURRENT_ADD(Type) of
        true ->
            Trie = trie(RealmUri),
            bondy_registry_trie:add(Entry, Trie);
        false ->
            Pid = bondy_registry_partition:pick(RealmUri),
            Add = fun(Trie) -> bondy_registry_trie:add(Entry, Trie) end,
            bondy_registry_partition:execute(Pid, Add, [], 5000)
    end.


%% @private
trie_delete(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Type = bondy_registry_entry:type(Entry),

    case ?CONCURRENT_DELETE(Type) of
        true ->
            Trie = trie(RealmUri),
            bondy_registry_trie:delete(Entry, Trie);
        false ->
            Pid = bondy_registry_partition:pick(RealmUri),
            Delete = fun(E, T) -> bondy_registry_trie:delete(E, T) end,
            bondy_registry_partition:async_execute(Pid, Delete, [Entry])
    end.


%% @private
trie_match(Type, RealmUri, Uri, Opts, FN) ->
    case ?CONCURRENT_MATCH(Type) of
        true ->
            Trie = trie(RealmUri),
            bondy_registry_trie:FN(Type, RealmUri, Uri, Opts, Trie);

        false ->
            Pid = bondy_registry_partition:pick(RealmUri),
            Match = fun(Trie) ->
                bondy_registry_trie:FN(Type, RealmUri, Uri, Opts, Trie)
            end,
            bondy_registry_partition:execute(Pid, Match, [], 15000)
    end.


%% @private
trie_match(Cont) ->
    trie_match(Cont, match).


%% @private
trie_match(Cont, FN) ->
    #{
        type := Type,
        realm_uri := RealmUri
    } = bondy_registry_trie:continuation_info(Cont),

    case ?CONCURRENT_MATCH(Type) of
        true ->
            bondy_registry_trie:FN(Cont);

        false ->
            Pid = bondy_registry_partition:pick(RealmUri),
            Match = fun(_Trie) ->
                bondy_registry_trie:FN(Cont)
            end,
            bondy_registry_partition:execute(Pid, Match, [], 15000)
    end.


%% @private
project_trie_match_res(L) when is_list(L) ->
    %% registrations
    lookup_entries(registration, L, []);

project_trie_match_res({L, R}) when is_list(L), is_list(R) ->
    %% subscriptions
    {lookup_entries(subscription, L, []), R};

project_trie_match_res(?EOT) ->
    ?EOT;

project_trie_match_res({L, Cont}) when is_list(L) ->
    #{type := Type} = bondy_registry_trie:continuation_info(Cont),
    {lookup_entries(Type, L, []), Cont};

project_trie_match_res({{L, R}, Cont}) when is_list(L), is_list(R) ->
    #{type := Type} = bondy_registry_trie:continuation_info(Cont),
    Entries = lookup_entries(Type, L, []),
    {{Entries, R}, Cont};

project_trie_match_res({error, Reason}) ->
    error(Reason).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
init_trie(State) ->
    ?LOG_NOTICE(#{
        description => "Initialising in-memory registry trie from main store."
    }),

    Now = State#state.start_ts,
    AnyRealm = '_',
    Opts = [{resolver, lww}, {remove_tombstones, true}],

    Fun = fun
        ({_, '$deleted'}) ->
            ok;

        ({_, Entry}) ->
            %% In the event of another node not terminating properly, the last
            %% sessions' registrations will still be in the DB. This function
            %% ensures no stale entry is restore from the main db to the trie
            %% and that they are removed from the db.
            Node = bondy_config:nodestring(),
            EntryNode = bondy_registry_entry:nodestring(Entry),
            Created = bondy_registry_entry:created(Entry),

            %% IMPORTANT We asume nodes keep their names forever.
            case Node == EntryNode andalso Created < Now of
                true ->
                    %% This entry should have been deleted when node
                    %% crashed or shutdown
                    ?LOG_DEBUG(#{
                        description => "Removing stale entry from plum_db",
                        entry => Entry
                    }),

                    _ = trie_delete(Entry),

                    %% TODO implement and use plum_db:async_delete(.., EntryKey)
                    ok;

                false ->
                    _ = trie_add(Entry),
                    ok
            end
    end,

    try
        %% We initialise the registration trie by reading the data from plum_db
        ok = bondy_registry_entry:foreach(registration, AnyRealm, Fun, Opts),
        ok = bondy_registry_entry:foreach(subscription, AnyRealm, Fun, Opts)

    catch
        throw:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description =>
                    "Error while initilising registry trie from store",
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



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


%% @private
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
    do_remove_all(bondy_registry_entry:match(Cont), SessionId, Fun, Acc);

do_remove_all({[{_EntryKey, Entry}|T], Cont}, SessionId, Fun, Acc) ->
    Session = bondy_registry_entry:session_id(Entry),

    case SessionId =:= Session orelse SessionId == '_' of
        true ->
            ok = trie_delete(Entry),
            %% We delete the entry from plum_db.
            %% This will broadcast the delete to all nodes.
            ok = bondy_registry_entry:delete(Entry),
            %% We continue traversing
            do_remove_all({T, Cont}, SessionId, Fun, [Entry|Acc]);

        false ->
            %% No longer our session
            ok
    end.


%% @private
lookup_entries(_, [], Acc) ->
    lists:reverse(Acc);

lookup_entries(Type, [H|T], Acc) ->
    EntryKey = entry_key(Type, H),

    case bondy_registry_entry:lookup(Type, EntryKey) of
        {ok, Entry} ->
            lookup_entries(Type, T, [Entry|Acc]);

        {error, not_found} ->
            lookup_entries(Type, T, Acc)
    end.


%% @private
entry_key(subscription, {_, Val}) -> Val;
entry_key(registration, {_, _, Val}) -> Val.

