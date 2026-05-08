%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_table_manager).
-behaviour(gen_server).


%% API
-export([add/2]).
-export([add_and_claim/2]).
-export([add_or_claim/2]).
-export([get_or_create/2]).
-export([add_anonymous/2]).
-export([get_or_create_anonymous/2]).
-export([lookup_anonymous/1]).
-export([delete_anonymous/1]).
-export([claim/1]).
-export([delete/1]).
-export([give_away/2]).
-export([lookup/1]).
-export([exists/1]).

%% SUPERVISOR CALLBACKS
-export([start_link/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Returns the table identifier for table with name `Name' if it exists.
%% Otherwise returns `error'.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(Name :: atom()) -> {ok, ets:tid() | atom()} | error.

lookup(Name) when is_atom(Name) ->
    case ets:lookup(?MODULE, Name) of
        [] ->
            error;
        [{Name, Tab}] ->
            {ok, Tab}
    end.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if table with name `Name' exists.
%% Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec exists(Name :: atom()) -> boolean().

exists(Name) ->
    case lookup(Name) of
        {ok, _} -> true;
        error -> false
    end.


%% -----------------------------------------------------------------------------
%% @doc Creates a new ets table, sets itself as heir.
%% Makes sense only for public tables.
%% @end
%% -----------------------------------------------------------------------------
-spec add(Name :: atom(), Opts :: list()) -> {ok, ets:tid() | atom()} | error.

add(Name, Opts) when
is_atom(Name) andalso Name =/= undefined andalso is_list(Opts) ->
    gen_server:call(?MODULE, {add, Name, Opts}).


%% -----------------------------------------------------------------------------
%% @doc Creates a new ets table, sets itself as heir and gives it away
%% to Requester
%% @end
%% -----------------------------------------------------------------------------
-spec add_and_claim(Name :: atom(), Opts :: list()) ->
    {ok, ets:tid() | atom()} | error.

add_and_claim(Name, Opts) when
is_atom(Name) andalso Name =/= undefined andalso is_list(Opts) ->
    gen_server:call(?MODULE, {add_and_claim, Name, Opts}).


%% -----------------------------------------------------------------------------
%% @doc If the table exists, it gives it away to Requester.
%% Otherwise, creates a new ets table, sets itself as heir and
%% gives it away to Requester.
%% @end
%% -----------------------------------------------------------------------------
-spec add_or_claim(Name :: atom(), Opts :: list()) ->
    {ok, ets:tid() | atom()} | error.

add_or_claim(Name, Opts) when
is_atom(Name) andalso Name =/= undefined andalso is_list(Opts) ->
    gen_server:call(?MODULE, {add_or_claim, Name, Opts}).


%% -----------------------------------------------------------------------------
%% @doc Idempotent variant of `add/2'. Returns the existing table for `Name'
%% if it is already registered; otherwise creates a new ETS table with
%% `bondy_table_manager' as owner and heir.
%%
%% Useful when a caller's `init' runs more than once (e.g. a gen_server is
%% restarted by its supervisor) and must tolerate pre-existing tables.
%% @end
%% -----------------------------------------------------------------------------
-spec get_or_create(Name :: atom(), Opts :: list()) ->
    {ok, ets:tid() | atom()}.

get_or_create(Name, Opts) when
is_atom(Name) andalso Name =/= undefined andalso is_list(Opts) ->
    gen_server:call(?MODULE, {get_or_create, Name, Opts}).


%% -----------------------------------------------------------------------------
%% @doc Creates a new anonymous ETS table (no `named_table', no atom
%% allocated) owned by `bondy_table_manager' and registered under the
%% caller-supplied `Key' (any term). Returns `{error, already_exists}' if
%% `Key' is already registered.
%%
%% Prefer `get_or_create_anonymous/2' for idempotent init paths.
%% @end
%% -----------------------------------------------------------------------------
-spec add_anonymous(Key :: term(), Opts :: list()) ->
    {ok, ets:tid()} | {error, already_exists}.

add_anonymous(Key, Opts) when is_list(Opts) ->
    gen_server:call(?MODULE, {add_anonymous, Key, Opts}).


%% -----------------------------------------------------------------------------
%% @doc Idempotent variant of `add_anonymous/2'. Returns the existing
%% anonymous table registered under `Key' or creates a new one if absent.
%% The table is owned by `bondy_table_manager', so it survives the caller's
%% crash and restart.
%% @end
%% -----------------------------------------------------------------------------
-spec get_or_create_anonymous(Key :: term(), Opts :: list()) ->
    {ok, ets:tid()}.

get_or_create_anonymous(Key, Opts) when is_list(Opts) ->
    gen_server:call(?MODULE, {get_or_create_anonymous, Key, Opts}).


%% -----------------------------------------------------------------------------
%% @doc Looks up the anonymous table registered under `Key'. Pure ETS
%% lookup — does not call the gen_server.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup_anonymous(Key :: term()) -> {ok, ets:tid()} | error.

lookup_anonymous(Key) ->
    case ets:lookup(?MODULE, Key) of
        [{Key, Tab}] -> {ok, Tab};
        [] -> error
    end.


%% -----------------------------------------------------------------------------
%% @doc Deletes the anonymous table registered under `Key' and its registry
%% entry. Returns `true' if the table existed and was deleted, `false'
%% otherwise.
%% @end
%% -----------------------------------------------------------------------------
-spec delete_anonymous(Key :: term()) -> boolean().

delete_anonymous(Key) ->
    gen_server:call(?MODULE, {delete_anonymous, Key}).


%% -----------------------------------------------------------------------------
%% @doc Deletes the ets table with name Name iff the caller is the owner.
%% @end
%% -----------------------------------------------------------------------------
-spec delete(Name :: atom()) -> boolean().

delete(Name) when is_atom(Name) ->
    try ets:delete(Name) of
        true ->
            gen_server:call(?MODULE, {delete, Name})
    catch
        _:badarg ->
            %% Not the owner
            false
    end.

%% -----------------------------------------------------------------------------
%% @doc Used by the table owner to delegate the ownership to the calling
%% process.
%% The process must be local and not already the owner of the table.
%% @end
%% -----------------------------------------------------------------------------
-spec claim(Name :: atom()) -> boolean().

claim(Name) when is_atom(Name)->
    gen_server:call(?MODULE, {give_away, Name, self()}).


%% -----------------------------------------------------------------------------
%% @doc Used by the table owner to delegate the ownership to another process.
%% NewOwner must be alive, local and not already the owner of the table. If any
%% condition is not met the function returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec give_away(Name :: atom(), NewOwner :: pid()) -> boolean().

give_away(Name, NewOwner)
when is_atom(Name) andalso Name =/= undefined andalso is_pid(NewOwner) ->
    gen_server:call(?MODULE, {give_away, Name, NewOwner}).



%% =============================================================================
%% SUPERVISOR CALLBACKS
%% =============================================================================



-spec start_link() -> {ok, pid()} | ignore | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).



%% ============================================================================
%% GEN SERVER CALLBACKS
%% ============================================================================



init([]) ->
    ?MODULE = ets:new(
        ?MODULE,
        [
            named_table,
            {read_concurrency, true},
            {write_concurrency, true},
            {decentralized_counters, true}
        ]),
    {ok, undefined}.


handle_call(stop, _From, St) ->
  {stop, normal, St};

handle_call({add, Name, Opts0}, {_From, _Tag}, St) ->
    Reply = case exists(Name) of
        true ->
            error;
        false ->
            Opts1 = set_heir(Opts0),
            Tab = ets:new(Name, Opts1),
            true = ets:insert(?MODULE, [{Name, Tab}]),
            {ok, Tab}
    end,
    {reply, Reply, St};

handle_call({add_and_claim, Name, Opts0}, {From, _Tag}, St) ->
    Reply = case exists(Name) of
        true ->
            error;
        false ->
            Opts1 = set_heir(Opts0),
            Tab = ets:new(Name, Opts1),
            true = do_give_away(Tab, From),
            true = ets:insert(?MODULE, [{Name, Tab}]),
            {ok, Tab}
    end,
    {reply, Reply, St};

handle_call({add_or_claim, Name, Opts0}, {From, _Tag}, St) ->
  case lookup(Name) of
    {ok, Tab} ->
        true = do_give_away(Tab, From),
        {reply, {ok, Tab}, St};
    error ->
        Opts1 = set_heir(Opts0),
        Tab = ets:new(Name, Opts1),
        true = do_give_away(Tab, From),
        ets:insert(?MODULE, [{Name, Tab}]),
        {reply, {ok, Tab}, St}
  end;

handle_call({get_or_create, Name, Opts0}, _From, St) ->
    Reply = case ets:lookup(?MODULE, Name) of
        [{Name, Tab}] ->
            {ok, Tab};
        [] ->
            Opts1 = set_heir(Opts0),
            Tab = ets:new(Name, Opts1),
            true = ets:insert(?MODULE, [{Name, Tab}]),
            {ok, Tab}
    end,
    {reply, Reply, St};

handle_call({add_anonymous, Key, Opts0}, _From, St) ->
    Reply = case ets:lookup(?MODULE, Key) of
        [{Key, _}] ->
            {error, already_exists};
        [] ->
            Tab = do_new_anonymous(Opts0),
            true = ets:insert(?MODULE, [{Key, Tab}]),
            {ok, Tab}
    end,
    {reply, Reply, St};

handle_call({get_or_create_anonymous, Key, Opts0}, _From, St) ->
    Reply = case ets:lookup(?MODULE, Key) of
        [{Key, Tab}] ->
            {ok, Tab};
        [] ->
            Tab = do_new_anonymous(Opts0),
            true = ets:insert(?MODULE, [{Key, Tab}]),
            {ok, Tab}
    end,
    {reply, Reply, St};

handle_call({delete_anonymous, Key}, _From, St) ->
    Reply = case ets:lookup(?MODULE, Key) of
        [{Key, Tab}] ->
            _ = catch ets:delete(Tab),
            true = ets:delete(?MODULE, Key),
            true;
        [] ->
            false
    end,
    {reply, Reply, St};

handle_call({delete, Name}, {_From, _Tag}, St) ->
    Reg = ?MODULE,
    case ets:lookup(Reg, Name) of
        [] ->
            {reply, false, St};
        [{Name, _} = Obj] ->
            true = ets:delete_object(Reg, Obj),
            {reply, true, St}
    end;

handle_call({give_away, Name, NewOwner}, {From, _Tag}, St) ->
    Reply = case lookup(Name) of
        {ok, Tab} ->
            TrueOwner = ets:info(Tab, owner),
            %% If TrueOwner == self() the previous owner (From) died
            %% and ownership returned to us
            case
                (TrueOwner == From orelse TrueOwner == self()) andalso
                is_process_alive(NewOwner) andalso
                node(self()) == node(NewOwner)
            of
                true ->
                    do_give_away(Tab, NewOwner);
                false ->
                    %% The table does not exist or belongs to another process
                    false
            end;
        error ->
            false
    end,
    {reply, Reply, St};

handle_call(_Request, _From, St) ->
    {reply, {error, unsupported_call}, St}.


handle_cast({'ETS-TRANSFER', _Tid, _, values_table}, St) ->
    {noreply, St};

handle_cast({'ETS-TRANSFER', _Tid, _, indices_table}, St) ->
    {noreply, St};

handle_cast(_, St) ->
    {noreply, St}.


handle_info(_Info, St) ->
    {noreply, St}.


terminate(_Reason, _State) ->
    ets:foldl(
        fun({_, Tab}, ok) -> catch ets:delete(Tab), ok end,
        ok,
        ?MODULE
    ),
    true = ets:delete(?MODULE),
    ok.


code_change(_OldVsn, St, _Extra) ->
    {ok, St}.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
set_heir(Opts) ->
    lists:keystore(heir, 1, Opts, {heir, self(), []}).

%% @private
%% Creates an anonymous ETS table owned by the calling (table_manager)
%% process. Strips `named_table' from Opts defensively so callers can reuse
%% the same opts list they pass to named variants.
do_new_anonymous(Opts0) ->
    Opts1 = set_heir(Opts0) -- [named_table],
    ets:new(anonymous, Opts1).

%% @private
do_give_away(Tab, From) ->
    true = ets:give_away(Tab, From, []).
