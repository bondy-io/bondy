%% @doc The Tuplespace Dynamic Table Manager is a server that implements
%% the dynamic table management capabilites exposed by the Tuplespace API
%% in {@link tuplespace}.
%%
%% Each server is responsible for the creation (and deletion) of the
%% tuplespace's dynamic in-memory tables (ets).
%%
%% A collection of servers conform a static pool where each one is responsible
%% for a subset of all the dynamic tables created in the system.
%%
%% Every server has exclusive access to one table_registry ets table with the
%% same name as the server, which contains a mapping of the dynamic table name
%% and corresponding ets:tid().
%%
%% Every time the server creates a table it will add it to its table_registry.
%% The size of the pool is determined by the number of partitions defined for
%% the table_registry table.
%%
%% By definition, the server is the owner for all the ets tables it created.
%% As such, it is crucial that no additional responsibilities and
%% functionalities are added to the server to eliminate the possibility of it
%% crashing as it will destroy all the owned tables.
%%
%%
%% ### Assumptions and Limitations
%% * Tables should be public (you should use the ets table option to ensure
%% that)
%% * Consistent Hashing Ring is determined by the tuplespace (we will
%% enable) configuring this in the future
%%
%% @end
-module(tuplespace_worker).
-behaviour(gen_server).
-include ("tuplespace.hrl").


-type state()               ::  #{registry => ets:tid()}.
-type request()             ::  term().
-type reply()               ::  term().
-type reason()              ::  term().
-type from()                ::  {pid(), Tag :: any()}.
-type result()              ::  reply_result()
                                | noreply_result()
                                | stop_result().
-type reply_result()        ::  {reply, reply(), state()}
                                | {reply, reply(), state(), timeout()}
                                | {reply, reply(), state(), hibernate}.
-type stop_result()         ::  {stop, reason(), reply(), state()}
                                | {stop, reason(), state()}.
-type noreply_result()      ::  {noreply, state()}
                                | {noreply, state(), timeout()}
                                | {noreply, state(), hibernate}.
-type version()             ::  term().
-type old_version()         ::  version()
                                | {down, version()}.
-type void()                ::  ok.


%% API
-export([start_link/2]).

%% GENSERVER CALLBACKS
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).


% @doc
% @end
-spec start_link(non_neg_integer(), ets:tid()) ->
    {ok, pid()} | ignore | betflow:error().
start_link(PIdx, PName) ->
    gen_server:start_link({local, PName}, ?MODULE, [PIdx, PName], []).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================


-spec init(list()) ->
    {ok, state()} | {ok, state(), timeout()} | ignore | {stop, any()}.
init([PIdx, PName]) ->
    State = #{
        index => PIdx,
        registry => PName % the name of the table_registry table
    },
    {ok, State}.


-spec handle_call(request(), from(), state()) -> result().
handle_call({new, Name, Opts}, _From, State) ->
    try
        #{registry := RegTid} = State,
        Tid = create_table(RegTid, Name, Opts),
        {reply, {ok, Tid}, State}
    catch
        _:Reason ->
            {reply, {error, Reason}, State}
    end;

handle_call({delete, Name}, _From, State) ->
    try
        #{registry := RegTid} = State,
        case ets:take(RegTid, Name) of
            [#table_registry{tid = Tid}] ->
                true = ets:delete(Tid),
                {reply, ok, State};
            [] ->
                throw({badarg, Name})
        end
    catch
        _:Reason ->
            {reply, {error, Reason}, State}
    end;

handle_call(Call, _From, State) ->
    {reply, {error, {invalid_call, Call}}, State}.


-spec handle_cast(Msg :: term(), state()) -> noreply_result() | stop_result().
handle_cast(_Msg, State) ->
    {noreply, State}.


-spec handle_info(Info :: term(), state()) -> noreply_result() | stop_result().
handle_info(_Info, State) ->
    {noreply, State}.


%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
-spec terminate(reason(), state()) -> void().
terminate(_Reason, _State) ->
    ok.


%% @private
%% @doc
%% Convert process state when code is changed
%% @end
-spec code_change(OldVsn :: old_version(), state(), Extra :: term()) ->
    {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================

create_table(RegTid, Name, Opts) ->
    ok = pre_create_table(Name),
    Tid = ets:new(undefined, lists:subtract(Opts, [named_table])),
    Entry = #table_registry{name = Name, tid = Tid},
    _ =     ets:insert_new(RegTid, Entry),
    Tid.

pre_create_table(Name) ->
    case tuplespace:lookup_table(Name) of
        not_found ->
            ok;
        Tid ->
            throw({table_already_exists, Tid})
    end.
