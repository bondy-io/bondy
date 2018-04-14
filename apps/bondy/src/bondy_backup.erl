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
            format => dvvset_log,
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
    try
        build_backup(plumtree_metadata_manager:iterator(), Log)
    catch
        throw:Reason ->
            lager:error(<<"Error creating backup; reason=~p">>, [Reason]),
            {error, Reason}
    after
        disk_log:close(Log)
    end.



%% @private
build_backup(PrefixIt, Log) ->
    case plumtree_metadata_manager:iterator_done(PrefixIt) of
        true ->
            plumtree_metadata_manager:iterator_close(PrefixIt);
        false ->
            Prefix = plumtree_metadata_manager:iterator_value(PrefixIt),
            ObjIt = plumtree_metadata_manager:iterator(Prefix, undefined),
            build_backup(PrefixIt, ObjIt, Log)
    end.


%% @private
build_backup(PrefixIt, ObjIt, Log) ->
    case plumtree_metadata_manager:iterator_done(ObjIt) of
        true ->
            plumtree_metadata_manager:iterator_close(ObjIt),
            build_backup(plumtree_metadata_manager:iterate(PrefixIt), Log);
        false ->
            FullPrefix = plumtree_metadata_manager:iterator_prefix(ObjIt),
            {K, V} = plumtree_metadata_manager:iterator_value(ObjIt),
            try
                ok = log([{{FullPrefix, K}, V}], Log),
                build_backup(
                    PrefixIt, plumtree_metadata_manager:iterate(ObjIt), Log)
            catch
                _:Reason ->
                    lager:error(
                        <<"Error creating backup; reason=~p">>, [Reason]),
                    ok = plumtree_metadata_manager:iterator_close(ObjIt),
                    ok = plumtree_metadata_manager:iterator_close(PrefixIt),
                    throw(Reason)
            end
    end.


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
        restore_chunk({head, disk_log:chunk(Log, start)}, Log, Counters)
    catch
        _:Reason ->
            lager:error(<<"Error restoring backup; reason=~p">>, [Reason]),
            {error, Reason}
    after
        disk_log:close(Log)
    end.



%% @private
restore_chunk(eof, Log, #{n := N, merged := M}) ->
    _ = lager:info(
        "Backup restore processed ~p records (~p records merged)", [N, M]),
    disk_log:close(Log);

restore_chunk({error, _} = Error, Log, _) ->
    _ = disk_log:close(Log),
    Error;

restore_chunk({head, {Cont, [H|T]}}, Log, Counters) ->
    ok = validate_head(H),
    restore_chunk({Cont, T}, Log, Counters);

restore_chunk({Cont, Terms}, Log, Counters0) ->
    try
        %% io:format("Terms : ~p~n", [Terms]),
        {ok, Counters} = restore_terms(Terms, Counters0),
        restore_chunk(disk_log:chunk(Log, Cont), Log, Counters)
    catch
        _:Reason ->
            _ = lager:error("Error restoring backup; reason=~p, ", [Reason]),
            {error, Reason}
    end.


%% @private
restore_terms([{PKey, Object}|T], #{n := N, merged := M} = Counters) ->
    case plumtree_metadata_manager:merge({PKey, undefined}, Object) of
        true ->
            restore_terms(T, Counters#{n => N + 1, merged => M + 1});
        false ->
            restore_terms(T, Counters#{n => N + 1})
    end;

restore_terms([], Counters) ->
    {ok, Counters}.


%% @private
validate_head(#{format := dvvset_log} = Head) ->
    _ = lager:info("Succesfully validate log head; head=~p", [Head]),
    ok;

validate_head(H) ->
    throw({invalid_header, H}).


%% @private
maybe_throw(ok) -> ok;
maybe_throw({error, Reason}) -> throw(Reason).

