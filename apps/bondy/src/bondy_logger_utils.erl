-module(bondy_logger_utils).

-export([set_process_metadata/1]).
-export([update_process_metadata/1]).
-export([message_and_meta/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec set_process_metadata(Map :: map()) -> ok.

set_process_metadata(Map) ->
    logger:set_process_metadata(Map#{
        node => bondy_peer_service:mynode(),
        router_vsn => bondy_app:vsn()
    }).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update_process_metadata(Map :: map()) -> ok.

update_process_metadata(Map) ->
    logger:update_process_metadata(Map).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec message_and_meta(wamp_message:t(), bondy_context:t()) -> {map(), map()}.

message_and_meta(WAMPMsg, Ctxt) ->
    Msg = #{
        message_type => element(1, WAMPMsg),
        message_id => element(2, WAMPMsg)
    },
    Meta = #{
        realm_uri => bondy_context:realm_uri(Ctxt),
        session_id => bondy_context:session_id(Ctxt),
        encoding => bondy_context:encoding(Ctxt)
    },

    {Msg, Meta}.