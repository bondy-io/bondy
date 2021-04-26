%% =============================================================================
%%  bondy_rest_gateway_utils.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_rest_gateway_utils).

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




