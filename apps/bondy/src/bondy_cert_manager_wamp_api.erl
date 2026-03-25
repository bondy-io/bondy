%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_cert_manager_wamp_api).
-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

-export([handle_call/3]).



%% =============================================================================
%% API
%% =============================================================================



-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined)
    }
    | {reply, wamp_result() | wamp_error()}.


handle_call(?BONDY_CERT_RELOAD_CACERTS, #call{} = M, _Ctxt) ->
    ok = bondy_cert_manager:reload_cacerts(),
    R = bondy_wamp_message:result(M#call.request_id, #{}, []),
    {reply, R};

handle_call(?BONDY_CERT_ROTATE_ALL, #call{} = M, _Ctxt) ->
    ok = bondy_cert_manager:rotate_all_listeners(),
    R = bondy_wamp_message:result(M#call.request_id, #{}, []),
    {reply, R};

handle_call(?BONDY_CERT_ROTATE_LISTENER, #call{} = M, Ctxt) ->
    [Args] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    ListenerRef = binary_to_existing_atom(Args),
    case bondy_cert_manager:rotate_listener(ListenerRef) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, []),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:maybe_error({error, Reason}, M),
            {reply, E}
    end;

handle_call(?BONDY_CERT_GET_SERVER_CERT_INFO, #call{} = M, Ctxt) ->
    [Args] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    ListenerRef = binary_to_existing_atom(Args),
    E = bondy_wamp_api_utils:maybe_error(
        bondy_cert_manager:get_server_cert_info(ListenerRef), M
    ),
    {reply, E};

handle_call(?BONDY_CERT_SET_CLIENT_AUTH, #call{} = M, Ctxt) ->
    [ListenerBin, Opts] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    ListenerRef = binary_to_existing_atom(ListenerBin),
    MtlsOpts = decode_mtls_opts(Opts),
    case bondy_cert_manager:set_client_auth(ListenerRef, MtlsOpts) of
        ok ->
            R = bondy_wamp_message:result(M#call.request_id, #{}, []),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_api_utils:maybe_error({error, Reason}, M),
            {reply, E}
    end;

handle_call(?BONDY_CERT_GET_CLIENT_AUTH, #call{} = M, Ctxt) ->
    [Args] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    ListenerRef = binary_to_existing_atom(Args),
    E = bondy_wamp_api_utils:maybe_error(
        bondy_cert_manager:get_client_auth(ListenerRef), M
    ),
    {reply, E};

handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
decode_mtls_opts(Map) when is_map(Map) ->
    Opts0 = case maps:find(<<"verify">>, Map) of
        {ok, <<"verify_peer">>} -> #{verify => verify_peer};
        {ok, <<"verify_none">>} -> #{verify => verify_none};
        _ -> #{}
    end,
    Opts1 = case maps:find(<<"fail_if_no_peer_cert">>, Map) of
        {ok, true} -> Opts0#{fail_if_no_peer_cert => true};
        {ok, false} -> Opts0#{fail_if_no_peer_cert => false};
        _ -> Opts0
    end,
    case maps:find(<<"cacertfile">>, Map) of
        {ok, Path} when is_binary(Path) ->
            Opts1#{cacertfile => Path};
        _ ->
            Opts1
    end.
