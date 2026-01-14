%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_http_gateway_utils).

-type state_fun() :: fun((any()) -> any()).
-export_type([state_fun/0]).


-export([location_uri/2]).
-export([set_resp_link_header/4]).
-export([set_resp_link_header/2]).


-spec location_uri(ID :: binary(), Req :: cowboy_req:req()) ->
    URI :: binary().
location_uri(ID, Req) ->
    Path = cowboy_req:path(Req),
    <<Path/binary, "/", ID/binary>>.



-spec set_resp_link_header(
        [{binary(), iodata(), iodata()}], Req :: cowboy_req:req()) ->
    NewReq :: cowboy_req:req().

set_resp_link_header([Link], Req) ->
    set_resp_link_header(resp_link_value(Link), Req);

set_resp_link_header(L, Req) ->
    Value = resp_link_values(L, []),
    cowboy_req:set_resp_header(<<"link">>, Value, Req).



-spec set_resp_link_header(
        binary(), iodata(), iodata(), Req :: cowboy_req:req()) ->
    NewReq :: cowboy_req:req().

set_resp_link_header(URI, Rel, Title, Req) ->
    Value = resp_link_value({URI, Rel, Title}),
    cowboy_req:set_resp_header(<<"link">>, Value, Req).


resp_link_values([], Acc) ->
    Acc;
resp_link_values([H | T], Acc0) ->
    Acc1 = [resp_link_value(H), $, | Acc0],
    resp_link_values(T, Acc1).


resp_link_value({URI, Rel, Title}) ->
    [
        $<, URI, $>, $;, $\s,
        "rel=", $", Rel, $", $;, $\s,
        "title=", $", Title, $"
    ].




