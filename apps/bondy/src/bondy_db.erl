-module(bondy_db).


-export([snapshot/1]).





%% =============================================================================
%% API
%% =============================================================================



%% bondy_db:snapshot("/Volumes/Macintosh HD/Users/aramallo/Desktop/tmp").
snapshot(Path) ->
    Ts = erlang:system_time(second),
    {ok, Log} = disk_log:open([
        {name, log},
        {file, Path ++ "/bondy_snapshot." ++ integer_to_list(Ts) ++ ".log"},
        {type, halt},
        {size, infinity},
        {head, #{version => plum_db}}
    ]),
    It = plum_db:iterator({undefined, undefined}),
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

