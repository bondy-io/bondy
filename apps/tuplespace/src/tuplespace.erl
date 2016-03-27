%% @doc This module is an interface for the collection of in-memory tables
%% conforming the betflow tuplespace.
%% The tuplespace is implemented by a collection of partitioned ets tables.
%% Partition is done using the consistency hashing technique and implemented
%% using Basho Riak Core's chash module.
%% The tuplespace is static, that is, once created you cannot add or remove
%% tables.
%% @end
-module(tuplespace).
-include("tuplespace.hrl").

-define(RESOURCE, tuplespace_manager).

-export([start/0]).
-export([make/0]).
-export([create_static_tables/0]).
-export([create_table/2]).
-export([create_table/3]).
-export([delete_table/1]).
-export([delete_table/2]).
-export([fetch_table/1]).
-export([locate_table/2]).
-export([lookup_table/1]).
-export([ring_size/0]).
-export([size/1]).
-export([tables/1]).
-export([get_ring/1]).



%% =============================================================================
%% APP UTILS
%% =============================================================================


%%------------------------------------------------------------------------------
%% @doc
%% A utility function that recompiles the modified erlang modules.
%% Calls 'make:all([load]).'
%% @end
%%------------------------------------------------------------------------------
make() ->
    make:all([load]).


%%------------------------------------------------------------------------------
%% @doc Starts the betflow application and all its dependencies
%%------------------------------------------------------------------------------
start() ->
    application:ensure_all_started(?MODULE, permanent).




%% -----------------------------------------------------------------------------
%% @doc Creates a new ets table and associates it with name Name.
%% It uses the default timeout value.
%%
%% This is a serialised sync call to the server and thus it blocks
%% the caller.
%%
%% The table will be owned by one of the existing tuplespace_worker(s).
%% @TODO At the moment this created a single table, we need to give the option to create a sharded table, the ring will be cached in mochiglobal and all tables in the shard will belong to the same tuplespace_worker.
%% @end
%% -----------------------------------------------------------------------------
create_table(Name, Opts) ->
    %% Ny convention the server is named after its corresponding
    %% table_registry table partition name
    RegTid = locate_table(?REGISTRY_TABLE_NAME, Name),
    gen_server:call(RegTid, {new, Name, Opts}).



%% -----------------------------------------------------------------------------
%% @doc Creates a ets new table and associates it with name Name.
%% This is a serialised sync call to the server and thus it blocks
%% the caller.
%% @end
%% -----------------------------------------------------------------------------
create_table(Name, Opts, Timeout) ->
    %% The server is named after its corresponding table_registry table
    %% partition name
    RegTid = locate_table(?REGISTRY_TABLE_NAME, Name),
    gen_server:call(RegTid, {new, Name, Opts}, Timeout).


%% -----------------------------------------------------------------------------
%% @doc Deletes the ets table associated with name Name.
%% It uses the default timeout value.
%% If a table does not exists it fails with a 'badarg' exception.
%% This is a serialised sync call to the tuplespace_manager.
%% @end
%% -----------------------------------------------------------------------------
delete_table(Name) ->
    %% The server is named after its corresponding table_registry table
    %% partition name
    RegTid = locate_table(?REGISTRY_TABLE_NAME, Name),
    gen_server:call(RegTid, {delete, Name}).


%% -----------------------------------------------------------------------------
%% @doc Deletes the ets table associated with name Name.
%% If a table does not exists it fails with a 'badarg' exception.
%% This is a serialised sync call to the tuplespace_manager.
%% @end
%% -----------------------------------------------------------------------------
delete_table(Name, Timeout) ->
    %% The server is named after its corresponding table_registry table
    %% partition name
    RegTid = locate_table(?REGISTRY_TABLE_NAME, Name),
    gen_server:call(RegTid, {delete, Name}, Timeout).


%% -----------------------------------------------------------------------------
%% @doc Returns the ets table associated with name Name.
%% If a table does not exists it fails with a 'badarg' exception.
%% This function is executed in the calling process.
%% @end
%% -----------------------------------------------------------------------------
-spec fetch_table(non_neg_integer()) -> ets:tid().
fetch_table(Name) ->
    case lookup_table(Name) of
        not_found ->
            error({badarg, Name});
        Tid ->
            Tid
    end.


%% -----------------------------------------------------------------------------
%% @doc Returns the ets table associated with name Name.
%% If a table does not exists it returns 'not_found'.
%% This function is executed in the calling process.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup_table(non_neg_integer()) -> ets:tid() | not_found.
lookup_table(Name) ->
    case ets:lookup(?REGISTRY_TABLE(Name), Name) of
        [#table_registry{tid = Tid}] ->
            Tid;
        [] ->
            not_found
    end.


%% -----------------------------------------------------------------------------
%% @doc Creates all the tables. This function should be called once and results
%% in the calling process owning all the created tables.
%% @end
%% -----------------------------------------------------------------------------

create_static_tables() ->
    L = application:get_env(tuplespace, static_tables, []),
    do_create_static_tables(lists:append(L, ?TABLE_SPECS), []).


%% -----------------------------------------------------------------------------
%% @doc Returns the name of the table corresponding to the logical table
%% named TabName and the given Term. The term will be hashed to determine which
%% of the tables in the tuplespace ring this term maps to.
%% -----------------------------------------------------------------------------
-spec locate_table(TabName :: atom(), Term :: any()) -> atom().
locate_table(TabName, Term) ->
    locate(Term, get_ring(TabName)).


-spec get_ring(atom()) -> list().
get_ring(Tab) ->
    mochiglobal:get(Tab).

%% -----------------------------------------------------------------------------
%% @doc Returns the size of the tuplespace ring as an integer.
%% It gets the size from the environment defaulting to 64.
%% @end
%% -----------------------------------------------------------------------------
-spec ring_size() -> pos_integer().
ring_size() ->
    tuplespace_config:ring_size().

%% -----------------------------------------------------------------------------
%% @doc Returns the number of entries for the given logical table name TabName
%% across the whole tuplespace
%% @end
%% -----------------------------------------------------------------------------
-spec size(TabName :: atom()) -> non_neg_integer().
size(TabName) ->
    {_, Partitions} = mochiglobal:get(TabName),
    lists:sum([ets:info(Tab, size) || {_, Tab} <- Partitions]).


%% @doc Returns the list of ets tables for the given logical table name TabName.
-spec tables(TabName :: atom()) -> [atom()].
tables(TabName) ->
    {_, Partitions} = mochiglobal:get(TabName),
    [Tab || {_Idx, Tab} <- Partitions].






%% =============================================================================
%%  PRIVATE
%% =============================================================================



%% @private
do_create_static_tables([], Acc) ->
    lists:append(Acc);
do_create_static_tables([{Name, Opts}|T], Acc) ->
    {_N, L} = Ring = ring(Name),
    %% We create a global static copy of the ring using mochiglobal
    mochiglobal:put(Name, Ring),
    Tabs = [ets:new(PName, Opts) || {_Idx, PName} <- L],
    do_create_static_tables(T, [Tabs|Acc]).


%% @private
locate(_, undefined) ->
    not_found;
locate(Term, Ring) ->
    Idx = chash:next_index(key(Term), Ring),
    chash:lookup(Idx, Ring).


%% @private
ring(Name) ->
    ring(Name, ring_size()).


%% @private
ring(Name, N) when is_atom(Name) ->
    {N, L} = chash:fresh(N, 1),
    {Indices, _Owners} = lists:unzip(L),
    NewOwners = [list_to_atom(atom_to_list(Name) ++ "_" ++ integer_to_list(X))
        || X <- lists:seq(1, N)],
    {N, lists:zip(Indices, NewOwners)}.






%% @private
key(Term) ->
    <<IndexAsInt:160/integer>>  = chash:key_of(Term),
    IndexAsInt.
