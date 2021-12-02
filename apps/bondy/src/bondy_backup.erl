%% =============================================================================
%%  bondy_backup.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, vsn 2.0 (the "License");
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
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_backup).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include("bondy.hrl").
-include("bondy_plum_db.hrl").
-include("bondy_backup.hrl").

-define(BACKUP_SPEC, #{
    <<"path">> => #{
        alias => path,
        key => path,
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (X) when is_list(X) ->
                {ok, X};
            (X) when is_binary(X) ->
                {ok, unicode:characters_to_list(X)};
            (_) ->
                false
        end
    }
}).

-define(RESTORE_SPEC, #{
    <<"filename">> => #{
        alias => filename,
        key => filename,
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (X) when is_list(X) ->
                {ok, X};
            (X) when is_binary(X) ->
                {ok, unicode:characters_to_list(X)};
            (_) ->
                false
        end
    }
}).

-define(STATUS_SPEC, #{
    <<"filename">> => #{
        alias => filename,
        key => filename,
        required => false,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (X) when is_list(X) ->
                {ok, X};
            (X) when is_binary(X) ->
                {ok, unicode:characters_to_list(X)};
            (_) ->
                false
        end
    }
}).


-record(state, {
    status          ::  status(),
    timestamp       ::  non_neg_integer(),
    pid             ::  pid() | undefined,
    filename        ::  file:filename() | undefined
}).


-type status()      ::  backup_in_progress | restore_in_progress | undefined.
-type info()        ::  #{
    filename => file:filename(),
    timestamp => non_neg_integer()
}.


%% API
-export([backup/1]).
-export([status/0]).
-export([status/1]).
-export([restore/1]).
-export([start_link/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).






%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc Backups up the database in the directory indicated by Path.
%% @end
%% -----------------------------------------------------------------------------
-spec backup(file:filename_all() | map()) ->
    {ok, info()} | {error, term()}.

backup(Map0) when is_map(Map0) ->
    try maps_utils:validate(Map0, ?BACKUP_SPEC) of
        Map1 ->
            gen_server:call(?MODULE, {backup, Map1})
    catch
        error:Reason ->
            {error, Reason}
    end;

backup(Path) ->
    backup(#{path => Path}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
status() ->
    status(#{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec status(file:filename_all() | map()) ->
    undefined | {status(), non_neg_integer()} | {error, unknown}.

status(Map0) when is_map(Map0) ->
    try maps_utils:validate(Map0, ?STATUS_SPEC) of
        Map1 ->
            gen_server:call(?MODULE, {status, Map1})
    catch
        error:Reason ->
            {error, Reason}
    end;

status(Filename) ->
    status(#{filename => Filename}).

%% -----------------------------------------------------------------------------
%% @doc Restores a backup log.
%% @end
%% -----------------------------------------------------------------------------
-spec restore(file:filename_all() | map()) -> {ok, info()} | {error, term()}.

restore(Map0) when is_map(Map0) ->
    try maps_utils:validate(Map0, ?RESTORE_SPEC) of
        Map1 ->
            gen_server:call(?MODULE, {restore, Map1})
    catch
        error:Reason ->
            {error, Reason}
    end;

restore(Filename) ->
    restore(#{filename => Filename}).





%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    {ok, #state{}}.


handle_call({backup, Map}, _From, #state{status = undefined} = State0) ->
    {ok, State1} = async_backup(Map, State0),
    Backup = #{
        filename => unicode:characters_to_binary(State1#state.filename),
        timestamp => State1#state.timestamp
    },
    {reply, {ok, Backup}, State1};

handle_call({backup, _}, _From, State) ->
    {reply, {error, State#state.status}, State};

handle_call({restore, Map}, _From, #state{status = undefined} = State0) ->
    {ok, State1} = async_restore(Map, State0),
    Restore = #{
        filename => unicode:characters_to_binary(State1#state.filename),
        timestamp => State1#state.timestamp
    },
    {reply, {ok, Restore}, State1};

handle_call({restore, _}, _From, State) ->
    {reply, {error, State#state.status}, State};

handle_call({status, Map}, _From, State) when map_size(Map) =:= 0 ->
    {reply, {ok, State#state.status}, State};

handle_call(
    {status, #{filename := Filename}},
    _From,
    #state{filename = Filename} = State) ->
    Reply = case State#state.status of
        undefined ->
            read_head(Filename);
        Status ->
            Secs = erlang:system_time(second) - State#state.timestamp,
            {ok, #{status => Status, elapsed_time_secs => Secs}}
    end,
    {reply, Reply, State};

handle_call({status, #{filename := Filename}}, _From, State) ->
    {reply, read_head(Filename), State};

handle_call(_, _, State) ->
    {reply, ok, State}.


handle_cast(_Event, State) ->
    {noreply, State}.

handle_info({backup_reply, ok, Pid}, #state{pid = Pid} = State) ->
    Secs = erlang:system_time(second) - State#state.timestamp,
    ok = notify_backup_finished([State#state.filename, Secs]),
    {noreply, State#state{status = undefined, pid = undefined}};

handle_info({backup_reply, {error, Reason}, Pid}, #state{pid = Pid} = State) ->
    Secs = erlang:system_time(second) - State#state.timestamp,
    ok = notify_backup_error([Reason, State#state.filename, Secs]),
    {noreply, State#state{status = undefined, pid = undefined}};

handle_info({restore_reply, {ok, Counters}, Pid}, #state{pid = Pid} = State) ->
    #{read_count := N, merged_count := M} = Counters,
    Secs = erlang:system_time(second) - State#state.timestamp,
    ok = notify_restore_finished([State#state.filename, Secs, N, M]),
    {noreply, State#state{status = undefined, pid = undefined}};

handle_info({restore_reply, {error, Reason}, Pid}, #state{pid = Pid} = State) ->
    Secs = erlang:system_time(second) - State#state.timestamp,
    ok = notify_restore_error([State#state.filename, Reason, Secs]),
    {noreply, State#state{status = undefined, pid = undefined}};

handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        description => "Unexpected event received",
        event => Info
    }),
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================


async_backup(#{path := Path} , State0) ->
    Ts = erlang:system_time(second),
    Filename = "bondy_backup." ++ integer_to_list(Ts) ++ ".bak",
    File = filename:join([Path, Filename]),
    Me = self(),
    Pid = spawn_link(fun() ->
        case do_backup(File, Ts) of
            ok ->
                Me ! {backup_reply, ok, self()};
            {error, _} = Error ->
                Me ! {backup_reply, Error, self()}
        end
    end),
    State1 = State0#state{
        filename = File,
        pid = Pid,
        timestamp = Ts,
        status = backup_in_progress
    },
    {ok, State1}.


%% @private
do_backup(File, Ts) ->
    Opts = [
        {name, log},
        {file, File},
        {type, halt},
        {size, infinity},
        {head, #{
            format => dvvset_log,
            mod => ?MODULE,
            mod_vsn => mod_vsn(),
            node => erlang:node(),
            timestamp => Ts,
            vsn => <<"1.2.0">>
        }}
    ],

    case disk_log:open(Opts) of
        {ok, Log} ->
            _ = notify_backup_started(File),
            build_backup(Log);
        {error, _} = Error ->
            Error
    end.


%% @private
mod_vsn() ->
    {vsn, Vsn} = lists:keyfind(vsn, 1, bondy_backup:module_info(attributes)),
    Vsn.


%% @private
build_backup(Log) ->
    Iterator = plum_db:iterator({'_', '_'}),
    try
        Acc1 = build_backup(Iterator, Log, []),
        %% We log the remaining elements
        log(Acc1, Log)
    catch
        throw:Reason ->
            {error, Reason}
    after
        ok = plum_db:iterator_close(Iterator),
        disk_log:close(Log)
    end.


%% @private
build_backup(Iterator, Log, Acc0) ->
    case plum_db:iterator_done(Iterator) of
        true ->
            Acc0;
        false ->
            %% iterator_element/1 gets the whole prefixed object without
            %% resolving conflicts
            E = plum_db:iterator_element(Iterator),
            Acc1 = maybe_add(E, Acc0),
            Acc2 = maybe_log(Acc1, Log),
            build_backup(plum_db:iterate(Iterator), Log, Acc2)
    end.


%% @private
maybe_add({{{registry_registrations, _}, _}, _}, Acc) ->
    Acc;
maybe_add({{{registry_subscriptions, _}, _}, _}, Acc) ->
    Acc;
maybe_add({{{registry, _}, _}, _}, Acc) ->
    %% Legacy prefix
    Acc;
maybe_add(E, Acc) ->
    [E | Acc].


%% @private
maybe_log(Acc, Log) when length(Acc) =:= 500 ->
    ok = log(Acc, Log),
    [];

maybe_log(Acc, _) ->
    Acc.


%% @private
log([], _) ->
    ok;

log(L, Log) ->
    ok = maybe_throw(disk_log:log_terms(Log, L)),
    maybe_throw(disk_log:sync(Log)).


%% @private
maybe_throw(ok) -> ok;
maybe_throw({error, Reason}) -> throw(Reason).


async_restore(#{filename := Filename}, State0) ->
    %% @TODO We might want to stop AAE so that
    %% (1) we avoid writing the hahstree during restore and
    %% (2) avoid exchanges too.
    Ts = erlang:system_time(second),
    Me = self(),
    Pid = spawn_link(fun() ->
        case do_restore(Filename) of
            {ok, _Counters} = OK ->
                Me ! {restore_reply, OK, self()};
            {error, _} = Error ->
                Me ! {restore_reply, Error, self()}
        end
    end),
    State1 = State0#state{
        filename = Filename,
        pid = Pid,
        timestamp = Ts,
        status = restore_in_progress
    },
    {ok, State1}.


%% @private
do_restore(Filename) ->
    Opts =  [
        {name, log},
        {mode, read_only},
        {file, Filename}
    ],

    case disk_log:open(Opts) of
        {ok, Log} ->
            ok = notify_restore_started([Filename, 0, 0]),
            do_restore_aux(Log);
        {repaired, Log, {recovered, Rec}, {badbytes, Bad}} ->
            ok = notify_restore_started([Filename, Rec, Bad]),
            do_restore_aux(Log);
        {error, _} = Error ->
            Error
    end.


do_restore_aux(Log) ->
    try
        Counters0 = #{read_count => 0, merged_count => 0},
        restore_chunk(
            {head, disk_log:chunk(Log, start)}, undefined, Log, Counters0)
    catch
       _:Reason ->
            {error, Reason}
    after
        _ = disk_log:close(Log)
    end.



%% @private
restore_chunk(eof, _, Log, Counters) ->
    ok = disk_log:close(Log),
    {ok, Counters};

restore_chunk({error, _} = Error, _, Log, _) ->
    _ = disk_log:close(Log),
    Error;

restore_chunk({head, {Cont, [H|T]}}, undefined, Log, Counters) ->
    ok = validate_head(H),
    case maps:get(vsn, H) of
        Vsn when Vsn >= <<"1.2.0">> ->
            restore_chunk({Cont, T}, <<"1.2.0">>, Log, Counters);
        Vsn ->
            restore_chunk({Cont, T}, Vsn, Log, Counters)
    end;

restore_chunk({Cont, Terms}, Vsn, Log, Counters0) ->
    try
        {ok, Counters} = restore_terms(Terms, Vsn, Counters0),
        restore_chunk(disk_log:chunk(Log, Cont), Vsn, Log, Counters)
    catch
       _:Reason ->
            {error, Reason}
    end.



%% @private
restore_terms(
    [{{{registry, _}, _}, _}|T], Vsn,
    #{read_count := N} = Counters) ->
    %% Previous version of backup would backup the registry
    restore_terms(T, Vsn, Counters#{read_count => N + 1});

restore_terms([H|T], Vsn, #{read_count := N, merged_count := M} = Counters) ->
    case migrate(Vsn, H) of
        {PKey, Object} ->
            case plum_db:merge({PKey, undefined}, Object) of
                true ->
                    restore_terms(
                        T, Vsn, Counters#{read_count => N + 1, merged_count => M + 1});
                false ->
                    restore_terms(T, Vsn, Counters#{read_count => N + 1})
            end;
        skip ->
            restore_terms(T, Vsn, Counters#{read_count => N + 1})
    end;

restore_terms([], _, Counters) ->
    {ok, Counters}.


%% @private
migrate(Vsn, KeyValue) when Vsn >= <<"1.2.0">> ->
    KeyValue;
migrate(Vsn, {PKey, Object}) when Vsn < <<"1.2.0">> ->
    {Prefix, Key} = PKey,
    case rename_prefix(Prefix) of
        skip ->
            skip;
        Renamed ->
            {{Renamed, Key}, migrate_object(Vsn, Object)}
    end.


%% @private
rename_prefix({global, realms}) ->
    {security, realms};

rename_prefix({global, api_specs}) ->
    {api_gateway, api_specs};

rename_prefix({A, B}) when is_binary(A) ->
    rename_prefix(B, A).


%% @private
rename_prefix(<<"groups">>, Bin) ->
    Realm = binary:part(Bin, {0, byte_size(Bin) - byte_size(<<".security">>)}),
    {?PLUM_DB_GROUP_TAB, Realm};

rename_prefix(<<"users">>, Bin) ->
    Realm = binary:part(Bin, {0, byte_size(Bin) - byte_size(<<".security">>)}),
    {?PLUM_DB_USER_TAB, Realm};

rename_prefix(<<"sources">>, Bin) ->
    Realm = binary:part(Bin, {0, byte_size(Bin) - byte_size(<<".security">>)}),
    {?PLUM_DB_SOURCE_TAB, Realm};

rename_prefix(<<"usergrants">>, Bin) ->
    Realm = binary:part(Bin, {0, byte_size(Bin) - byte_size(<<".security">>)}),
    {?PLUM_DB_USER_GRANT_TAB, Realm};

rename_prefix(<<"groupgrants">>, Bin) ->
    Realm = binary:part(Bin, {0, byte_size(Bin) - byte_size(<<".security">>)}),
    {?PLUM_DB_GROUP_GRANT_TAB, Realm};

rename_prefix(<<"status">>, Bin) ->
    Realm = binary:part(Bin, {0, byte_size(Bin) - byte_size(<<".security">>)}),
    {security_status, Realm};

rename_prefix(<<"config">>, Bin) ->
    Realm = binary:part(Bin, {0, byte_size(Bin) - byte_size(<<".security">>)}),
    {security_config, Realm};

rename_prefix(<<"refresh_tokens">>, _Bin) ->
    %% There is no sensible way to migrate this as we used
    %% $. as separator before :-(
    skip.
    %% case binary:split(Bin, <<$.>>, [global]) of
    %%     [Realm, IssuerOrSub] ->
    %%         {oauth2_refresh_tokens, <<Realm/binary, $,, IssuerOrSub/binary>>};
    %%     [Realm, Issuer, Sub] ->
    %%         {oauth2_refresh_tokens,
    %%             <<Realm/binary, $,, Issuer/binary, $,, Sub/binary>>}
    %% end.


%% @private
migrate_object(_, {metadata, _} = Object) ->
    %% For versions < 1.1.0
    setelement(1, Object, object);
migrate_object(_, {object, _} = Object) ->
    Object.


%% @private
validate_head(#{format := dvvset_log}) ->
    ok;

validate_head(H) ->
    throw({invalid_header, H}).


%% @private
read_head(Filename) ->
    Opts =  [
        {name, log},
        {mode, read_only},
        {file, Filename}
    ],
    Acc = #{filename => unicode:characters_to_binary(Filename)},
    case disk_log:open(Opts) of
        {ok, Log} ->
            do_read_head(Log, Acc);
        {repaired, Log, {recovered, Rec}, {badbytes, Bad}} ->
            do_read_head(Log, Acc#{recovered => Rec, bad_bytes => Bad});
        {error, no_such_log} ->
            {error, not_found};
        {error, _} = Error ->
            Error
    end.


%% @private
do_read_head(Log, Acc0) ->
    try
        case disk_log:chunk(Log, start) of
            {_Cont, [H|_]} ->
                ok = validate_head(H),
                Acc1 = Acc0#{
                    status => ok,
                    bad_bytes => 0
                },
                {ok, maps:merge(Acc1, H)};
            {_Cont, [H|_], BadBytes} ->
                ok = validate_head(H),
                Acc1 = Acc0#{
                    status => ok,
                    bad_bytes => BadBytes
                },
                {ok, maps:merge(Acc1, H)};
            eof ->
                {ok, Acc0#{status => invalid_format}};
            {error, {corrupt_log_file, _}} ->
            {ok, Acc0#{status => corrupt, bad_bytes => 0}};
            {error, {blocked_log, _}} ->
                {ok, Acc0#{status => blocked, bad_bytes => 0}};
            {error, _} = Error ->
                Error
        end
    catch
       _:Reason ->
            {error, Reason}
    after
        _ = disk_log:close(Log)
    end.


%% @private
notify_backup_started(File) ->
    ?LOG_NOTICE(#{
        description => "Started backup",
        filename => File
    }),
    bondy_event_manager:notify({backup_started, File}).


%% @private
notify_backup_finished([Filename, Time] = Args) ->
    ?LOG_NOTICE(#{
        description => "Finished creating backup",
        filename => Filename,
        elapsed_time_secs => Time
    }),
    bondy_event_manager:notify({backup_finished, Args}).


%% @private
notify_backup_error([Reason, Filename, Time] = Args)  ->
    ?LOG_ERROR(#{
        description => "Error creating backup",
        filename => Filename,
        reason => Reason,
        elapsed_time_secs => Time
    }),
    bondy_event_manager:notify({backup_failed, Args}).


%% @private
notify_restore_started([Filename, Rec, Bad]) ->
    ?LOG_NOTICE(#{
        description => "Backup restore started",
        filename => Filename,
        recovered => Rec,
        bad_bytes => Bad
    }),
    bondy_event_manager:notify({backup_restore_started, Filename}).


%% @private
notify_restore_finished([Filename, Time, Read, Merged] = Args) ->
    ?LOG_NOTICE(#{
        description => "Backup restore finished",
        filename => Filename,
        elapsed_time_secs => Time,
        read_count => Read,
        merged_count => Merged
    }),
    bondy_event_manager:notify({backup_restore_finished, Args}).


%% @private
notify_restore_error([Filename, Reason, Time] = Args) ->
    ?LOG_ERROR(#{
        description => "Backup restore failed",
        filename => Filename,
        reason => Reason,
        elapsed_time_secs => Time
    }),
    bondy_event_manager:notify({backup_restore_failed, Args}).