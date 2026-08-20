%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_tcp_proxy_protocol).
-moduledoc """
Handles the PROXY protocol for a Ranch listener.

Reads the PROXY protocol header on a connection (when enabled) and resolves the
effective source IP according to the configured `strict` or `relaxed` mode,
falling back to the local IP when permitted.
""".
-include_lib("partisan/include/partisan_util.hrl").
-include("bondy.hrl").

-type t() :: #{
    enabled := boolean(),
    mode := strict | relaxed,
    proxy_info => ranch_proxy_header:proxy_info() | undefined,
    error => any() | undefined
}.

-export_type([t/0]).

-export([init/1]).
-export([init/2]).
-export([enabled/1]).
-export([error/1]).
-export([has_error/1]).
-export([mode/1]).
-export([proxy_info/1]).
-export([source_ip/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec init(atom()) -> t().

init(Ref) ->
    init(Ref, 15_000).

-spec init(atom(), timeout()) -> t().

init(Ref, Timeout) ->
    %% `enabled` AND `mode` are defaulted into the map, not merely read with a
    %% default below: every `source_ip/2` clause matches on one or both —
    %% including the invalid-input clause, which requires `mode` — so a map
    %% missing either makes `source_ip/2`, called on every accepted connection,
    %% fail with `function_clause` naming no listener.
    %%
    %% Both gaps are reachable, because `listeners.$name.proxy_protocol` and
    %% `listeners.$name.proxy_protocol.mode` are two independent default-free
    %% mappings. A listener needs no option block at all
    %% (`bondy_config:listener_transport_opts/2` supplies ranch's), which leaves
    %% `enabled` absent; and one that sets only `proxy_protocol = on` yields
    %% `[{enabled, true}]`, which leaves `mode` absent. Verified directly:
    %% `source_ip/2` on the map `init/2` builds for the latter matches none of
    %% its five clauses.
    %%
    %% `relaxed` is the value all eight legacy `*.proxy_protocol.mode` mappings
    %% already carry as their schema default, so a legacy deployment is
    %% unaffected — its own value wins this merge.
    Opts = maps:merge(
        #{enabled => false, mode => relaxed},
        maps:from_list(bondy_config:get([Ref, proxy_protocol], []))
    ),

    %% No default here: the merge above always supplies `enabled`, so a default
    %% would be unreachable and would quietly restore the `function_clause` in
    %% `source_ip/2` if the merge were ever removed.
    case maps:get(enabled, Opts) of
        true ->
            case ranch:recv_proxy_header(Ref, Timeout) of
                {ok, ProxyInfo} ->
                    Opts#{proxy_info => ProxyInfo};
                {error, Reason} ->
                    Opts#{error => {socket_error, Reason}};
                {error, protocol_error, Reason} ->
                    Opts#{error => {protocol_error, Reason}}
            end;
        false ->
            Opts
    end.

enabled(#{enabled := Val}) ->
    Val.

mode(#{mode := Val}) ->
    Val.

proxy_info(#{proxy_info := Val}) ->
    Val;
proxy_info(_) ->
    undefined.

error(#{error := Val}) ->
    Val;
error(_) ->
    undefined.

has_error(#{error := _}) -> true;
has_error(#{}) -> false.

source_ip(#{enabled := true, mode := relaxed, error := _}, LocalIP) when
    ?IS_IP(LocalIP)
->
    {ok, LocalIP};
source_ip(#{enabled := true, mode := strict, error := Reason}, LocalIP) when
    ?IS_IP(LocalIP)
->
    {error, Reason};
source_ip(#{enabled := true, mode := Mode, proxy_info := Info}, LocalIP) when
    ?IS_IP(LocalIP)
->
    case Info of
        #{command := local} ->
            {ok, LocalIP};
        #{command := proxy, src_address := SourceIP} ->
            {ok, SourceIP};
        #{command := proxy} when Mode == relaxed ->
            {ok, LocalIP};
        #{command := proxy} when Mode == strict ->
            {error, {protocol_error, <<"Missing src_address field">>}}
    end;
source_ip(#{enabled := false}, LocalIP) when ?IS_IP(LocalIP) ->
    {ok, LocalIP};
source_ip(#{enabled := _, mode := _} = T, LocalIP) ->
    ?ERROR(badarg, [T, LocalIP], #{1 => "should be a valid IP address"}).
