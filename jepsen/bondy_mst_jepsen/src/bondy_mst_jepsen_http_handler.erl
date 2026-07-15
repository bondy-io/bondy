%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_jepsen_http_handler).

-behaviour(cowboy_handler).

-include_lib("kernel/include/logger.hrl").

-export([init/2]).

-define(BODY_OPTS, #{length => 64_000}).

init(Req0 = #{method := <<"GET">>}, State) ->
    Reply = handle_get(Req0),
    {ok, reply(Req0, Reply), State};
init(Req0 = #{method := <<"PUT">>}, State) ->
    {ok, KeyVals, Req1} =
        cowboy_req:read_urlencoded_body(Req0, ?BODY_OPTS),
    Reply = handle_put(Req1, KeyVals),
    {ok, reply(Req1, Reply), State};
init(Req0, State) ->
    {ok,
     cowboy_req:reply(405,
        #{<<"allow">> => <<"GET, PUT">>}, <<>>, Req0),
     State}.

%% =============================================================================
%% GET
%% =============================================================================

handle_get(Req) ->
    case bind_table(Req) of
        {table, Table} ->
            Realm = cowboy_req:binding(realm, Req),
            Key   = cowboy_req:binding(key,   Req),
            case bondy_db:read(Table, Realm, Key) of
                %% PR-2 step 2 (2026-05-21): `bondy_db:read/3` now
                %% returns the **value** via the fold's `to_value/1`,
                %% not the underlying state. For `lww_register` that
                %% is `binary() | undefined`.
                {ok, Value, Hlc} when is_binary(Value) ->
                    {ok, 200, hlc_headers(Hlc), Value};
                {ok, undefined, Hlc} ->
                    {ok, 200, hlc_headers(Hlc), <<>>};
                not_found ->
                    {ok, 404, [], <<"undefined">>};
                {error, _} = E ->
                    {error, E}
            end;
        Reply ->
            Reply
    end.

%% =============================================================================
%% PUT
%% =============================================================================

handle_put(Req, KeyVals) ->
    case bind_table(Req) of
        {table, Table} ->
            Realm = cowboy_req:binding(realm, Req),
            Key   = cowboy_req:binding(key,   Req),
            Value = proplists:get_value(<<"value">>, KeyVals, <<>>),
            case proplists:get_value(<<"expected">>, KeyVals, not_present) of
                not_present ->
                    do_set(Table, Realm, Key, Value);
                Expected ->
                    do_cas(Table, Realm, Key, Expected, Value)
            end;
        Reply ->
            Reply
    end.

do_set(Table, Realm, Key, Value) ->
    Hlc = bondy_db:tick(Table),
    case bondy_db:apply(Table, Realm, Key, {set, Hlc, Value}) of
        ok            -> {ok, 200, hlc_headers(Hlc), <<>>};
        {error, _} = E -> {error, E}
    end.

do_cas(Table, Realm, Key, Expected, New) ->
    %% CAS over a CRDT register: read the current value, compare, then
    %% conditionally apply. This is a best-effort CAS — concurrent
    %% writers may see the same `Expected` and both succeed; the
    %% Jepsen `cas-register` checker is the authoritative judge of
    %% whether the resulting history is linearizable.
    Current =
        case bondy_db:read(Table, Realm, Key) of
            %% PR-2 step 2: `bondy_db:read/3` returns the fold's value
            %% (`binary() | undefined` for `lww_register`).
            {ok, V, _} when is_binary(V) -> V;
            {ok, undefined, _}           -> <<>>;
            not_found                    -> <<>>;
            {error, _} = ReadErr         -> ReadErr
        end,
    case Current of
        {error, _} = E ->
            {error, E};
        Expected ->
            Hlc = bondy_db:tick(Table),
            case bondy_db:apply(Table, Realm, Key, {set, Hlc, New}) of
                ok ->
                    {ok, 200, hlc_headers(Hlc), <<>>};
                {error, _} = E ->
                    {error, E}
            end;
        _Other ->
            %% Mismatch → 409, same as ra-kv-store. Java client maps
            %% this onto `cas-failure`.
            {ok, 409, [], <<"cas-mismatch">>}
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

bind_table(Req) ->
    TableBin = cowboy_req:binding(table, Req),
    %% Defensive: only allow table atoms that bondy_mst_jepsen_cluster
    %% knows about. This avoids creating arbitrary atoms from
    %% untrusted input.
    case lists:keyfind(TableBin, 1, table_index()) of
        false        -> {ok, 404, [], <<"unknown-table">>};
        {_, Name}    ->
            case bondy_mst_jepsen_cluster:table(Name) of
                {ok, T} -> {table, T};
                error   -> {ok, 503, [], <<"table-unavailable">>}
            end
    end.

%% Build a `{binary(), atom()}` index from the known table list once
%% per call. Cheap; the list has 10 entries.
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
        description => "jepsen http error",
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
