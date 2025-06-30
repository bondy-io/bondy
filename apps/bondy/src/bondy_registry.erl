%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry).
-behaviour(gen_server).

-doc("""
An in-memory registry for PubSub subscriptions and Routed RPC registrations,
providing pattern matching capabilities including support for WAMP's
version 2.0 match policies (exact, prefix and wildcard).
The registry entries are stored in plum_db (using an in-memory prefix). The
registry also uses in-memory trie-based indexed (materialised
view) using {@link bondy_registry_trie}.
This module also provides a singleton server to perform the initialisation
of the trie from the plum_db tables.
""").

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_registry.hrl").
-include("bondy_plum_db.hrl").

-define(MERGE_STATUS_TAB, bondy_registry_merge_status).

-define(REMOVE_MATCH_OPTS, [
    {allow_put, false} | ?MATCH_OPTS
]).

-define(MATCH_OPTS, [
    {remove_tombstones, true},
    {resolver, lww}
]).

-record(state, {
    timers = #{}    ::  #{node() => reference()},
    start_ts        ::  pos_integer()
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
-export([find/1]).
-export([find/3]).
-export([find/4]).
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
-export([trie/1]).
-export([pick/1]).


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
%% and AAE events in order to keep the `bondy_registry_trie' up-to-date with
%% plum_db.
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc Initialises the trie  ({@link bondy_registry_trie}) from the stored
%% entries.
%% @end
%% -----------------------------------------------------------------------------
init_trie() ->
    gen_server:call(?MODULE, init_trie, timer:minutes(10)).


%% -----------------------------------------------------------------------------
%% @doc Returns the registry partition pid for realm uri `Uri'.
%% @end
%% -----------------------------------------------------------------------------
-spec pick(Uri :: uri()) -> pid().

pick(Uri) ->
    bondy_registry_partition:pick(Uri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec trie(Arg :: integer() | uri()) -> trie() | undefined.

trie(Arg) ->
    bondy_registry_partition:trie(Arg).


%% -----------------------------------------------------------------------------
%% @doc Returns the tuple `{Size, Mem}; where `Size' is the number of elements
%% stored in the registry and `Mem' is the memory consumed by the registry in
%% bytes.
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
%% Fails with `badarg' if  `Entry' is not a proxy entry
%% (`bondy_registry_entry:t()').
%% @end
%% -----------------------------------------------------------------------------
-spec add(entry()) ->
    {ok, IsFirstEntry :: boolean()} | {error, already_exists} | no_return().

add(Entry) ->
    bondy_registry_entry:is_entry(Entry)
        orelse ?ERROR(badarg, [Entry], #{
            1 => "is not an entry()"
        }),

    bondy_registry_entry:is_proxy(Entry)
        orelse ?ERROR(badarg, [Entry], #{
            1 => "is not a proxy entry()"
        }),

    ok = bondy_registry_entry:store(Entry),

    case add_indices(Entry) of
        {ok, _, IsFirstEntry} ->
            %% No need to add to remote index as proxies are local
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
%% `{ok, entry(), boolean()}'.
%%
%% In case of a registration, as a default, only a single Callee may
%% register a procedure for an URI. However, when shared registrations are
%% supported, then the first Callee to register a procedure for a particular URI
%% MAY determine that additional registrations for this URI are allowed, and
%% what Invocation Rules to apply in case such additional registrations are
%% made.
%%
%% This is configured through the `invoke' options.
%% When invoke is not `single', Dealer MUST fail all subsequent attempts to
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
            bondy_registry_partition:execute(Pid, fun add/6, Args, 5_000)
    end.


%% -----------------------------------------------------------------------------
%% @doc Removes (deletes) an entry from the registry.
%% @end
%% -----------------------------------------------------------------------------
-spec remove(entry()) -> ok.

remove(Entry) ->
    ok = delete_indices(Entry),
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
        RealmUri, SessionId, EntryId
    ),

    MatchOpts = [{limit, 1} | ?MATCH_OPTS],

    %% We should match at most one entry for the {RealmUri, SessionId, EntryId}
    %% combination.
    case bondy_registry_entry:match(Type, Pattern, MatchOpts) of
        ?EOT ->
            ok;
        {[{_Key, Entry}], _Cont} ->
            %% We delete entry from the trie first
            ok = delete_indices(Entry),
            %% We delete the entry from plum_db. This will broadcast the delete
            %% amongst the nodes in the cluster
            ok = bondy_registry_entry:delete(Entry),
            %% If Task is a fun, execute it
            maybe_execute(maybe_fun(Task, Ctxt), Entry)
    end.


%% -----------------------------------------------------------------------------
%% @doc Removes all entries of type `Type' matching the context's realm and
%% session_id.
%%
%% Same as calling `remove_all(Type, Ctxt, undefined)'.
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(entry_type(), bondy_context:t()) -> ok.

remove_all(Type, Ctxt) ->
    remove_all(Type, Ctxt, undefined).


%% -----------------------------------------------------------------------------
%% @doc Removes all entries of type `Type' matching the context's realm and
%% session_id.
%%
%% If `Task' is defined, it executes the task passing the removed entry as
%% argument.
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(entry_type(), bondy_context:t(), task() | undefined) -> ok.

remove_all(Type, Ctxt, Task)
when Task == undefined
orelse is_function(Task, 1) orelse is_function(Task, 2) ->

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
                RealmUri, SessionId, '_'
            ),
            MaybeFun = maybe_fun(Task, Ctxt),
            MatchOpts = [{limit, 100} | ?REMOVE_MATCH_OPTS],
            Matches = bondy_registry_entry:match(Type, Pattern, MatchOpts),
            do_remove_all(Matches, SessionId, MaybeFun)
    end.


%% -----------------------------------------------------------------------------
%% @doc Removes all registry entries of type Type, for a {RealmUri
%% SessionId} relation.
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(
    Type :: entry_type(),
    RealmUri :: uri(),
    SessionId :: id(),
    Task :: task() | undefined) -> [entry()].

remove_all(Type, RealmUri, SessionId, Task)
when Task == undefined orelse is_function(Task, 1) ->
    Pattern = bondy_registry_entry:key_pattern(RealmUri, SessionId, '_'),

    MatchOpts = [{limit, 100} | ?REMOVE_MATCH_OPTS],
    Matches = bondy_registry_entry:match(Type, Pattern, MatchOpts),
    do_remove_all(Matches, SessionId, Task).


%% -----------------------------------------------------------------------------
%% @doc Looks up the entry in plum_db
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
    Pattern = bondy_registry_entry:key_pattern(RealmUri, SessionId, '_'),
    Opts = [{limit, Limit} | ?MATCH_OPTS],

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
%% @doc Finds entries using the trie.
%% @end
%% -----------------------------------------------------------------------------
-spec find(trie_continuation() | eot()) ->
    Registrations :: [entry()]
    | {Registrations :: [entry()], trie_continuation() | eot()}
    | Subscriptions :: {[entry()], [node()]}
    | {Subscriptions :: {[entry()], [node()]}, trie_continuation() | eot()}
    | eot().

find(?EOT) ->
    ?EOT;

find(Cont0) ->
    try
        #{type := Type} = bondy_registry_trie:continuation_info(Cont0),
        project_trie_res(Type, trie_find(Cont0))

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
-spec find
    (subscription, RealmUri :: uri(), uri()) ->
        {[entry()], [node()]};
    (registration, RealmUri :: uri(), uri()) ->
        [entry()].

find(Type, RealmUri, Uri) ->
    find(Type, RealmUri, Uri, #{}).


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
-spec find
    (subscription, RealmUri :: uri(), uri(), map()) ->
        {[entry()], [node()]}
        | {{[entry()], [node()]}, trie_continuation() | eot()} | eot();
    (registration, RealmUri :: uri(), uri(), map()) ->
        [entry()]
        | {[entry()], trie_continuation() | eot()} | eot().

find(Type, RealmUri, Uri, Opts) ->
    Limit = maps:get(limit, Opts, undefined),

    try
        project_trie_res(Type, trie_find(Type, RealmUri, Uri, Opts))

    catch
        throw:non_eligible_entries when Limit =/= undefined ->
            ?EOT;

        error:Reason:Stacktrace when Limit =/= undefined ->
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
-spec match(trie_continuation() | eot()) ->
    Registrations :: [entry()]
    | {Registrations :: [entry()], trie_continuation() | eot()}
    | Subscriptions :: {[entry()], [node()]}
    | {Subscriptions :: {[entry()], [node()]}, trie_continuation() | eot()}
    | eot().

match(?EOT) ->
    ?EOT;

match(Cont0) ->
    try
        #{type := Type} = bondy_registry_trie:continuation_info(Cont0),
        project_trie_res(Type, trie_match(Cont0))

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
-spec match
    (subscription, RealmUri :: uri(), uri()) ->
        {[entry()], [node()]};
    (registration, RealmUri :: uri(), uri()) ->
        [entry()].

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
-spec match
    (subscription, RealmUri :: uri(), uri(), map()) ->
        {[entry()], [node()]}
        | {{[entry()], [node()]}, trie_continuation() | eot()} | eot();
    (registration, RealmUri :: uri(), uri(), map()) ->
        [entry()]
        | {[entry()], trie_continuation() | eot()} | eot().

match(Type, RealmUri, Uri, Opts) ->
    try
        project_trie_res(Type, trie_match(Type, RealmUri, Uri, Opts))

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
will_merge(_PKey, _New, undefined) ->
    %% [Case 1] If New is an entry rooted in this node we need to delete and
    %% broadcast to the cluster members.
    %% We handle this case in on_merge as we can simply read the entry from
    %% plum_db and immediately delete (without the entry ever being added to
    %% the trie) which sends a broadcast.
    true;

will_merge(_PKey, New, Old) ->
    %% ?LOG_DEBUG(#{
    %%     description => "Will merge called", new => New, old => Old
    %% }),
    NewResolved = maybe_resolve(New),
    NewEntry = plum_db_object:value(NewResolved),
    OldEntry = resolve_value(Old),

    case {NewEntry, OldEntry} of
        {?TOMBSTONE, ?TOMBSTONE} ->
            true;

        {?TOMBSTONE, OldEntry} ->
            case bondy_registry_entry:is_local(OldEntry) of
                true ->
                    %% [Case 2]
                    %% A peer node deleted an entry rooted in this node.
                    %% The entry is still active as we still have it on plum_db.
                    %% This MUST only occur when the other node was
                    %% disconnected from us but we both remained operational
                    %% i.e. a net split. In this situation the other node used
                    %% bondy_registry_entry:dirty_delete/1 which adds a
                    %% tombstone in a deterministic way (by using a static
                    %% ActorID and the original timestamp). It also disables
                    %% broadcast, so the fact that we are handling this here is
                    %% due to an AAE exchange. We need override the delete and
                    %% let all cluster members know the entry is still active.
                    %% To do that we replace the delete with the old value
                    %% while advancing the vector clock.
                    %% plum_db will store this new value locally and broadcast
                    %% the change to the cluster members.
                    Ctxt = plum_db_object:context(New),
                    [{{Partition, _}, _}|_] = Ctxt,
                    ActorId = {Partition, partisan:node()},
                    Modified = plum_db_object:modify(
                        New, Ctxt, OldEntry, ActorId
                    ),
                    {true, Modified};

                false ->
                    %% [Case 3]
                    %% We (A) need to first check if this was deleted by the
                    %% owner (B) or not, and if not, check if we are still
                    %% connected to the owner. If so we MUST ignore. This would
                    %% be the case of node C deleting the entry (as itself got
                    %% disconnected from B but not from us).
                    %% Also we should ignore if merging is disabled.
                    Peer = bondy_registry_entry:node(OldEntry),
                    Status = bondy_table:get(Peer, ?MERGE_STATUS_TAB, enabled),

                    case plum_db_object:context(NewResolved) of
                        [{{_, ?PLUM_DB_REGISTRY_ACTOR}, _}] ->
                            %% Not deleted by the owner, merge only if we are
                            %% disconnected from the owner and merging is
                            %% enabled
                            not partisan:is_connected(Peer)
                                andalso Status == enabled;

                        _ ->
                            %% Deleted by the owner. Merge and handle the
                            %% delete in on_merge/3 if merging is enabled
                            Status == enabled
                    end
            end;

        {NewEntry, ?TOMBSTONE} ->
            case bondy_registry_entry:is_local(NewEntry) of
                true ->
                    %% [Case 4]
                    %% Another node is telling us we are missing an entry that
                    %% is rooted here, this is an inconsistency issue produced
                    %% by the eventual consistency model. Most probably this
                    %% other node has not handled the nodedown signal properly.
                    %% We need to mark it as deleted in plum_db so that the
                    %% other nodes get the event and stop trying to re-surface
                    %% it.
                    %% The following will mark it as deleted and broadcast the
                    %% change to all cluster members.
                    Ctxt = plum_db_object:context(New),
                    [{{Partition, _}, _}|_] = Ctxt,
                    ActorId = {Partition, partisan:node()},
                    Modified = plum_db_object:modify(
                        New, Ctxt, ?TOMBSTONE, ActorId
                    ),
                    {true, Modified};
                false ->
                    %% [Case 5]
                    %% An entry rooted in another node is being resurfaced.
                    %% Most probably we were disconnected from this node and
                    %% marked the entry as deleted but now we got a connection
                    %% back to this node. However, we might not yet have a
                    %% connection with that node but getting this via another
                    %% node, so we need to check. If its not connected we
                    %% return false, ignoring the merge (retaining our
                    %% tombstone). If connected we check if merging is enabled (
                    %% disabled during pruning).
                    Peer = bondy_registry_entry:node(NewEntry),
                    Status = bondy_table:get(Peer, ?MERGE_STATUS_TAB, enabled),

                    partisan:is_connected(Peer) andalso Status == enabled
            end;

        {Val, Val} ->
            %% This should not happen. It would be an issue in plum_db but just
            %% in case we deal with it
            false

    end.


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
    %% Every time a node goes up/down we get an info message
    ok = partisan:monitor_nodes(true),

    %% We create a table allowing us to suspend merging data with a node
    %% during a prune operation.
    %% When a node gets disconnected we need to 'dirty_delete' its entries in
    %% case the node never comes back e.g. pruning. During pruning we might get
    %% entries from the disconnected node either because it re-connects sends
    %% broadcasts or performs an AAE exchange or because a third node which is
    %% still connected to it and to us is performing an AAE exchange (this
    %% latter case means we cannot simply decide to postpone the reconnection
    %% of the disconnected node e.g. via Partisan).
    %% The apprach is for the will_merge/3 callback to use this table to check
    %% the registry merge status for a node i.e. suspended | running.
    ?MERGE_STATUS_TAB = bondy_table:new(?MERGE_STATUS_TAB, protected, true),

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


handle_info({nodeup, _Node} = Event, State) ->
    ?LOG_DEBUG(#{event => Event}),
    {noreply, State};

handle_info({nodedown, Node} = Event, State) ->
    ?LOG_DEBUG(#{event => Event}),
    Tref = erlang:send_after(5000, self(), {prune, Node}),
    Timers = (State#state.timers)#{Node => Tref},
    {noreply, State#state{timers = Timers}};

handle_info({prune_finished, Node} = Event, State) ->
    ?LOG_DEBUG(#{event => Event}),
    ok = bondy_table:put(Node, enabled, ?MERGE_STATUS_TAB),
    {noreply, State};

handle_info({prune, Node} = Event, State) ->
    %% A connection with node has gone down
    ?LOG_DEBUG(#{event => Event}),
    ok = prune(Node),
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
    KeyPattern = bondy_registry_entry:key_pattern(RealmUri, SessionId, '_'),
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
            ok = maybe_remote_index_do(add, Entry),
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
    Match = maps:get(match, Opts, ?EXACT_MATCH),
    PBR = bondy_config:get([dealer, pattern_based_registration], true),

    try

        Match =/= ?EXACT_MATCH andalso PBR == false
            andalso throw(pattern_based_registration_disabled),

        Invoke == ?INVOKE_SINGLE orelse Shared == true
            orelse throw(shared_registration_disabled),

        add_registration(RealmUri, Uri, Opts, Ref, Trie)

    catch
        throw:Reason ->
            {error, Reason}
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

    Results = bondy_registry_trie:find(Type, RealmUri, Uri, MOpts, Trie),

    case Results of
        [] ->
            %% No existing registrations for this URI
            Entry = new_registration(RealmUri, Ref, Uri, Opts),
            ok = bondy_registry_entry:store(Entry),
            ok = maybe_remote_index_do(add, Entry),
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

            %% TODO extract this so that it is implemented as a function that
            %% the dealer will send.

            case resolve_inconsistencies(Invoke, SessionId, L) of
                ok ->
                    Entry = new_registration(RealmUri, Ref, Uri, Opts),
                    ok = bondy_registry_entry:store(Entry),
                    ok = maybe_remote_index_do(add, Entry),
                    bondy_registry_trie:add(Entry, Trie);

                {error, {already_exists, _}} = Error ->
                    Error
            end
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
maybe_remote_index_do(Op, Entry) ->
    Nodestring = partisan:nodestring(),

    case bondy_registry_entry:nodestring(Entry) of
        Nodestring ->
            %% Local entry, we skip
            ok;

        Peerstring ->
            %% We choose index partition based on Node and not RealmUri, so
            %% that all entries for a given node are together.
            Index = bondy_registry_partition:remote_index(Peerstring),

            %% We can add/delete concurrently to this index
            case Op of
                add ->
                    bondy_registry_remote_index:add(Entry, Index);
                delete ->
                    bondy_registry_remote_index:delete(Entry, Index)
            end
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc We might have inconsistencies that might have occurred during a net
%% split.
%%
%% There are two cases:
%% 1. Multiple registrations w/invoke == single
%% 2. Multiple registrations with differring invoke strategies
%% @end
%% -----------------------------------------------------------------------------
-spec resolve_inconsistencies(
    Invoke :: binary(),
    SessionId :: optional(bondy_session_id:t()),
    [bondy_registration_trie:registration_match()]
    ) -> ok | {error, any()}.

resolve_inconsistencies(_, _, []) ->
    ok;

resolve_inconsistencies(Invoke, SessionId, L) ->
    Groups = bondy_utils:groups_from_list(
        fun({_, _, _, InvocationPolicy, _}) -> InvocationPolicy end,
        L
    ),
    resolve_inconsistencies(Invoke, SessionId, L, Groups, maps:keys(Groups)).


%% @private
resolve_inconsistencies(_, _, _, Groups, [H]) when H == ?INVOKE_SINGLE ->
    case maps:get(H, Groups) of
        [Match] ->
            %% Result is 'ok' iff entry is missing from main store
            %% (due to inconsistency). Otherwise is the already_exists
            %% error.
            resolve_existing(registration, Match);
        Matches ->
            %% Multiple registrations w/invoke == single
            %% We need to revoke all but the first one registered, so we sort
            Sorted = sort_registration_matches(Matches),

            %% Result is 'ok' iff all entries are missing from main store
            %% (due to inconsistency). Otherwise is the already_exists
            %% error with the first entry alive.
            resolve_duplicates(Sorted)
    end;

resolve_inconsistencies(Invoke, SessionId, _, Groups, [H]) when H == Invoke ->
    %% The registrations are consistent (all using the same invocation
    %% policy). However, we still need to check for duplicates within
    %% the same session.
    Dups = find_registration_duplicates(maps:get(Invoke, Groups), SessionId),
    resolve_duplicates(Dups);

resolve_inconsistencies(_, _, L, _, [_]) ->
    %% The caller is trying to register using an invocation policy
    %% that does not match the one being used so far for this procedure.
    %% We test each one to discard an inconsistency between trie and
    %% main store.
    %% Normally we will get {error, {already_exists, Entry}} where
    %% Entry is the first element in L.
    Sorted = sort_registration_matches(L),
    resolve_existing(registration, Sorted);

resolve_inconsistencies(_, _, L, _, [_|_]) ->
    %% The worse case: 2 or more groups.
    Sorted = sort_registration_matches(L),

    case resolve_existing(registration, Sorted) of
        ok ->
            ok;
        {error, {already_exists, _Entry}} = Error ->
            %% TODO if we have INVOKE_SINGLE, we need to
            %% revoke all other registrations.
            %% if other policy, revoke all registrations for other
            %% policies
            Error
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Sort registration `proc()' index entries by time
%% @end
%% -----------------------------------------------------------------------------
-spec sort_registration_matches(
    [bondy_registration_trie:registration_match()]) ->
    [bondy_registration_trie:registration_match()].

sort_registration_matches(L) ->
    lists:sort(
        fun ({_, _, _, _, TsA}, {_, _, _, _, TsB}) ->
            TsA =< TsB
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

find_registration_duplicates(Quads, SessionId) ->
    [
        Quad
        || {_, EntryKey, IsProxy, _Invoke, _Timestamp} = Quad <- Quads,
            %% Proxy entries can have duplicates, this is
            %% because the handler (proxy) is registering
            %% the entries for multiple remote handlers,
            %% so we filter them out
            false == IsProxy,
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
        ok ->
            resolve_existing(Type, T);
        Error ->
            Error
    end;

resolve_existing(Type, {_IndexKey, EntryKey, _, _, _}) ->
    Opts = [{remove_tombstones, false}, {resolver, lww}],

    case bondy_registry_entry:lookup(Type, EntryKey, Opts) of
        {ok, ?TOMBSTONE} ->
            %% We found an inconsistency between the trie and plum_db.
            %% This is very rare, but we need to cater for it.
            %% TODO
            %% delete_from_trie(registration, RealmUri, TrieKey),
            %% TODO maybe revoke registration (but the client might
            %% crash if it doesn't know it)
            ok;

        {error, not_found} ->
            %% We found an inconsistency between the trie and plum_db.
            %% This is very rare, but we need to cater for it.
            ?LOG_WARNING(#{
                description =>
                    "Inconsistency found in registry. "
                    "An entry found in the trie "
                    "could not be found on the main store.",
                reason => not_found,
                registry_entry_key => EntryKey
            }),

            %% TODO
            %% delete_from_trie(registration, RealmUri, TrieKey),
            %% TODO maybe revoke registration (but the client might
            %% crash if it doesn't know it)
            ok;

        {ok, Entry} ->
            case bondy_registry_entry:is_alive(Entry) of
                true ->
                    {error, {already_exists, Entry}};
                false ->
                    %% It will be eventually pruned, so ignore
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
    bondy_message_id:router(RealmUri).


%% @private
subscription_id(_, #{subscription_id := Val}) ->
    Val;

subscription_id(Uri, _) ->
    bondy_message_id:router(Uri).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
trie_on_merge({{_, RealmUri}, _} = PKey, New, Old) ->
    Pid = bondy_registry_partition:pick(RealmUri),
    Args = [PKey, New, Old], %% + Trie arg appended by bondy_registry_partition
    bondy_registry_partition:async_execute(Pid, fun trie_on_merge/4, Args).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% WARNING: This function must be only be called by trie_on_merge/3 as it
%% assumes it is executing in a registry partition process
%% @end
%% -----------------------------------------------------------------------------
trie_on_merge(_PKey, New, undefined, Trie) ->
    case resolve_value(New) of
        ?TOMBSTONE ->
            %% We got a delete for an entry we do not know anymore.
            %% This could happen when we shutdown or crashed
            %% (while the registry is using ram-only storage).
            %% We assume the tombstone was created with
            %% bondy_registry_entry:dirty_delete/1 and if this was an entry
            %% rooted in this node the result would be the same as if it have
            %% been done locally (idempotence).
            ok;
        NewEntry ->
            case bondy_registry_entry:is_local(NewEntry) of
                true ->
                    %% [Case 1]
                    %% Another node is telling us we are missing an entry that
                    %% is rooted here, this is an inconsistency issue produced
                    %% by the eventual consistency model. Most probably this
                    %% other node has not handled the nodedown signal properly.
                    %% We need to mark it as deleted in plum_db so that the
                    %% other nodes get the event and stop trying to re-surface
                    %% it.
                    %% The following will mark it as deleted and broadcast the
                    %% change to all cluster nodes.
                    ok = bondy_registry_entry:delete(NewEntry);

                false ->
                    maybe_merge(NewEntry, Trie)
            end
    end;

trie_on_merge(_PKey, New, Old, Trie) ->

    case {resolve_value(New), resolve_value(Old)} of
        {?TOMBSTONE, ?TOMBSTONE}  ->
            ok;

        {?TOMBSTONE, OldEntry}  ->
            case bondy_registry_entry:is_local(OldEntry) of
                true ->
                    %% [Case 2] We handled this on will_merge/3;
                    %% We do not need to update the trie
                    ok;

                false ->
                    %% [Case 3]
                    %% We need to delete the entry from the trie (as it was
                    %% deleted from plum_db) but we do not have the key, so we
                    %% use the old value to get the Entry to be deleted.
                    %% This works because registry entries are immutable.
                    ok = maybe_remote_index_do(delete, OldEntry),
                    bondy_registry_trie:delete(OldEntry, Trie)

                end;

        {NewEntry, _} ->
            %% Case 4
            case bondy_registry_entry:is_local(NewEntry) of
                true ->
                    %% [Case 4] Handled by will_merge/3. We do not need to
                    %% update the trie.
                    ok;

                false ->
                    %% [Case 5] Handled by will_merge/3.
                    %% If we are here then the we are connected to the root
                    %% node for Entry, so we add to the trie
                    maybe_merge(NewEntry, Trie)
            end
    end.


%% @private
maybe_merge(Entry, Trie) ->
    Peer = bondy_registry_entry:node(Entry),

    %% Disabled when prunning in progress, we skip merging to
    %% avoid inconsistencies in the trie, we will converge
    %% on a subsequent AAE exchange (if/when merge re-enabled)
    case bondy_table:get(Peer, ?MERGE_STATUS_TAB, enabled) of
        enabled ->
            ok = maybe_remote_index_do(add, Entry),
            %% TODO we need to resolve registrationinconsistencies here, so we
            %% need to reuse the logic of ?MODULE:maybe_add_registration
            _ = bondy_registry_trie:add(Entry, Trie),
            ok;

        disabled ->
            ok
    end.


%% @private
maybe_resolve(Object) ->
    maybe_resolve(Object, lww).


%% @private
maybe_resolve(Object, Resolver) ->
    case plum_db_object:value_count(Object) > 1 of
        true ->
            plum_db_object:resolve(Object, Resolver);
        false ->
            Object
    end.


%% @private
resolve_value(Object) ->
    plum_db_object:value(maybe_resolve(Object)).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
add_indices(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Type = bondy_registry_entry:type(Entry),

    Add = fun(E, Trie) ->
        maybe_remote_index_do(add, E),
        bondy_registry_trie:add(E, Trie)
    end,

    MatchPolicy = bondy_registry_entry:match_policy(Entry),
    Decision = MatchPolicy == ?EXACT_MATCH orelse ?CONCURRENT_ADD(Type),

    case Decision of
        true ->
            Add(Entry, trie(RealmUri));

        false ->
            Pid = bondy_registry_partition:pick(RealmUri),
            bondy_registry_partition:execute(Pid, Add, [Entry], 5000)
    end.


%% @private
delete_indices(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Type = bondy_registry_entry:type(Entry),

    Delete = fun(E, T) ->
        ok = maybe_remote_index_do(delete, Entry),
        ok = bondy_registry_trie:delete(E, T)
    end,

    MatchPolicy = bondy_registry_entry:match_policy(Entry),
    Decision = MatchPolicy == ?EXACT_MATCH orelse ?CONCURRENT_DELETE(Type),

    case Decision of
        true ->
            Delete(Entry, trie(RealmUri));
        false ->
            Pid = bondy_registry_partition:pick(RealmUri),
            bondy_registry_partition:async_execute(Pid, Delete, [Entry])
    end.


%% @private
trie_find(Type, RealmUri, Uri, Opts) ->
    Match = fun(Trie) ->
        bondy_registry_trie:find(Type, RealmUri, Uri, Opts, Trie)
    end,

    case ?CONCURRENT_MATCH(Type) of
        true ->
            Match(trie(RealmUri));

        false ->
            Pid = bondy_registry_partition:pick(RealmUri),
            bondy_registry_partition:execute(Pid, Match, [], 5_000)
    end.


%% @private
trie_find(?EOT) ->
    ?EOT;

trie_find(Cont) ->
    #{
        type := Type,
        realm_uri := RealmUri
    } = bondy_registry_trie:continuation_info(Cont),

    case ?CONCURRENT_MATCH(Type) of
        true ->
            bondy_registry_trie:find(Cont);

        false ->
            Pid = bondy_registry_partition:pick(RealmUri),
            Find = fun(_Trie) ->
                bondy_registry_trie:find(Cont)
            end,
            bondy_registry_partition:execute(Pid, Find, [], 5_000)
    end.


%% @private
trie_match(Type, RealmUri, Uri, Opts0) ->
    Match = fun(Trie) ->
        Fun = bondy_registry_entry:mg_comparator(),
        Opts = Opts0#{sort => Fun},
        bondy_registry_trie:match(Type, RealmUri, Uri, Opts, Trie)
    end,

    case ?CONCURRENT_MATCH(Type) of
        true ->
            Match(trie(RealmUri));

        false ->
            Pid = bondy_registry_partition:pick(RealmUri),
            bondy_registry_partition:execute(Pid, Match, [], 5_000)
    end.


%% @private
trie_match(?EOT) ->
    ?EOT;

trie_match(Cont) ->
    #{
        type := Type,
        realm_uri := RealmUri
    } = bondy_registry_trie:continuation_info(Cont),

    case ?CONCURRENT_MATCH(Type) of
        true ->
            bondy_registry_trie:match(Cont);

        false ->
            Pid = bondy_registry_partition:pick(RealmUri),
            Match = fun(_Trie) ->
                bondy_registry_trie:match(Cont)
            end,
            bondy_registry_partition:execute(Pid, Match, [], 5_000)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Takes the trie matches (index entries and nodes) and returns entries
%% and nodes
%% @end
%% -----------------------------------------------------------------------------
project_trie_res(_, ?EOT) ->
    ?EOT;

project_trie_res(_, {error, Reason}) ->
    error(Reason);

project_trie_res(Type, {{L, Nodes}, Cont})
when Type == subscription, is_list(L), is_list(Nodes) ->
    Entries = lookup_entries(Type, L, []),
    {{Entries, Nodes}, Cont};

project_trie_res(Type, {L, Nodes})
when Type == subscription, is_list(L), is_list(Nodes) ->
    Entries = lookup_entries(Type, L, []),
    {Entries, Nodes};

project_trie_res(Type, {L, Cont}) when Type == registration, is_list(L) ->
    Entries = lookup_entries(Type, L, []),
    {Entries, Cont};

project_trie_res(Type, L) when Type == registration, is_list(L) ->
    lookup_entries(Type, L, []).


%% @private
lookup_entries(_, [], []) ->
    [];

lookup_entries(registration, [], Acc) ->
    lists:sort(bondy_registry_entry:mg_comparator(), Acc);

lookup_entries(subscription, [], Acc) ->
    Acc;

lookup_entries(Type, [H|T], Acc) ->
    EntryKey = entry_key(Type, H),

    case bondy_registry_entry:lookup(Type, EntryKey) of
        {ok, Entry} ->
            lookup_entries(Type, T, [Entry|Acc]);

        {error, not_found} ->
            lookup_entries(Type, T, Acc)
    end.


%% @private
entry_key(registration, {_, Val, _, _, _}) ->
    %% {{Realm, Uri}, EntryKey, IsProxy, Invoke}
    Val;

entry_key(subscription, {_, Val, _}) ->
    %% {{Realm, Uri}, EntryKey, IsProxy}
    Val.


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
        ({_, ?TOMBSTONE}) ->
            ok;

        ({_, Entry}) ->
            %% In the event of another node not terminating properly, the last
            %% sessions' registrations will still be in the DB. This function
            %% ensures no stale entry is restore from the main db to the trie
            %% and that they are removed from the db.
            Node = bondy_config:nodestring(),
            EntryNode = bondy_registry_entry:nodestring(Entry),
            Created = bondy_registry_entry:created(Entry),

            %% IMPORTANT We assume nodes keep their names forever.
            case Node == EntryNode andalso Created < Now of
                true ->
                    %% This entry should have been deleted when node
                    %% crashed or shutdown
                    ?LOG_DEBUG(#{
                        description => "Removing stale entry from plum_db",
                        entry => Entry
                    }),

                    _ = delete_indices(Entry),

                    %% TODO implement and use plum_db:async_delete(.., EntryKey)
                    ok;

                false ->
                    _ = add_indices(Entry),
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
                    "Error while initialising registry trie from store",
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
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

    Res = bondy_registry_entry:match(Cont, ?REMOVE_MATCH_OPTS),

    do_remove_all(Res, SessionId, Fun, Acc);

do_remove_all({[{_EntryKey, Entry}|T], Cont}, SessionId, Fun, Acc) ->
    Session = bondy_registry_entry:session_id(Entry),

    case SessionId =:= Session orelse SessionId == '_' of
        true ->
            ok = delete_indices(Entry),
            %% We delete the entry from plum_db.
            %% This will broadcast the delete to all nodes.
            ok = bondy_registry_entry:delete(Entry),
            %% We continue traversing
            do_remove_all({T, Cont}, SessionId, Fun, [Entry|Acc]);

        false ->
            %% No longer our session
            ok
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
prune(Node) when is_atom(Node) ->
    Nodestring = atom_to_binary(Node, utf8),
    %% We prune all entries from the trie and plum_db
    Index = bondy_registry_partition:remote_index(Nodestring),
    %% TODO use bondy_worker pool
    From = self(),
    Fun = fun() -> do_prune(Node, Index, From) end,
    {_Pid, _Ref} = erlang:spawn_monitor(Fun),
    ok.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
do_prune(Node, Index, From) when is_atom(Node) ->
    case bondy_registry_remote_index:match(Node, 100, Index) of
        ?EOT ->
            From ! {prune_finished, Node};

        {L, ?EOT} ->
            ok = do_prune(Node, Index, From, L),
            From ! {prune_finished, Node};

        {L, ETSCont} ->
            ok = do_prune(Node, Index, From, L),
            do_prune(Node, Index, From, ETSCont)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
do_prune(_Node, _Index, _From, L) when is_list(L) ->
    %% Delete them from Plum_db
    lists:foreach(
        fun({Type, EntryKey}) ->
            case bondy_registry_entry:dirty_delete(Type, EntryKey) of
                undefined ->
                    ?LOG_WARNING(#{
                        description =>
                            "Inconsistency between registry trie "
                            "and main store.",
                        entry_type => Type,
                        entry_key => EntryKey
                    }),
                    ok;

                ?TOMBSTONE ->
                    %% it is not a possible result; TODO: delete it!
                    ok;

                Entry ->
                    delete_indices(Entry)
            end
        end,
        L
    );

do_prune(Node, Index, From, ETSCont0) ->
    case bondy_registry_remote_index:match(ETSCont0) of
        ?EOT ->
            From ! {prune_finished, Node};

        {L, ?EOT} ->
            ok = do_prune(Node, Index, From, L),
            From ! {prune_finished, Node};

        {L, ETSCont} ->
            ok = do_prune(Node, Index, From, L),
            do_prune(Node, Index, From, ETSCont)
    end.



