-module(bondy_logger_utils).

-export([message_and_meta/2]).
-export([set_primary_metadata/1]).
-export([set_process_metadata/1]).
-export([update_primary_metadata/1]).
-export([update_process_metadata/1]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec set_primary_metadata(Map :: map()) -> ok.

set_primary_metadata(Map0) ->
    Map = Map0#{
        node => bondy_config:node(),
        router_vsn => bondy_app:vsn()
    },
    logger:update_primary_config(#{metadata => Map}).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update_primary_metadata(Map :: map()) -> ok.

update_primary_metadata(Map) ->
    NewMeta = Map#{
        node => bondy_config:node(),
        router_vsn => bondy_app:vsn()
    },
    Config = logger:get_primary_config(),
    Meta = case maps:find(metadata, Config) of
        {ok, OldMeta} -> maps:merge(OldMeta, NewMeta);
        error -> NewMeta
    end,

    logger:update_primary_config(Config#{metadata => Meta}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec set_process_metadata(Map :: map()) -> ok.

set_process_metadata(Map) ->
    logger:set_process_metadata(Map#{
        node => bondy_config:node(),
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