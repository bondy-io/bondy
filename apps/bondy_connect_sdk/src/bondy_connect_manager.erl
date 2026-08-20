%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_manager).

-moduledoc """
Owns connection **identity** (optional names) and **lifecycle delegation**:
validates a connect spec, asks `bondy_connect_connections_sup` to start a
per-connection supervisor, tracks `connection pid → conn_sup` (and `name → pid`)
and monitors the connection so the registry self-heals when it dies.

It does **not** wait for the session to establish — the caller (`bondy_connect_sdk`)
does that via `bondy_connect_connection:await_ready/2`, so the manager never
blocks on a network handshake.
""".

-behaviour(gen_server).

-record(state, {
    conns = #{} :: #{pid() => entry()},
    names = #{} :: #{atom() => pid()}
}).

-type entry() :: #{
    conn_sup := pid(),
    name := atom() | undefined,
    ref := reference()
}.

-export([start_link/0]).
-export([connect/2]).
-export([disconnect/1]).
-export([whereis_name/1]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).

-define(SERVER, ?MODULE).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc """
Validate `Spec`, start a supervised connection, and return the connection pid.
`Name` (an atom or `undefined`) optionally registers the connection for lookup.
The returned connection is not yet established — the caller awaits readiness.
""".
-spec connect(Name :: atom() | undefined, Spec :: map()) ->
    {ok, pid()} | {error, term()}.
connect(Name, Spec) ->
    gen_server:call(?SERVER, {connect, Name, Spec}).

-doc "Stop a connection (by pid or registered name).".
-spec disconnect(pid() | atom()) -> ok.
disconnect(Conn) ->
    try
        gen_server:call(?SERVER, {disconnect, Conn})
    catch
        %% The manager is unavailable because the application is stopping; the
        %% connection is therefore already gone, so the disconnect has
        %% effectively succeeded. Honour the `-> ok` contract rather than
        %% exiting in the caller's teardown code.
        exit:{noproc, _} -> ok;
        exit:{normal, _} -> ok;
        exit:{shutdown, _} -> ok;
        exit:{{shutdown, _}, _} -> ok
    end.

-doc "Resolve a registered name to a connection pid.".
-spec whereis_name(atom()) -> pid() | undefined.
whereis_name(Name) when is_atom(Name) ->
    gen_server:call(?SERVER, {whereis, Name}).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    {ok, #state{}}.

handle_call({connect, Name, _Spec}, _From, State) when
    Name =/= undefined, is_map_key(Name, State#state.names)
->
    {reply, {error, {already_started, Name}}, State};
handle_call({connect, Name, Spec}, _From, State) ->
    case bondy_connect_config:validate(Spec) of
        {ok, Config} ->
            do_connect(Name, Config, State);
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({disconnect, Conn}, _From, State) ->
    {reply, ok, do_disconnect(Conn, State)};
handle_call({whereis, Name}, _From, State) ->
    {reply, maps:get(Name, State#state.names, undefined), State};
handle_call(_Request, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, Pid, _Reason}, State) ->
    {noreply, forget(Pid, Ref, State)};
handle_info(_Info, State) ->
    {noreply, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_connect(Name, Config, State) ->
    case bondy_connect_connections_sup:start_connection(Config) of
        {ok, ConnSup} ->
            case bondy_connect_conn_sup:connection(ConnSup) of
                undefined ->
                    _ = bondy_connect_connections_sup:stop_connection(ConnSup),
                    {reply, {error, no_connection_process}, State};
                ConnPid ->
                    Ref = erlang:monitor(process, ConnPid),
                    Entry = #{conn_sup => ConnSup, name => Name, ref => Ref},
                    Conns = maps:put(ConnPid, Entry, State#state.conns),
                    Names = maybe_register(Name, ConnPid, State#state.names),
                    NewState = State#state{conns = Conns, names = Names},
                    {reply, {ok, ConnPid}, NewState}
            end;
        {error, _} = Error ->
            {reply, Error, State}
    end.

%% @private
do_disconnect(Conn, State) ->
    case resolve(Conn, State) of
        undefined ->
            State;
        ConnPid ->
            _ =
                case maps:find(ConnPid, State#state.conns) of
                    {ok, #{conn_sup := ConnSup}} ->
                        bondy_connect_connections_sup:stop_connection(ConnSup);
                    error ->
                        ok
                end,
            %% The 'DOWN' from the monitored connection performs the cleanup.
            State
    end.

%% @private
maybe_register(undefined, _Pid, Names) -> Names;
maybe_register(Name, Pid, Names) -> maps:put(Name, Pid, Names).

%% @private
resolve(Pid, _State) when is_pid(Pid) ->
    Pid;
resolve(Name, State) when is_atom(Name) ->
    maps:get(Name, State#state.names, undefined).

%% @private
forget(Pid, Ref, State) ->
    case maps:find(Pid, State#state.conns) of
        {ok, #{name := Name, conn_sup := ConnSup, ref := Ref}} ->
            %% Tear down the per-connection supervisor. Idempotent: a user
            %% disconnect already stopped it; a connection that gave up on its
            %% own (reconnect budget exhausted) did not, so this reaps the
            %% otherwise-orphaned conn_sup + handler_sup.
            _ = bondy_connect_connections_sup:stop_connection(ConnSup),
            State#state{
                conns = maps:remove(Pid, State#state.conns),
                names = drop_name(Name, State#state.names)
            };
        _ ->
            State
    end.

%% @private
drop_name(undefined, Names) -> Names;
drop_name(Name, Names) -> maps:remove(Name, Names).
