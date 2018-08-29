-module(bondy_oauth2_wamp_handler).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(REVOKE_USER_TOKEN,
    <<"com.leapsight.bondy.oauth2.revoke_token">>).
-define(REVOKE_USER_TOKENS,
    <<"com.leapsight.bondy.oauth2.revoke_tokens">>).

-export([handle_call/2]).




%% =============================================================================
%% API
%% =============================================================================



handle_call(#call{procedure_uri = ?REVOKE_USER_TOKEN} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 4) of
        {ok, [Uri, Issuer, Username, DeviceId]} ->
            Res = bondy_oauth2:revoke_token(
                refresh_token, Uri, Issuer, Username, DeviceId),
            bondy_wamp_utils:maybe_error(Res, M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?REVOKE_USER_TOKENS} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Issuer, Username]} ->
            Res = bondy_oauth2:revoke_token(
                refresh_token, Uri, Issuer, Username),
            bondy_wamp_utils:maybe_error(Res, M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{} = M, Ctxt) ->
    Error = bondy_wamp_utils:no_such_procedure_error(M),
    bondy:send(bondy_context:peer_id(Ctxt), Error).
