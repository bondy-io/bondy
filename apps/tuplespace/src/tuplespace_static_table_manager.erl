%% -----------------------------------------------------------------------------
%% @doc The Table Manager is a server that is responsible for the
%% creation of all tuplespace's in-memory tables (ets) on application startup.
%% The manager is the single table owner for all tables.
%% It is crucial that no additional responsibilities and functionalities are
%% added to the server to eliminate the possibility of it crashing.
%% @end
%% -----------------------------------------------------------------------------
-module(tuplespace_static_table_manager).
-behaviour(gen_server).
-include ("tuplespace.hrl").


-define(SERVER, ?MODULE).


-type state()               :: #{tables => list()}.
-type request()             :: term().
-type reply()               :: term().
-type reason()              :: term().
-type from()                :: {pid(), Tag :: any()}.
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
-export([start_link/0]).

%% GENSERVER CALLBACKS
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
% @doc
% This function is intended to be called from sup, as part of
% starting the betflow application
% @end
%% -----------------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | ignore | betflow:error().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

-spec init(list()) ->
    {ok, state()} | {ok, state(), timeout()} | ignore | {stop, any()}.
init([]) ->
    %% By calling create_static_tables this server becomes their owner
    %% We do it here to avoid returning control to the sup until
    %% we created the tables
    Tabs = tuplespace:create_static_tables(),
    {ok, #{tables => Tabs}}.


-spec handle_call(request(), from(), state()) -> result().
handle_call(Call, _From, State) ->
    {reply, {error, {invalid_call, Call}}, State}.


-spec handle_cast(Msg :: term(), state()) -> noreply_result() | stop_result().
handle_cast(_Msg, State) ->
    {noreply, State}.


-spec handle_info(Info :: term(), state()) -> noreply_result() | stop_result().
handle_info(_Info, State) ->
    {noreply, State}.


-spec terminate(reason(), state()) -> void().
terminate(_Reason, _State) ->
    %% All tables will be deleted now
    ok.


-spec code_change(OldVsn :: old_version(), state(), Extra :: term()) ->
    {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
