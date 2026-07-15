%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_jepsen_http_counter).

-behaviour(cowboy_handler).

-include_lib("kernel/include/logger.hrl").

%% HTTP shim for the PN-Counter convergence workload.
%%
%%   GET  /counters/:table/:realm/:key
%%        → 200, body = the counter's current integer value (decimal),
%%          x-bondy-hlc + x-bondy-node headers
%%
%%   POST /counters/:table/:realm/:key
%%        body: value=<integer-delta>   → {inc, Delta}
%%        → 200 after the applier durably installs the increment
%%
%% Drives the native `pn_counter` CRDT via `bondy_db:counter_inc/4`
%% (a thin wrapper over `apply/4` with `{inc, Delta}`). `Delta` may be
%% negative, but the Jepsen `checker/counter` assumes monotonic adds, so
%% the workload generates positive increments and this handler just
%% forwards whatever it is given.

-export([init/2]).

-define(BODY_OPTS, #{length => 64_000}).

init(Req = #{method := <<"GET">>}, State) ->
    Reply = handle_get(Req),
    {ok, reply(Req, Reply), State};
init(Req0 = #{method := <<"POST">>}, State) ->
    {ok, KeyVals, Req1} =
        cowboy_req:read_urlencoded_body(Req0, ?BODY_OPTS),
    Reply = handle_post(Req1, KeyVals),
    {ok, reply(Req1, Reply), State};
init(Req0, State) ->
    {ok,
     cowboy_req:reply(405,
        #{<<"allow">> => <<"GET, POST">>}, <<>>, Req0),
     State}.

%% =============================================================================
%% GET — return the counter's integer value as a decimal string
%% =============================================================================

handle_get(Req) ->
    case bind_table(Req) of
        {table, Table} ->
            Realm = cowboy_req:binding(realm, Req),
            Key   = cowboy_req:binding(key,   Req),
            case bondy_db:read(Table, Realm, Key) of
                {ok, N, Hlc} when is_integer(N) ->
                    {ok, 200, hlc_headers(Hlc), integer_to_binary(N)};
                {ok, undefined, Hlc} ->
                    {ok, 200, hlc_headers(Hlc), <<"0">>};
                not_found ->
                    {ok, 200, [], <<"0">>};
                {error, _} = E ->
                    {error, E}
            end;
        Reply ->
            Reply
    end.

%% =============================================================================
%% POST — increment the counter by a (possibly negative) delta
%% =============================================================================

handle_post(Req, KeyVals) ->
    case bind_table(Req) of
        {table, Table} ->
            Realm = cowboy_req:binding(realm, Req),
            Key   = cowboy_req:binding(key,   Req),
            Delta = parse_int(
                proplists:get_value(<<"value">>, KeyVals, <<"0">>)
            ),
            Hlc = bondy_db:tick(Table),
            case bondy_db:counter_inc(Table, Realm, Key, Delta) of
                ok ->
                    {ok, 200, hlc_headers(Hlc), <<>>};
                {error, _} = E ->
                    {error, E}
            end;
        Reply ->
            Reply
    end.

%% =============================================================================
%% Helpers (shared shape with bondy_mst_jepsen_http_handler)
%% =============================================================================

parse_int(Bin) when is_binary(Bin) ->
    try binary_to_integer(Bin)
    catch error:badarg -> 0
    end.

bind_table(Req) ->
    TableBin = cowboy_req:binding(table, Req),
    case lists:keyfind(TableBin, 1, table_index()) of
        false        -> {ok, 404, [], <<"unknown-table">>};
        {_, Name}    ->
            case bondy_mst_jepsen_cluster:table(Name) of
                {ok, T} -> {table, T};
                error   -> {ok, 503, [], <<"table-unavailable">>}
            end
    end.

table_index() ->
    [{atom_to_binary(N, utf8), N}
     || N <- bondy_mst_jepsen_cluster:tables()].

hlc_headers(Hlc) when is_integer(Hlc) ->
    [{<<"x-bondy-hlc">>, integer_to_binary(Hlc)},
     {<<"x-bondy-node">>, atom_to_binary(node(), utf8)}].

reply(Req, {ok, Status, Headers, Body}) ->
    cowboy_req:reply(Status, headers_map(Headers), Body, Req);
reply(Req, {error, Reason}) ->
    ?LOG_WARNING(#{
        description => "jepsen counter http error",
        reason => Reason
    }),
    cowboy_req:reply(503, #{}, io_lib:format("error: ~p", [Reason]), Req).

headers_map(Headers) ->
    maps:from_list([
        {Name, to_value(V)} || {Name, V} <- Headers
    ]).

to_value(V) when is_binary(V) -> V;
to_value(V) when is_list(V)   -> iolist_to_binary(V);
to_value(V) when is_atom(V)   -> atom_to_binary(V, utf8).
