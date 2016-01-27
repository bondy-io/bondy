-module(ramp_context).
-include ("ramp.hrl").


-type context()       ::  #{
    session_id => id(),
    realm_uri => uri(),
    subprotocol => subprotocol(),
    goodbye_initiated => false
}.
-export_type([context/0]).

-export([new/0]).
-export([session_id/1]).
-export([set_session_id/2]).


-spec new() -> context().
new() ->
    #{}.


-spec session_id(context()) -> id().
session_id(#{session_id := S}) -> S.


-spec set_session_id(context(), id()) -> context().
set_session_id(Ctxt, SessionId) ->
    Ctxt#{session_id => SessionId}.
