%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_proxy_protocol).
-moduledoc """
Resolves the source IP address of an HTTP request when Bondy sits behind a
proxy or load balancer, inspecting the `Forwarded`, `X-Real-IP` and
`X-Forwarded-For` headers in `strict` or `relaxed` mode.
""".
-include_lib("kernel/include/logger.hrl").
-include_lib("partisan/include/partisan_util.hrl").
-include("bondy.hrl").

-type t() :: #{
    enabled := boolean(),
    mode := strict | relaxed,
    proxy_info => #{
        local_address := inet:ip_address(),
        src_address := inet:ip_address() | undefined
    },
    error => any() | undefined
}.

-export([init/1]).
-export([enabled/1]).
-export([error/1]).
-export([has_error/1]).
-export([mode/1]).
-export([proxy_info/1]).
-export([source_ip/1]).

-ifdef(TEST).
-export([is_trusted_peer/2]).
-export([rightmost_untrusted/2]).
-export([trusted_proxies/1]).
-endif.

%% =============================================================================
%% API
%% =============================================================================

-spec init(cowboy_req:req()) -> t().

init(#{ref := Ref} = Req) ->
    {LocalIP, _Port} = cowboy_req:peer(Req),
    Opts = maps:from_list(bondy_config:get([Ref, proxy_protocol], [])),

    case maps:get(enabled, Opts, false) of
        true ->
            %% G-2: the `Forwarded`/`X-Real-IP`/`X-Forwarded-For` headers are
            %% client-supplied and trivially spoofable. Only honour them when the
            %% IMMEDIATE socket peer is a configured trusted proxy; otherwise the
            %% socket peer IS the source IP. With no `trusted_proxies` configured
            %% (the default) no peer is trusted, so a spoofed header can never
            %% move `source_ip` (which feeds `bondy_rbac_source` CIDR auth).
            case is_trusted_peer(LocalIP, Opts) of
                true ->
                    TrustedProxies = trusted_proxies(Opts),
                    case find_src_address(Req, TrustedProxies) of
                        {ok, SourceIP} ->
                            Opts#{
                                proxy_info => #{
                                    local_address => LocalIP,
                                    src_address => SourceIP
                                }
                            };
                        {error, Reason} ->
                            Opts#{
                                proxy_info => #{local_address => LocalIP},
                                error => Reason
                            }
                    end;
                false ->
                    maybe_log_untrusted_forwarded(Req, LocalIP),
                    Opts#{
                        proxy_info => #{
                            local_address => LocalIP,
                            src_address => LocalIP
                        }
                    }
            end;
        false ->
            Opts#{
                proxy_info => #{local_address => LocalIP}
            }
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

source_ip(#{enabled := true, mode := strict, error := Reason}) ->
    {error, {protocol_error, Reason}};
source_ip(#{enabled := true, mode := Mode, proxy_info := Info}) ->
    case Info of
        #{src_address := SourceIP} ->
            {ok, SourceIP};
        #{local_address := LocalIP} when Mode == relaxed ->
            {ok, LocalIP}
    end;
source_ip(#{enabled := false, proxy_info := #{local_address := LocalIP}}) ->
    {ok, LocalIP}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% We reach here only when the immediate socket peer is a trusted proxy, so
%% `TrustedProxies` is non-empty. The chain-based headers (`Forwarded`,
%% `X-Forwarded-For`) are resolved via `rightmost_untrusted/2`, which is robust
%% against a client PREPENDING spoofed hops. `X-Real-IP` is a single,
%% non-chainable value (whatever the proxy set) so it is tried LAST — only when
%% neither chain header yields an untrusted client.
find_src_address(Req, TrustedProxies) ->
    Funs = [
        fun(R) -> forwarded(R, TrustedProxies) end,
        fun(R) -> forwarded_for(R, TrustedProxies) end,
        fun real_ip/1
    ],
    first_ok(Req, Funs, not_found).

%% @private
first_ok(Req, [H | T], _LastReason) ->
    case H(Req) of
        {ok, _IP} = OK ->
            OK;
        {error, Reason} ->
            first_ok(Req, T, Reason)
    end;
first_ok(_Req, [], Reason) ->
    {error, Reason}.

%% @private
-spec real_ip(cowboy_req:req()) ->
    {ok, inet:ip_address()} | {error, any()}.

real_ip(Req) ->
    try
        case cowboy_req:header(<<"x-real-ip">>, Req, not_found) of
            not_found ->
                {error, not_found};
            Val ->
                case inet:parse_address(binary_to_list(Val)) of
                    {ok, Addr} ->
                        {ok, Addr};
                    {error, _} = Error ->
                        Error
                end
        end
    catch
        _:{request_error, {header, _}, Reason} ->
            {error, Reason}
    end.

%% @private
-spec forwarded_for(cowboy_req:req(), [bondy_cidr:t()]) ->
    {ok, inet:ip_address()} | {error, any()}.

forwarded_for(Req, TrustedProxies) ->
    try
        L = cowboy_req:parse_header(<<"x-forwarded-for">>, Req, []),
        rightmost_untrusted(L, TrustedProxies)
    catch
        _:{request_error, {header, _}, Reason} ->
            {error, Reason}
    end.

%% @private
-spec forwarded(cowboy_req:req(), [bondy_cidr:t()]) ->
    {ok, inet:ip_address()} | {error, any()}.

forwarded(Req, TrustedProxies) ->
    try
        case cowboy_req:header(<<"forwarded">>, Req, not_found) of
            not_found ->
                {error, not_found};
            Bin ->
                L = parse_forwarded(Bin),
                rightmost_untrusted(L, TrustedProxies)
        end
    catch
        _:{request_error, {header, _}, Reason} ->
            {error, Reason}
    end.

parse_forwarded(Bin) ->
    L = [
        parse_forwarded_element(string:trim(X))
     || X <- string:split(Bin, <<",">>, all)
    ],
    lists:flatten(L).

parse_forwarded_element(Bin) ->
    [
        parse_forwarded_pair(string:trim(X))
     || X <- string:split(Bin, <<";">>, all)
    ].

parse_forwarded_pair(<<"for", _/binary>> = Bin) ->
    [_, Value] = string:split(Bin, <<"=">>, all),
    parse_for(string:trim(Value, both, [$"]));
parse_forwarded_pair(_) ->
    %% We are only interested in the IP address
    [].

%% @private
parse_for(<<"[", Rest/binary>>) ->
    %% IPv6
    %% We remove "]" and any port number e.g. "]:9000"
    [IPAddr, _] = string:split(Rest, <<"]">>),
    IPAddr;
parse_for(Bin) ->
    %% IPv4
    [IPAddr | _] = string:split(Bin, <<":">>),
    IPAddr.

%% @private
%% G-2: is the immediate socket peer within a configured `trusted_proxies` CIDR?
%% Only then may client-supplied forwarding headers be believed. The address
%% families must agree so an IPv4 CIDR cannot accidentally match an IPv6 peer.
-spec is_trusted_peer(inet:ip_address(), map()) -> boolean().

is_trusted_peer(PeerIP, Opts) ->
    in_cidrs(PeerIP, trusted_proxies(Opts)).

%% @private
%% Is `IP` within any of `Cidrs`? Address families must agree so an IPv4 CIDR
%% cannot accidentally match an IPv6 address.
in_cidrs(IP, Cidrs) ->
    lists:any(
        fun({Addr, Mask} = Cidr) ->
            tuple_size(Addr) == tuple_size(IP) andalso
                bondy_cidr:match(Cidr, {IP, Mask})
        end,
        Cidrs
    ).

%% @private
%% G-2 refinement: pick the correct element of a forwarding CHAIN. Walk from the
%% RIGHT (the hop our trusted proxy vouched for) and return the first address NOT
%% in a trusted-proxy CIDR — the real client. Entries an attacker BEHIND the
%% trusted proxy could have PREPENDED sit to the left of the segment the trusted
%% proxies appended, so they are never selected.
rightmost_untrusted(Chain, TrustedProxies) ->
    do_rightmost_untrusted(lists:reverse(Chain), TrustedProxies).

%% @private
do_rightmost_untrusted([Bin | Rest], TrustedProxies) ->
    case inet:parse_address(binary_to_list(Bin)) of
        {ok, IP} ->
            case in_cidrs(IP, TrustedProxies) of
                true ->
                    %% A trusted hop — keep walking inward (leftward).
                    do_rightmost_untrusted(Rest, TrustedProxies);
                false ->
                    {ok, IP}
            end;
        {error, _} ->
            do_rightmost_untrusted(Rest, TrustedProxies)
    end;
do_rightmost_untrusted([], _TrustedProxies) ->
    {error, not_found}.

%% @private
%% Configured trusted-proxy CIDRs as `[bondy_cidr:t()]`. Accepts a pre-parsed
%% list (schema) or a comma-separated string, skipping entries that do not parse.
trusted_proxies(Opts) ->
    case maps:get(trusted_proxies, Opts, []) of
        L when is_list(L) ->
            case is_string_list(L) of
                true ->
                    parse_cidrs(
                        binary:split(iolist_to_binary(L), <<",">>, [global])
                    );
                false ->
                    parse_cidrs(L)
            end;
        Bin when is_binary(Bin) ->
            parse_cidrs(binary:split(Bin, <<",">>, [global]));
        _ ->
            []
    end.

%% @private
%% A cuttlefish `string` datatype yields a flat char list; distinguish it from a
%% list of CIDR tuples / binaries.
is_string_list([C | _]) when is_integer(C) -> true;
is_string_list(_) -> false.

%% @private
parse_cidrs(Items) ->
    lists:filtermap(fun to_cidr/1, Items).

%% @private
to_cidr({Addr, Mask} = Cidr) when is_tuple(Addr) andalso is_integer(Mask) ->
    {true, Cidr};
to_cidr(Item) when is_binary(Item) ->
    case string:trim(Item) of
        <<>> ->
            false;
        Trimmed ->
            try
                {true, bondy_cidr:parse(Trimmed)}
            catch
                _:_ -> false
            end
    end;
to_cidr(_) ->
    false.

%% @private
maybe_log_untrusted_forwarded(Req, PeerIP) ->
    HasForwarded =
        cowboy_req:header(<<"forwarded">>, Req, undefined) =/= undefined orelse
            cowboy_req:header(<<"x-forwarded-for">>, Req, undefined) =/=
                undefined orelse
            cowboy_req:header(<<"x-real-ip">>, Req, undefined) =/= undefined,

    HasForwarded andalso
        ?LOG_WARNING(#{
            description =>
                "Ignoring client-supplied forwarding headers from an untrusted "
                "peer (not in proxy_protocol.trusted_proxies); using the socket "
                "peer as the source IP.",
            peer_ip => PeerIP
        }),
    ok.
