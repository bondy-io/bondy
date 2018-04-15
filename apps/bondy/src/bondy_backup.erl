%% =============================================================================
%%  bondy_backup.erl -
%%
%%  Copyright (c) 2016-2018 Ngineo Limited t/a Leapsight. All rights reserved.
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

-module(bondy_backup).


-export([backup/1]).
-export([restore/1]).





%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Backups up the database in the directory indicated by Path.
%% @end
%% -----------------------------------------------------------------------------
backup(Path) ->
    Ts = erlang:system_time(second),
    Filename = "bondy_backup." ++ integer_to_list(Ts) ++ ".log",
    Opts = [
        {name, log},
        {file, filename:join([Path, Filename])},
        {type, halt},
        {size, infinity},
        {head, #{
            format => {object, dvvset_log},
            mod => ?MODULE,
            mod_vsn => mod_vsn(),
            node => erlang:node(),
            timestamp => Ts,
            vsn => <<"1.0.0">>
        }}
    ],
    case disk_log:open(Opts) of
        {ok, Log} ->
            _ = lager:info(
                "Succesfully opened backup log; filename=~p", [Filename]),
            build_backup(Log);
        {repaired, Log, {recovered, Rec}, {badbytes, Bad}} ->
            _ = lager:info(
                "Succesfully opened backup log; filename=~p, recovered=~p, bad_bytes=~p",
                [Filename, Rec, Bad]
            ),
            build_backup(Log);
        {error, _} = Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc Restores a backup log.
%% @end
%% -----------------------------------------------------------------------------
restore(Filename) ->
    Opts =  [
        {name, log},
        {mode, read_only},
        {file, Filename}
    ],

    case disk_log:open(Opts) of
        {ok, Log} ->
            _ = lager:info(
                "Succesfully opened backup log; filename=~p", [Filename]),
            do_restore(Log);
        {repaired, Log, {recovered, Rec}, {badbytes, Bad}} ->
            _ = lager:info(
                "Succesfully opened backup log; filename=~p, recovered=~p, bad_bytes=~p",
                [Filename, Rec, Bad]
            ),
            do_restore(Log);
        {error, _} = Error ->
            Error
    end.





%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
mod_vsn() ->
    {vsn, Vsn} = lists:keyfind(vsn, 1, bondy_backup:module_info(attributes)),
    Vsn.



%% @private
build_backup(Log) ->
    Iterator = plum_db:iterator({undefined, undefined}),

    Fun = fun(FullPrefix, ok) ->
        PAcc1 = plum_db:fold_elements(
            fun
                (E, {Cnt, PAcc0}) ->
                    maybe_log(Cnt, [E | PAcc0], Log)
            end,
            {0, []},
            FullPrefix
        ),
        log([{FullPrefix, PAcc1}], Log)
    end,

    try
        build_backup(Fun, ok, Iterator)
    catch
        throw:Reason ->
            lager:error(<<"Error creating backup; reason=~p">>, [Reason]),
            {error, Reason}
    after
        ok = plum_db:iterator_close(Iterator),
        disk_log:close(Log)
    end.


%% @private
build_backup(Fun, Acc, Iterator) ->
    case plum_db:iterator_done(Iterator) of
        true ->
            Acc;
        false ->
            Next = Fun(plum_db:iterator_value(Iterator), Acc),
            build_backup(Fun, Next, plum_db:iterate(Iterator))
    end.


%% @private
maybe_log(Cnt, Acc, Log) when Cnt >= 1000 ->
    ok = log(Acc, Log),
    {0, []};

maybe_log(Cnt, Acc, _) ->
    {Cnt, Acc}.

%% @private
log([], _) ->
    ok;

log(L, Log) ->
    ok = maybe_throw(disk_log:log_terms(Log, L)),
    maybe_throw(disk_log:sync(Log)).


%% @private
do_restore(Log) ->
    try
        Counters = #{n => 0, merged => 0},
        restore_chunk(
            {head, disk_log:chunk(Log, start)}, undefined, Log, Counters)
    catch
        _:Reason ->
            lager:error(<<"Error restoring backup; reason=~p">>, [Reason]),
            {error, Reason}
    after
        disk_log:close(Log)
    end.



%% @private
restore_chunk(eof, _, Log, #{n := N, merged := M}) ->
    _ = lager:info(
        "Backup restore processed ~p records (~p records merged)", [N, M]),
    disk_log:close(Log);

restore_chunk({error, _} = Error, _, Log, _) ->
    _ = disk_log:close(Log),
    Error;

restore_chunk({head, {Cont, [H|T]}}, undefined, Log, Counters) ->
    ok = validate_head(H),
    Translate = case maps:get(format, H) of
        dvvset_log ->
            fun({metadata, DvvSet}) -> {object, DvvSet} end;
        {object, dvvset_log} ->
            undefined
    end,
    restore_chunk({Cont, T}, Translate, Log, Counters);

restore_chunk({Cont, Terms}, Translate, Log, Counters0) ->
    try
        %% io:format("Terms : ~p~n", [Terms]),
        {ok, Counters} = restore_terms(Terms, Translate, Counters0),
        restore_chunk(disk_log:chunk(Log, Cont), Translate, Log, Counters)
    catch
        _:Reason ->
            _ = lager:error("Error restoring backup; reason=~p, ", [Reason]),
            {error, Reason}
    end.


%% @private
restore_terms([{PKey, Object0}|T], Translate, Counters) ->
    #{n := N, merged := M} = Counters,
    Object = maybe_translate(Translate, Object0),
    case plum_db:merge({PKey, undefined}, Object) of
        true ->
            restore_terms(T, Translate, Counters#{n => N + 1, merged => M + 1});
        false ->
            restore_terms(T, Translate, Counters#{n => N + 1})
    end;

restore_terms([], _, Counters) ->
    {ok, Counters}.


%% @private
maybe_translate(undefined, Object) ->
    Object;

maybe_translate(Fun, Object) when is_function(Fun, 1) ->
    Fun(Object).


%% @private
validate_head(#{format := dvvset_log} = Head) ->
    _ = lager:info("Succesfully validate log head; head=~p", [Head]),
    ok;

validate_head(H) ->
    throw({invalid_header, H}).


%% @private
maybe_throw(ok) -> ok;
maybe_throw({error, Reason}) -> throw(Reason).

