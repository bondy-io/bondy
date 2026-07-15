%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_jepsen_http_set).

-behaviour(cowboy_handler).

-include_lib("kernel/include/logger.hrl").

%% HTTP shim for the set-convergence workload.
%%
%%   GET  /sets/:table/:realm/:key
%%        → 200, body = space-separated decimal members,
%%          x-bondy-hlc + x-bondy-node headers
%%
%%   POST /sets/:table/:realm/:key
%%        body: value=<binary>           → {add, Value}
%%        body: value=<binary>&op=rmv    → {rmv, Value}
%%        → 200 after the applier durably installs the op
%%
%% This drives the native operation-based set CRDTs — `aw_set`, `rw_set`,
%% `two_p_set`, `g_set` — selected per run via the cluster's
%% `crdt_module`. The op shape is the **pure** `{add, E}` / `{rmv, E}`:
%% no client-side dot and no HLC in the op. For the tier_2 add-/remove-
%% wins types the substrate stamps the cell's causal context into the
%% event meta at single-applier scope; the tier_0 `two_p_set` / `g_set`
%% need no context. (The legacy OR-set's client-minted `{add,Hlc,V,Dot}`
%% shape was retired with the `orset` fold.)

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
%% GET — return the live set members as a space-separated string
%% =============================================================================

handle_get(Req) ->
    case bind_table(Req) of
        {table, Table} ->
            Realm = cowboy_req:binding(realm, Req),
            Key   = cowboy_req:binding(key,   Req),
            case bondy_db:read(Table, Realm, Key) of
                {ok, Members, Hlc} when is_list(Members) ->
                    %% PR-2 step 2 (2026-05-21): `bondy_db:read/3` now
                    %% returns the **value** (orset → ordset of element
                    %% binaries), not the underlying fold state. Encode
                    %% as a space-separated list for the Jepsen client.
                    {ok, 200, hlc_headers(Hlc), encode_members(Members)};
                {ok, undefined, Hlc} ->
                    {ok, 200, hlc_headers(Hlc), <<>>};
                not_found ->
                    {ok, 200, [], <<>>};
                {error, _} = E ->
                    {error, E}
            end;
        Reply ->
            Reply
    end.

%% =============================================================================
%% POST — apply an {add, V} (default) or {rmv, V} to the set
%% =============================================================================

handle_post(Req, KeyVals) ->
    case bind_table(Req) of
        {table, Table} ->
            Realm = cowboy_req:binding(realm, Req),
            Key   = cowboy_req:binding(key,   Req),
            Value = proplists:get_value(<<"value">>, KeyVals, <<>>),
            Op    = set_op(KeyVals, Value),
            Hlc   = bondy_db:tick(Table),
            case bondy_db:apply(Table, Realm, Key, Op) of
                ok ->
                    %% PR-J4 audit: record (value -> hlc) on ack so a
                    %% lost Jepsen value can be traced back to its HLC
                    %% across the scraped node logs. Tier_2 ops carry no
                    %% client dot; the cell's stamped context is the
                    %% authoritative identity (visible in the MST dump).
                    TableBin = cowboy_req:binding(table, Req),
                    _ = bondy_mst_jepsen_audit:log_post_ack(
                        Value, Hlc, node(), 0, TableBin
                    ),
                    {ok, 200, hlc_headers(Hlc), <<>>};
                {error, _} = E ->
                    {error, E}
            end;
        Reply ->
            Reply
    end.

%% The pure set op: `op=rmv` removes, anything else (incl. absent) adds.
set_op(KeyVals, Value) ->
    case proplists:get_value(<<"op">>, KeyVals, <<"add">>) of
        <<"rmv">> -> {rmv, Value};
        _         -> {add, Value}
    end.

%% =============================================================================
%% Helpers (shared shape with bondy_mst_jepsen_http_handler)
%% =============================================================================

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

encode_members(Members) ->
    %% Space-separated members; same wire shape rakvstore's set workload
    %% uses, so a Clojure `(str/split ...)` recovers the set.
    case Members of
        [] -> <<>>;
        _  ->
            iolist_to_binary(
                lists:join(<<" ">>, lists:sort(Members))
            )
    end.

hlc_headers(Hlc) when is_integer(Hlc) ->
    [{<<"x-bondy-hlc">>, integer_to_binary(Hlc)},
     {<<"x-bondy-node">>, atom_to_binary(node(), utf8)}].

reply(Req, {ok, Status, Headers, Body}) ->
    cowboy_req:reply(Status, headers_map(Headers), Body, Req);
reply(Req, {error, Reason}) ->
    ?LOG_WARNING(#{
        description => "jepsen set http error",
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
