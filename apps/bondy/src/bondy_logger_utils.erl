-module(bondy_logger_utils).

-export([set_process_metadata/1]).
-export([update_process_metadata/1]).



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