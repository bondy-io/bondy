%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry).
-behaviour(gen_server).

-moduledoc """
An in-memory registry for PubSub subscriptions and Routed RPC registrations,
providing pattern matching capabilities including support for WAMP's
version 2.0 match policies (exact, prefix and wildcard).

Entries are stored in the ephemeral `registry` bondy_db (an in-RAM, memory
topology DB — no durable / on-disk backing, provisioned by
`m:bondy_namespace_catalog`). The registry also maintains in-memory indices
as a materialised view: ETS bags for exact matching, and lock-free persistent
ART tries (`m:bondy_registry_ptrie`) for prefix and wildcard matching.

This module also provides a singleton server that rebuilds the indices from
the bondy_db store on startup (a no-op on a fresh boot, since the ephemeral
store does not survive a restart).

The registry consists of this server and a pool of `bondy_registry_partition`
workers; each partition owns its own slice of the indices.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_db_tables.hrl").
-include("bondy_registry.hrl").

-record(state, {
    timers = #{} :: #{node() => reference()},
    start_ts :: pos_integer()
}).

-type task() :: fun((entry(), bondy_context:t()) -> ok).

%% Aliases
-type entry() :: bondy_registry_entry:t().
-type entry_type() :: bondy_registry_entry:entry_type().
-type entry_key() :: bondy_registry_entry:key().
-type continuation() :: bondy_registry_partition:continuation().
-type eot() :: bondy_registry_partition:eot().

%% SERVER API
-export([start_link/0]).
-export([partitions/0]).
-export([pick_partition/1]).
-export([init_indices/0]).
-export([format_error/2]).
-export([info/0]).

%% CRUD API
-export([add/1]).
-export([add/4]).
-export([add/5]).
-export([entries/1]).
-export([entries/2]).
-export([entries/3]).
-export([entries/4]).
-export([lookup/2]).
-export([lookup/3]).
-export([remove/1]).
-export([remove/3]).
-export([remove/4]).
-export([remove_all/2]).
-export([remove_all/3]).
-export([remove_all/5]).

%% INDEX BASED MATCHING API
-export([has_matches/3]).
-export([list_local/4]).
-export([match/1]).
-export([match/3]).
-export([match/4]).
-export([find_matches/1]).
-export([find_matches/3]).
-export([find_matches/4]).

%% GEN_SERVER CALLBACKS
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Starts the registry server.

The server monitors cluster node up / down events (to schedule pruning of a
departed node's entries) and rebuilds the partitions' in-memory indices from
the bondy_db store on startup.
""".
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Rebuilds the partitions' in-memory match indices from the entries in the
bondy_db `registry` store.
""".
init_indices() ->
    gen_server:call(?MODULE, init_indices, timer:minutes(10)).

-doc """
""".
-spec partitions() -> [pid()].

partitions() ->
    gproc_pool:active_workers(?REGISTRY_POOL).

-doc """
""".
-spec pick_partition(Arg :: binary() | entry()) -> pid().

pick_partition(Arg) ->
    bondy_registry_partition:pick(Arg).

-doc """
""".
-spec info() -> #{size => non_neg_integer(), memory => non_neg_integer()}.

info() ->
    {Size, Mem} = lists:foldl(
        fun(Partition, {S, M}) ->
            {{bondy_registry_partition, _N}, Pid} = Partition,
            #{
                size := Size,
                memory := Mem
            } = bondy_registry_partition:info(Pid),

            {S + Size, M + Mem}
        end,
        {0, 0},
        partitions()
    ),
    #{size => Size, memory => Mem}.

-doc """
Used for adding proxy entries only as it skips all checks.
Fails with `badarg` if  `Entry` is not a proxy entry.
""".
-spec add(entry()) ->
    {ok, IsFirstEntry :: boolean()} | {error, already_exists} | no_return().

add(Entry) ->
    bondy_registry_entry:is_proxy(Entry) orelse
        ?ERROR(badarg, [Entry], #{
            1 => "is not a proxy entry()"
        }),

    Partition = pick_partition(Entry),
    bondy_registry_partition:add(Partition, Entry).

-doc "See `add/5`.".
-spec add(
    Type :: entry_type(),
    RegUri :: uri(),
    Opts :: map(),
    Ctxt :: bondy_context:t()
) ->
    {ok, {Entry :: entry(), IsFirstEntry :: boolean()}}
    | {error, {already_exists, entry()} | any()}.

add(Type, Uri, Opts, Ctxt) when is_map(Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Ref = bondy_context:ref(Ctxt),
    add(Type, RealmUri, Uri, Opts, Ref).

-doc """
Adds an entry to the registry.

Adding an already existing entry is treated differently based on whether the
entry is a `registration` or a `subscription`.

According to the WAMP specification, in the case of a subscription that was
already added before by the same _Subscriber_, the _Broker_ should not fail
and answer with a `SUBSCRIBED` message, containing the existing
`Subscription|id`. So in this case this function returns
`{ok, entry(), boolean()}`.

In case of a registration, as a default, only a single Callee may
register a procedure for an URI. However, when shared registrations are
supported, then the first Callee to register a procedure for a particular URI
MAY determine that additional registrations for this URI are allowed, and
what Invocation Rules to apply in case such additional registrations are
made.

This is configured through the `invoke` option.
When invoke is not `single`, Dealer MUST fail all subsequent attempts to
register a procedure for the URI where the value for the invoke option does
not match that of the initial registration. Accordingly this function might
return an error tuple.

> #### {.notice}
> At the moment this logic is implemented here but it should really be the
> responsibility of `bondy_dealer` and `bondy_broker`.
""".
-spec add(
    Type :: entry_type(),
    RealmUri :: uri(),
    Uri :: uri(),
    Opts :: map(),
    Ref :: bondy_ref:t()
) ->
    {ok, Entry :: entry(), IsFirstEntry :: boolean()}
    | {error, {already_exists, entry()} | any()}.

add(Type, RealmUri, Uri, Opts, Ref) ->
    Partition = pick_partition(RealmUri),
    maybe_add(Type, RealmUri, Uri, Opts, Ref, Partition).

-doc "Removes (deletes) an entry from the registry.".
-spec remove(entry()) -> ok | {error, any()}.

remove(Entry) ->
    bondy_registry_partition:remove(pick_partition(Entry), Entry).

-spec remove(entry_type(), id(), bondy_context:t()) ->
    ok | {error, not_found}.

remove(Type, EntryId, Ctxt) ->
    remove(Type, EntryId, Ctxt, undefined).

-spec remove(
    Type :: entry_type(),
    EntryId :: id(),
    Ctxt :: bondy_context:t(),
    Task :: optional(task())
) -> ok | {error, any()}.

remove(Type, EntryId, Ctxt, Task) when
    Task == undefined orelse is_function(Task, 1)
->
    RealmUri = bondy_context:realm_uri(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    Pattern = bondy_registry_entry:key_pattern(RealmUri, SessionId, EntryId),
    FindOpts = [{limit, 1}],
    Partition = pick_partition(RealmUri),

    %% We should match at most one entry for the {RealmUri, SessionId, EntryId}
    %% combination.
    case bondy_registry_partition:find(Partition, Type, Pattern, FindOpts) of
        ?EOT ->
            ok;
        {[{_Key, Entry}], _Cont} ->
            maybe
                ok ?= bondy_registry_partition:remove(Partition, Entry),
                %% If Task is a fun, execute it
                maybe_execute(maybe_fun(Task, Ctxt), Entry)
            end
    end.

-doc """
Removes all entries of type `Type` matching the context's realm and
session_id.

Same as calling `remove_all(Type, Ctxt, undefined)`.
""".
-spec remove_all(entry_type(), bondy_context:t()) -> ok.

remove_all(Type, Ctxt) ->
    remove_all(Type, Ctxt, undefined).

-doc """
Removes all entries of type `Type` matching the context's realm and
session_id.

If `Task` is defined, it executes the task passing the removed entry as
argument.
""".
-spec remove_all(entry_type(), bondy_context:t(), task() | undefined) -> ok.

remove_all(Type, Ctxt, Task) when
    Task == undefined orelse
        is_function(Task, 1) orelse is_function(Task, 2)
->
    case bondy_context:session_id(Ctxt) of
        undefined ->
            ?LOG_DEBUG(#{
                description => "Failed to remove registry contents",
                reason => no_session_id
            }),
            ok;
        SessionId ->
            RealmUri = bondy_context:realm_uri(Ctxt),
            Partition = pick_partition(RealmUri),
            Pattern = bondy_registry_entry:key_pattern(
                RealmUri, SessionId, '_'
            ),
            MaybeFun = maybe_fun(Task, Ctxt),
            MatchOpts = [{limit, 100}],
            Matches = bondy_registry_partition:find(
                Partition, Type, Pattern, MatchOpts
            ),
            do_remove_all(Matches, SessionId, MaybeFun, #{})
    end.

-doc """
Removes all registry entries of type Type, for a {RealmUri
SessionId} relation.

### Opts
- broadcast => boolean()
""".
-spec remove_all(
    Type :: entry_type(),
    RealmUri :: uri(),
    SessionId :: id(),
    Task :: task() | undefined,
    Opts :: map()
) -> [entry()].

remove_all(Type, RealmUri, SessionId, Task, Opts) when
    Task == undefined orelse is_function(Task, 1)
->
    Pattern = bondy_registry_entry:key_pattern(RealmUri, SessionId, '_'),

    MatchOpts = [{limit, 100}],
    Partition = pick_partition(RealmUri),
    Matches = bondy_registry_partition:find(
        Partition, Type, Pattern, MatchOpts
    ),
    do_remove_all(Matches, SessionId, Task, Opts).

-doc """
Looks up a registration / subscription entry by its key.
""".
-spec lookup(Type :: entry_type(), Key :: entry_key()) ->
    {ok, entry()} | {error, not_found}.

lookup(Type, EntryKey) ->
    Partition = pick_partition(EntryKey),
    bondy_registry_partition:lookup(Partition, Type, EntryKey).

lookup(Type, RealmUri, EntryId) when is_integer(EntryId) ->
    Partition = pick_partition(RealmUri),
    bondy_registry_partition:lookup(Partition, Type, RealmUri, EntryId).

-doc """
Continues returning the list of entries owned by a session started with
`entries/4`.

The next chunk of the size specified in the initial `entries/4` call is
returned together with a new Continuation, which can be used in subsequent
calls to this function.

When there are no more objects in the table, `{[], '$end_of_table'}` is
returned.
""".
-spec entries(continuation()) ->
    {[entry()], continuation() | eot()} | eot().

entries(?EOT) ->
    ?EOT;
entries(Cont0) ->
    %% We need to add back the resolver strategy
    case bondy_registry_partition:find(Cont0) of
        ?EOT ->
            ?EOT;
        {L, ContOrEOT} ->
            {[V || {_, V} <- L], ContOrEOT}
    end.

-doc """
Returns the list of entries owned by the active session.

This function is equivalent to calling `entries/2` with the RealmUri
and SessionId extracted from the Context.
""".
-spec entries(entry_type(), bondy_context:t()) -> [entry()].

entries(Type, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    entries(Type, RealmUri, SessionId).

-doc """
Returns the complete list of entries owned by a session matching
RealmUri and SessionId.

Use `entries/3` and `entries/1` to limit the number
of entries returned.
""".
-spec entries(Type :: entry_type(), RealmUri :: uri(), SessionId :: id()) ->
    [entry()].

entries(Type, RealmUri, SessionId) ->
    entries(Type, RealmUri, SessionId, infinity).

-doc """
Works like `entries/3`, but only returns a limited (Limit) number of
entries. Term Continuation can then be used in subsequent calls to `entries/1`
to get the next chunk of entries.
""".
-spec entries(
    Type :: entry_type(),
    Realm :: uri(),
    SessionId :: id() | '_',
    Limit :: pos_integer() | infinity
) ->
    [entry()] | {[entry()], continuation() | eot()} | eot().

entries(Type, RealmUri, SessionId, Limit) ->
    Partition = pick_partition(RealmUri),
    Pattern = bondy_registry_entry:key_pattern(RealmUri, SessionId, '_'),
    Opts =
        case Limit of
            infinity ->
                [];
            N when is_integer(N), N > 0 ->
                [{limit, Limit}]
        end,

    case bondy_registry_partition:find(Partition, Type, Pattern, Opts) of
        ?EOT ->
            ?EOT;
        {L, ?EOT} ->
            {[V || {_, V} <- L], ?EOT};
        {L, NewCont} ->
            {[V || {_, V} <- L], {Type, NewCont}};
        L when is_list(L) ->
            [V || {_, V} <- L]
    end.

-doc "Continues a match started with `match/3` or `match/4`.".
-spec match(continuation() | eot()) ->
    Registrations ::
        [entry()]
        | {Registrations :: [entry()], continuation() | eot()}
        | Subscriptions ::
        {[entry()], [node()]}
        | {Subscriptions :: {[entry()], [node()]}, continuation() | eot()}
        | eot().

match(?EOT) ->
    ?EOT;
match(Cont0) ->
    try
        #{type := Type} = bondy_registry_partition:continuation_info(Cont0),
        sort(Type, do_match(Cont0))
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while searching registry",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ?EOT
    end.

-doc """
Returns `true` iff at least one stored entry (local or remote, any
match policy) subsumes `Uri` — the boolean form of `find_matches/3`
(the routing direction), answered fail-fast in the calling process
(no partition server round-trip).

This is the demand predicate for WAMP meta events: emitters call it
before constructing a meta-event publication so that, in the common
case of zero meta-topic subscribers, no work is done at all (see
METRICS_GAP_ANALYSIS.md Part III).
""".
-spec has_matches(Type :: entry_type(), RealmUri :: uri(), Uri :: uri()) ->
    boolean().

has_matches(Type, RealmUri, Uri) ->
    Store = bondy_registry_partition:store(RealmUri),
    bondy_registry_store:has_matches(Store, Type, RealmUri, Uri) orelse
        rib_has_matches(Type, RealmUri, Uri).

-doc """
A keyset page of THIS node's entries of `Type` in `RealmUri`, in ascending
`EntryId` order: up to `Limit` entries whose id is strictly greater than
`AfterId` (all of them when `AfterId` is `undefined`, the first page).

This is the node-local leg of the distributed introspection walk in
`bondy_registry_meta` — it reads only local full entries (never the RIB), so a
coordinator pages each node's own registrations/subscriptions and merges the
per-node pages across the cluster.
""".
-spec list_local(
    Type :: entry_type(),
    RealmUri :: uri(),
    AfterId :: id() | undefined,
    Limit :: pos_integer()
) -> [entry()].

list_local(Type, RealmUri, AfterId, Limit) ->
    Partition = pick_partition(RealmUri),
    bondy_registry_partition:list_local(
        Partition, Type, RealmUri, AfterId, Limit
    ).

%% @private
%% Demand from remote nodes: full entries are not replicated, so a matching
%% registration or subscription owned by a peer is visible here only as a RIB
%% summary. Consult the stub view so the demand predicate stays true when the
%% only matching peer lives on another node.
rib_has_matches(subscription, RealmUri, Uri) ->
    bondy_registry_rib:subscription_nodes(RealmUri, Uri, #{}) =/= [];
rib_has_matches(registration, RealmUri, Uri) ->
    bondy_registry_rib:match_stubs(RealmUri, Uri) =/= [].

-doc "Calls `match/4`".
-spec match
    (subscription, RealmUri :: uri(), uri()) ->
        {[entry()], [node()]};
    (registration, RealmUri :: uri(), uri()) ->
        [entry()].

match(Type, RealmUri, Uri) ->
    match(Type, RealmUri, Uri, #{}).

-doc """
Returns the entries matching either a topic or procedure Uri according to
each entry's configured match specification.

This function is used by the Broker to return all subscriptions that match a
topic. And in case of registrations it is used by the Dealer to return all
registrations matching a procedure.
""".
-spec match
    (subscription, RealmUri :: uri(), uri(), map()) ->
        {[entry()], [node()]}
        | {{[entry()], [node()]}, continuation() | eot()}
        | eot();
    (registration, RealmUri :: uri(), uri(), map()) ->
        [entry()]
        | {[entry()], continuation() | eot()}
        | eot().

match(Type, RealmUri, Uri, Opts) ->
    try
        sort(Type, do_match(Type, RealmUri, Uri, Opts))
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while searching registry",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ?EOT
    end.

-doc "Continues a match started with `find_matches/3` or `find_matches/4`.".
-spec find_matches(continuation() | eot()) ->
    Registrations ::
        [entry()]
        | {Registrations :: [entry()], continuation() | eot()}
        | Subscriptions ::
        {[entry()], [node()]}
        | {Subscriptions :: {[entry()], [node()]}, continuation() | eot()}
        | eot().

find_matches(?EOT) ->
    ?EOT;
find_matches(Cont0) ->
    try
        #{type := Type} = bondy_registry_partition:continuation_info(Cont0),
        sort(Type, do_find_matches(Cont0))
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while searching registry",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ?EOT
    end.

-doc "Calls `find_matches/4`".
-spec find_matches
    (subscription, RealmUri :: uri(), uri()) ->
        {[entry()], [node()]};
    (registration, RealmUri :: uri(), uri()) ->
        [entry()].

find_matches(Type, RealmUri, Uri) ->
    find_matches(Type, RealmUri, Uri, #{}).

-doc """
Returns the entries matching either a topic or procedure Uri according to
each entry's configured match specification.

This function is used by the Broker to return all subscriptions that match a
topic. And in case of registrations it is used by the Dealer to return all
registrations matching a procedure.
""".
-spec find_matches
    (subscription, RealmUri :: uri(), uri(), map()) ->
        {[entry()], [node()]}
        | {{[entry()], [node()]}, continuation() | eot()}
        | eot();
    (registration, RealmUri :: uri(), uri(), map()) ->
        [entry()]
        | {[entry()], continuation() | eot()}
        | eot().

find_matches(Type, RealmUri, Uri, Opts) ->
    try
        sort(Type, do_find_matches(Type, RealmUri, Uri, Opts))
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while searching registry",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ?EOT
    end.

format_error(Reason, [{_M, _F, _As, Info} | _]) ->
    ErrorInfo = proplists:get_value(error_info, Info, #{}),
    ErrorMap = maps:get(cause, ErrorInfo),
    ErrorMap#{
        %% general => "optional general information",
        reason => io_lib:format("~p: ~p", [?MODULE, Reason])
    }.

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    %% Cluster node up / down events drive the registry presence machine
    %% (STORAGE_ARCHITECTURE §9.6). A peer's registrations reach this node's
    %% bondy_db projection via anti-entropy and its routing trie via
    %% `bondy_aae_reactor`; here we maintain their node-level liveness:
    %%
    %% - `nodedown(N)` SUSPENDs N — masks its entries (out of the routing trie,
    %%   retained in the projection / per-node index) — and arms an EVICT timer.
    %% - `nodeup(N)` RESUMEs N — unmasks its entries — and cancels the timer.
    %% - EVICT (after the grace period, by the rendezvous-hashed cleanup peer)
    %%   issues a replicated `clear` for a permanently-departed node's entries.
    %%
    %% Masking is derived from THIS node's Partisan view, so it needs no
    %% replicated event; only cluster-wide removals (DELETE, owner self-clean,
    %% EVICT) ride AAE. The plum_db net-split merge-veto machinery
    %% (`will_merge`/`on_merge` + the per-node merge-status table) is retired.
    ok = partisan:monitor_nodes(true),

    %% The owner self-cleanup invariant (§9.6.1): periodically DELETE this node's
    %% own entries whose session is no longer live — the C2/C3 discriminator that
    %% lets a rebooted node shed the stale registrations a peer would otherwise
    %% RESUME. First sweep runs shortly after boot, once AAE has had a chance to
    %% pull this node's pre-restart entries back.
    _ = erlang:send_after(self_clean_boot_ms(), self(), self_clean),

    %% Periodic RIB consistency sweep: compares the replicated routing
    %% summaries against the ground truth per realm
    %% (`bondy_registry_rib:check/1`) and logs any divergence — the
    %% production form of the gate the test suites assert on.
    ok = schedule_rib_check(),

    State = #state{
        start_ts = erlang:system_time(millisecond)
    },

    {ok, State}.

handle_call(init_indices, _From, State) ->
    Res = init_indices(State),
    {reply, Res, State};
handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.

handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

handle_info({nodeup, Node} = Event, State) ->
    %% A peer (re)connected within the grace period (presence RESUME, §9.6):
    %% cancel its pending EVICT and unmask its entries back into the routing
    %% trie. A node that rebooted empty (C3) will shed any now-stale entries via
    %% the owner self-cleanup sweep on its own side.
    ?LOG_DEBUG(#{event => Event}),
    State1 = cancel_evict(Node, State),
    T0 = erlang:monotonic_time(millisecond),
    ok = resume(Node),
    ok = observe_presence(unmask, T0),
    ok = gauge_suspended(State1),
    {noreply, State1};
handle_info({nodedown, Node} = Event, State) ->
    %% A peer disconnected (presence SUSPEND, §9.6): mask its entries for routing
    %% immediately and arm an EVICT timer to GC them if it never returns.
    ?LOG_DEBUG(#{event => Event}),
    T0 = erlang:monotonic_time(millisecond),
    ok = suspend(Node),
    ok = observe_presence(mask, T0),
    Tref = erlang:send_after(evict_grace_ms(), self(), {evict, Node}),
    Timers = (State#state.timers)#{Node => Tref},
    State1 = State#state{timers = Timers},
    ok = gauge_suspended(State1),
    {noreply, State1};
handle_info({evict, Node} = Event, State) ->
    %% The grace period elapsed (presence EVICT, §9.6). If the node is still gone
    %% and this node is its rendezvous-hashed cleanup peer, issue a replicated
    %% `clear` for each of its entries.
    ?LOG_DEBUG(#{event => Event}),
    Timers = maps:remove(Node, State#state.timers),
    ok = maybe_evict(Node),
    State1 = State#state{timers = Timers},
    ok = gauge_suspended(State1),
    {noreply, State1};
handle_info(self_clean = Event, State) ->
    %% Owner self-cleanup invariant (§9.6.1). Defensive: a sweep walks the realm
    %% list and the registry projection, none of which may take the registry
    %% server down — on any error we simply retry at the steady cadence.
    ?LOG_DEBUG(#{event => Event}),
    Cleaned =
        try
            self_clean()
        catch
            Class:Reason:Stacktrace ->
                ?LOG_WARNING(#{
                    description => "Registry owner self-cleanup sweep failed",
                    class => Class,
                    reason => Reason,
                    stacktrace => Stacktrace
                }),
                0
        end,
    _ = erlang:send_after(self_clean_next_ms(Cleaned), self(), self_clean),
    {noreply, State};
handle_info(rib_check = Event, State) ->
    %% Periodic RIB consistency sweep. Defensive: the check scans the
    %% registry projections realm by realm and must never take the registry
    %% server down.
    ?LOG_DEBUG(#{event => Event}),
    _ =
        try
            rib_check()
        catch
            Class:Reason:Stacktrace ->
                ?LOG_WARNING(#{
                    description => "Registry RIB consistency sweep failed",
                    class => Class,
                    reason => Reason,
                    stacktrace => Stacktrace
                })
        end,
    ok = schedule_rib_check(),
    {noreply, State};
handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unexpected_event,
        event => Info
    }),
    {noreply, State}.

terminate(normal, _State) ->
    ok;
terminate(shutdown, _State) ->
    ok;
terminate({shutdown, _}, _State) ->
    ok;
terminate(_Reason, _State) ->
    %% TODO publish metaevent
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @private
%% Adds an entry to the registry.
%%
%% Adding an already existing entry is treated differently based on whether the
%% entry is a registration or a subscription.
%%
%% According to the WAMP specification, in the case of a subscription that was
%% already added before by the same _Subscriber_, the _Broker_ should not fail
%% and answer with a "SUBSCRIBED" message, containing the existing
%% "Subscription|id". So in this case this function returns
%% {ok, entry(), boolean()}.
%%
%% In case of a registration, as a default, only a single Callee may
%% register a procedure for an URI. However, when shared registrations are
%% supported, then the first Callee to register a procedure for a particular URI
%% MAY determine that additional registrations for this URI are allowed, and
%% what Invocation Rules to apply in case such additional registrations are
%% made.
%%
%% This is configured through the 'invoke' options.
%% When invoke is not 'single', Dealer MUST fail all subsequent attempts to
%% register a procedure for the URI where the value for the invoke option does
%% not match that of the initial registration. Accordingly this function might
%% return an error tuple.
%%
%% IMPORTANT: This function must be safe to call by
%% bondy_registry_partition instances. As a result it MUST NEVER make a call to
%% bondy_registry_partition itself.
%% -----------------------------------------------------------------------------
maybe_add(registration, RealmUri, Uri, Opts, Ref, Partition) ->
    case bondy_ref:target_type(Ref) of
        callback ->
            add_callback_registration(RealmUri, Uri, Opts, Ref, Partition);
        _ ->
            maybe_add_registration(RealmUri, Uri, Opts, Ref, Partition)
    end;
maybe_add(subscription = Type, RealmUri, Uri, Opts, Ref, Partition) ->
    SessionId = bondy_ref:session_id(Ref),
    MP = maps:get(match, Opts, ?EXACT_MATCH),

    Fun = fun({_, E} = KV, Acc) ->
        %% It is valid for a subscriber to subscribe to both
        %% {foo, exact} and {foo, prefix}.
        Matches =
            Uri == bondy_registry_entry:uri(E) andalso
                MP == bondy_registry_entry:match_policy(E),

        case Matches of
            false ->
                %% We continue
                Acc;
            true when SessionId == undefined ->
                NewAcc = [KV | Acc],

                %% Internal process subscribing w/o session, we check it is not
                %% the same process reference
                Ref =/= bondy_registry_entry:ref(E) orelse
                    throw({break, NewAcc}),
                NewAcc;
            true ->
                throw({break, [KV | Acc]})
        end
    end,

    Acc = [],
    KeyPattern = bondy_registry_entry:key_pattern(RealmUri, SessionId, '_'),
    FoldOpts = [
        {match, KeyPattern},
        {remove_tombstones, true},
        %% TODO maybe use FWW and check node (ActorID)?
        {resolver, lww}
    ],
    FoldResult = bondy_registry_partition:fold(
        Partition, Type, RealmUri, Fun, Acc, FoldOpts
    ),

    case FoldResult of
        [] ->
            %% No matching subscriptions for this SessionId exists
            RegId = subscription_id(RealmUri, Opts),
            Entry = bondy_registry_entry:new(
                Type, RegId, RealmUri, Ref, Uri, Opts
            ),
            bondy_registry_partition:add(Partition, Entry);
        [{_EntryKey, Entry}] ->
            %% In case of receiving a "SUBSCRIBE" message from the same
            %% _Subscriber_ and to already added topic, _Broker_ should
            %% answer with "SUBSCRIBED" message, containing the existing
            %% "Subscription|id".
            %% {ok, Entry} = bondy_registry_partition:lookup(
            %%     Partition, Type, EntryKey
            %% ),

            {error, {already_exists, Entry}}
    end.

%% -----------------------------------------------------------------------------
%% @private
%% IMPORTANT: This function must be safe to call by
%% bondy_registry_partition instances. As a result it MUST NEVER make a call to
%% bondy_registry_partition itself.
%% -----------------------------------------------------------------------------
add_callback_registration(RealmUri, Uri, Opts0, Ref, Partition) ->
    {callback, MF} = bondy_ref:target(Ref),
    Args = maps:get(callback_args, Opts0, []),

    case bondy_wamp_callback:validate_target(MF, Args) of
        true ->
            Opts1 = maps:without([callback_args], Opts0),
            %% In the case of callbacks we do not allow shared
            %% registrations.
            %% This means we cannot have multiple registrations for the
            %% same URI associated to the same Target.
            Opts = Opts1#{
                invoke => ?INVOKE_SINGLE,
                callback_args => Args
            },
            maybe_add_registration(RealmUri, Uri, Opts, Ref, Partition);
        false ->
            {error, {invalid_callback, erlang:append_element(MF, Args)}}
    end.

%% -----------------------------------------------------------------------------
%% @private
%% IMPORTANT: This function must be safe to call by
%% bondy_registry_partition instances. As a result it MUST NEVER make a call to
%% bondy_registry_partition itself.
%% -----------------------------------------------------------------------------
maybe_add_registration(RealmUri, Uri, Opts, Ref, Partition) ->
    Invoke = maps:get(invoke, Opts, ?INVOKE_SINGLE),
    Shared = maps:get(shared_registration, Opts, false),
    Match = maps:get(match, Opts, ?EXACT_MATCH),
    PBR = bondy_config:get([wamp, dealer, features, pattern_based_registration]),

    try
        Match =/= ?EXACT_MATCH andalso PBR == false andalso
            throw(pattern_based_registration_disabled),

        Invoke == ?INVOKE_SINGLE orelse Shared == true orelse
            throw(shared_registration_disabled),

        add_registration(RealmUri, Uri, Opts, Ref, Partition)
    catch
        throw:Reason ->
            {error, Reason}
    end.

%% -----------------------------------------------------------------------------
%% @private
%% IMPORTANT: This function must be safe to call by
%% bondy_registry_partition instances. As a result it MUST NEVER make a call to
%% bondy_registry_partition itself.
%% -----------------------------------------------------------------------------
add_registration(RealmUri, Uri, Opts, Ref, Partition) ->
    Type = registration,
    MatchOpts = #{
        match => maps:get(match, Opts, ?EXACT_MATCH),
        invoke => '_'
    },
    MatchResult = bondy_registry_partition:match(
        Partition, Type, RealmUri, Uri, MatchOpts
    ),

    case MatchResult of
        [] ->
            %% No existing registrations for this URI
            Entry = new_registration(RealmUri, Ref, Uri, Opts),
            bondy_registry_partition:add(Partition, Entry);
        L ->
            %% Shared Registration (RFC 13.3.9)
            %% When shared registrations are supported, then the first
            %% Callee to register a procedure for a particular URI
            %% MAY determine that additional registrations for this URI
            %% are allowed, and what Invocation Rules to apply in case
            %% such additional registrations are made.
            %% When invoke is not 'single', Dealer MUST fail
            %% all subsequent attempts to register a procedure for the
            %% URI where the value for the invoke option does not match
            %% that of the initial registration.

            SessionId = bondy_ref:session_id(Ref),
            Invoke = maps:get(invoke, Opts, ?INVOKE_SINGLE),

            %% TODO extract this so that it is implemented as a function that
            %% the dealer will send.

            case resolve_inconsistencies(Invoke, SessionId, L) of
                ok ->
                    Entry = new_registration(RealmUri, Ref, Uri, Opts),
                    bondy_registry_partition:add(Partition, Entry);
                {error, {already_exists, _}} = Error ->
                    Error
            end
    end.

%% -----------------------------------------------------------------------------
%% @private
%% We might have inconsistencies that might have occurred during a net
%% split.
%%
%% There are two cases:
%% 1. Multiple registrations w/invoke == single
%% 2. Multiple registrations with differring invoke strategies
%% -----------------------------------------------------------------------------
-spec resolve_inconsistencies(
    Invoke :: binary(),
    SessionId :: optional(bondy_session_id:t()),
    [bondy_registry_entry:entry()]
) -> ok | {error, any()}.

resolve_inconsistencies(_, _, []) ->
    ok;
resolve_inconsistencies(Invoke, SessionId, L) ->
    Groups = bondy_utils:groups_from_list(
        fun(Entry) -> bondy_registry_entry:invocation_policy(Entry) end,
        L
    ),
    resolve_inconsistencies(Invoke, SessionId, L, Groups, maps:keys(Groups)).

%% @private
resolve_inconsistencies(_, _, _, Groups, [H]) when H == ?INVOKE_SINGLE ->
    case maps:get(H, Groups) of
        [Match] ->
            %% Result is 'ok' iff entry is missing from main store
            %% (due to inconsistency). Otherwise is the already_exists
            %% error.
            resolve_existing(registration, Match);
        Matches ->
            %% Multiple registrations w/invoke == single
            %% We need to revoke all but the first one registered, so we sort
            Sorted = sort_registration_matches(Matches),

            %% Result is 'ok' iff all entries are missing from main store
            %% (due to inconsistency). Otherwise is the already_exists
            %% error with the first entry alive.
            resolve_duplicates(Sorted)
    end;
resolve_inconsistencies(Invoke, SessionId, _, Groups, [H]) when H == Invoke ->
    %% The registrations are consistent (all using the same invocation
    %% policy). However, we still need to check for duplicates within
    %% the same session.
    Dups = find_registration_duplicates(maps:get(Invoke, Groups), SessionId),
    resolve_duplicates(Dups);
resolve_inconsistencies(_, _, L, _, [_]) ->
    %% The caller is trying to register using an invocation policy
    %% that does not match the one being used so far for this procedure.
    %% We test each one to discard an inconsistency between trie and
    %% main store.
    %% Normally we will get {error, {already_exists, Entry}} where
    %% Entry is the first element in L.
    Sorted = sort_registration_matches(L),
    resolve_existing(registration, Sorted);
resolve_inconsistencies(_, _, L, _, [_ | _]) ->
    %% The worse case: 2 or more groups.
    Sorted = sort_registration_matches(L),

    case resolve_existing(registration, Sorted) of
        ok ->
            ok;
        {error, {already_exists, _Entry}} = Error ->
            %% TODO if we have INVOKE_SINGLE, we need to
            %% revoke all other registrations.
            %% if other policy, revoke all registrations for other
            %% policies
            Error
    end.

%% -----------------------------------------------------------------------------
%% @private
%% Sort registration `proc()' index entries by time
%% -----------------------------------------------------------------------------
-spec sort_registration_matches(
    [bondy_registration_partition:reg_match()]
) ->
    [bondy_registration_partition:reg_match()].

sort_registration_matches(L) ->
    lists:sort(
        fun(A, B) ->
            bondy_registry_entry:created(A) =< bondy_registry_entry:created(B)
        end,
        L
    ).

%% @private
-spec find_registration_duplicates(
    Triples :: [bondy_registration_partition:reg_match()],
    SessionId :: bondy_session_id:t()
) -> Duplicates :: [bondy_registration_partition:reg_match()].

find_registration_duplicates([], _) ->
    [];
find_registration_duplicates(_, undefined) ->
    %% Undefined is used for internal callees and we allow duplicates
    [];
find_registration_duplicates(Entries, SessionId) ->
    %% Proxy entries can have duplicates, this is
    %% because the handler (proxy) is registering
    %% the entries for multiple remote handlers,
    %% so we filter them out
    [
        Entry
     || Entry <- Entries,
        false == bondy_registry_entry:is_proxy(Entry),
        SessionId == bondy_registry_entry:session_id(Entry)
    ].

%% @private
revoke(_) ->
    %% TODO
    ok.

%% @private
-spec resolve_duplicates([bondy_registration_partition:reg_match()]) ->
    ok | {error, {already_exists, entry()}}.

resolve_duplicates([H | T]) ->
    case resolve_existing(registration, H) of
        ok ->
            %% This means we had an inconsistency between the indices
            %% and the main store and the entry doesn't exist, so we try with
            %% the next
            resolve_duplicates(T);
        {error, {already_exists, _}} = Error ->
            %% H is active and earlieast registered single, we need to revoke
            %% all others.
            ok = revoke(T),
            Error
    end;
resolve_duplicates([]) ->
    %% No duplicates or all the entries were inconsistent (indices vs plum_db).
    ok.

%% @private
-spec resolve_existing(
    entry_type(),
    bondy_registration_partition:reg_match()
    | [bondy_registration_partition:reg_match()]
) -> ok | {error, {already_exists, entry()}}.

resolve_existing(_, []) ->
    ok;
resolve_existing(Type, [H | T]) ->
    case resolve_existing(Type, H) of
        ok ->
            resolve_existing(Type, T);
        Error ->
            Error
    end;
resolve_existing(_Type, Entry) ->
    case bondy_registry_entry:is_alive(Entry) of
        true ->
            {error, {already_exists, Entry}};
        false ->
            %% It will be eventually pruned, so ignore
            ok
    end.

%% @private
new_registration(RealmUri, Ref, Uri, Opts) ->
    RegId = registration_id(RealmUri, Opts),
    bondy_registry_entry:new(
        registration, RegId, RealmUri, Ref, Uri, Opts
    ).

%% @private
registration_id(_, #{registration_id := Val}) ->
    Val;
registration_id(RealmUri, _) ->
    bondy_message_id:router(RealmUri).

%% @private
subscription_id(_, #{subscription_id := Val}) ->
    Val;
subscription_id(Uri, _) ->
    bondy_message_id:router(Uri).

%% @private
do_match(?EOT) ->
    ?EOT;
do_match(Cont) ->
    bondy_registry_partition:find_matches(Cont).

%% @private
do_match(Type, RealmUri, Uri, Opts0) ->
    Partition = pick_partition(RealmUri),
    Opts = Opts0#{sort => bondy_registry_entry:mg_comparator()},
    bondy_registry_partition:match(Partition, Type, RealmUri, Uri, Opts).

%% @private
do_find_matches(?EOT) ->
    ?EOT;
do_find_matches(Cont) ->
    bondy_registry_partition:find_matches(Cont).

%% @private
do_find_matches(Type, RealmUri, Uri, Opts0) ->
    Partition = pick_partition(RealmUri),
    Opts = Opts0#{sort => bondy_registry_entry:mg_comparator()},
    bondy_registry_partition:find_matches(Partition, Type, RealmUri, Uri, Opts).

%% @private
%% Rebuilds the in-memory match indices (trie / ETS) from the durable
%% (ephemeral, in-RAM) bondy_db store, per realm, sweeping any stale entry left
%% by a previous incarnation of THIS node (same nodestring, created before this
%% boot). With the registry on a memory topology and AAE off, a fresh node boot
%% finds an empty store — nothing survives a restart — so this only does real
%% work on a registry-process restart while bondy_db stays up.
init_indices(State) ->
    ?LOG_NOTICE(#{
        description =>
            "Rebuilding in-memory registry indices from the bondy_db store."
    }),

    Now = State#state.start_ts,
    Node = bondy_config:nodestring(),

    try
        ok = rebuild_indices(registration, Now, Node),
        ok = rebuild_indices(subscription, Now, Node)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description =>
                    "Error while initialising registry from bondy_db",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.

%% @private
rebuild_indices(Type, Now, Node) ->
    case bondy_namespace_catalog:table(registry_table_name(Type)) of
        undefined ->
            %% Registry not provisioned (e.g. the catalogue is idle) — nothing
            %% to rebuild.
            ok;
        _Table ->
            _ = [
                rebuild_realm_indices(Type, RealmUri, Now, Node)
             || Realm <- bondy_realm:list(),
                (RealmUri = bondy_realm:uri(Realm)) =/= undefined
            ],
            ok
    end.

%% @private
%% Enumeration goes through the store so it reads whichever entry backend
%% the store runs on (bondy_db, or partition-local ETS under RIB `write`
%% mode).
rebuild_realm_indices(Type, RealmUri, Now, Node) ->
    Partition = pick_partition(RealmUri),
    case bondy_registry_partition:store(Partition) of
        undefined ->
            ok;
        Store ->
            bondy_registry_store:foreach(
                Store,
                Type,
                RealmUri,
                fun({_Key, Entry}) ->
                    maybe_restore_index(Partition, Entry, Now, Node)
                end,
                []
            )
    end.

%% @private
maybe_restore_index(Partition, Entry, Now, Node) ->
    EntryNode = bondy_registry_entry:nodestring(Entry),
    Created = bondy_registry_entry:created(Entry),

    %% IMPORTANT We assume nodes keep their names forever.
    case Node == EntryNode andalso Created < Now of
        true ->
            %% A stale entry from a previous incarnation of this node — it
            %% should have been deleted on crash/shutdown.
            ?LOG_DEBUG(#{
                description => "Removing stale registry entry",
                entry => Entry
            }),
            _ = bondy_registry_partition:remove(Partition, Entry),
            ok;
        false ->
            _ = bondy_registry_partition:add_indices(Partition, Entry),
            ok
    end.

%% @private
registry_table_name(registration) -> ?BONDY_DB_REGISTRATION_TAB;
registry_table_name(subscription) -> ?BONDY_DB_SUBSCRIPTION_TAB.

%% @private
maybe_fun(undefined, _) ->
    undefined;
maybe_fun(Fun, _) when is_function(Fun, 1) ->
    Fun;
maybe_fun(Fun, Ctxt) when is_function(Fun, 2) ->
    fun(Entry) -> Fun(Entry, Ctxt) end.

%% @private
maybe_execute(undefined, _) ->
    ok;
maybe_execute(Fun, Entry) when is_function(Fun, 1) ->
    try
        _ = Fun(Entry),
        ok
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while executing user function",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

%% @private
do_remove_all(Matches, SessionId, Fun, Opts) ->
    do_remove_all(Matches, SessionId, Fun, Opts, []).

%% @private
do_remove_all(?EOT, _, Fun, _Opts, Acc) ->
    _ = [maybe_execute(Fun, Entry) || Entry <- Acc],
    ok;
do_remove_all({[], ?EOT}, _, Fun, _Opts, Acc) ->
    _ = [maybe_execute(Fun, Entry) || Entry <- Acc],
    ok;
do_remove_all({[], Cont}, SessionId, Fun, Opts, Acc) ->
    %% We apply the Fun here as opposed to in every iteration to minimise art
    %% trie concurrency access,
    _ = [maybe_execute(Fun, Entry) || Entry <- Acc],
    Res = bondy_registry_partition:find(Cont),
    do_remove_all(Res, SessionId, Fun, Opts, Acc);
do_remove_all({[{_EntryKey, Entry} | T], Cont}, SessionId, Fun, Opts, Acc) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Session = bondy_registry_entry:session_id(Entry),

    case SessionId =:= Session orelse SessionId == '_' of
        true ->
            %% Delete the entry from the bondy_db store and its in-memory
            %% indices (cross-node convergence rides AAE, design D-3).
            ok = bondy_registry_partition:remove(
                pick_partition(RealmUri), Entry, Opts
            ),
            %% We continue traversing
            do_remove_all({T, Cont}, SessionId, Fun, Opts, [Entry | Acc]);
        false ->
            %% No longer our session
            ok
    end.

%% @private
%% Presence SUSPEND (§9.6): mask every entry owned by a now-disconnected node so
%% it is no longer selectable for routing, while retaining it for a possible
%% RESUME. Runs off the registry server (see run_remote_task/2).
suspend(Node) ->
    run_remote_task(Node, fun(Partition, Entry) ->
        _ = bondy_registry_partition:mask(Partition, Entry),
        ok
    end).

%% @private
%% Presence RESUME (§9.6): unmask a reconnected node's entries back into the
%% routing trie. Entries the node has since shed (owner self-clean) are no longer
%% in this node's projection, so the per-entry lookup skips them.
resume(Node) ->
    run_remote_task(Node, fun(Partition, Entry) ->
        _ = bondy_registry_partition:unmask(Partition, Entry),
        ok
    end).

%% @private
%% Presence EVICT (§9.6): the grace period elapsed. If the node is still gone and
%% this node is its rendezvous-hashed cleanup peer, replicate a `clear` for each
%% of its entries — the clear converges cluster-wide and every node's merge
%% reactor drops it from its trie.
maybe_evict(Node) ->
    case partisan:is_connected(Node) of
        true ->
            %% Reconnected between the timer firing and now; nodeup handled it.
            ok;
        false ->
            case is_evict_owner(Node) of
                true ->
                    run_remote_task(Node, fun(Partition, Entry) ->
                        Type = bondy_registry_entry:type(Entry),
                        _ = bondy_registry_partition:remove(Partition, Entry),
                        maybe_flush_callee_promises(Type, Entry)
                    end);
                false ->
                    ok
            end
    end.

%% @private
%% Rendezvous hashing (LRW): the surviving node with the highest weight for the
%% departed node is its single cleanup peer, so the EVICT `clear`s are issued
%% once cluster-wide rather than once per surviving node. Self is in the
%% candidate set.
is_evict_owner(Node) ->
    Self = partisan:node(),
    case lrw:top(Node, [Self | partisan:nodes()], 1) of
        [Self] ->
            true;
        _ ->
            false
    end.

%% @private
%% Cancel a node's pending EVICT timer (it reconnected within the grace period).
cancel_evict(Node, #state{timers = Timers} = State) ->
    case maps:take(Node, Timers) of
        {Tref, Timers1} ->
            _ = erlang:cancel_timer(Tref),
            State#state{timers = Timers1};
        error ->
            State
    end.

%% @private
%% Walk a node's remote entries (enumerated via the per-node remote index) and
%% apply `EntryFun(Partition, Entry)` to each, resolving the full entry from its
%% realm partition. Runs in a spawned process so a large membership transition
%% does not block the registry server; the per-entry index ops are process-safe.
run_remote_task(Node, EntryFun) ->
    _ = erlang:spawn(fun() -> foreach_remote_entry(Node, EntryFun) end),
    ok.

%% @private
%% Apply `EntryFun(Partition, Entry)` to each entry owned by `Node`. The set of a
%% node's entries is taken from the AAE reactor's tombstone table (every peer
%% registration this node merged is recorded there), which is the reliable
%% by-owner source — the registry's per-node index is not populated for
%% AAE-merged entries.
foreach_remote_entry(Node, EntryFun) ->
    lists:foreach(
        fun(Entry) ->
            Partition = pick_partition(Entry),
            EntryFun(Partition, Entry)
        end,
        bondy_aae_reactor:remote_entries_of(Node)
    ).

%% @private
%% Owner self-cleanup invariant (§9.6.1): DELETE this node's own registry entries
%% whose session is no longer live. On a clean reboot the ephemeral projection
%% starts empty and AAE pulls this node's pre-restart entries back; none has a
%% live session, so they are cleared — which is what stops a peer from RESUMEing
%% dead registrations. A `clear` replicates, so peers drop them via the merge
%% reactor. Returns the number of entries cleaned (drives the sweep cadence).
self_clean() ->
    lists:foldl(
        fun(Realm, Acc) ->
            RealmUri = bondy_realm:uri(Realm),
            Acc +
                self_clean_table(
                    ?BONDY_DB_REGISTRATION_TAB, registration, RealmUri
                ) +
                self_clean_table(
                    ?BONDY_DB_SUBSCRIPTION_TAB, subscription, RealmUri
                )
        end,
        0,
        bondy_realm:list()
    ).

%% @private
self_clean_table(TabName, Type, RealmUri) ->
    case bondy_namespace_catalog:table(TabName) of
        undefined ->
            0;
        Table ->
            case bondy_db:list(Table, RealmUri) of
                {ok, Rows} ->
                    lists:foldl(
                        fun(Row, Acc) ->
                            Acc + maybe_self_clean(Type, RealmUri, Row)
                        end,
                        0,
                        Rows
                    );
                {error, _} ->
                    0
            end
    end.

%% @private
maybe_self_clean(Type, RealmUri, {_Key, #{entry := Entry}, _Hlc}) ->
    case bondy_registry_entry:is_local(Entry) andalso is_stale_session(Entry) of
        true ->
            Partition = pick_partition(RealmUri),
            _ = bondy_registry_partition:remove(Partition, Entry),
            _ = maybe_flush_callee_promises(Type, Entry),
            1;
        false ->
            0
    end;
maybe_self_clean(_Type, _RealmUri, _Row) ->
    0.

%% @private
%% A session-bound entry whose session is gone is stale. An entry with no session
%% (a callback / internal handler) is tied to node lifecycle, not a session, so it
%% is left for clean shutdown to remove.
is_stale_session(Entry) ->
    case bondy_registry_entry:session_id(Entry) of
        undefined ->
            false;
        SessionId ->
            bondy_session:lookup(SessionId) =:= {error, not_found}
    end.

%% @private
%% Runs the RIB consistency check for every realm, logs each divergent one
%% (realm, divergence count and a bounded sample) and gauges the node-wide
%% total.
rib_check() ->
    Total = lists:foldl(
        fun(Realm, Acc) ->
            RealmUri = bondy_realm:uri(Realm),
            case bondy_registry_rib:check(RealmUri) of
                [] ->
                    Acc;
                Divergences ->
                    ?LOG_WARNING(#{
                        description =>
                            "Registry RIB summaries diverge from "
                            "the ground truth for realm",
                        realm_uri => RealmUri,
                        count => length(Divergences),
                        sample => lists:sublist(Divergences, 3)
                    }),
                    Acc + length(Divergences)
            end
        end,
        0,
        bondy_realm:list()
    ),
    registry_metric(gauge, #{
        name => bondy_registry_rib_divergences, value => Total
    }).

%% @private
%% The number of currently SUSPENDed peers is exactly the number of armed
%% EVICT timers, so the gauge is set absolutely from the timers map after
%% every presence transition.
gauge_suspended(#state{timers = Timers}) ->
    registry_metric(gauge, #{
        name => bondy_registry_presence_suspended_nodes,
        value => map_size(Timers)
    }).

%% @private
observe_presence(Op, T0) ->
    registry_metric(histogram, #{
        name => bondy_registry_presence_mask_duration_ms,
        label => #{op => Op},
        value => erlang:monotonic_time(millisecond) - T0
    }).

%% @private
%% Record a metric without ever raising — nothing here may take the
%% registry server down.
registry_metric(Type, Spec) ->
    try
        case Type of
            gauge -> bondy_metrics:gauge(Spec);
            histogram -> bondy_metrics:histogram(Spec)
        end
    catch
        _:_ ->
            ok
    end.

%% @private
%% Arms the next RIB consistency sweep. `registry.rib.check_interval`
%% (default 5 min); `0` disables the sweep.
schedule_rib_check() ->
    case rib_check_interval_ms() of
        0 ->
            ok;
        Interval when is_integer(Interval), Interval > 0 ->
            _ = erlang:send_after(Interval, self(), rib_check),
            ok
    end.

%% @private
rib_check_interval_ms() ->
    application:get_env(
        bondy_router, registry_rib_check_interval, timer:minutes(5)
    ).

%% @private
%% Grace before a departed node's entries are EVICTed (default 24h). A node that
%% reconnects within the grace RESUMEs instead.
evict_grace_ms() ->
    application:get_env(
        bondy_router, registry_presence_evict_after, timer:hours(24)
    ).

%% @private
%% Delay from boot to the first owner self-cleanup sweep, giving AAE time to pull
%% this node's pre-restart entries back.
self_clean_boot_ms() ->
    application:get_env(
        bondy_router, registry_presence_self_clean_boot, timer:seconds(5)
    ).

%% @private
%% Cadence of the owner self-cleanup sweep: while a sweep is still shedding stale
%% entries (a node that just rebooted is converging) keep it tight; once a sweep
%% finds nothing, fall back to the steady safety-net interval (default 5 min).
self_clean_next_ms(Cleaned) when Cleaned > 0 ->
    timer:seconds(5);
self_clean_next_ms(_) ->
    application:get_env(
        bondy_router, registry_presence_self_clean_interval, timer:minutes(5)
    ).

%% @private
-doc """
Fast-fails in-flight callers whose callee was on the pruned
node's registration, so they don't wait for the call timeout.
Subscriptions have no promise table to reap.
""".
maybe_flush_callee_promises(registration, Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Ref = bondy_registry_entry:ref(Entry),
    bondy_dealer:flush_callee_promises(RealmUri, Ref);
maybe_flush_callee_promises(_, _) ->
    ok.

sort(_, ?EOT) ->
    ?EOT;
sort(registration, L) when is_list(L) ->
    lists:sort(bondy_registry_entry:mg_comparator(), L);
sort(registration, {L, C}) when is_list(L) ->
    {lists:sort(bondy_registry_entry:mg_comparator(), L), C};
sort(subscription, Term) ->
    Term.
