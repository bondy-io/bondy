-module(bondy_session_api).
-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-export([get/3]).


get(Key, SessionId, _Details) ->
    try

        case bondy_session:lookup(Key) of
            {ok, Session} ->
                case bondy_session:external_id(Session) of
                    SessionId ->
                        {ok, #{}, [bondy_session:to_external(Session)], #{}};
                    OtherId ->
                        ?LOG_WARNING(#{
                            description => "Session data inconsistency. SessionId should be " ++ integer_to_list(SessionId) ++ ".",
                            session_id => OtherId
                        }),
                        throw(no_such_session)
                end;
            {error, not_found} ->
                throw(no_such_session)
        end

    catch
        throw:no_such_session ->
            Uri = ?WAMP_NO_SUCH_SESSION,
            Msg = <<"No session exists for the supplied identifier">>,
            {error, Uri, #{}, [Msg]}
    end.


