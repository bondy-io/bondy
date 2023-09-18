%% =============================================================================
%%  bondy_table_owner.erl -
%%
%%  Copyright (c) 2018-2023 Leapsight. All rights reserved.
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

-module(bondy_table_owner).
-behaviour(gen_server).


%% API
-export([add/2]).
-export([add_and_claim/2]).
-export([add_or_claim/2]).
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
        ok = do_give_away(Tab, From),
        {reply, {ok, Tab}, St};
    error ->
        Opts1 = set_heir(Opts0),
        Tab = ets:new(Name, Opts1),
        true = do_give_away(Tab, From),
        ets:insert(?MODULE, [{Name, Tab}]),
        {reply, {ok, Tab}, St}
  end;

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
do_give_away(Tab, From) ->
    true = ets:give_away(Tab, From, []).
