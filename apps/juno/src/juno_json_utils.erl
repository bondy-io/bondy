-module(juno_json_utils).

-export([error/1]).

error({Name, Desc}) ->
    jsx:encode(#{<<"code">> => Name, <<"message">> => Desc});
error({Name, Desc, L}) when is_list(L) ->
    jsx:encode(#{
        <<"code">> => Name,
        <<"message">> => Desc,
        <<"errors">> => [pbs_json_utils:error(E) || E <- L]
    });
error(Reason) ->
    jsx:encode(#{<<"code">> => Reason}).
