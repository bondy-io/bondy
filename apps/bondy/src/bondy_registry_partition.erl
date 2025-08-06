%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_registry_partition).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_registry.hrl").

-moduledoc """

""".

-define(IS_TYPE(X), (X == registration orelse X == subscription)).
-define(SERVER_NAME(Index), {?MODULE, Index}).
-define(REGISTRY_REMOTE_IDX_KEY(Index), {?SERVER_NAME(Index), remote_tab}).
-define(REGISTRY_STORE_KEY(Index), {?SERVER_NAME(Index), store}).


-record(state, {
    index               ::  integer(),
    store               ::  bondy_registry_store:t(),
    remote_tab          ::  bondy_registry_remote_index:t(),
    start_ts            ::  pos_integer()
}).


-type execute_fun()     ::  fun((bondy_registry_store:t()) -> execute_ret())
                            | fun((...) -> execute_ret()).
-type execute_ret()     ::  any().

%% Aliases
-type entry()               ::  bondy_registry_entry:t().
-type entry_type()          ::  bondy_registry_entry:entry_type().
-type entry_key()           ::  bondy_registry_entry:key().
-type continuation()        ::  bondy_registry_store:continuation().
-type wildcard(T)           ::  bondy_registry_store:wildcart(T).
-type eot()                 ::  bondy_registry_store:eot().
-type store()               ::  bondy_registry_store:t().
-type find_result()         ::  bondy_registry_store:find_result().
-type match_result()        ::  bondy_registry_store:match_result().
-type reg_match()           ::  bondy_registry_store:reg_match().


-export_type([continuation/0]).
-export_type([eot/0]).
-export_type([store/0]).
-export_type([find_result/0]).
-export_type([match_result/0]).
-export_type([reg_match/0]).


%% SERVER API
-export([async_execute/2]).
-export([async_execute/3]).
-export([execute/2]).
-export([execute/3]).
-export([execute/4]).
-export([info/1]).
-export([pick/1]).
-export([remote_index/1]).
-export([start_link/1]).
-export([store/1]).

%% CRUD APIs
-export([add/2]).
-export([add_indices/2]).
-export([continuation_info/1]).
-export([dirty_delete/2]).
-export([dirty_delete/3]).
-export([find/1]).
-export([find/3]).
-export([find/4]).
-export([fold/4]).
-export([fold/5]).
-export([fold/6]).
-export([lookup/3]).
-export([lookup/2]).
-export([lookup/4]).
-export([lookup/5]).
-export([remove/2]).
-export([remove/3]).
-export([take/2]).

%% INDEX-BASED APIS
-export([match/1]).
-export([match/5]).
-export([find_matches/1]).
-export([find_matches/5]).


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


-doc "Starts the registry partition server".
start_link(Index) ->
    Opts = [{spawn_opt, bondy_config:get([registry, partition_spawn_opts])}],
    ServerName = {via, gproc, bondy_gproc:local_name(?SERVER_NAME(Index))},
    gen_server:start_link(ServerName, ?MODULE, [Index], Opts).


-doc "Returns the pid of the server in based on hashing `Arg`.".
-spec pick(Arg :: binary() | entry()) -> pid().

pick(Arg) when is_binary(Arg) ->
    gproc_pool:pick_worker(?REGISTRY_POOL, Arg);

pick(Arg)  ->
    bondy_registry_entry:is_entry(Arg)
        orelse bondy_registry_entry:is_key(Arg)
        orelse error(badarg),

    pick(bondy_registry_entry:realm_uri(Arg)).


-doc """
Returns the underlying store the partition if `Arg` is a pid. Otherwise hashes
`Arg` to determine the partition pid and then returns its undelying store
""".
-spec store(Arg :: pid() | binary() | entry()) ->
    bondy_registry_store:t() | undefined.

store(Pid) when is_pid(Pid) ->
    persistent_term:get(?REGISTRY_STORE_KEY(Pid), undefined);

store(Arg) when is_binary(Arg) orelse is_tuple(Arg) ->
    store(pick(Arg)).


-doc """
Returns statistical information about the partition.
""".
-spec info(Partition :: pid()) -> #{size => integer(), memory => integer()}.

info(Partition) when is_pid(Partition) ->
    bondy_registry_store:info(store(Partition)).


-spec remote_index(Arg :: integer() | nodestring()) ->
    bondy_registry_remote_index:t() | undefined.

remote_index(Index) when is_integer(Index) ->
    persistent_term:get(?REGISTRY_REMOTE_IDX_KEY(Index), undefined);

remote_index(Nodestring) when is_binary(Nodestring) ->
    %% This is the same hashing algorithm used by gproc_pool but using
    %% gproc_pool:pick to determine the Index is 2x slower.
    %% We assume there gproc will not stop using phash2.
    N = bondy_config:get([registry, partitions]),
    Index = erlang:phash2(Nodestring, N) + 1,
    remote_index(Index).


-spec execute(Partition :: pid(), Fun :: execute_fun()) ->
    execute_ret() | {error, timeout}.

execute(Partition, Fun) ->
    execute(Partition, Fun, []).


-spec execute(Partition :: pid(), Fun :: execute_fun(), Args :: [any()]) ->
    {ok, execute_ret()} | {error, timeout}.

execute(Partition, Fun, Args) ->
    execute(Partition, Fun, Args, 5_000).


-spec execute(
    Partition :: pid(),
    Fun :: execute_fun(),
    Args :: [any()],
    Timeout :: timeout()) -> {ok, execute_ret()} | {error, timeout}.

execute(Partition, Fun, Args, Timeout)
when is_pid(Partition), is_list(Args), is_function(Fun, length(Args)) ->
    try
        gen_server:call(Partition, {execute, Fun, Args}, Timeout)
    catch
        exit:{timeout, _} ->
            {error, timeout}
    end.


-spec async_execute(Partition :: pid(), Fun :: execute_fun()) -> ok.

async_execute(Partition, Fun) ->
    async_execute(Partition, Fun, []).


-spec async_execute(Partition :: pid(), Fun :: execute_fun(), Args :: [any()]) ->
    ok.

async_execute(Partition, Fun, Args)
when is_pid(Partition), is_list(Args), is_function(Fun, length(Args)) ->
    gen_server:cast(Partition, {execute, Fun, Args}).



%% =============================================================================
%% CRUD API
%% =============================================================================



-doc """
Used for adding proxy entries only as it skips all checks.
Fails with `badarg` if  `Entry` is not a proxy entry.
""".
-spec add(Partition :: pid(), entry()) ->
    {ok, IsFirstEntry :: boolean()} | {error, any()}.

add(Partition, Entry) when is_pid(Partition) ->
    Result = bondy_registry_store:add(store(Partition), Entry),
    resulto:then(Result, fun(Value) ->
        _ = add_remote_index(Entry),
        {ok, Value}

    end).


-doc """
The function inserts the indices for an entry.

Indices are inserted concurrently for entries with `exact` or `prefix` matching
policies. However, for `wildcard` policy, the insertion will be serialized
through a trie server.

> #### {.warning}
> This function is used when we received an entry via AAE sync exchange. You
> MUST only use it when you know the entry has been stored in PlumDB.

> #### {.info}
> This is an interim design that will be replaced by a more concurrent one in
> the next releases.
""".
-spec add_indices(Partition :: pid(), Entry :: entry()) ->
    ok | {error, Reason :: any()} | no_return().

add_indices(Partition, Entry) when is_pid(Partition) ->
    Result = bondy_registry_store:add_indices(store(Partition), Entry),
    resulto:then(Result, fun(undefined) ->
        _ = add_remote_index(Entry),
        ok
    end).


-doc "".
-spec remove(Partition :: pid(), Entry :: entry()) -> ok.

remove(Partition, Entry) when is_pid(Partition) ->
    remove(Partition, Entry, #{broadcast => true}).



-doc """
Removes a registration or subscription entry (`bondy_registry_entry:t()`) from
the registry and its indices.

The function first deletes the entry from PlumDB (this is serialised via a
partition server), then deletes the indices.

Indices are deleted concurrently for entries with `exact` or `prefix` matching
policies. However, for `wildcard` policy, the deletion will be serialized
through a trie server.

> #### {.info}
> This is an interim design that will be replaced by a more concurrent one in
> next releases.
""".
-spec remove(Partition :: pid(), Entry :: entry(), Opts :: key_value:t()) -> ok.

remove(Partition, Entry, Opts0) when is_pid(Partition) ->
    Store = store(Partition),
    Opts = key_value:put(broadcast, true, Opts0),
    Result = bondy_registry_store:remove(Store, Entry, Opts),
    resulto:then(Result, fun(undefined) ->
        delete_remote_index(Entry)
    end).

-doc "Removes an entry (and its indices) from the store returning it.".
-spec take(Partition :: pid(), Entry :: entry()) ->
    {ok, StoredEntry :: entry()} | {error, not_found}.

take(Partition, Entry) when is_pid(Partition) ->
    Store = store(Partition),
    Result = bondy_registry_store:take(Store, Entry),
    resulto:then(Result, fun(Value) ->
        ok = delete_remote_index(Value),
        {ok, Value}
    end).


-doc """
WARNING: Never use this unless you know exactly what you are doing!
We use this only when we want to remove a remote entry from the registry as
a result of the owner node being down.
We want to achieve the following:
1. The delete has to be idempotent, so that we avoid having to merge N
versions either during broadcast or AAE exchange. We can use the owners
ActorID and Timestamp for this, manipulating the plum_db_object, a little
bit nasty but effective and almost harmless as entries are immutable anyway.
2. If we can achieve (1) then we could disable broadcast, as all nodes
will be doing (1).
3. We still have the AAE exchange, so (1) has to ensure that the hash of
the object is the same in all nodes. I think that comes naturally from
doing (1) anyway, but we need to check, e.g. timestamp differences?
""".
-spec dirty_delete(Partition :: pid(), entry()) -> entry() | undefined.

dirty_delete(Partition, Entry) when is_pid(Partition) ->
    Result = bondy_registry_store:dirty_delete(store(Partition), Entry),
    resulto:then(Result, fun(Value) ->
        ok = delete_remote_index(Entry),
        {ok, Value}
    end).


-doc """
WARNING: Never use this unless you know exactly what you are doing!
We use this only when we want to remove a remote entry from the registry as
a result of the owner node being down.
We want to achieve the following:
1. The delete has to be idempotent, so that we avoid having to merge N
versions either during broadcast or AAE exchange. We can use the owners
ActorID and Timestamp for this, manipulating the plum_db_object, a little
bit nasty but effective and almost harmless as entries are immutable anyway.
2. If we can achieve (1) then we could disable broadcast, as all nodes
will be doing (1).
3. We still have the AAE exchange, so (1) has to ensure that the hash of
the object is the same in all nodes. I think that comes naturally from
doing (1) anyway, but we need to check, e.g. timestamp differences?
""".
-spec dirty_delete(
    Partition :: pid(), Type :: entry_type(), EntryKey :: entry_key()) ->
    {ok, entry()} | {error, not_found | any()}.

dirty_delete(Partition, Type, EntryKey) when is_pid(Partition) ->
    Store = store(Partition),
    Result = bondy_registry_store:dirty_delete(Store, Type, EntryKey),
    resulto:then(Result, fun(Entry) ->
        ok = delete_remote_index(Entry),
        {ok, Entry}
    end).


-doc "".
-spec lookup(
    Partition :: pid(), IndexEntry :: bondy_registry_store:index_entry()) ->
    {ok, Entry :: entry()} | {error, not_found}.

lookup(Partition, IndexEntry) when is_pid(Partition) ->
    bondy_registry_store:lookup(store(Partition), IndexEntry).


-doc "".
-spec lookup(
    Partition :: pid(), Type :: entry_type(), EntryKey :: entry_key()) ->
    {ok, Entry :: entry()} | {error, not_found}.

lookup(Partition, Type, EntryKey) when is_pid(Partition) ->
    bondy_registry_store:lookup(store(Partition), Type, EntryKey).


-doc "".
-spec lookup(
    Partition :: pid(),
    Type :: entry_type(),
    RealmUri :: uri(),
    EntryId :: id()) ->
    {ok, Entry :: entry()} | {error, not_found}.

lookup(Partition, Type, RealmUri, EntryId) when is_pid(Partition) ->
    Store = store(Partition),
    bondy_registry_store:lookup(Store, Type, RealmUri, EntryId, []).



-doc "".
-spec lookup(
    Partition :: pid(),
    Type :: entry_type(),
    RealmUri :: uri(),
    EntryId :: id(),
    Opts :: key_value:t()) ->
    {ok, Entry :: entry()} | {error, not_found}.

lookup(Partition, Type, RealmUri, EntryId, Opts) ->
    Store = store(Partition),
    bondy_registry_store:lookup(Store, Type, RealmUri, EntryId, Opts).


-doc "".
-spec find(continuation()) -> find_result().

find(Cont) ->
    bondy_registry_store:find(Cont).


-doc """
Finds entries in the registry using a pattern.

This is used for entry maintenance and not for routing. For routing based on
and URI use the `match_` functions instead.
""".
-spec find(pid(), entry_type(), entry_key()) -> [entry()].

find(Partition, Type, Pattern) when ?IS_TYPE(Type) ->
    bondy_registry_store:find(store(Partition), Type, Pattern).


-doc """
Finds entries in the registry using a pattern.

This is used for entry maintenance and not for routing. For routing based on
and URI use the `match_` functions instead.
""".
-spec find(pid(), entry_type(), entry_key(), plum_db:match_opts()) ->
    bondy_registry_store:find_result().

find(Partition, Type, Pattern, Opts) when ?IS_TYPE(Type) ->
    bondy_registry_store:find(store(Partition), Type, Pattern, Opts).


-doc "".
-spec fold(
    Partition :: pid(),
    Fun :: plum_db:fold_fun(),
    Acc :: any(),
    Cont :: continuation()) ->
    any() | {any(), continuation() | eot()}.

fold(Partition, Fun, Acc, Cont) ->
    bondy_registry_store:fold(store(Partition), Fun, Acc, Cont).


-doc "".
-spec fold(
    Partition :: pid(),
    Fun :: plum_db:fold_fun(),
    Acc :: any(),
    Cont :: continuation(),
    Opts :: plum_db:fold_opts()) ->
    any() | {any(), continuation() | eot()}.

fold(Partition, Fun, Acc, Cont, Opts) ->
    bondy_registry_store:fold(store(Partition), Fun, Acc, Cont, Opts).


-doc "".
-spec fold(
    Partition :: pid(),
    Type :: entry_type(),
    RealmUri :: wildcard(uri()),
    Fun :: plum_db:fold_fun(),
    Acc :: any(),
    Opts :: plum_db:fold_opts()) ->
    any() | {any(), continuation() | eot()}.

fold(Partition, Type, RealmUri, Fun, Acc, Opts) ->
    bondy_registry_store:fold(store(Partition), Type, RealmUri, Fun, Acc, Opts).


-doc "".
-spec continuation_info(continuation()) ->
    #{type := entry_type(), realm_uri := uri()}.

continuation_info(Cont) ->
    bondy_registry_store:continuation_info(Cont).



%% =============================================================================
%% INDEX-BASED APIS
%% =============================================================================


-doc """
Continues a match started with `match/5'. The next chunk of the size
specified in the initial `match/5' call is returned together with a new
`Continuation', which can be used in subsequent calls to this function.
When there are no more objects in the table, '$end_of_table' is returned.
""".
-spec match(Continuation :: continuation() | eot()) ->
    bondy_registry_store:match_result().

match(Cont) ->
    bondy_registry_store:match(Cont).



-doc """
Finds entries matching `Type`, `RealmUri` and `Uri`.

This call executes concurrently for entries with `exact` or `prefix` matching
policies. However, for `wildcard` policy, the call will be serialized
through a gen_server.
""".
-spec match(
    Partition :: pid(),
    Type :: entry_type(),
    RealmUri :: uri(),
    Uri :: uri(),
    Opts :: map()
    ) -> match_result().


match(Partition, Type, RealmUri, Uri, Opts) when is_pid(Partition) ->
    bondy_registry_store:match(store(Partition), Type, RealmUri, Uri, Opts).



-doc """
Continues a find started with `find_matches/5'. The next chunk of the size
specified in the initial `find_matches/5' call is returned together with a new
`Continuation', which can be used in subsequent calls to this function.
When there are no more objects in the table, '$end_of_table' is returned.
""".
-spec find_matches(Continuation :: continuation() | eot()) ->
    bondy_registry_store:match_result().

find_matches(Cont) ->
    bondy_registry_store:find_matches(Cont).


-doc """
Finds entries matching `Type`, `RealmUri` and `Uri`.

This call executes concurrently for entries with `exact` or `prefix` matching
policies. However, for `wildcard` policy, the call will be serialized
through a gen_server.
""".
-spec find_matches(
    Partition :: pid(),
    Type :: entry_type(),
    RealmUri :: uri(),
    Uri :: uri(),
    Opts :: map()
    ) -> match_result().


find_matches(Partition, Type, RealmUri, Uri, Opts) when is_pid(Partition) ->
    bondy_registry_store:find_matches(
        store(Partition), Type, RealmUri, Uri, Opts
    ).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([Index]) ->
    %% Trap exists otherwise terminate/1 won't be called when shutdown by
    %% supervisor.
    erlang:process_flag(trap_exit, true),

    %% We connect this worker to the pool worker name
    PoolName = ?REGISTRY_POOL,
    WorkerName = ?SERVER_NAME(Index),
    true = gproc_pool:connect_worker(PoolName, WorkerName),

    Store = bondy_registry_store:new(Index),
    _ = persistent_term:put(?REGISTRY_STORE_KEY(self()), Store),

    Tab = bondy_registry_remote_index:new(Index),
    _ = persistent_term:put(?REGISTRY_REMOTE_IDX_KEY(self()), Tab),

    State = #state{
        index = Index,
        store = Store,
        remote_tab = Tab,
        start_ts = erlang:system_time()
    },
    {ok, State}.


handle_call({execute, Fun, Args}, _From, State) ->
    Result = do_execute(State, Fun, Args),
    {reply, Result, State};

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.



handle_cast({execute, Fun, Args}, State) ->
    _ = do_execute(State, Fun, Args),
    {noreply, State};

handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.



handle_info({'ETS-TRANSFER', _, _, _}, State) ->
    %% The store and remote_index ets tables use bondy_table_manager.
    %% We ignore as tables are named.
    {noreply, State};


handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unexpected_event,
        event => Info
    }),
    {noreply, State}.


terminate(normal, State) ->
    cleanup(State);

terminate(shutdown, State) ->
    cleanup(State);

terminate({shutdown, _}, State) ->
    cleanup(State);

terminate(_Reason, State) ->
    cleanup(State).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.




%% =============================================================================
%% PRIVATE
%% =============================================================================



cleanup(_State) ->
    _ = persistent_term:erase(?REGISTRY_STORE_KEY(self())),
    _ = persistent_term:erase(?REGISTRY_REMOTE_IDX_KEY(self())),
    ok.


do_execute(_State, Fun, []) ->
    try
        resulto:flatten(
            resulto:result(Fun())
        )
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error during async execute",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end;

do_execute(_State, Fun, Args) ->
    try
        resulto:flatten(
            resulto:result(erlang:apply(Fun, Args))
        )
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error during async execute",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            })
    end.

add_remote_index(Entry) ->
    try
        Idx = remote_index(bondy_registry_entry:nodestring(Entry)),
        bondy_registry_remote_index:add(Idx, Entry)
    catch
        _:_ ->
            ok
    end.


delete_remote_index(Entry) ->
    try
        Idx = remote_index(bondy_registry_entry:nodestring(Entry)),
        bondy_registry_remote_index:delete(Idx, Entry)
    catch
        _:_ ->
            ok
    end.
