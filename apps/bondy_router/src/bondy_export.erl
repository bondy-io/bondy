%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_export).
-moduledoc """
A `gen_server` that exports and imports the Bondy database, running the work
asynchronously and writing to (or reading from) a `disk_log` file while
tracking progress and emitting lifecycle events.

This is a logical **export/import** of the durable `bondy_db` `main` tables
(security, realms, gateway specs, tokens, tickets, bridges, retained
messages) — not a byte-level backup. Each entry is dumped as a logical
`{entry, Table, Band, Key, Value}` tuple (the fold-decoded domain term) and
re-applied on import via `bondy_db:apply(Table, Band, Key, {set, Value})`.
Storage-level metadata (HLCs, CRDT lineage) is intentionally **not** preserved
— an import is a set of fresh writes, which is the correct semantics for moving
data between nodes / deployments.

Enumeration is domain-agnostic: every main table is listed over the band set
`[<<>> | RealmURIs]`. Per-realm tables (users, groups, grants, sources,
tickets, tokens, retained messages) hold their entries under each realm's URI
band; the global-band tables (realms, API gateway specs, bridges) hold theirs
under the constant `<<>>` band. The two never overlap, so the union covers
every table without per-table knowledge. The ephemeral `registry` (routing)
tables are not exported.

## Backwards compatibility

Import detects the file header. Files written by this module carry
`format => bondy_db_export`, `vsn => "2.0.0"`. The legacy `plum_db`-format
backups produced by the former `bondy_backup` module (`format => dvvset_log`,
`vsn =< "1.2.0"`) are translated on the fly: each legacy record
`{{{Prefix, Sub}, Key}, Object}` is resolved from its `dvvset` (last-writer-wins
by the stored modification timestamp; tombstones are skipped) and reshaped into
the current `bondy_db` `{Table, Band, Key, Value}` layout.

The translated domains are the durable identity / RBAC model, the API gateway
specs, and OAuth refresh tokens: `security_users` and `security_groups` (upgraded
via each module's `from_term/1`), `security_{user,group}_grants` and
`security_sources` (re-keyed through the live `encode_key/1`), `api_gateway`
specs (global band), and `oauth2_refresh_tokens` — the latest non-expired refresh
token per `(realm, user)` is reconstructed into the current per-subject token set
plus a pointer from the bare legacy token string, so the first refresh that
presents it resolves and transparently upgrades the client to the current token
format (see `bondy_oauth_token:import_legacy/1`); expired tokens are dropped.

The following are intentionally **skipped** (counted by reason, never
mis-written):

- **realms** — the legacy `#realm{}` record has no upgrade path and carries
  security material best managed by configuration; recreate realms from config.
  The per-realm *data* (users, groups, grants, sources, tokens) still imports,
  because it is banded by the realm URI, independent of the realm record.
- **`security_status`** — dead; the live flag is the realm's `security_enabled`.

The administrative WAMP procedures are `bondy.export.create`,
`bondy.export.status` and `bondy.export.import`; the former `bondy.backup.*`
procedures are kept as deprecated aliases.
""".
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include("bondy.hrl").
-include("bondy_db_tables.hrl").

%% The current (bondy_db) export file format + version.
-define(EXPORT_FORMAT, bondy_db_export).
-define(EXPORT_VSN, <<"2.0.0">>).
%% The legacy plum_db backup format written by the former bondy_backup module.
-define(LEGACY_FORMAT, dvvset_log).
%% Import write-batch size: tier_0 (lww) entries are buffered and flushed via
%% `bondy_db:apply_many/1` (one atomic WAL frame — one fsync — per shard per
%% flush) instead of one fsync'd `apply/4` per entry. Tier_2 (ew/mv/aw) entries
%% can't ride a shared frame and are applied individually.
-define(IMPORT_BATCH, 500).

-define(EXPORT_SPEC, #{
    <<"path">> => #{
        alias => path,
        key => path,
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (X) when is_list(X) ->
                {ok, X};
            (X) when is_binary(X) ->
                {ok, unicode:characters_to_list(X)};
            (_) ->
                false
        end
    }
}).

-define(IMPORT_SPEC, #{
    <<"filename">> => #{
        alias => filename,
        key => filename,
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (X) when is_list(X) ->
                {ok, X};
            (X) when is_binary(X) ->
                {ok, unicode:characters_to_list(X)};
            (_) ->
                false
        end
    }
}).

-define(STATUS_SPEC, #{
    <<"filename">> => #{
        alias => filename,
        key => filename,
        required => false,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (X) when is_list(X) ->
                {ok, X};
            (X) when is_binary(X) ->
                {ok, unicode:characters_to_list(X)};
            (_) ->
                false
        end
    }
}).

-record(state, {
    status :: status(),
    timestamp :: non_neg_integer(),
    pid :: pid() | undefined,
    filename :: file:filename() | undefined
}).

-type status() :: export_in_progress | import_in_progress | undefined.
-type info() :: #{
    filename => file:filename(),
    timestamp => non_neg_integer()
}.

%% API
-export([export/1]).
-export([import/1]).
-export([status/0]).
-export([status/1]).
-export([start_link/0]).
%% Exported for testing the legacy-format translation without a running import.
-export([legacy_translate/4]).
-export([resolve_object/1]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).

%% =============================================================================
%% API
%% =============================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Exports the database to a `disk_log` file in the directory indicated by `path`.
""".
-spec export(file:filename_all() | map()) ->
    {ok, info()} | {error, term()}.

export(Map0) when is_map(Map0) ->
    try maps_utils:validate(Map0, ?EXPORT_SPEC) of
        Map1 ->
            gen_server:call(?MODULE, {export, Map1})
    catch
        error:Reason ->
            {error, Reason}
    end;
export(Path) ->
    export(#{path => Path}).

status() ->
    status(#{}).

-spec status(file:filename_all() | map()) ->
    undefined | {status(), non_neg_integer()} | {error, unknown}.

status(Map0) when is_map(Map0) ->
    try maps_utils:validate(Map0, ?STATUS_SPEC) of
        Map1 ->
            gen_server:call(?MODULE, {status, Map1})
    catch
        error:Reason ->
            {error, Reason}
    end;
status(Filename) ->
    status(#{filename => Filename}).

-doc """
Imports an export file (or a legacy `bondy_backup` file).
""".
-spec import(file:filename_all() | map()) -> {ok, info()} | {error, term()}.

import(Map0) when is_map(Map0) ->
    try maps_utils:validate(Map0, ?IMPORT_SPEC) of
        Map1 ->
            gen_server:call(?MODULE, {import, Map1})
    catch
        error:Reason ->
            {error, Reason}
    end;
import(Filename) ->
    import(#{filename => Filename}).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    {ok, #state{}}.

handle_call({export, Map}, _From, #state{status = undefined} = State0) ->
    {ok, State1} = async_export(Map, State0),
    Reply = #{
        filename => unicode:characters_to_binary(State1#state.filename),
        timestamp => State1#state.timestamp
    },
    {reply, {ok, Reply}, State1};
handle_call({export, _}, _From, State) ->
    {reply, {error, State#state.status}, State};
handle_call({import, Map}, _From, #state{status = undefined} = State0) ->
    {ok, State1} = async_import(Map, State0),
    Reply = #{
        filename => unicode:characters_to_binary(State1#state.filename),
        timestamp => State1#state.timestamp
    },
    {reply, {ok, Reply}, State1};
handle_call({import, _}, _From, State) ->
    {reply, {error, State#state.status}, State};
handle_call({status, Map}, _From, State) when map_size(Map) =:= 0 ->
    {reply, {ok, State#state.status}, State};
handle_call(
    {status, #{filename := Filename}},
    _From,
    #state{filename = Filename} = State
) ->
    Reply =
        case State#state.status of
            undefined ->
                read_head(Filename);
            Status ->
                Secs = erlang:system_time(second) - State#state.timestamp,
                {ok, #{status => Status, elapsed_time_secs => Secs}}
        end,
    {reply, Reply, State};
handle_call({status, #{filename := Filename}}, _From, State) ->
    {reply, read_head(Filename), State};
handle_call(_, _, State) ->
    {reply, ok, State}.

handle_cast(_Event, State) ->
    {noreply, State}.

handle_info({export_reply, ok, Pid}, #state{pid = Pid} = State) ->
    Secs = erlang:system_time(second) - State#state.timestamp,
    ok = notify_export_finished([State#state.filename, Secs]),
    {noreply, State#state{status = undefined, pid = undefined}};
handle_info({export_reply, {error, Reason}, Pid}, #state{pid = Pid} = State) ->
    Secs = erlang:system_time(second) - State#state.timestamp,
    ok = notify_export_error([Reason, State#state.filename, Secs]),
    {noreply, State#state{status = undefined, pid = undefined}};
handle_info({import_reply, {ok, Counters}, Pid}, #state{pid = Pid} = State) ->
    #{read_count := N, written_count := M} = Counters,
    Secs = erlang:system_time(second) - State#state.timestamp,
    _ =
        case maps:get(skipped, Counters, #{}) of
            Skipped when map_size(Skipped) > 0 ->
                ?LOG_NOTICE(#{
                    description =>
                        "Import skipped some legacy records by reason",
                    filename => State#state.filename,
                    skipped => Skipped
                });
            _ ->
                ok
        end,
    ok = notify_import_finished([State#state.filename, Secs, N, M]),
    {noreply, State#state{status = undefined, pid = undefined}};
handle_info({import_reply, {error, Reason}, Pid}, #state{pid = Pid} = State) ->
    Secs = erlang:system_time(second) - State#state.timestamp,
    ok = notify_import_error([State#state.filename, Reason, Secs]),
    {noreply, State#state{status = undefined, pid = undefined}};
handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        description => "Unexpected event received",
        event => Info
    }),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE: EXPORT
%% =============================================================================

%% @private
async_export(#{path := Path}, State0) ->
    Ts = erlang:system_time(second),
    Filename = "bondy_export." ++ integer_to_list(Ts) ++ ".bondy",
    File = filename:join([Path, Filename]),
    Me = self(),
    Pid = spawn_link(fun() ->
        case do_export(File, Ts) of
            ok ->
                Me ! {export_reply, ok, self()};
            {error, _} = Error ->
                Me ! {export_reply, Error, self()}
        end
    end),
    State1 = State0#state{
        filename = File,
        pid = Pid,
        timestamp = Ts,
        status = export_in_progress
    },
    {ok, State1}.

%% @private
do_export(File, Ts) ->
    Opts = [
        {name, log},
        {file, File},
        {type, halt},
        {size, infinity},
        {head, #{
            format => ?EXPORT_FORMAT,
            mod => ?MODULE,
            mod_vsn => mod_vsn(),
            node => erlang:node(),
            timestamp => Ts,
            vsn => ?EXPORT_VSN
        }}
    ],

    case disk_log:open(Opts) of
        {ok, Log} ->
            _ = notify_export_started(File),
            build_export(Log);
        {error, _} = Error ->
            Error
    end.

%% @private
mod_vsn() ->
    {vsn, Vsn} = lists:keyfind(vsn, 1, ?MODULE:module_info(attributes)),
    Vsn.

%% @private
build_export(Log) ->
    Bands = [<<>> | realm_uris()],
    Tables = main_table_names(),
    try
        Acc = lists:foldl(
            fun(Name, Acc0) -> export_table(Name, Bands, Log, Acc0) end,
            [],
            Tables
        ),
        %% Flush the remaining buffered entries.
        log(Acc, Log)
    catch
        throw:Reason ->
            {error, Reason}
    after
        disk_log:close(Log)
    end.

%% @private
%% Exports one main table over every band, buffering entries and flushing in
%% 500-entry batches (via `maybe_log/2`). Tables that are declared but not
%% provisioned on this node (handle `undefined`) are skipped.
export_table(Name, Bands, Log, Acc0) ->
    case bondy_namespace_catalog:table(Name) of
        undefined ->
            Acc0;
        Table ->
            lists:foldl(
                fun(Band, Acc1) ->
                    export_band(Name, Table, Band, Log, Acc1)
                end,
                Acc0,
                Bands
            )
    end.

%% @private
export_band(Name, Table, Band, Log, Acc0) ->
    case bondy_db:list(Table, Band) of
        {ok, Rows} ->
            lists:foldl(
                fun({Key, Value, _Hlc}, Acc) ->
                    maybe_log([{entry, Name, Band, Key, Value} | Acc], Log)
                end,
                Acc0,
                Rows
            );
        {error, Reason} ->
            throw(Reason)
    end.

%% @private
%% The durable database's table names, in declaration order (realms first,
%% so they are imported before per-realm data). Delegates to the catalogue
%% rather than filtering `tables()` by a literal db-name atom, so a future
%% rename of the durable database touches one definition, not every caller.
main_table_names() ->
    bondy_namespace_catalog:table_names(bondy_namespace_catalog:main_db_name()).

%% @private
%% The URIs of all realms; drives per-realm table enumeration.
realm_uris() ->
    [
        Uri
     || R <- bondy_realm:list(), (Uri = bondy_realm:uri(R)) =/= undefined
    ].

%% @private
maybe_log(Acc, Log) when length(Acc) =:= 500 ->
    ok = log(Acc, Log),
    [];
maybe_log(Acc, _) ->
    Acc.

%% @private
log([], _) ->
    ok;
log(L, Log) ->
    ok = maybe_throw(disk_log:log_terms(Log, L)),
    maybe_throw(disk_log:sync(Log)).

%% @private
maybe_throw(ok) -> ok;
maybe_throw({error, Reason}) -> throw(Reason).

%% =============================================================================
%% PRIVATE: IMPORT
%% =============================================================================

%% @private
async_import(#{filename := Filename}, State0) ->
    Ts = erlang:system_time(second),
    Me = self(),
    Pid = spawn_link(fun() ->
        case do_import(Filename) of
            {ok, _Counters} = OK ->
                Me ! {import_reply, OK, self()};
            {error, _} = Error ->
                Me ! {import_reply, Error, self()}
        end
    end),
    State1 = State0#state{
        filename = Filename,
        pid = Pid,
        timestamp = Ts,
        status = import_in_progress
    },
    {ok, State1}.

%% @private
do_import(Filename) ->
    Opts = [
        {name, log},
        {mode, read_only},
        {file, Filename}
    ],
    case disk_log:open(Opts) of
        {ok, Log} ->
            ok = notify_import_started([Filename, 0, 0]),
            do_import_aux(Log);
        {repaired, Log, {recovered, Rec}, {badbytes, Bad}} ->
            ok = notify_import_started([Filename, Rec, Bad]),
            do_import_aux(Log);
        {error, _} = Error ->
            Error
    end.

%% @private
do_import_aux(Log) ->
    try
        Counters0 = #{
            read_count => 0, written_count => 0, writes => [], writes_n => 0
        },
        import_chunk(
            {head, disk_log:chunk(Log, start)}, undefined, Log, Counters0
        )
    catch
        _:Reason ->
            {error, Reason}
    after
        _ = disk_log:close(Log)
    end.

%% @private
import_chunk(eof, Mode, Log, Counters0) ->
    Counters1 = flush_writes(Counters0),
    Counters = maybe_flush_tokens(Mode, Counters1),
    ok = disk_log:close(Log),
    {ok, Counters};
import_chunk({error, _} = Error, _, Log, _) ->
    _ = disk_log:close(Log),
    Error;
import_chunk({head, {Cont, [H | T]}}, undefined, Log, Counters) ->
    Mode = import_mode(H),
    import_chunk({Cont, T}, Mode, Log, Counters);
import_chunk({Cont, Terms}, Mode, Log, Counters0) ->
    try
        {ok, Counters} = import_terms(Terms, Mode, Counters0),
        import_chunk(disk_log:chunk(Log, Cont), Mode, Log, Counters)
    catch
        _:Reason ->
            {error, Reason}
    end.

%% @private
%% Determines the import mode from the file header: the current bondy_db export
%% format, or the legacy plum_db backup format (with its version, for the
%% < 1.2.0 prefix renames).
import_mode(#{format := ?EXPORT_FORMAT, vsn := Vsn}) when Vsn >= ?EXPORT_VSN ->
    new;
import_mode(#{format := ?LEGACY_FORMAT, vsn := Vsn}) ->
    %% Old plum_db-format backup: translate each record on the fly (see the
    %% moduledoc and `legacy_translate/4`).
    {legacy, Vsn};
import_mode(H) ->
    throw({invalid_header, H}).

%% @private
%% New (bondy_db) format: each entry is a logical `{entry, Table, Band, Key,
%% Value}`, re-applied as a fresh `{set, Value}`.
import_terms([], _Mode, Counters) ->
    {ok, Counters};
import_terms([Term | T], {legacy, _} = Mode, Counters) ->
    import_terms(T, Mode, import_legacy(Term, Counters));
import_terms([{entry, Name, Band, Key, Value} | T], new, Counters) ->
    import_terms(T, new, apply_entry(Name, Band, Key, Value, Counters));
import_terms([_Other | T], new, #{read_count := N} = Counters) ->
    %% Unknown term (e.g. a stray header) — count as read, skip.
    import_terms(T, new, Counters#{read_count => N + 1}).

%% @private
%% Applies one logical entry to bondy_db. Tables declared but not provisioned on
%% this node are skipped (counted as read only).
apply_entry(Name, Band, Key, Value, #{read_count := N} = C) ->
    C1 = C#{read_count => N + 1},
    case bondy_namespace_catalog:table(Name) of
        undefined ->
            C1;
        Table ->
            import_entry(Name, Table, Band, Key, Value, C1)
    end.

%% @private
%% Most tables re-apply as a plain `{set, Value}`. Realm key material is special:
%% it lives in its own aw-map `bondy_realm_keys` cell, NOT in the realm identity
%% cell (see `bondy_realm`).
%%
%% - `bondy_realm` — split the imported realm value into a key-stripped identity
%%   (`{set, Identity}`) plus key entries routed to `bondy_realm_keys`. A
%%   post-split backup's record is already stripped (no key entries; the keys
%%   arrive via their own `bondy_realm_keys` entries); a pre-split backup carries
%%   the keys in the record, which are extracted here.
%% - `bondy_realm_keys` — exported as a materialized aw-map; an aw-map cannot be
%%   `{set}`, so re-apply each kid as a `{put, Kid, Bundle}` op.
import_entry(?BONDY_DB_REALM_TAB, Table, Band, Key, Value, C) ->
    {Identity, KeyEntries} = bondy_realm:split_for_import(Value),
    C1 = buffer_write(Table, Band, Key, {set, Identity}, C),
    put_realm_keys(Band, Key, KeyEntries, C1);
import_entry(?BONDY_DB_REALM_KEYS_TAB, Table, Band, Key, Value, C) ->
    put_realm_keys_into(
        Table, Band, Key, bondy_realm:keys_value_to_entries(Value), C
    );
import_entry(_Name, Table, Band, Key, Value, C) ->
    buffer_write(Table, Band, Key, {set, Value}, C).

%% @private
put_realm_keys(_Band, _Key, [], C) ->
    C;
put_realm_keys(Band, Key, Entries, C) ->
    case bondy_namespace_catalog:table(?BONDY_DB_REALM_KEYS_TAB) of
        undefined -> C;
        Table -> put_realm_keys_into(Table, Band, Key, Entries, C)
    end.

%% @private
put_realm_keys_into(Table, Band, Key, Entries, C) ->
    lists:foldl(
        fun({Kid, Bundle}, Acc) ->
            buffer_write(Table, Band, Key, {put, Kid, Bundle}, Acc)
        end,
        C,
        Entries
    ).

%% =============================================================================
%% PRIVATE: LEGACY (plum_db / bondy_backup) IMPORT
%% =============================================================================

%% @private
%% Translates and applies one legacy `{{{Prefix, Sub}, Key}, Object}` record.
%% Every record counts as read; an applied record additionally bumps
%% `written_count`; everything else is tallied under `skipped` by reason.
import_legacy(Term, C0) ->
    C = bump(read_count, C0),
    do_import_legacy(Term, C).

%% @private
do_import_legacy({{{Prefix, Sub}, Key}, {object, _} = Object}, C) ->
    try resolve_object(Object) of
        deleted ->
            skip(tombstone, C);
        {ok, Payload} ->
            case legacy_translate(Prefix, Sub, Key, Payload) of
                {entry, Table, Band, Key1, Value1} ->
                    apply_legacy(Table, Band, Key1, Value1, C);
                {oauth_token, AuthRealm, AuthId, IssuedAt, ExpiresIn, Spec} ->
                    accumulate_token(
                        AuthRealm, AuthId, IssuedAt, ExpiresIn, Spec, C
                    );
                {skip, Reason} ->
                    skip(Reason, C)
            end
    catch
        _:_ ->
            skip(translate_error, C)
    end;
do_import_legacy(_Other, C) ->
    skip(unrecognised_term, C).

%% @private
split_oauth_sub(Sub) ->
    %% The legacy oauth sub-prefix is `<<"Realm,Issuer">>`; the realm URI is
    %% comma-free, so the first comma separates the two.
    case binary:split(Sub, <<",">>) of
        [AuthRealm, ClientId] -> {AuthRealm, ClientId};
        [AuthRealm] -> {AuthRealm, all}
    end.

%% @private
%% Keeps the latest non-expired legacy refresh token per (realm, user) in the
%% `tokens` accumulator. They are materialised at end of import (`flush_tokens/1`)
%% rather than per-record, so each subject ends with a single current token.
accumulate_token(AuthRealm, AuthId, IssuedAt, ExpiresIn, Spec, C) ->
    case IssuedAt + ExpiresIn =< erlang:system_time(second) of
        true ->
            skip(token_expired, C);
        false ->
            Tokens = maps:get(tokens, C, #{}),
            MapKey = {AuthRealm, AuthId},
            case maps:get(MapKey, Tokens, undefined) of
                {Prev, _} when Prev >= IssuedAt ->
                    C;
                _ ->
                    C#{tokens => Tokens#{MapKey => {IssuedAt, Spec}}}
            end
    end.

%% @private
maybe_flush_tokens({legacy, _}, C) ->
    flush_tokens(C);
maybe_flush_tokens(_Mode, C) ->
    C.

%% @private
%% Materialises the accumulated latest-per-user tokens via bondy_oauth_token
%% (which builds the current token + the legacy-string pointer). Drops the
%% internal accumulator from the counters before returning.
flush_tokens(#{tokens := Tokens} = C0) ->
    C = maps:remove(tokens, C0),
    maps:fold(
        fun(_MapKey, {_IssuedAt, Spec}, Acc) ->
            case bondy_oauth_token:import_legacy(Spec) of
                ok ->
                    bump(written_count, Acc);
                {error, Reason} ->
                    skip({token_import, Reason}, Acc)
            end
        end,
        C,
        Tokens
    );
flush_tokens(C) ->
    C.

%% @private
apply_legacy(Table, Band, Key, Value, C) ->
    case bondy_namespace_catalog:table(Table) of
        undefined ->
            skip({table_not_provisioned, Table}, C);
        Handle ->
            buffer_write(Handle, Band, Key, {set, Value}, C)
    end.

%% @private
%% Buffer one write for batched application, or apply it inline when the table
%% can't ride a shared WAL frame. tier_0 (lww) entries accumulate and flush via
%% `bondy_db:apply_many/1` — one fsync per shard per `?IMPORT_BATCH`-sized flush
%% rather than one fsync per entry, which is the difference between an import
%% taking minutes and seconds. tier_2 (ew/mv/aw) cells stamp a per-cell causal
%% context that `apply_many/1` refuses, so they are applied individually.
buffer_write(Handle, Band, Key, Event, C) ->
    case maps:get(causal_tier, Handle, tier_0) of
        tier_2 ->
            ok = bondy_db:apply(Handle, Band, Key, Event),
            bump(written_count, C);
        _ ->
            Buf = [{Handle, Band, Key, Event} | maps:get(writes, C, [])],
            N = maps:get(writes_n, C, 0) + 1,
            C1 = C#{writes => Buf, writes_n => N},
            case N >= ?IMPORT_BATCH of
                true -> flush_writes(C1);
                false -> C1
            end
    end.

%% @private
%% Apply the buffered tier_0 writes as one `apply_many/1` (grouped into one
%% atomic WAL frame per shard) and credit them to `written_count`.
flush_writes(#{writes := Buf, writes_n := N} = C) when Buf =/= [] ->
    ok = bondy_db:apply_many(lists:reverse(Buf)),
    C#{
        writes => [],
        writes_n => 0,
        written_count => maps:get(written_count, C, 0) + N
    };
flush_writes(C) ->
    C.

-doc """
Resolves a legacy plum_db object (a `dvvset`) to its live payload, unwrapping the
`{Value, ModifiedTimestamp}` storage wrapper the former `bondy_backup` used.
Returns `deleted` when every sibling is a tombstone (or there is no value);
otherwise `{ok, Value}`, resolving concurrent siblings last-writer-wins by the
wrapped modification timestamp.
""".
-spec resolve_object(Object :: {object, term()}) ->
    {ok, term()} | deleted.

resolve_object({object, {Entries, _Deferred}}) ->
    Live = [
        {Payload, Ts}
     || {_Dot, _Counter, Values} <- Entries,
        {Payload, Ts} <- Values,
        Payload =/= '$deleted'
    ],
    case Live of
        [] ->
            deleted;
        _ ->
            {Payload, _Ts} = lists:last(lists:keysort(2, Live)),
            {ok, Payload}
    end.

-doc """
Maps one legacy plum_db `{Prefix, SubPrefix, Key, Value}` to the current
`bondy_db` `{entry, Table, Band, Key, Value}` layout, or `{skip, Reason}` for an
intentionally-unmigrated domain (see the moduledoc). The reshape per domain:

- per-realm security tables band by the realm URI (the legacy `SubPrefix`);
- grants / sources re-key through the live `encode_key/1`;
- users / groups upgrade their value via the module's `from_term/1`;
- `api_gateway` specs live under the global band.
""".
-spec legacy_translate(
    Prefix :: atom(),
    SubPrefix :: term(),
    Key :: term(),
    Value :: term()
) ->
    {entry, atom(), binary(), term(), term()} | {skip, term()}.

legacy_translate(security_users, Realm, Username, Payload) when
    is_binary(Realm)
->
    {entry, ?BONDY_DB_USER_TAB, Realm, Username,
        bondy_rbac_user:from_term({Username, Payload})};
legacy_translate(security_groups, Realm, Name, Payload) when is_binary(Realm) ->
    {entry, ?BONDY_DB_GROUP_TAB, Realm, Name,
        bondy_rbac_group:from_term({Name, Payload})};
legacy_translate(security_user_grants, Realm, {_Role, Resource} = K, Perms) when
    is_binary(Realm), is_list(Perms)
->
    {entry, ?BONDY_DB_USER_GRANT_TAB, Realm, bondy_rbac:encode_key(K), #{
        resource => Resource, permissions => Perms
    }};
legacy_translate(
    security_group_grants, Realm, {_Role, Resource} = K, Perms
) when
    is_binary(Realm), is_list(Perms)
->
    {entry, ?BONDY_DB_GROUP_GRANT_TAB, Realm, bondy_rbac:encode_key(K), #{
        resource => Resource, permissions => Perms
    }};
legacy_translate(security_sources, Realm, LegacyKey, Source) when
    is_binary(Realm), is_map(Source), is_tuple(LegacyKey)
->
    %% The legacy key leads with the Username (a binary, or `all`/`anonymous`);
    %% the mask + method come from the value, which the current source map also
    %% carries. The current value additionally needs the username field.
    Username = element(1, LegacyKey),
    AMask = maps:get(cidr, Source),
    Authmethod = maps:get(authmethod, Source),
    EncKey = bondy_rbac_source:encode_key({Username, AMask, Authmethod}),
    {entry, ?BONDY_DB_SOURCE_TAB, Realm, EncKey, Source#{username => Username}};
legacy_translate(security_sources, _Realm, _Key, _Value) ->
    %% A pre-v1.1 source: a `{Username, CIDR}` key with an `{Authmethod, Opts}`
    %% value (rather than the v1.1 `{Username, CIDR, Authmethod}` key + source
    %% map). In practice these are superseded by the v1.1 map-form entries, so we
    %% skip rather than synthesise a partial source map.
    {skip, legacy_source_format};
legacy_translate(api_gateway, api_specs, Id, Spec) when
    is_binary(Id), is_map(Spec)
->
    {entry, api_gateway, <<>>, Id, Spec};
%% Intentionally skipped domains (see the moduledoc).
legacy_translate(security_status, _, _, _) ->
    {skip, security_status_dead};
legacy_translate(oauth2_refresh_tokens, Sub, RefreshToken, Rec) when
    is_binary(Sub) andalso
        is_binary(RefreshToken) andalso
        is_tuple(Rec) andalso
        element(1, Rec) =:= bondy_oauth2_token andalso
        tuple_size(Rec) =:= 8
->
    %% Sub = `<<"Realm,Issuer">>`; Rec = `{bondy_oauth2_token, Issuer(client),
    %% Username, Groups, Meta, ExpiresIn, IssuedAt, IsActive}`. We carry the
    %% parsed fields up; the import loop keeps the latest non-expired token per
    %% (realm, user) and flushes via `bondy_oauth_token:import_legacy/1`.
    {AuthRealm, ClientId} = split_oauth_sub(Sub),
    {bondy_oauth2_token, _Issuer, Username, Groups, Meta, ExpiresIn, IssuedAt,
        _Active} = Rec,
    AuthId = string:casefold(Username),
    DeviceId = maps:get(<<"client_device_id">>, Meta, all),
    Spec = #{
        authrealm => AuthRealm,
        refresh_token => RefreshToken,
        username => Username,
        client_id => ClientId,
        device_id => DeviceId,
        groups => Groups,
        meta => Meta,
        expires_in => ExpiresIn,
        issued_at => IssuedAt
    },
    {oauth_token, AuthRealm, AuthId, IssuedAt, ExpiresIn, Spec};
legacy_translate(oauth2_refresh_tokens, _, _, _) ->
    {skip, oauth_token_unparsable};
legacy_translate(bondy_realm, _, _, _) ->
    {skip, realm_recreate_from_config};
legacy_translate(security, realms, _, _) ->
    {skip, realm_recreate_from_config};
legacy_translate(Prefix, _, _, _) ->
    {skip, {unsupported_prefix, Prefix}}.

%% @private
bump(Key, C) ->
    maps:update_with(Key, fun(N) -> N + 1 end, 1, C).

%% @private
skip(Reason, C) ->
    Skipped = maps:get(skipped, C, #{}),
    C#{skipped => maps:update_with(Reason, fun(N) -> N + 1 end, 1, Skipped)}.

%% =============================================================================
%% PRIVATE: STATUS / HEADER
%% =============================================================================

%% @private
read_head(Filename) ->
    Opts = [
        {name, log},
        {mode, read_only},
        {file, Filename}
    ],
    Acc = #{filename => unicode:characters_to_binary(Filename)},
    case disk_log:open(Opts) of
        {ok, Log} ->
            do_read_head(Log, Acc);
        {repaired, Log, {recovered, Rec}, {badbytes, Bad}} ->
            do_read_head(Log, Acc#{recovered => Rec, bad_bytes => Bad});
        {error, no_such_log} ->
            {error, not_found};
        {error, _} = Error ->
            Error
    end.

%% @private
do_read_head(Log, Acc0) ->
    try
        case disk_log:chunk(Log, start) of
            {_Cont, [H | _]} ->
                ok = validate_head(H),
                {ok, maps:merge(Acc0#{status => ok, bad_bytes => 0}, H)};
            {_Cont, [H | _], BadBytes} ->
                ok = validate_head(H),
                {ok, maps:merge(Acc0#{status => ok, bad_bytes => BadBytes}, H)};
            eof ->
                {ok, Acc0#{status => invalid_format}};
            {error, {corrupt_log_file, _}} ->
                {ok, Acc0#{status => corrupt, bad_bytes => 0}};
            {error, {blocked_log, _}} ->
                {ok, Acc0#{status => blocked, bad_bytes => 0}};
            {error, _} = Error ->
                Error
        end
    catch
        _:Reason ->
            {error, Reason}
    after
        _ = disk_log:close(Log)
    end.

%% @private
validate_head(#{format := ?EXPORT_FORMAT}) ->
    ok;
validate_head(#{format := ?LEGACY_FORMAT}) ->
    ok;
validate_head(H) ->
    throw({invalid_header, H}).

%% =============================================================================
%% PRIVATE: EVENTS
%% =============================================================================

%% @private
notify_export_started(File) ->
    ?LOG_NOTICE(#{description => "Started export", filename => File}),
    bondy_event_manager:notify({[bondy, export, start], #{filename => File}}).

%% @private
notify_export_finished([Filename, Time]) ->
    ?LOG_NOTICE(#{
        description => "Finished creating export",
        filename => Filename,
        elapsed_time_secs => Time
    }),
    bondy_event_manager:notify(
        {[bondy, export, stop], #{
            filename => Filename, elapsed_time_secs => Time
        }}
    ).

%% @private
notify_export_error([Reason, Filename, Time]) ->
    ?LOG_ERROR(#{
        description => "Error creating export",
        filename => Filename,
        reason => Reason,
        elapsed_time_secs => Time
    }),
    bondy_event_manager:notify(
        {[bondy, export, exception], #{
            filename => Filename, reason => Reason, elapsed_time_secs => Time
        }}
    ).

%% @private
notify_import_started([Filename, Rec, Bad]) ->
    ?LOG_NOTICE(#{
        description => "Import started",
        filename => Filename,
        recovered => Rec,
        bad_bytes => Bad
    }),
    bondy_event_manager:notify(
        {[bondy, export, import, start], #{filename => Filename}}
    ).

%% @private
notify_import_finished([Filename, Time, Read, Written]) ->
    ?LOG_NOTICE(#{
        description => "Import finished",
        filename => Filename,
        elapsed_time_secs => Time,
        read_count => Read,
        written_count => Written
    }),
    bondy_event_manager:notify(
        {[bondy, export, import, stop], #{
            filename => Filename,
            elapsed_time_secs => Time,
            read_count => Read,
            written_count => Written
        }}
    ).

%% @private
notify_import_error([Filename, Reason, Time]) ->
    ?LOG_ERROR(#{
        description => "Import failed",
        filename => Filename,
        reason => Reason,
        elapsed_time_secs => Time
    }),
    bondy_event_manager:notify(
        {[bondy, export, import, exception], #{
            filename => Filename, reason => Reason, elapsed_time_secs => Time
        }}
    ).
