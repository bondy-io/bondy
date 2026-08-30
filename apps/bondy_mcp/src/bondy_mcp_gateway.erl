%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_gateway).

-moduledoc """
The MCP manifest cache manager (design §7.10) and the MCP overlay document
store (§18.3).

## Overlay documents

`load/1`, `delete/1`, `lookup/1` and `list/0` manage the operator's MCP
overlay documents in the durable `mcp_gateway` bondy_db table: one key per
document, the stored value the SOURCE map (never a parsed form), the same
posture `bondy_http_gateway` takes with API specifications. A document is
validated as a whole by `bondy_mcp_spec_parser:parse/1` — one invalid entry
rejects the load — plus the two checks the parser cannot run pure: every
named realm must exist, and no `(realm, name)` the document claims may
belong to a DIFFERENT loaded document (§17's overlay-collision rule; the
compile-time skip-and-alarm below remains the backstop for collisions that
arrive already-converged via anti-entropy). These functions are plain
`bondy_db` writes: no process is involved, and they work on a node that
never serves MCP.

## The manifest cache

A gen_server holding compiled per-realm manifests (`bondy_mcp_spec:t()`
entries keyed by MCP name) in a protected ETS table — ONE cell per realm
whose value is the whole compiled manifest map, so a reader always sees one
consistent snapshot and a rebuild is a single atomic `ets:insert/2`; no
table swap exists to get wrong. It is a sibling of `bondy_http_gateway` in
kind — a node-level manager with debounced invalidation — but contributes
no routes and takes no part in dispatch: a manifest change alters what
`tools/list` answers, nothing more.

The server is started ON DEMAND by the first `manifest/1` call (§18.2: a
node with no MCP listener runs nothing of this application), and then:

- subscribes to the `bondy_interface` and `mcp_gateway` table namespaces
  (both `publish => true`), so a local write, an AE-replicated peer write
  or a bootstrap snapshot install invalidates the cache;
- coalesces event bursts behind an `mcp.manifest.rebuild_debounce` window
  (default 1s) and then rebuilds every realm currently cached — a realm
  nobody asked for is never compiled;
- serves reads through `manifest/1`: fresh cache hits bypass the server
  entirely; a miss or a manifest older than `mcp.manifest.cache_ttl`
  (default 60s — the backstop for a lost event) rebuilds through a
  `gen_server` call, so concurrent stale readers collapse into one
  rebuild.

Registration and deregistration are deliberately NOT invalidation
triggers: the manifest declares surface and the registry decides liveness
(§7.7), so a callee connecting or dropping changes nothing a rebuild would
see.

## Collisions

A compile reporting §17 name collisions (one name, different underlying
WAMP bindings, e.g. from two overlay documents converged via AE) raises
one `major` alarm per `(realm, name)` through OTP's `alarm_handler` and
exposes NEITHER entry; the alarm clears on the first rebuild where the
collision is gone.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_router/include/bondy_db_tables.hrl").

%% Overlay documents live in a single flat bucket: a document's entries name
%% their own realms, so the realm is data, not part of the key.
-define(BUCKET, <<>>).
%% The manifest cache: `{RealmUri, BuiltAt :: monotonic ms, Manifest}`.
-define(TAB, ?MODULE).
%% Retry cadence for the oplog subscriptions while a table is not
%% provisioned yet — same value as `bondy_http_gateway`'s, for one cadence
%% across the subscribers of `publish => true` tables.
-define(RESUBSCRIBE_AFTER, 500).
-define(DEFAULT_CACHE_TTL, 60000).
-define(DEFAULT_REBUILD_DEBOUNCE, 1000).

-record(state, {
    %% Change-event subscription refs, one per table namespace.
    oplog_subs = [] :: [reference()],
    %% Pending debounce timer for a coalesced rebuild of the cached realms.
    rebuild_timer :: reference() | undefined,
    %% The §17 collision alarms currently raised, per realm, so a rebuild
    %% can clear the ones its collisions no longer justify.
    alarms = #{} :: #{binary() => [term()]}
}).

-type manifest() :: #{
    realm := binary(),
    entries := #{binary() => bondy_mcp_spec:t()},
    built_at := integer()
}.

-export_type([manifest/0]).

%% API
-export([delete/1]).
-export([list/0]).
-export([check/1]).
-export([load/1]).
-export([lookup/1]).
-export([manifest/1]).
-export([start_link/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Starts the manifest cache manager, registered as `bondy_mcp_gateway`.".
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Loads (or REPLACES) an MCP overlay document. The whole document is
validated first — the parser's checks plus realm existence and
cross-document name exclusivity — and the first failure rejects it with
nothing written. The SOURCE map is stored, keyed by the document's id.
""".
-spec load(Document :: map()) -> ok | {error, any()}.

load(Document) when is_map(Document) ->
    case check(Document) of
        {ok, #{id := Id}} ->
            bondy_db:apply(spec_table(), ?BUCKET, Id, {set, Document});
        {error, _} = Error ->
            Error
    end;
load(_) ->
    {error, invalid_document}.

-doc """
Every check `load/1` performs, and nothing else: the parser's checks plus realm
existence and cross-document name exclusivity. Writes nothing.

This is `load/1` minus its single `bondy_db:apply/4`, which is what makes the
`dry_run` convention honest here rather than a second implementation that could
answer `ok` where the real one fails.
""".
-spec check(Document :: map()) ->
    {ok, #{id := binary(), entries := [map()]}} | {error, any()}.

check(Document) when is_map(Document) ->
    case bondy_mcp_spec_parser:parse(Document) of
        {ok, #{id := _, entries := Entries} = Parsed} ->
            try
                ok = assert_realms_exist(Entries),
                ok = assert_names_unclaimed(maps:get(id, Parsed), Entries),
                {ok, Parsed}
            catch
                throw:Reason -> {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end;
check(_) ->
    {error, invalid_document}.

-doc "Deletes the overlay document `Id`.".
-spec delete(Id :: binary()) -> ok | {error, not_found}.

delete(Id) when is_binary(Id) ->
    case bondy_db:read(spec_table(), ?BUCKET, Id) of
        {ok, {Document, _}} when is_map(Document) ->
            bondy_db:apply(spec_table(), ?BUCKET, Id, clear);
        _ ->
            {error, not_found}
    end.

-doc "The SOURCE of overlay document `Id`, as originally loaded.".
-spec lookup(Id :: binary()) -> {ok, map()} | {error, not_found}.

lookup(Id) when is_binary(Id) ->
    case bondy_db:read(spec_table(), ?BUCKET, Id) of
        {ok, {Document, _}} when is_map(Document) -> {ok, Document};
        _ -> {error, not_found}
    end.

-doc "The sources of every loaded overlay document.".
-spec list() -> [map()].

list() ->
    [Document || {_Id, Document} <- stored_docs()].

-doc """
The compiled MCP manifest of `RealmUri` — a fresh cached snapshot when one
exists, a (re)build otherwise. Starts the cache manager if this node has
not served a manifest before. `{error, no_such_realm}` for a realm that
does not exist, so an unresolvable URI can never grow the cache.
""".
-spec manifest(RealmUri :: binary()) ->
    {ok, manifest()} | {error, any()}.

manifest(RealmUri) when is_binary(RealmUri) ->
    case bondy_realm:exists(RealmUri) of
        true -> cached_or_build(RealmUri);
        false -> {error, no_such_realm}
    end.

%% @private
cached_or_build(RealmUri) ->
    case ensure_started() of
        ok ->
            Now = erlang:monotonic_time(millisecond),
            Ttl = cache_ttl(),
            case ets:lookup(?TAB, RealmUri) of
                [{_, BuiltAt, Manifest}] when Now - BuiltAt < Ttl ->
                    {ok, Manifest};
                _ ->
                    gen_server:call(?MODULE, {build, RealmUri})
            end;
        {error, _} = Error ->
            Error
    end.

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    ?TAB = ets:new(?TAB, [
        named_table, set, protected, {read_concurrency, true}
    ]),
    %% Adopt collision alarms a previous incarnation raised, so one this
    %% incarnation's rebuilds no longer justify is cleared rather than
    %% orphaned by the crash.
    {ok, subscribe(#state{alarms = recover_alarms()})}.

handle_call({build, RealmUri}, _From, State0) ->
    %% Recheck freshness under the serialization point: concurrent stale
    %% readers collapse into the first caller's rebuild.
    Now = erlang:monotonic_time(millisecond),
    Ttl = cache_ttl(),
    case ets:lookup(?TAB, RealmUri) of
        [{_, BuiltAt, Manifest}] when Now - BuiltAt < Ttl ->
            {reply, {ok, Manifest}, State0};
        _ ->
            {Manifest, State} = rebuild(RealmUri, demand, State0),
            {reply, {ok, Manifest}, State}
    end;
handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.

handle_cast(Event, State) ->
    ?LOG_WARNING(#{reason => unsupported_event, event => Event}),
    {noreply, State}.

handle_info({bondy_oplog_core_event, _NS, _Key, _Hlc, _Op}, State) ->
    %% A local interface or overlay write.
    {noreply, note_change(State)};
handle_info(
    {bondy_oplog_core_merge_event, _NS, _Key, _Hlc, _Op, _Old}, State
) ->
    %% A peer's write arrived via anti-entropy.
    {noreply, note_change(State)};
handle_info({bondy_oplog_core_bootstrap_event, _NS, _Bucket}, State) ->
    %% A catalogue-snapshot bootstrap installed a table's projection
    %% wholesale; that path emits no per-cell events.
    {noreply, note_change(State)};
handle_info(retry_subscribe, State) ->
    {noreply, subscribe(State)};
handle_info(rebuild, State0) ->
    %% The debounce window elapsed — rebuild every realm currently cached.
    Realms = ets:foldl(fun({R, _, _}, Acc) -> [R | Acc] end, [], ?TAB),
    State1 = lists:foldl(
        fun(R, Acc0) ->
            {_, Acc1} = rebuild(R, db_event, Acc0),
            Acc1
        end,
        State0#state{rebuild_timer = undefined},
        Realms
    ),
    {noreply, State1};
handle_info(Info, State) ->
    ?LOG_WARNING(#{reason => unsupported_event, event => Info}),
    {noreply, State}.

terminate(_Reason, State) ->
    _ = [bondy_oplog_core:unsubscribe(Ref) || Ref <- State#state.oplog_subs],
    ok.

%% =============================================================================
%% PRIVATE — overlay document store
%% =============================================================================

%% @private
assert_realms_exist(Entries) ->
    lists:foreach(
        fun(#{realm := Realm}) ->
            bondy_realm:exists(Realm) orelse throw({no_such_realm, Realm})
        end,
        Entries
    ).

%% @private
%% §17: a `(realm, name)` this document claims that another LOADED document
%% already claims rejects the whole load. Reloading one's own document is a
%% replace, never a conflict.
assert_names_unclaimed(Id, Entries) ->
    Claimed = lists:usort([
        {maps:get(realm, E), maps:get(name, E)}
     || E <- Entries
    ]),
    lists:foreach(
        fun({OtherId, Doc}) ->
            OtherId == Id orelse
                lists:foreach(
                    fun(Key) ->
                        lists:member(Key, doc_names(Doc)) andalso
                            throw(
                                {conflict, #{
                                    realm => element(1, Key),
                                    name => element(2, Key),
                                    owner => OtherId
                                }}
                            )
                    end,
                    Claimed
                )
        end,
        stored_docs()
    ).

%% @private
%% The `(realm, name)` pairs a STORED document claims — LENIENT, like
%% `bondy_interface:doc_keys/1`: the document validated when it loaded, and
%% a later load must not be blocked by one that no longer parses.
doc_names(Doc) ->
    case bondy_mcp_spec_parser:parse(Doc) of
        {ok, #{entries := Entries}} ->
            [{maps:get(realm, E), maps:get(name, E)} || E <- Entries];
        {error, _} ->
            []
    end.

%% @private
%% Every stored overlay document as `{Id, Doc}` (tombstones excluded).
stored_docs() ->
    {ok, Cells} = bondy_db:list(spec_table(), ?BUCKET),
    [{Id, Doc} || {Id, Doc, _Hlc} <- Cells, is_map(Doc)].

%% @private
spec_table() ->
    case bondy_namespace_catalog:table(?BONDY_DB_MCP_GATEWAY_TAB) of
        undefined -> error(mcp_gateway_table_unavailable);
        Table -> Table
    end.

%% =============================================================================
%% PRIVATE — manifest cache
%% =============================================================================

%% @private
recover_alarms() ->
    lists:foldl(
        fun
            ({{bondy_mcp_name_collision, Realm, _} = Id, _}, Acc) ->
                maps:update_with(
                    Realm, fun(L) -> [Id | L] end, [Id], Acc
                );
            (_, Acc) ->
                Acc
        end,
        #{},
        bondy_alarm_handler:get_alarms()
    ).

%% @private
%% Idempotent, race-safe on-demand start under `bondy_mcp_sup`.
ensure_started() ->
    case erlang:whereis(?MODULE) of
        Pid when is_pid(Pid) ->
            ok;
        undefined ->
            case bondy_mcp_sup:start_gateway() of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok;
                {error, _} = Error -> Error
            end
    end.

%% @private
%% Subscribe to change events of both source tables. Either table missing
%% arms a retry: staying silently deaf would turn the TTL backstop into the
%% only invalidation path for the node's lifetime.
subscribe(State) ->
    Tables = [
        bondy_namespace_catalog:table(?BONDY_DB_INTERFACE_TAB),
        bondy_namespace_catalog:table(?BONDY_DB_MCP_GATEWAY_TAB)
    ],
    case lists:member(undefined, Tables) of
        true ->
            ?LOG_WARNING(#{
                description =>
                    "An MCP manifest source table is not available; the "
                    "manifest-cache reactor is not subscribed yet and "
                    "will retry (is the namespace catalogue running?)",
                retry_in_ms => ?RESUBSCRIBE_AFTER
            }),
            _ = erlang:send_after(
                ?RESUBSCRIBE_AFTER, self(), retry_subscribe
            ),
            State;
        false ->
            Refs = [
                begin
                    {ok, Ref} = bondy_oplog_core:subscribe(
                        bondy_db:namespace(T), all
                    ),
                    Ref
                end
             || T <- Tables
            ],
            %% RECONCILE ON ATTACH: anything cached before this point may
            %% predate events we never heard. On a fresh start the cache is
            %% empty and this is a no-op.
            State1 = State#state{oplog_subs = Refs},
            note_change(State1)
    end.

%% @private
%% (Re)arm the debounce timer; changes inside the window coalesce behind it.
note_change(#state{rebuild_timer = undefined} = State) ->
    Ref = erlang:send_after(rebuild_debounce(), self(), rebuild),
    State#state{rebuild_timer = Ref};
note_change(State) ->
    State.

%% @private
%% Compile `RealmUri`'s manifest, publish it as ONE cell (the atomic
%% snapshot), and reconcile the §17 collision alarms.
rebuild(RealmUri, Trigger, State) ->
    T0 = erlang:monotonic_time(microsecond),
    Previous =
        case ets:lookup(?TAB, RealmUri) of
            [{_, _, #{entries := Prev}}] -> Prev;
            [] -> undefined
        end,
    Mode = application:get_env(bondy_mcp, manifest_mode, curated),
    #{entries := Entries, collisions := Collisions} =
        bondy_mcp_spec:compile(RealmUri, overlay_entries(RealmUri), Mode),
    Manifest = #{
        realm => RealmUri,
        entries => Entries,
        built_at => erlang:system_time(millisecond)
    },
    true = ets:insert(
        ?TAB, {RealmUri, erlang:monotonic_time(millisecond), Manifest}
    ),
    %% §7.10: after a rebuild that CHANGED the manifest, tell the realm's
    %% `subscriptions/listen` streams which kinds changed — each stream
    %% forwards only what its own filter requested (§9.1). A first build
    %% and a no-op rebuild (the TTL backstop, a burst that compiled to
    %% the same result) notify nobody: nothing a client saw has changed.
    Changed = changed_kinds(Previous, Entries),
    ok = bondy_mcp_stream:notify_manifest_changed(RealmUri, Changed),
    %% The handshake era's sessions (§12) get the same signal as
    %% pre-encoded `notifications/*/list_changed` in their transport
    %% queues — buffered while no GET stream is connected.
    ok = bondy_mcp_handshake:notify_manifest_changed(RealmUri, Changed),
    ok = bondy_mcp_metrics:manifest_rebuild(
        RealmUri,
        Trigger,
        erlang:monotonic_time(microsecond) - T0,
        entry_census(Entries)
    ),
    Collisions == [] orelse
        bondy_mcp_metrics:manifest_conflict(
            RealmUri, name_collision, length(Collisions)
        ),
    {Manifest, reconcile_alarms(RealmUri, Collisions, State)}.

%% @private
%% The compiled entry count per kind, written as the absolute
%% `bondy_mcp_manifest_entries` gauge value by the metrics sink.
entry_census(Entries) ->
    maps:fold(
        fun(_, #{kind := Kind}, Acc) ->
            maps:update_with(Kind, fun(N) -> N + 1 end, 1, Acc)
        end,
        #{tool => 0, resource => 0, resource_template => 0},
        Entries
    ).

%% @private
%% Which §9.1 list-changed kinds a rebuild changed, compared as
%% `Name => hash` projections — the §7.5 hash covers exactly the content
%% a client can observe through a descriptor.
changed_kinds(undefined, _) ->
    [];
changed_kinds(Prev, New) ->
    [
        Kind
     || {Kind, Kinds} <- [
            {tools, [tool]}, {resources, [resource, resource_template]}
        ],
        kind_hashes(Prev, Kinds) =/= kind_hashes(New, Kinds)
    ].

%% @private
kind_hashes(Entries, Kinds) ->
    maps:from_list([
        {Name, maps:get(hash, E)}
     || {Name, #{kind := K} = E} <- maps:to_list(Entries),
        lists:member(K, Kinds)
    ]).

%% @private
%% The parsed entries of every loaded overlay document that name
%% `RealmUri`, each annotated with its source document id. A stored
%% document that no longer parses is skipped with a warning — it was valid
%% when loaded, and a rebuild must not fail because a peer on a newer
%% version replicated a shape this node cannot read yet.
overlay_entries(RealmUri) ->
    lists:flatmap(
        fun({Id, Doc}) ->
            case bondy_mcp_spec_parser:parse(Doc) of
                {ok, #{entries := Entries}} ->
                    [
                        E#{overlay_source => Id}
                     || E <- Entries, maps:get(realm, E) == RealmUri
                    ];
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        description =>
                            "Skipping a stored MCP overlay document that "
                            "no longer parses",
                        document_id => Id,
                        reason => Reason
                    }),
                    []
            end
        end,
        stored_docs()
    ).

%% @private
%% One alarm per colliding `(realm, name)`; cleared on the first
%% rebuild of that realm where the collision is gone.
reconcile_alarms(RealmUri, Collisions, #state{alarms = Alarms} = State) ->
    New = lists:usort([
        {bondy_mcp_name_collision, RealmUri, maps:get(name, C)}
     || C <- Collisions
    ]),
    Old = maps:get(RealmUri, Alarms, []),
    _ = [alarm_handler:clear_alarm(Id) || Id <- Old -- New],
    _ = [
        begin
            {_, _, Name} = Id,
            ?LOG_ERROR(#{
                description =>
                    "MCP manifest name collision: one name resolves to "
                    "different WAMP bindings; NEITHER entry is exposed. "
                    "Rename one side in an MCP overlay document.",
                realm => RealmUri,
                name => Name
            }),
            alarm_handler:set_alarm(
                {
                    Id,
                    <<
                        "MCP manifest name collision; the colliding entries "
                        "are not exposed"
                    >>
                }
            )
        end
     || Id <- New -- Old
    ],
    State#state{
        alarms =
            case New of
                [] -> maps:remove(RealmUri, Alarms);
                _ -> maps:put(RealmUri, New, Alarms)
            end
    }.

%% @private
cache_ttl() ->
    application:get_env(bondy_mcp, manifest_cache_ttl, ?DEFAULT_CACHE_TTL).

%% @private
rebuild_debounce() ->
    application:get_env(
        bondy_mcp, manifest_rebuild_debounce, ?DEFAULT_REBUILD_DEBOUNCE
    ).
