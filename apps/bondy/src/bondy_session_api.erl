-module(bondy_session_api).

-include_lib("wamp/include/wamp.hrl").

-export([get/3]).


get(RealmUri, SessionId, _Details) ->
    case bondy_session:lookup(RealmUri, SessionId) of
        {error, not_found} ->
            Uri = ?WAMP_NO_SUCH_SESSION,
            Msg = <<"No session exists for the supplied identifier">>,
            {error, Uri, #{}, [Msg]};

        Session ->
            {ok, #{}, [bondy_session:info(Session)], #{}}
    end.


