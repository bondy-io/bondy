%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_store).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_plum_db.hrl").
-include("bondy_registry.hrl").

-moduledoc """
Indeces for matching bondy_registry_entry(s).
""".

-define(IS_TYPE(X), (X == registration orelse X == subscription)).

-define(PDB_FOLD_OPTS, [
    %% NOTICE THIS SHOULD BE KEY SORTED!!!!!
    %% Entries are never modified so by disabling put
    %% (conflict resolution on read) plum_db will read concurrently from
    %% ets.
    {allow_put, false},
    {remove_tombstones, true},
    {resolver, lww}
]).
-define(PDB_GET_OPTS, ?PDB_FOLD_OPTS).
-define(MATCH_POLICIES, [?EXACT_MATCH, ?PREFIX_MATCH, ?WILDCARD_MATCH]).

-record(bondy_registry_store, {
    partition                       ::  pid(),
    index                           ::  integer(),
    %% Registrations w/match_policy == exact (bag) -> concurrent r/w
    reg_exact_idx_tab               ::  ets:tab(),
    %% Registrations w/match_policy == prefix (ordered_set) -> serialised r/w
    reg_prefix_idx_art              ::  art:t(),
    %% Registrations w/match_policy == wildcard (set) -> concurrent r/w
    reg_wc_buffer_tab               ::  ets:tab(),
    %% Registrations w/match_policy == wildcard -> serialised r/w
    reg_wc_idx_art                  ::  art:t(),
    %% Subscriptions w/match_policy == exact (bag) -> concurrent r/w
    sub_local_exact_idx_tab         ::  ets:tab(),
    %% Sbscriptions w/match_policy == exact -> concurrent r/w
    sub_remote_exact_idx_tab        ::  ets:tab(),
    %% Subscriptions w/match_policy == prefix -> serialised r/w
    sub_prefix_idx_art              ::  art:t(),
    %% Subscriptions w/match_policy == wildcard -> concurrent r/w
    sub_wc_buffer_tab               ::  ets:tab(),
    %% Subscriptions w/match_policy == wildcard -> serialised r/w
    sub_wc_idx_art                  ::  art:t(),
    %% Counter per URI, used to distinguish on_create vs.
    %% on_register|on_subscribe -> concurrent r/w
    counters_tab                    ::  ets:tab()
}).

-record(reg_idx, {
    key                         ::  index_key(),
    entry_key                   ::  var(entry_key()),
    is_proxy                    ::  var(boolean()),
    invoke                      ::  var(invoke()),
    timestamp                   ::  var(pos_integer())
}).

-record(sub_idx, {
    key                         ::  index_key(),
    protocol_session_id         ::  var(id()),
    entry_key                   ::  var(entry_key()),
    is_proxy                    ::  var(boolean())
}).

-record(remote_sub_idx, {
    key                         ::  {
                                        RealmUri :: uri(),
                                        MatchPolicy :: binary(),
                                        Uri :: uri()
                                    },
    node                        ::  var(node())
}).

-record(continuation, {
    store                       ::  t(),
    %% undefined when source == plum_db otherwise an entry_type()
    type                        ::  optional(entry_type()),
    function                    ::  atom(),
    policies                    ::  [binary()] | '_',
    %% undefined when source == plum_db otherwise an uri()
    realm_uri                   ::  optional(uri()),
    uri                         ::  uri(),
    opts                        ::  map(),
    source                      ::  ets | art | plum_db,
    original                    ::  optional(
                                        term()
                                        | ets:continuation()
                                        | prefix_continuation()
                                        | eot()
                                    )
}).

-record(prefix_continuation, {
    table                       ::  ets:tab(),
    match_spec                  ::  reg_idx(),
    match_spec_compiled         ::  reference(),
    uri                         ::  uri(),
    next                        ::  optional(index_key() | ?EOT)
}).


-opaque t()                 ::  #bondy_registry_store{}.
-opaque continuation()      ::  #continuation{}.
-type prefix_continuation() ::  #prefix_continuation{}.
-type partial(T)            ::  {T, continuation() | eot()}.
-type reg_idx()             ::  #reg_idx{}.
-type sub_idx()             ::  #sub_idx{}.
-type index_entry()         ::  reg_idx() | sub_idx().
%% -type remote_sub_idx()          ::  #remote_sub_idx{}.
-type index_key()           ::  {RealmUri :: uri(), Uri :: uri()}.
-type invoke()              ::  binary().
-type wildcard(T)           ::  T | '_'.
-type var(T)                ::  wildcard(T) | '$1' | '$2' | '$3' | '$4'.
-type eot()                 ::  ?EOT.
-type find_opts()           ::  plum_db:match_opts().
-type find_result()         ::  eot()
                                | [t()]
                                | partial([t()]).
-type match_opts()          ::  reg_match_opts() | sub_match_opts().
-type reg_match_opts()      ::  #{
                                    %% WAMP match policy
                                    match => wildcard(binary()),
                                    %% WAMP invocation policy
                                    invoke => wildcard(binary()),
                                    sort => bondy_registry_entry:comparator()
                                }.
-type sub_match_opts()      ::  #{
                                    nodestring => wildcard(nodestring()),
                                    node => wildcard(node()),
                                    eligible => [id()],
                                    exclude => [id()],
                                    sort => bondy_registry_entry:comparator()
                                }.
-type match_result()        ::  reg_match_result() | sub_match_result().
-type reg_match_result()    ::  [entry()]
                                | partial([entry()]).
-type sub_match_result()    ::  {[entry()], [node()]}
                                | partial({[entry()], [node()]}).

%% Aliases
-type entry()                   ::  bondy_registry_entry:t().
-type entry_type()              ::  bondy_registry_entry:entry_type().
-type entry_key()               ::  bondy_registry_entry:key().


-export_type([continuation/0]).
-export_type([eot/0]).
-export_type([find_opts/0]).
-export_type([find_result/0]).
-export_type([index_entry/0]).
-export_type([match_opts/0]).
-export_type([match_result/0]).
-export_type([partial/1]).
-export_type([reg_idx/0]).
-export_type([reg_match_opts/0]).
-export_type([reg_match_result/0]).
-export_type([sub_idx/0]).
-export_type([sub_match_opts/0]).
-export_type([sub_match_result/0]).
-export_type([t/0]).


%% STORE APIS
-export([new/1]).
-export([info/1]).

%% ENTRY API
-export([add/2]).
-export([add_indices/2]).
-export([remove/2]).
-export([remove/3]).
-export([dirty_delete/2]).
-export([dirty_delete/3]).
-export([find/1]).
-export([find/2]).
-export([find/3]).
-export([find/4]).
-export([fold/4]).
-export([fold/5]).
-export([fold/6]).
-export([foreach/5]).
-export([lookup/2]).
-export([lookup/3]).
-export([lookup/4]).
-export([lookup/5]).
-export([take/2]).
-export([take/3]).

%% INDEX-BASED APIs
-export([continuation_info/1]).
-export([match/1]).
-export([match/5]).
-export([match_exact/1]).
-export([match_exact/5]).
-export([match_prefix/1]).
-export([match_prefix/5]).
-export([match_wildcard/1]).
-export([match_wildcard/5]).
-export([find_matches/1]).
-export([find_matches/5]).
-export([find_exact_matches/1]).
-export([find_exact_matches/5]).
-export([find_prefix_matches/1]).
-export([find_prefix_matches/5]).
-export([find_wildcard_matches/1]).
-export([find_wildcard_matches/5]).


%% =============================================================================
%% STORE API
%% =============================================================================



-doc """
Returns a new registry store.

The store currently used PlumDB to store all entries and builds a number of
in-memory indices using `ets` and `art`.

The store record contains the references to the `ets` tables and `art`
processes and it is stored for concurrent access via `persistent_term`. This
allows the caller to concurrently access the indices that use `ets` and only
get serialised when accessing PlumDB and `art`.

> #### {.notice}
> In future releases the `art` tries will be replaced by a simpler
> read-concurrent alternative.
""".
-spec new(PartitionIndex :: integer()) -> t().

new(PartitionIndex) ->
    Opts = [
        named_table,
        public,
        {read_concurrency, true},
        {write_concurrency, true},
        {decentralized_counters, true},
        {keypos, 2}
    ],

    %% Registration tables
    {ok, R1} = bondy_table_manager:add_or_claim(
        gen_name(reg_exact_idx_tab, PartitionIndex),
        [bag | Opts]
    ),
    R2 = art:new(gen_name(reg_prefix_idx_art, PartitionIndex), []),
    {ok, R3} = bondy_table_manager:add_or_claim(
        gen_name(reg_wc_buffer_tab, PartitionIndex),
        [set | Opts]
    ),
    R4 = art:new(gen_name(reg_wc_idx_art, PartitionIndex), []),

    %% Subscription tables
    {ok, S1} = bondy_table_manager:add_or_claim(
        gen_name(sub_local_exact_idx_tab, PartitionIndex),
        [bag | Opts]
    ),
    {ok, S2} = bondy_table_manager:add_or_claim(
        gen_name(sub_remote_exact_idx_tab, PartitionIndex),
        [bag | Opts]
    ),
    S3 = art:new(gen_name(sub_prefix_idx_art, PartitionIndex), []),
    {ok, S4} = bondy_table_manager:add_or_claim(
        gen_name(sub_wc_buffer_tab, PartitionIndex),
        [set | Opts]
    ),
    S5 = art:new(gen_name(sub_wc_idx_art, PartitionIndex), []),

    %% Common
    {ok, C1} = bondy_table_manager:add_or_claim(
        gen_name(counters_tab, PartitionIndex),
        [set, {keypos, 1} | Opts]
    ),

    #bondy_registry_store{
        partition = self(),
        index = PartitionIndex,
        %% Registrations
        reg_exact_idx_tab = R1,
        reg_prefix_idx_art = R2,
        reg_wc_buffer_tab = R3,
        reg_wc_idx_art = R4,
        %% Subscriptions
        sub_local_exact_idx_tab = S1,
        sub_remote_exact_idx_tab = S2,
        sub_prefix_idx_art = S3,
        sub_wc_buffer_tab = S4,
        sub_wc_idx_art = S5,
        %% Common
        counters_tab = C1
    }.


-spec info(Store :: t()) -> #{size => integer(), memory => integer()}.

info(#bondy_registry_store{} = Store) ->
    Tabs = [
        Store#bondy_registry_store.reg_exact_idx_tab,
        Store#bondy_registry_store.reg_wc_buffer_tab,
        Store#bondy_registry_store.sub_local_exact_idx_tab,
        Store#bondy_registry_store.sub_wc_buffer_tab,
        Store#bondy_registry_store.sub_remote_exact_idx_tab,
        Store#bondy_registry_store.counters_tab
    ],

    ArtInfo1 = art:info(Store#bondy_registry_store.reg_prefix_idx_art),
    ArtInfo2 = art:info(Store#bondy_registry_store.reg_wc_idx_art),
    ArtInfo3 = art:info(Store#bondy_registry_store.sub_prefix_idx_art),
    ArtInfo4 = art:info(Store#bondy_registry_store.sub_wc_idx_art),


    Size =
        key_value:get(nodes, ArtInfo1) +
        key_value:get(nodes, ArtInfo2) +
        key_value:get(nodes, ArtInfo3) +
        key_value:get(nodes, ArtInfo4) +
        lists:sum([ets:info(Tab, size) || Tab <- Tabs]),

    Mem =
        key_value:get(memory, ArtInfo1) +
        key_value:get(memory, ArtInfo2) +
        key_value:get(memory, ArtInfo3) +
        key_value:get(memory, ArtInfo4) +
        lists:sum([ets:info(Tab, memory) || Tab <- Tabs]),

    #{size => Size, memory => Mem}.


-doc """
Adds a registration or subscription entry (`m:bondy_registry_entry`) and its
indices to the registry.

The function first stores the entry in PlumDB (this is serialised via a
partition server), then inserts the indices.

Indices are inserted concurrently for entries with `exact` or `prefix` matching
policies. However, for `wildcard` policy, the insertion will be serialized
through a trie server.

> #### {.info}
> This is an interim design that will be replaced by a more concurrent one in
> next releases.
""".
-spec add(Store :: t(), Entry :: entry()) ->
    {ok, {entry(), IsFirstEntry :: boolean()}} | {error, Reason :: any()}.

add(#bondy_registry_store{} = Store, Entry) ->
    ok = validate_entry(Entry),

    maybe
      ok ?= store(Store, Entry),
      store_indices(Store, Entry)
    end.


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
-spec add_indices(Store :: t(), Entry :: entry()) ->
    ok | {error, Reason :: any()} | no_return().

add_indices(#bondy_registry_store{} = Store, Entry) ->
    ok = validate_entry(Entry),

    case store_indices(Store, Entry) of
        {ok, _} ->
            ok;

        {error, _} = Error ->
            Error
    end.


-doc "".
-spec remove(Store :: t(), Entry :: entry()) -> ok.

remove(Store, Entry) ->
    remove(Store, Entry, #{broadcast => true}).


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
-spec remove(Store :: t(), Entry :: t(), Opts :: map()) -> ok.

remove(#bondy_registry_store{} = Store, Entry, Opts) ->
    ok = validate_entry(Entry),

    maybe
        ok ?= delete(
            Store,
            bondy_registry_entry:type(Entry),
            bondy_registry_entry:key(Entry),
            Opts
        ),
        delete_indices(Store, Entry)
    end.


-doc "Removes an entry (and its indices) from the store returning it.".
-spec take(Store :: t(), Entry :: entry()) ->
    {ok, StoredEntry :: entry()} | {error, not_found}.

take(Store, Entry) ->
    take(
        Store,
        bondy_registry_entry:type(Entry),
        bondy_registry_entry:key(Entry)
    ).


-doc "Removes an entry (and its indices) from the store returning it.".
-spec take(Store :: t(), Type :: entry_type(), EntryKey :: entry_key()) ->
    {ok, Entry :: entry()} | {error, not_found}.

take(#bondy_registry_store{} = Store, Type, EntryKey) when ?IS_TYPE(Type) ->
    ok = validate_key(EntryKey),
    PDBPrefix = pdb_prefix(Type, bondy_registry_entry:realm_uri(EntryKey)),

    case plum_db:take(PDBPrefix, EntryKey) of
        undefined ->
            {error, not_found};

        Entry ->
            Result = delete_indices(Store, Entry),
            resulto:then(Result, fun(_) -> {ok, Entry} end)
    end.


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
-spec dirty_delete(t(), entry()) -> entry() | undefined.

dirty_delete(#bondy_registry_store{} = Store, Entry) ->
    dirty_delete(
        Store, bondy_registry_entry:type(Entry), bondy_registry_entry:key(Entry)
    ).


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
    Store :: t(), Type :: entry_type(), EntryKey :: entry_key()) ->
    {ok, entry()} | {error, not_found | any()}.

dirty_delete(#bondy_registry_store{} = Store, Type, EntryKey) ->
    PDBPrefix = pdb_prefix(Type, bondy_registry_entry:realm_uri(EntryKey)),

    case plum_db:get_object({PDBPrefix, EntryKey}) of
        {ok, {object, Clock} = Obj0} ->
            %% We use a static fake ActorID and the original timestamp so that
            %% the tombstone is deterministic.
            %% This allows the operation to be idempotent when performed
            %% concurrently by multiple nodes. Idempotency is a requirement so
            %% that the hash of the object compares equal between nodes
            %% irrespective of which created it.
            %% Also the ActorID helps us determine this is a dirty delete.
            Partition = plum_db:get_partition({PDBPrefix, EntryKey}),
            ActorId = {Partition, ?PLUM_DB_REGISTRY_ACTOR},
            Context = plum_db_object:context(Obj0),
            [{_, Timestamp}] = plum_db_dvvset:values(Clock),
            InsertRec = plum_db_dvvset:new(Context, {?TOMBSTONE, Timestamp}),

            %% We create a new object
            Obj = {object, plum_db_dvvset:update(InsertRec, Clock, ActorId)},

            %% We must resolve the object before calling dirty_put/4.
            Resolved = plum_db_object:resolve(Obj, lww),

            %% Avoid broadcasting, the primary objective of this delete is to
            %% remove the local replica of an entry when we get disconnected
            %% from its root node.
            %% Every node will do the same, so if this is a node crashing we
            %% would have a tsunami of deletes being broadcasted.
            %% We will achieve convergence via AAE on our next exchange.
            Opts = [{broadcast, false}],

            ok = plum_db:dirty_put(PDBPrefix, EntryKey, Resolved, Opts),

            %% We return the original value
            Entry = plum_db_object:value(Obj0),
            Result = delete_indices(Store, Entry),
            resulto:then(Result, fun(_) -> {ok, Entry} end);

        {error, _} = Error ->
            Error

    end.


-doc "".
-spec lookup(Store :: t(), IndexEntry :: index_entry()) ->
    {ok, Entry :: entry()} | {error, not_found}.

lookup(Store, #reg_idx{entry_key = EntryKey}) ->
    lookup(Store, registration, EntryKey);

lookup(Store, #sub_idx{entry_key = EntryKey}) ->
    lookup(Store, subscription, EntryKey).



-doc "".
-spec lookup(Store :: t(), Type :: entry_type(), EntryKey :: entry_key()) ->
    {ok, Entry :: entry()} | {error, not_found}.

lookup(Store, Type, EntryKey) when ?IS_TYPE(Type) ->
    lookup(Store, Type, EntryKey, ?PDB_GET_OPTS).


-doc "".
-spec lookup(
    Store :: t(),
    Type :: entry_type(),
    EntryKey :: entry_key(),
    Opts :: plum_db:get_opts()) -> {ok, Entry :: entry()} | {error, not_found}.

lookup(#bondy_registry_store{} = _Store, Type, EntryKey, Opts0)
when ?IS_TYPE(Type) ->
    ok = validate_key(EntryKey),
    PDBPrefix = pdb_prefix(Type, bondy_registry_entry:realm_uri(EntryKey)),
    Opts = lists:keymerge(1, lists:sort(Opts0), ?PDB_GET_OPTS),

    case plum_db:get(PDBPrefix, EntryKey, Opts) of
        undefined ->
            {error, not_found};

        Entry ->
            {ok, Entry}
    end.


-doc "".
-spec lookup(
    Store :: t(),
    Type :: entry_type(),
    RealmUri :: uri(),
    EntryId :: id(),
    Opts :: map()) ->
    {ok, Entry :: entry()} | {error, not_found}.

lookup(#bondy_registry_store{} = _Store, Type, RealmUri, EntryId, Opts0)
when ?IS_TYPE(Type) ->
    PDBPrefix = pdb_prefix(Type, RealmUri),
    Pattern = bondy_registry_entry:key_pattern(RealmUri, '_', EntryId),
    Opts = lists:keymerge(1, lists:sort(Opts0), ?PDB_FOLD_OPTS),

    case plum_db:match(PDBPrefix, Pattern, Opts) of
        [{_, Entry}] ->
            {ok, Entry};

        [] ->
            {error, not_found}
    end.


-doc "".
-spec find(continuation()) -> find_result().

find(Cont) ->
    find(Cont, ?PDB_FOLD_OPTS).


-doc "".
-spec find(continuation(), plum_db:match_opts()) -> find_result().

find(#continuation{source = plum_db, original = Cont0} = C, Opts0)
when is_list(Opts0) ->
    Opts = lists:keymerge(1, lists:sort(Opts0), ?PDB_FOLD_OPTS),

    case plum_db:match(Cont0, Opts) of
        {L, Cont1} when Cont1 =/= ?EOT ->
            {L, C#continuation{original = Cont1}};

        Other ->
            Other
    end.


-doc """
Finds entries in the registry using a pattern.

This is used for entry maintenance and not for routing. For routing based on
and URI use the `match_` functions instead.
""".
-spec find(t(), entry_type(), entry_key()) -> [entry()].

find(_Store, Type, Pattern) when ?IS_TYPE(Type) ->
    ok = validate_key(Pattern),
    find(Type, Pattern, ?PDB_FOLD_OPTS).


-spec find(t(), entry_type(), entry_key(), plum_db:match_opts()) ->
    find_result().

find(Store, Type, Pattern, Opts0) when ?IS_TYPE(Type) ->
    ok = validate_key(Pattern),
    RealmUri = bondy_registry_entry:realm_uri(Pattern),
    PDBPrefix = pdb_prefix(Type, RealmUri),
    Opts = lists:keymerge(1, lists:sort(Opts0), ?PDB_FOLD_OPTS),

    case plum_db:match(PDBPrefix, Pattern, Opts) of
        L when is_list(L) ->
            L;

        {L, C} when C =/= ?EOT ->
            Cont = #continuation{
                store = Store,
                type = Type,
                function = ?FUNCTION_NAME,
                realm_uri = RealmUri,
                opts = Opts,
                source = plum_db,
                original = C
            },
            {L, Cont};

        Other ->
            Other
    end.


-doc "".
-spec fold(
    Store :: t(),
    Fun :: plum_db:fold_fun(),
    Acc :: any(),
    Cont :: continuation()) -> any() | partial(any()).

fold(_Store, Fun, Acc, Cont) ->
    fold(_Store, Fun, Acc, Cont, ?PDB_FOLD_OPTS).


-doc "".
-spec fold(
    Store :: t(),
    Fun :: plum_db:fold_fun(),
    Acc :: any(),
    Cont :: continuation(),
    Opts :: plum_db:fold_opts()) -> any() | partial(any()).

fold(Store, Fun, Acc, #continuation{source = plum_db, original = C0}, Opts0) ->
    Opts = lists:keymerge(1, lists:sort(Opts0), ?PDB_FOLD_OPTS),

    case plum_db:fold(Fun, Acc, C0, Opts) of
        {L, C1} when C1 =/= ?EOT ->
            Cont = #continuation{
                store = Store,
                type = undefined,
                function = ?FUNCTION_NAME,
                realm_uri = undefined,
                opts = Opts,
                source = plum_db,
                original = C1
            },
            {L, Cont};

        Other ->
            Other
    end.


-doc "".
-spec fold(
    Store :: t(),
    Type :: entry_type(),
    RealmUri :: wildcard(uri()),
    Fun :: plum_db:fold_fun(),
    Acc :: any(),
    Opts :: plum_db:fold_opts()) -> any() | partial(any()).

fold(Store, Type, RealmUri, Fun, Acc, Opts0) when ?IS_TYPE(Type) ->
    PDBPrefix = pdb_prefix(Type, RealmUri),
    Opts = lists:keymerge(1, lists:sort(Opts0), ?PDB_FOLD_OPTS),

    case plum_db:fold(Fun, Acc, PDBPrefix, Opts) of
        L when is_list(L) ->
            L;

        {L, Cont1} when Cont1 =/= ?EOT ->
            C = #continuation{
                store = Store,
                type = Type,
                function = ?FUNCTION_NAME,
                realm_uri = RealmUri,
                opts = Opts,
                source = plum_db,
                original = Cont1
            },
            {L, C};

        Other ->
            Other
    end.


-doc "".
-spec foreach(
    Store :: t(),
    Type :: entry_type(),
    RealmUri :: uri(),
    Fun :: plum_db:foreach_fun(),
    Opts :: plum_db:fold_opts()) -> ok.

foreach(_Store, Type, RealmUri, Fun, Opts0) when ?IS_TYPE(Type) ->
    PDBPrefix = pdb_prefix(Type, RealmUri),
    Opts = lists:keymerge(1, lists:sort(Opts0), ?PDB_FOLD_OPTS),

    plum_db:foreach(Fun, PDBPrefix, Opts).


-doc "".
-spec continuation_info(continuation()) ->
    #{type := entry_type(), realm_uri := uri()}.

continuation_info(#continuation{type = Type, realm_uri = RealmUri}) ->
    #{type => Type, realm_uri => RealmUri}.



%% =============================================================================
%% INDEX-BASED APIS
%% =============================================================================



-doc """
Finds entries matching `Type`, `RealmUri` and `Uri`.

This call executes concurrently for entries with `exact` or `prefix` matching
policies. However, for `wildcard` policy, the call will be serialized
through a gen_server.
""".
-spec match(
    Store :: t(),
    Type :: entry_type(),
    RealmUri :: uri(),
    Uri :: uri(),
    Opts :: map()
    ) -> match_result().


match(Store, Type, RealmUri, Uri, Opts) ->
    Limit = maps:get(limit, Opts, undefined),
    Policy = maps:get(match, Opts, '_'),

    case {Policy, Limit} of
        {'_', undefined} ->
            ExactRes = match_exact(Store, Type, RealmUri, Uri, Opts),
            PrefixRes = match_prefix(Store, Type, RealmUri, Uri, Opts),
            WildRes = match_wildcard(Store, Type, RealmUri, Uri, Opts),
            merge_results([ExactRes, PrefixRes, WildRes], Type, match);

        {'_', N} when is_integer(N), N > 0 ->
            match_each(Store, Type, RealmUri, Uri, Opts, ?MATCH_POLICIES);

        {?EXACT_MATCH, _} ->
            match_exact(Store, Type, RealmUri, Uri, Opts);

        {?PREFIX_MATCH, _} ->
            match_prefix(Store, Type, RealmUri, Uri, Opts);

        {?WILDCARD_MATCH, _} ->
            match_wildcard(Store, Type, RealmUri, Uri, Opts)
    end.


-doc """
Continues a match started with `match/5'. The next chunk of the size
%% specified in the initial `match/5' call is returned together with a new
%% `Continuation', which can be used in subsequent calls to this function.
%% When there are no more objects in the table, '$end_of_table' is returned.
""".
-spec match(Continuation :: continuation() | eot()) -> match_result().

match(?EOT) ->
    ?EOT;

match(#continuation{function = Name} = C) when Name =/= find ->
    error(badarg, [C]);

match(#continuation{policies = []}) ->
    ?EOT;

match(#continuation{policies = [?EXACT_MATCH]} = C) ->
    match_exact(C);

match(#continuation{policies = [?PREFIX_MATCH]} = C) ->
    match_prefix(C);

match(#continuation{policies = [?WILDCARD_MATCH]} = C) ->
    match_wildcard(C);

match(#continuation{policies = [H | T]} = C) ->
    case match(C#continuation{policies = [H]}) of
        ?EOT ->
            Type = C#continuation.type,
            RealmUri = C#continuation.realm_uri,
            Uri = C#continuation.uri,
            Opts = C#continuation.opts,
            Store = C#continuation.store,
            match_each(Store, Type, RealmUri, Uri, Opts, T);

        Result ->
            Result
    end.


-doc """
Continues a match started with `match_exact/5`. The next chunk of the size
specified in the initial `match_exact/5` call is returned together with a new
`Continuation`, which can be used in subsequent calls to this function.

When there are no more objects in the table, `'$end_of_table'` is returned.
""".
match_exact(#continuation{type = registration} = C0) ->
    Store = C0#continuation.store,

    case ets:select(C0#continuation.original) of
        ?EOT ->
            Type = C0#continuation.type,
            RealmUri = C0#continuation.realm_uri,
            Uri = C0#continuation.uri,
            Opts = C0#continuation.opts,

            case match_exact(Store, Type, RealmUri, Uri, Opts) of
                ?EOT ->
                    ?EOT;

                {L, ?EOT} ->
                    {project(Store, L), ?EOT};

                {L, C1} ->
                    C = C1#continuation{original = ?EOT},
                    {project(Store, L), C}
            end;

        {L, Cont} ->
            C = C0#continuation{original = Cont},
            {project(Store, L), C}
    end;

match_exact(#continuation{type = subscription} = C) ->
    L = match_local_exact_subscription(C),
    R = match_remote_exact_subscription(C),
    zip_local_remote(L, R).


-doc """
Finds entries matching `Type`, `RealmUri` and `Uri` and the `prefix` policy.

This call executes concurrently.
""".
-spec match_exact(t(), entry_type(), uri(), uri(), map()) -> reg_match_result().

match_exact(Store, registration, RealmUri, Uri, Opts) ->
    %% This option might be passed for admin purposes, not during a call
    Invoke = maps:get(invoke, Opts, '_'),
    Tab = Store#bondy_registry_store.reg_exact_idx_tab,
    Pattern = #reg_idx{
        key = {RealmUri, Uri},
        entry_key = '_',
        is_proxy = '_',
        invoke = '$1',
        timestamp = '_'
    },
    Conds =
        case Invoke of
            '_' ->
                [];

            _ ->
                [{'=:=', '$1', Invoke}]
        end,

    MS = [{ Pattern, Conds, ['$_'] }],

    case ets_select(Tab, MS, Opts)  of
        ?EOT ->
            ?EOT;

        L when is_list(L) ->
            project(Store, L);

        {L, ETSCont} ->
            Policies = maps:get(match, Opts, ?MATCH_POLICIES),

            C = #continuation{
                type = registration,
                function = ?FUNCTION_NAME,
                realm_uri = RealmUri,
                uri = Uri,
                policies = Policies,
                opts = Opts,
                store = Store,
                source = ets,
                original = ETSCont
            },
            {project(Store, L), C}
    end;


match_exact(Store, subscription, RealmUri, Uri, Opts) ->
    L = match_local_exact_subscription(Store, RealmUri, Uri, Opts),
    R = match_remote_exact_subscription(Store, RealmUri, Uri, Opts),
    zip_local_remote(L, R).



-doc """
Continues a match started with `match_prefix/5`. The next chunk of the size
specified in the initial `match_prefix/5` call is returned together with a new
`Continuation`, which can be used in subsequent calls to this function.

When there are no more objects in the table, `'$end_of_table'` is returned.
""".
match_prefix(?EOT) ->
    ?EOT;

match_prefix(#continuation{}) ->
    %% ART does not support limits yet
    ?EOT.


-doc """
Finds entries matching `Type`, `RealmUri` and `Uri` and the `prefix` policy.

This call executes concurrently.
""".
-spec match_prefix(t(), entry_type(), uri(), uri(), map()) -> match_result().

match_prefix(Store, Type, RealmUri, Uri, Opts) when Type == registration ->
    ART = Store#bondy_registry_store.reg_prefix_idx_art,
    art_match(Store, Type, RealmUri, Uri, Opts, ART);

match_prefix(Store, Type, RealmUri, Uri, Opts) when Type == subscription ->
    ART = Store#bondy_registry_store.sub_prefix_idx_art,
    art_match(Store, Type, RealmUri, Uri, Opts, ART).


-doc """
At the moment this call always returns `'$end_of_table'`.
""".
-spec match_wildcard(continuation()) -> match_result().

match_wildcard(?EOT) ->
    ?EOT;

match_wildcard(#continuation{}) ->
    %% ART does not support limits yet
    ?EOT.


-doc """
Finds entries matching `Type`, `RealmUri` and `Uri` and the `wildcard` policy.

This call is serialised through a partition server.
""".
-spec match_wildcard(t(), entry_type(), uri(), uri(), map()) -> match_result().

match_wildcard(Store, Type, RealmUri, Uri, Opts)
when Type == registration ->
    ART = Store#bondy_registry_store.reg_wc_idx_art,
    art_match(Store, Type, RealmUri, Uri, Opts, ART);

match_wildcard(Store, Type, RealmUri, Uri, Opts)
when Type == subscription ->
    ART = Store#bondy_registry_store.sub_wc_idx_art,
    art_match(Store, Type, RealmUri, Uri, Opts, ART).


-doc """
Returns a list of all entries, where their key subsumes `Uri`.
i.e. this function treats the stored entries as patterns that are used to match
`Uri`.

This call executes concurrently for entries with `exact` or `prefix` matching
policies. However, for `wildcard` policy, the call will be serialized
through a gen_server.
""".
-spec find_matches(
    Store :: t(),
    Type :: entry_type(),
    RealmUri :: uri(),
    Uri :: uri(),
    Opts :: map()
    ) -> match_result().


find_matches(Store, Type, RealmUri, Uri, Opts) ->
    Limit = maps:get(limit, Opts, undefined),
    Policy = maps:get(match, Opts, '_'),

    case {Policy, Limit} of
        {'_', undefined} ->
            ExactRes = find_exact_matches(Store, Type, RealmUri, Uri, Opts),
            PrefixRes = find_prefix_matches(Store, Type, RealmUri, Uri, Opts),
            WildRes = find_wildcard_matches(Store, Type, RealmUri, Uri, Opts),
            merge_results([ExactRes, PrefixRes, WildRes], Type, match);

        {'_', N} when is_integer(N), N > 0 ->
            find_exact_matches(Store, Type, RealmUri, Uri, Opts);

        {?EXACT_MATCH, _} ->
            find_exact_matches(Store, Type, RealmUri, Uri, Opts);

        {?PREFIX_MATCH, _} ->
            find_prefix_matches(Store, Type, RealmUri, Uri, Opts);

        {?WILDCARD_MATCH, _} ->
            find_wildcard_matches(Store, Type, RealmUri, Uri, Opts)
    end.


-doc """
Continues a search started with `find_matches/5'. The next chunk of the size
specified in the initial `find_matches/5' call is returned together with a new
`Continuation', which can be used in subsequent calls to this function.
When there are no more objects in the table, '$end_of_table' is returned.
""".
-spec find_matches(Continuation :: continuation() | eot()) -> match_result().

find_matches(?EOT) ->
    ?EOT;

find_matches(#continuation{function = Name} = C) when Name =/= find ->
    error(badarg, [C]);

find_matches(#continuation{policies = []}) ->
    ?EOT;

find_matches(#continuation{policies = [?EXACT_MATCH]} = C) ->
    find_exact_matches(C);

find_matches(#continuation{policies = [?PREFIX_MATCH]} = C) ->
    find_prefix_matches(C);

find_matches(#continuation{policies = [?WILDCARD_MATCH]} = C) ->
    find_wildcard_matches(C);

find_matches(#continuation{policies = [H | T]} = C) ->
    case find_matches(C#continuation{policies = [H]}) of
        ?EOT ->
            Type = C#continuation.type,
            RealmUri = C#continuation.realm_uri,
            Uri = C#continuation.uri,
            Opts = C#continuation.opts,
            Store = C#continuation.store,
            find_matches_each(Store, Type, RealmUri, Uri, Opts, T);

        Result ->
            Result
    end.


-doc """
Continues a match started with `find_exact_matches/5`. The next chunk of the size
specified in the initial `find_exact_matches/5` call is returned together with a
new `Continuation`, which can be used in subsequent calls to this function.

When there are no more objects in the table, `'$end_of_table'` is returned.
""".
find_exact_matches(#continuation{} = C) ->
    %% For exact this is equivalent to match_exact
    match_exact(C).


-doc """
Finds entries matching `Type`, `RealmUri` and `Uri` and the `prefix` policy.

This call executes concurrently.
""".
-spec find_exact_matches(t(), entry_type(), uri(), uri(), map()) -> reg_match_result().

find_exact_matches(Store, Type, RealmUri, Uri, Opts) ->
    %% For exact this is equivalent to match_exact
    match_exact(Store, Type, RealmUri, Uri, Opts).


-doc """
At the moment this call always returns `'$end_of_table'`.
""".
find_prefix_matches(?EOT) ->
    ?EOT;

find_prefix_matches(#continuation{}) ->
    %% ART does not support limits yet
    ?EOT.


-doc """
Finds entries matching `Type`, `RealmUri` and `Uri` and the `prefix` policy.

This call executes concurrently.
""".
-spec find_prefix_matches(t(), entry_type(), uri(), uri(), map()) ->
    match_result().

find_prefix_matches(Store, Type, RealmUri, Uri, Opts)
when Type == registration ->
    ART = Store#bondy_registry_store.reg_prefix_idx_art,
    art_find_matches(Store, Type, RealmUri, Uri, Opts, ART);

find_prefix_matches(Store, Type, RealmUri, Uri, Opts)
 when Type == subscription ->
    ART = Store#bondy_registry_store.sub_prefix_idx_art,
    art_find_matches(Store, Type, RealmUri, Uri, Opts, ART).


-doc """
At the moment this call always returns `'$end_of_table'`.
""".
-spec find_wildcard_matches(continuation()) -> match_result().

find_wildcard_matches(?EOT) ->
    ?EOT;

find_wildcard_matches(#continuation{}) ->
    %% ART does not support limits yet
    ?EOT.


-doc """
Finds entries matching `Type`, `RealmUri` and `Uri` and the `wildcard` policy.

This call is serialised through the ART server.
""".
-spec find_wildcard_matches(t(), entry_type(), uri(), uri(), map()) ->
    match_result().

find_wildcard_matches(Store, Type, RealmUri, Uri, Opts)
when Type == registration ->
    ART = Store#bondy_registry_store.reg_wc_idx_art,
    art_find_matches(Store, Type, RealmUri, Uri, Opts, ART);

find_wildcard_matches(Store, Type, RealmUri, Uri, Opts)
when Type == subscription ->
    ART = Store#bondy_registry_store.sub_wc_idx_art,
    art_find_matches(Store, Type, RealmUri, Uri, Opts, ART).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
validate_entry(Entry) ->
    bondy_registry_entry:is_entry(Entry)
        orelse ?ERROR(badarg, [Entry], #{
            1 => "is not a bondy_registry_entry:t()"
        }),
    ok.


%% @private
validate_key(Entry) ->
    bondy_registry_entry:is_key(Entry)
        orelse ?ERROR(badarg, [Entry], #{
            1 => "is not a bondy_registry_entry:key()"
        }),
    ok.


%% -----------------------------------------------------------------------------
%% @private
%% Generates a dynamic ets table name given a generic name and and index
%% (partition number).
%% -----------------------------------------------------------------------------
gen_name(Name, Index) when is_atom(Name), is_integer(Index) ->
    list_to_atom(
        "bondy_registry_store_"
        ++ integer_to_list(Index)
        ++ "_"
        ++ atom_to_list(Name)
    ).


%% =============================================================================
%% PRIVATE: CRUD
%% =============================================================================


%% @private
pdb_prefix(registration, RealmUri)
when is_binary(RealmUri) orelse RealmUri == '_' ->
    ?PLUM_DB_REGISTRATION_PREFIX(RealmUri);

pdb_prefix(subscription, RealmUri)
when is_binary(RealmUri) orelse RealmUri == '_' ->
    ?PLUM_DB_SUBSCRIPTION_PREFIX(RealmUri).


%% @private
%% Inserts the entry in plum_db. This will broadcast the delete amongst
%% the nodes in the cluster.
%% It will also called the `on_update/3' callback if enabled.
-spec store(t(), Entry :: bondy_registry_entry:t()) -> ok | {error, any()}.

store(_T, Entry) ->
    %% to be replaced with local-only ets table and globally replicated summmary
    PDBPrefix = pdb_prefix(
        bondy_registry_entry:type(Entry),
        bondy_registry_entry:realm_uri(Entry)
    ),
    Key = bondy_registry_entry:key(Entry),
    plum_db:put(PDBPrefix, Key, Entry).


%% @private
-spec delete(
    Store :: t(),
    Type :: entry_type(),
    EntryKey :: entry_key(),
    Opts :: map()) -> ok.

delete(#bondy_registry_store{} = _Store, Type, EntryKey, Opts)
when ?IS_TYPE(Type) ->
    PDBPrefix = pdb_prefix(Type, bondy_registry_entry:realm_uri(EntryKey)),
    PDBOpts = #{broadcast => maps:get(broadcast, Opts, true)},
    plum_db:delete(PDBPrefix, EntryKey, PDBOpts).



%% =============================================================================
%% PRIVATE: INDICES
%% =============================================================================



%% @private
reg_idx(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    EntryKey = bondy_registry_entry:key(Entry),
    IsProxy = bondy_registry_entry:is_proxy(Entry),
    Invoke = bondy_registry_entry:get_option(invoke, Entry, ?INVOKE_SINGLE),
    Timestamp = bondy_registry_entry:created(Entry),

    #reg_idx{
        key = {RealmUri, Uri},
        entry_key = EntryKey,
        is_proxy = IsProxy,
        invoke = Invoke,
        timestamp = Timestamp
    }.


%% @private
sub_idx(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    EntryKey = bondy_registry_entry:key(Entry),
    IsProxy = bondy_registry_entry:is_proxy(Entry),

    #sub_idx{
        key = {RealmUri, Uri},
        entry_key = EntryKey,
        is_proxy = IsProxy
    }.


%% @private
-spec store_indices(Store :: t(), Entry :: entry()) ->
    {ok, {entry(), IsFirstEntry :: boolean()}} | {error, any()}.

store_indices(#bondy_registry_store{} = Store, Entry) ->
    Type = bondy_registry_entry:type(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),
    IsLocal = bondy_registry_entry:is_local(Entry),

    ok = maybe_do_for_all_remote_idx(Store, Entry, add),

    case {Type, MatchPolicy, IsLocal} of
        {registration, ?EXACT_MATCH, _} ->
            add_exact_registration_index(Store, Entry);

        {registration, ?PREFIX_MATCH, _} ->
            add_prefix_registration_idx(Store, Entry);

        {registration, ?WILDCARD_MATCH, _} ->
            add_wildcard_registration_index(Store, Entry);

        {subscription, ?EXACT_MATCH, true} ->
            add_local_exact_subscription_index(Store, Entry);

        {subscription, ?EXACT_MATCH, false} ->
            add_remote_exact_subscription_idx(Store, Entry);

        {subscription, ?PREFIX_MATCH, _} ->
            add_prefix_subscription_index(Store, Entry);

        {subscription, ?WILDCARD_MATCH, _} ->
            add_wildcard_subscription_index(Store, Entry)
    end.


%% @private
-spec delete_indices(Store :: t(), Entry :: entry()) -> ok | {error, any()}.

delete_indices(Store, Entry) ->
    Type = bondy_registry_entry:type(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),
    IsLocal = bondy_registry_entry:is_local(Entry),

    ok = maybe_do_for_all_remote_idx(Store, Entry, delete),

    case {Type, MatchPolicy, IsLocal} of
        {registration, ?EXACT_MATCH, _} ->
            del_exact_registration_index(Store, Entry);

        {registration, ?PREFIX_MATCH, _} ->
            del_prefix_registration_index(Store, Entry);

        {registration, ?WILDCARD_MATCH, _} ->
            del_wildcard_registration_index(Store, Entry);

        {subscription, ?EXACT_MATCH, true} ->
            del_local_exact_subscription_index(Store, Entry);

        {subscription, ?EXACT_MATCH, false} ->
            del_remote_exact_subscription_index(Store, Entry);

        {subscription, ?PREFIX_MATCH, _} ->
            del_prefix_subscription_index(Store, Entry);

        {subscription, ?WILDCARD_MATCH, _} ->
            del_wildcard_subscription_index(Store, Entry)
    end.


%% If Entry is remote, it adds it to the remote_tab index.
%% This index is solely used by find_by_node/3 function.
maybe_do_for_all_remote_idx(Store, Entry, Op) ->
    Tab = Store#bondy_registry_store.sub_remote_exact_idx_tab,

    case bondy_registry_entry:is_local(Entry) of
        true ->
            ok;

        false ->
            Node = bondy_registry_entry:node(Entry),
            Type = bondy_registry_entry:type(Entry),
            EntryKey = bondy_registry_entry:key(Entry),

            %% Entry is the value we are interested in but we use it as part of
            %% the key to disambiguate, and avoid adding more elements to the
            %% tuple.
            Key = {Node, Type, EntryKey},

            case Op of
                add ->
                    Object = {Key},
                    true = ets:insert(Tab, Object);

                delete ->
                    true = ets:match_delete(Tab, Key)
            end,
            ok
    end.


%% @private
add_exact_registration_index(Store, Entry) ->
    Tab = Store#bondy_registry_store.reg_exact_idx_tab,
    Uri = bondy_registry_entry:uri(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),

    Object = reg_idx(Entry),
    true = ets:insert(Tab, Object),
    IsFirstEntry = incr_counter(Store, Uri, MatchPolicy, 1) =:= 1,
    {ok, {Entry, IsFirstEntry}}.


%% @private
del_exact_registration_index(Store, Entry) ->
    Tab = Store#bondy_registry_store.reg_exact_idx_tab,
    Pattern = reg_idx(Entry),

    case ets:select_delete(Tab, [{Pattern, [], [true]}]) of
        0 ->
            ok;

        1 ->
            Uri = bondy_registry_entry:uri(Entry),
            MatchPolicy = bondy_registry_entry:match_policy(Entry),
            _ = decr_counter(Store, Uri, MatchPolicy, 1),
            ok
    end.


%% @private
add_local_exact_subscription_index(Store, Entry) ->
    Tab = Store#bondy_registry_store.sub_local_exact_idx_tab,
    Uri = bondy_registry_entry:uri(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),

    Object = sub_idx(Entry),
    true = ets:insert(Tab, Object),
    IsFirstEntry = incr_counter(Store, Uri, MatchPolicy, 1) =:= 1,
    {ok, {Entry, IsFirstEntry}}.


%% @private
del_local_exact_subscription_index(Store, Entry) ->
    Tab = Store#bondy_registry_store.sub_local_exact_idx_tab,

    Pattern = sub_idx(Entry),

    case ets:select_delete(Tab, [{Pattern, [], [true]}]) of
        0 ->
            ok;

        1 ->
            Uri = bondy_registry_entry:uri(Entry),
            MatchPolicy = bondy_registry_entry:match_policy(Entry),
            _ = decr_counter(Store, Uri, MatchPolicy, 1),
            ok
    end.


%% @private
add_prefix_registration_idx(Store, Entry) ->
    ART = Store#bondy_registry_store.reg_prefix_idx_art,
    add_art_index(Store, Entry, ART).


%% @private
del_prefix_registration_index(Store, Entry) ->
    ART = Store#bondy_registry_store.reg_prefix_idx_art,
    del_art_index(Store, Entry, ART).


%% @private
add_prefix_subscription_index(Store, Entry) ->
    ART = Store#bondy_registry_store.sub_prefix_idx_art,
    add_art_index(Store, Entry, ART).


%% @private
del_prefix_subscription_index(Store, Entry) ->
    ART = Store#bondy_registry_store.sub_prefix_idx_art,
    del_art_index(Store, Entry, ART).


%% -----------------------------------------------------------------------------
%% @private
%% @doc increases the ref_count for entry's node by 1. If the node was not
%% present creates the entry on the table with ref_count = 1.
%% @end
%% -----------------------------------------------------------------------------
add_remote_exact_subscription_idx(Store, Entry) ->
    Tab = Store#bondy_registry_store.sub_remote_exact_idx_tab,
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),
    Node = bondy_registry_entry:node(Entry),

    Key = {RealmUri, MatchPolicy, Uri},

    Obj = #remote_sub_idx{
        key = Key,
        node = Node
    },

    true = ets:insert(Tab, Obj),

    %% This is a remote entry, so the on_create event was already generated on
    %% its node.
    IsFirstEntry = false,
    {ok, {Entry, IsFirstEntry}}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc decreases the ref_count for entry's node by 1. If the node was not
%% present creates the entry on the table with ref_count = 1.
%% @end
%% -----------------------------------------------------------------------------
del_remote_exact_subscription_index(Store, Entry) ->
    Tab = Store#bondy_registry_store.sub_remote_exact_idx_tab,
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),
    Node = bondy_registry_entry:node(Entry),

    Obj = #remote_sub_idx{
        key = {RealmUri, MatchPolicy, Uri},
        node = Node
    },

    true = ets:delete_object(Tab, Obj),
    ok.


%% @private
%% This MUST NOT be called concurrently
add_wildcard_registration_index(Store, Entry) ->
    ART = Store#bondy_registry_store.reg_wc_idx_art,
    add_art_index(Store, Entry, ART).


%% @private
%% This MUST NOT be called concurrently
del_wildcard_registration_index(Store, Entry) ->
    ART = Store#bondy_registry_store.reg_wc_idx_art,
    del_art_index(Store, Entry, ART).


%% @private
add_wildcard_subscription_index(Store, Entry) ->
    ART = Store#bondy_registry_store.sub_wc_idx_art,
    add_art_index(Store, Entry, ART).


%% @private
del_wildcard_subscription_index(Store, Entry) ->
    ART = Store#bondy_registry_store.sub_wc_idx_art,
    del_art_index(Store, Entry, ART).


%% @private
%% Calls art:set/3 serialising the call via a registry partition server
add_art_index(Store, Entry, ART) ->
    Pid = Store#bondy_registry_store.partition,
    Key = art_key(Entry),
    Value = art_value(Entry),
    Args = [Key, Value, ART],

    Result = bondy_registry_partition:execute(Pid, fun art:set/3, Args, 5_000),

    case Result of
        ok ->
            Uri = bondy_registry_entry:uri(Entry),
            MatchPolicy = bondy_registry_entry:match_policy(Entry),
            IsFirstEntry = incr_counter(Store, Uri, MatchPolicy, 1) =:= 1,
            {ok, {Entry, IsFirstEntry}};

        {error, _} = Error ->
            Error
    end.


%% @private
%% Calls art:delete/2 serialising the call via a registry partition server
del_art_index(Store, Entry, ART) ->
    Pid = Store#bondy_registry_store.partition,
    Key = art_key(Entry),
    Args = [Key, ART],

    Result = bondy_registry_partition:execute(
        Pid, fun art:delete/2, Args, 5_000
    ),

    case Result of
        {ok, true} ->
            Uri = bondy_registry_entry:uri(Entry),
            MatchPolicy = bondy_registry_entry:match_policy(Entry),
            _ = decr_counter(Store, Uri, MatchPolicy, 1),
            ok;

        {ok, false} ->
            ok;

        {error, _} = Error ->
            Error
    end.


%% =============================================================================
%% PRIVATE: URI COUNTERS
%% =============================================================================

%% TODO we should remove the use of these counters. We use them because
%% WAMP distinguishes between on_create|on_delete and on_subscribe|on_register
%% events.
%% In a distributed setting with no coordination this distinction is impossible
%% to guarantee and has absolutely no value to the user. At the moment two
%% nodes might trigger the on_create as the counters are not global. Even if we
%% used global CRDT counters there is a possibility of multiple nodes
%% triggering simultaneous on_create|on_delete events.

%% @private
incr_counter(Store, Uri, MatchPolicy, N) ->
    Tab = Store#bondy_registry_store.counters_tab,
    Key = {Uri, MatchPolicy},
    Default = {counter, Key, 0},
    ets:update_counter(Tab, Key, {3, N}, Default).


%% @private
decr_counter(Store, Uri, MatchPolicy, N) ->
    Tab = Store#bondy_registry_store.counters_tab,
    Key = {Uri, MatchPolicy},
    Default = {counter, Key, 0},

    case ets:update_counter(Tab, Key, {3, -N, 0, 0}, Default) of
        0 ->
            %% Other process might have concurrently incremented the counter,
            %% so we do a match delete
            true = ets:match_delete(Tab, Default),
            0;

        Val ->
            Val
    end.



%% =============================================================================
%% PRIVATE: ART UTILS
%% =============================================================================



%% @private
-spec art_key(bondy_registry_entry:t_or_key()) -> art:key().

art_key(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    SessionId0 = bondy_registry_entry:session_id(Entry),
    Nodestring = bondy_registry_entry:nodestring(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),

    {ProtocolSessionId, SessionId, Id} = case bondy_registry_entry:id(Entry) of
        _ when SessionId0 == '_' ->
            %% As we currently do not support wildcard matching in art:match,
            %% we turn this into a prefix matching query
            %% TODO change when wildcard matching is enabled in art.
            {<<>>, <<>>, <<>>};

        Id0 when SessionId0 == undefined ->
            {<<"undefined">>, <<"undefined">>, term_to_art_key_part(Id0)};

        Id0 when is_binary(SessionId0) ->
            ProtocolSessionId0 = bondy_session_id:to_external(SessionId0),
            {
                term_to_art_key_part(ProtocolSessionId0),
                term_to_art_key_part(SessionId0),
                term_to_art_key_part(Id0)
            }
    end,

    %% RealmUri is always ground, so we join it with URI using a $. as any
    %% other separator will not work with art:find_matches/2
    Key = <<RealmUri/binary, $., Uri/binary>>,

    %% We add Nodestring for cases where SessionId == <<>>
    case MatchPolicy of
        ?PREFIX_MATCH ->
            %% art lib uses the star char to explicitly denote a prefix
            {<<Key/binary, $*>>, Nodestring, ProtocolSessionId, SessionId, Id};

        _ ->
            {Key, Nodestring, ProtocolSessionId, SessionId, Id}
    end.


%% @private
term_to_art_key_part('_') ->
    <<>>;

term_to_art_key_part(Term) when is_atom(Term) ->
    atom_to_binary(Term, utf8);

term_to_art_key_part(Term) when is_integer(Term) ->
    integer_to_binary(Term);

term_to_art_key_part(Term) when is_binary(Term) ->
    Term.


%% @private
art_value(Entry) ->
    art_value(Entry, bondy_registry_entry:type(Entry)).


%% @private
art_value(Entry, registration) ->
    EntryKey = bondy_registry_entry:key(Entry),
    IsProxy = bondy_registry_entry:is_proxy(Entry),
    Invoke = bondy_registry_entry:get_option(invoke, Entry, ?INVOKE_SINGLE),
    Timestamp = bondy_registry_entry:created(Entry),
    {EntryKey, IsProxy, Invoke, Timestamp};

art_value(Entry, subscription) ->
    EntryKey = bondy_registry_entry:key(Entry),
    IsProxy = bondy_registry_entry:is_proxy(Entry),
    {EntryKey, IsProxy}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc This is match_spec that art applies after a match.
%% @end
%% -----------------------------------------------------------------------------
-spec art_ms(Type :: entry_type(), Opts :: map()) ->
    ets:match_spec() | undefined.

art_ms(registration, Opts) ->
    Nodestring =
        case maps:find(node, Opts) of
            {ok, Val} ->
                Val;

            error ->
                case maps:get(nodestring, Opts, '_') of
                    '_' ->
                        '_';
                    Bin ->
                        binary_to_atom(Bin, utf8)
                end
        end,

    Conds =
        case maps:get(invoke, Opts, '_') of
            '_' ->
                [];
            Invoke ->
                [{'=:=', '$3', Invoke}]
        end,

    case Conds of
        [] ->
            undefined;

        [_] ->
            %% {Key, Nodestring, ProtocolSessionId, SessionId, EntryIdBin}
            Key = {'_', Nodestring, '_', '_'},
            %% {EntryKey, IsProxy, Invoke}
            Value = {'_', '_', '$3', '_'},

            [{ {Key, Value}, Conds, ['$_'] }]
    end;

art_ms(subscription, Opts) ->
    %% {{$1, $2, $3, $4, $5}, $6},
    %% {{Key, Node, ProtocolSessionId, SessionId, EntryIdBin}, '_'},
    Node =
        case maps:find(node, Opts) of
            {ok, Val} ->
                Val;

            error ->
                case maps:get(nodestring, Opts, '_') of
                    '_' ->
                        '_';
                    Bin ->
                        binary_to_atom(Bin, utf8)
                end
        end,

    Conds1 =
        case maps:find(eligible, Opts) of
            error ->
                [];

            {ok, []} ->
                [];

            {ok, EligibleIds} ->
                [
                    maybe_or(
                        [
                            {'=:=', '$1', {const, integer_to_binary(S)}}
                            || S <- EligibleIds
                        ]
                    )
                ]
        end,

    Conds2 =
        case maps:find(exclude, Opts) of
            error ->
                Conds1;

            {ok, []} ->
                Conds1;

            {ok, ExcludedIds} ->
                ExclConds = maybe_and(
                    [
                        {'=/=', '$1', {const, integer_to_binary(S)}}
                        || S <- ExcludedIds
                    ]
                ),
                [ExclConds | Conds1]
        end,

    Conds =
        case Conds2 of
            [] ->
                [];
            [_] ->
                Conds2;
            _ ->
                [list_to_tuple(['andalso' | Conds2])]
        end,

    case Conds of
        [] ->
            undefined;

        _ ->
            %% {Key, Node, ProtocolSessionId, SessionId, EntryIdBin}
            Key = {'_', Node, '$1', '_', '_'},
            %% {EntryKey, IsProxy}.
            Value = {'_', '_'},

            [{ {Key, Value}, Conds, ['$_'] }]
    end.


%% @private
%% See trie_key to understand how we generated Bin
parse_index_key_uri(RealmUri, Bin) ->
    Sz = byte_size(RealmUri),
    <<RealmUri:Sz/binary, $., Uri0/binary>> = Bin,
    string:trim(Uri0, trailing, "*").


%% @private
art_match_result(_, _, ?EOT) ->
    ?EOT;

art_match_result(_, subscription, []) ->
    {[], []};

art_match_result(Store, subscription, All) when is_list(All) ->
    Nodestring = partisan:nodestring(),

    {L, R} = lists:foldl(
        fun
            ({{_, NS, _, _, _}, _}, {L, R}) when NS =/= Nodestring ->
                %% A remote subscription, we just append the nodestring on the
                %% right-hand side acc
                Node = binary_to_atom(NS, utf8),
                {L, sets:add_element(Node, R)};

            ({{Bin, _, _, _, _}, {EntryKey, IsProxy}}, {L, R}) ->
                %% We project the expected triple
                %% TODO this is projection subscriptions only at the moment,
                %% registrations need the Invoke field too.
                %% We will need to add INvoke Policy to the art value
                RealmUri = bondy_registry_entry:realm_uri(EntryKey),
                Uri = parse_index_key_uri(RealmUri, Bin),
                Match = #sub_idx{
                    key = {RealmUri, Uri},
                    entry_key = EntryKey,
                    is_proxy = IsProxy
                },
                {[Match|L], R}
        end,
        {[], sets:new()},
        All
    ),
    {lists:reverse(project(Store, L)), sets:to_list(R)};

art_match_result(Store, registration, All) when is_list(All) ->
    L = [
        begin
            RealmUri = bondy_registry_entry:realm_uri(EntryKey),
            Uri = parse_index_key_uri(RealmUri, Bin),
            #reg_idx{
                key = {RealmUri, Uri},
                entry_key = EntryKey,
                is_proxy = IsProxy,
                invoke = Invoke,
                timestamp = TS
            }
        end
        || {{Bin, _, _, _, _}, {EntryKey, IsProxy, Invoke, TS}} <- All
    ],
    project(Store, L);

art_match_result(Store, Type, {All, Cont}) ->
    {art_match_result(Store, Type, All), Cont}.


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



%% =============================================================================
%% PRIVATE: CONTINUATIONS, ETC
%% =============================================================================



%% @private
continue(#continuation{source = ets} = C0) ->
    case ets:select(C0#continuation.original) of
        ?EOT ->
            ?EOT;

        {L, ETSCont} ->
            C = C0#continuation{original = ETSCont},
            Store = C#continuation.store,
            {project(Store, L), C}
    end.


%% @private
ets_select(Tab, MS, #{limit := N}) when is_integer(N), N > 0 ->
    ets:select(Tab, MS, N);

ets_select(Tab, MS, _) ->
    ets:select(Tab, MS).


%% @private
%% At the moment (R)emote cannot contina continuation
zip_local_remote(?EOT, ?EOT) ->
    ?EOT;

zip_local_remote(L, ?EOT) when is_list(L) ->
    {L, []};

zip_local_remote(?EOT, R) when is_list(R) ->
    {[], R};

zip_local_remote(L, R) when is_list(L), is_list(R) ->
    {L, R};

zip_local_remote({L, C}, ?EOT) ->
    {{L, []}, C};

zip_local_remote({L, C}, R) ->
    {{L, R}, C}.


%% @private
topic_session_restrictions(Var, Opts) ->
    R = case maps:find(eligible, Opts) of
        error ->
            %% Not provided
            {'_', []};

        {ok, []} ->
            %% Idem as not provided
            {'_', []};

        {ok, EligibleIds} ->
            %% We include the provided ProtocolSessionIds
            Eligible = maybe_or(
                [
                    {'=:=', Var, {const, S}}
                    || S <- EligibleIds
                ]
            ),

            {Var, [Eligible]}
    end,

    case maps:find(exclude, Opts) of
        error ->
            R;

        {ok, []} ->
            R;

        {ok, ExcludedIds} ->

            %% We exclude the provided ProtocolSessionIds
            Excluded = maybe_and(
                [
                    {'=/=', Var, {const, S}}
                    || S <- ExcludedIds
                ]
            ),

            {_, Conds} = R,
            {Var, [Excluded | Conds]}
    end.


%% @private
merge_results(Terms, Type, FN) ->
    merge_results(Terms, Type, FN, ?EOT).


%% @private
merge_results([], _, _, Acc) ->
    Acc;

merge_results([?EOT | T], Type, FN, Acc) ->
    merge_results(T, Type, FN, Acc);

merge_results([H | T], Type, FN, ?EOT) ->
    merge_results(T, Type, FN, H);

merge_results([L | T], registration = Type, FN, Acc) when is_list(L), is_list(Acc) ->
    merge_results(T, Type, FN, lists:append(L, Acc));

merge_results([{L1, C1} | T], registration = Type, FN, {L0, C0})
when is_list(L0), is_list(L1) ->
    C = merge_continuation(FN, [C1, C0]),
    merge_results(T, Type, FN, {lists:append(L1, L0), C});

merge_results([{L1, R1} | T], subscription = Type, FN, {L0, R0})
when is_list(L0), is_list(R0), is_list(L1), is_list(R1) ->
    %% The case for subscriptions w/o limit
    Acc = {lists:append(L1, L0), lists:append(R1, R0)},
    merge_results(T, Type, FN, Acc);

merge_results([{{L1, R1}, C1} | T], subscription = Type, FN, {{L0, R0}, C0})
when is_list(L0), is_list(R0), is_list(L1), is_list(R1) ->
    %% The case for subscriptions w/limit
    C = merge_continuation(FN, [C1, C0]),
    Acc = {{lists:append(L1, L0), lists:append(R1, R0)}, C},
    merge_results(T, Type, FN, Acc).


%% @private
merge_continuation(FN, L) when is_list(L) ->
    merge_continuation(FN, L, ?EOT).


%% @private
merge_continuation(FN, [?EOT| T], ?EOT = Acc) ->
    merge_continuation(FN, T, Acc);

merge_continuation(FN, [#continuation{} = H| T], ?EOT) ->
    merge_continuation(FN, T, H#continuation{function = FN});

merge_continuation(FN, [?EOT | T], #continuation{} = Acc) ->
    merge_continuation(FN, T, Acc);

merge_continuation(
    FN, [#continuation{} = H | T], #continuation{} = Acc0) ->
    #continuation{
        type = T1,
        realm_uri = R1,
        original = C1
    } = Acc0,

    #continuation{
        type = T2,
        realm_uri = R2,
        original = C2
    } = H,

    (T1 == T2 andalso R1 == R2) orelse error(badarg),

    Acc = H#continuation{
        function = FN,
        original = bondy_stdlib:or_else(C1, C2)
    },

    merge_continuation(FN, T, Acc);

merge_continuation(_, [], Acc) ->
    Acc.


%% =============================================================================
%% PRIVATE: MATCH
%% =============================================================================


%% @private
match_each(#bondy_registry_store{} = Store, Type, RealmUri, Uri, Opts, [H|T])
when H == ?EXACT_MATCH ->
    case match_exact(Store, Type, RealmUri, Uri, Opts) of
        ?EOT ->
            match_each(Store, Type, RealmUri, Uri, Opts, T);

        Result ->
            Result
    end;

match_each(#bondy_registry_store{} = Store, Type, RealmUri, Uri, Opts, [H|T])
when H == ?PREFIX_MATCH ->
    case match_prefix(Store, Type, RealmUri, Uri, Opts) of
        ?EOT ->
            match_each(Store, Type, RealmUri, Uri, Opts, T);

        Result ->
            Result
    end;

match_each(#bondy_registry_store{} = Store, Type, RealmUri, Uri, Opts, [H])
when H == ?WILDCARD_MATCH ->
    match_wildcard(Store, Type, RealmUri, Uri, Opts);

match_each(_, _, _, _, _, []) ->
    ?EOT.


%% @private
-spec match_local_exact_subscription(continuation()) ->
    sub_match_result().

match_local_exact_subscription(#continuation{} = C0) ->
     case ets:select(C0#continuation.original) of
        ?EOT ->
            ?EOT;

        {L, ETSCont} ->
            Store = C0#continuation.store,
            {project(Store, L), C0#continuation{original = ETSCont}}
    end.


%% @private
-spec match_local_exact_subscription(t(), uri(), uri(), map()) ->
    {[sub_idx()], continuation() | eot()} | eot().

match_local_exact_subscription(Store, RealmUri, Uri, Opts) ->
    Tab = Store#bondy_registry_store.sub_local_exact_idx_tab,

    {Var, Conds} = topic_session_restrictions('$1', Opts),

    Pattern = #sub_idx{
        key = {RealmUri, Uri},
        protocol_session_id = Var,
        entry_key = '_',
        is_proxy = '_'
    },

    MS = [{Pattern, Conds, ['$_']}],

    case ets_select(Tab, MS, Opts) of
        ?EOT ->
            ?EOT;

        L when is_list(L) ->
            project(Store, L);

        {L, ETSCont} ->
            C = #continuation{
                type = subscription,
                function = ?FUNCTION_NAME,
                realm_uri = RealmUri,
                uri = Uri,
                opts = Opts,
                store = Store,
                source = ets,
                original = ETSCont
            },
            {project(Store, L), C}
    end.


%% @private
-spec match_remote_exact_subscription(ets:continuation()) ->
    sub_match_result().

match_remote_exact_subscription(#continuation{} = C) ->
    continue(C).


%% @private
-spec match_remote_exact_subscription(t(), uri(), uri(), map()) ->
    {[node()], continuation() | eot()} | eot().

match_remote_exact_subscription(Store, RealmUri, Uri, Opts) ->
    Tab = Store#bondy_registry_store.sub_remote_exact_idx_tab,

    Pattern = #remote_sub_idx{
        key = {RealmUri, ?EXACT_MATCH, Uri},
        node = '$1'
    },
    Conds = [],
    Return = ['$1'],

    MS = [{Pattern, Conds, Return}],

    case ets_select(Tab, MS, Opts) of
        ?EOT ->
            ?EOT;

        L when is_list(L) ->
            project(Store, L);

        {L, ETSCont} ->
            C = #continuation{
                type = subscription,
                function = ?FUNCTION_NAME,
                realm_uri = RealmUri,
                uri = Uri,
                opts = Opts,
                store = Store,
                source = ets,
                original = ETSCont
            },
            {project(Store, L), C}
    end.


%% @private
art_key_pattern(_Type, RealmUri, Uri) ->
    {<<RealmUri/binary, $., Uri/binary>>, <<>>, <<>>, <<>>, <<>>}.


%% @private
%% Calls art:match/3 serialising the call via a registry partition server
-spec art_match(t(), entry_type(), uri(), uri(), map(), art:t()) ->
    match_result().

art_match(Store, Type, RealmUri, Uri, Opts, ART) ->
    Pid = Store#bondy_registry_store.partition,
    Pattern = art_key_pattern(Type, RealmUri, term_to_art_key_part(Uri)),
    Limit = maps:get(limit, Opts, infinity),
    %% We do not use limit as ART does not support it yet.
    ARTOpts = #{
        %% We match the Uri exactly
        mode => exact,
        match_spec => art_ms(Type, Opts),
        first => <<RealmUri/binary, $.>>
    },
    Args = [Pattern, ART, ARTOpts],

    Result = bondy_registry_partition:execute(
        Pid, fun art:match/3, Args, 10_000
    ),

    case Result of
        {ok, []} when Limit =/= infinity ->
            art_match_result(Store, Type, ?EOT);

        {ok, []} ->
            art_match_result(Store, Type, []);

        {ok, L} when Limit =/= infinity ->
            art_match_result(Store, Type, {L, ?EOT});

        {ok, L} ->
            art_match_result(Store, Type, L);

        {error, badarg} when Limit =/= infinity ->
            art_match_result(Store, Type, ?EOT);

        {error, badarg} ->
            art_match_result(Store, Type, []);

        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Error when executing serialised match on registry"
                    "Returning empty result",
                partition => Pid,
                reason => Reason
            }),
            art_match_result(Store, Type, ?EOT)
    end.



%% =============================================================================
%% PRIVATE: FIND_MATCHES
%% =============================================================================



%% @private
find_matches_each(
    #bondy_registry_store{} = Store, Type, RealmUri, Uri, Opts, [H|T]
) when H == ?EXACT_MATCH ->
    case find_exact_matches(Store, Type, RealmUri, Uri, Opts) of
        ?EOT ->
            find_matches_each(Store, Type, RealmUri, Uri, Opts, T);

        Result ->
            Result
    end;

find_matches_each(
    #bondy_registry_store{} = Store, Type, RealmUri, Uri, Opts, [H|T]
) when H == ?PREFIX_MATCH ->
    case find_prefix_matches(Store, Type, RealmUri, Uri, Opts) of
        ?EOT ->
            find_matches_each(Store, Type, RealmUri, Uri, Opts, T);

        Result ->
            Result
    end;

find_matches_each(
    #bondy_registry_store{} = Store, Type, RealmUri, Uri, Opts, [H]
) when H == ?WILDCARD_MATCH ->
    find_wildcard_matches(Store, Type, RealmUri, Uri, Opts);

find_matches_each(_, _, _, _, _, []) ->
    ?EOT.


%% @private
%% This MUST NOT be called concurrently
-spec art_find_matches(t(), entry_type(), uri(), uri(), map(), art:t()) ->
    match_result().

art_find_matches(Store, Type, RealmUri, Uri, Opts, ART) ->
    Pid = Store#bondy_registry_store.partition,
    Pattern = <<RealmUri/binary, $., Uri/binary>>,
    Limit = maps:get(limit, Opts, undefined),
    %% We do not use limit as ART does not support them yet.
    ARTOpts = #{
        match_spec => art_ms(Type, Opts),
        first => <<RealmUri/binary, $.>>
    },
    %% Notice we have an inconsistency between art:match/3 and
    %% art:find_matches/3. In the latter the Trie is the 3rd arg instead of the
    %% 2nd (as in match/3)
    Args = [Pattern, ARTOpts, ART],

    Result = bondy_registry_partition:execute(
        Pid, fun art:find_matches/3, Args, 10_000
    ),

    %% Always sync at the moment
    case Result of
        {ok, []} when Limit =/= undefined ->
            art_match_result(Store, Type, ?EOT);

        {ok, []} ->
            art_match_result(Store, Type, []);

        {ok, L} when Limit =/= undefined ->
            art_match_result(Store, Type, {L, ?EOT});

        {ok, L} ->
            art_match_result(Store, Type, L);

        {error, badarg} when Limit =/= undefined ->
            art_match_result(Store, Type, ?EOT);

        {error, badarg} ->
            art_match_result(Store, Type, []);

        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Error when executing serialised find_matches on registry"
                    "Returning empty result",
                partition => Pid,
                reason => Reason
            }),
            art_match_result(Store, Type, ?EOT)
    end.


%% @private
-spec project(t(), [index_entry()]) -> [entry()].

project(Store, L) when is_list(L) ->
    lists:filtermap(
        fun
            (IndexEntry)
            when is_record(IndexEntry, reg_idx);
            is_record(IndexEntry, sub_idx) ->
                case lookup(Store, IndexEntry) of
                    {ok, Entry} ->
                        {true, Entry};

                    {error, not_found} ->
                        %% This is very rare, but we need to cater for it.
                        ?LOG_WARNING(#{
                            description =>
                                "Inconsistency found in registry. "
                                "An entry found in the indices "
                                "could not be found on the main store.",
                            reason => not_found,
                            index_entry => IndexEntry
                        }),
                        false
                end;

            (Term) ->
                error({badarg, Term})
        end,
        L
    ).


