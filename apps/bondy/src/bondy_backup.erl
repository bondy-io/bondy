-module(bondy_backup).


-export([snapshot/1]).
-export([import/1]).





%% =============================================================================
%% API
%% =============================================================================



import(Filename) ->
    Res =  disk_log:open([
        {name, log},
        {mode, read_only},
        {file, Filename}
    ]),
    Log = case Res of
        {ok, Log0} ->
            _ = lager:info("Succesfully opened log; path=~p", [Filename]),
            Log0;
        {repaired, Log0, {recovered, Rec}, {badbytes, Bad}} ->
            _ = lager:info(
                "Succesfully opened log; path=~p, recovered=~p, bad_bytes=~p",
                [Filename, Rec, Bad]
            ),
            Log0
    end,

    import_chunk(disk_log:chunk(Log, start), Log).



%% bondy_backup:snapshot("/Volumes/Macintosh HD/Users/aramallo/Desktop/tmp").
snapshot(Path) ->
    Ts = erlang:system_time(second),
    {ok, Log} = disk_log:open([
        {name, log},
        {file, Path ++ "/bondy_snapshot." ++ integer_to_list(Ts) ++ ".log"},
        {type, halt},
        {size, infinity},
        {head, #{version => plum_db}}
    ]),
    It = plum_db:iterator(),
    Fun = fun(FullPrefix, ok) ->
        PAcc1 = plum_db:fold(
            fun
                ({_, ['$deleted']}, {Cnt, PAcc0}) ->
                    {Cnt, PAcc0};
                (E, {Cnt, PAcc0}) ->
                    maybe_log(Cnt, [E | PAcc0], Log)
            end,
            {0, []},
            FullPrefix
        ),
        log([{FullPrefix, PAcc1}], Log)
    end,
    try
        fold_it(Fun, ok, It)
    catch
        throw:Reason ->
            lager:error(<<"Error creating snapshot; reason=~p">>, [Reason]),
            {error, Reason}
    after
        ok =  plum_db:iterator_close(It),
        maybe_throw(disk_log:close(Log))
    end.


%% @private
fold_it(Fun, Acc, It) ->
    case plum_db:iterator_done(It) of
        true ->
            Acc;
        false ->
            Next = Fun(plum_db:iterator_value(It), Acc),
            fold_it(Fun, Next, plum_db:iterate(It))
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
maybe_throw(ok) -> ok;
maybe_throw({error, Reason}) -> throw(Reason).




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
import_chunk(eof, Log) ->
    disk_log:close(Log);

import_chunk({error, _} = Error, Log) ->
    _ = disk_log:close(Log),
    Error;

import_chunk({Cont, Terms}, Log) ->
    try
        io:format("Terms : ~p~n", [Terms]),
        ok = import_terms(Terms),
        import_chunk(disk_log:chunk(Log, Cont), Log)
    catch
        _:Reason ->
            _ = lager:error("Error importing snapshot; reason=~p", {Reason}),
            {error, Reason}
    end.


%% @private
import_terms([{FPKey, Object}|T]) ->
    %% We use the server directly as we are importing objects
    ok = plum_db_partition_server:put(FPKey, Object),
    import_terms(T);

import_terms([]) ->
    ok.

