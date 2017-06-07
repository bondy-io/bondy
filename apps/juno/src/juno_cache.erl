-module(juno_cache).


-export([get/2]).
-export([put/3]).
-export([put/4]).
-export([remove/2]).


-spec get(RealmUri :: binary(), any()) -> {ok, any()} | not_found.
get(_, _) ->
    %%TODO
    not_found.

put(RealmUri, K, V) ->
    juno_cache:put(RealmUri, K, V, #{}).


put(_RealmUri, _, _, _Opts) ->
    %%TODO
    ok.

remove(_RealmUri, _) ->
    %%TODO
    ok.

%%TODO factor out all TTL related functionality from tuplespace_queue into a tuplespace_ttl module to be reused