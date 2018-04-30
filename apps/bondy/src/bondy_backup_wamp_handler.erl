-module(bondy_backup_wamp_handler).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-export([handle_call/2]).



%% =============================================================================
%% API
%% =============================================================================



handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.backup.create">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [Info]} ->
            bondy_wamp_utils:maybe_error(bondy_backup:backup(Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R).