%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_core_dispatcher).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Reference subscription dispatcher for `bondy_oplog_core:subscribe/2`.

Subscriptions are local-only (do not cross nodes). The dispatcher owns
a `public set` ETS table of `(SubRef, Namespace, Pid, MonitorRef,
Pattern)` rows. The gen_server only handles subscription churn and
`DOWN` cleanup; the publish hot path is a pure `ets:select/2` walk
followed by `erlang:send/2` to matching subscribers — no round-trip,
no contention with subscribers.

## Table

```erlang
ets:new(bondy_oplog_core_dispatcher_tab, [
    set,
    public,
    named_table,
    {keypos, #sub.ref},
    {read_concurrency, true}
])
```

## Patterns

| Pattern                 | Matches                                                     |
|-------------------------|-------------------------------------------------------------|
| `all`                   | every event                                                 |
| `{prefix, P}` (binary)  | binary keys with `P` as a prefix                            |
| `{prefix, P}` (list)    | list keys with `P` as a prefix                              |
| `{match, F}`            | keys for which `F(Key)` returns `true`                      |
| `{exact, T}`            | keys equal to `T`                                           |

Exact-key subscriptions use `{exact, T}`. Bare terms are not accepted —
the pattern type is closed so dialyzer can verify subscribers at
compile time.

## Message shape

Subscribers receive one of

```erlang
{bondy_oplog_core_event,       Namespace, Key, Hlc, Operation}       %% local write
{bondy_oplog_core_merge_event, Namespace, Key, Hlc, Operation, Old}  %% remote merge
```

The first is published by the applier for a **local** `bondy_db:apply/4`
write; the second by the replay path when **anti-entropy** merges a peer's
write into the local projection. Both carry the same `(Key, Operation)` so a
reactor can subscribe once and handle either tag.

Delivery uses the bare send operator (`Pid ! Msg`), which is local-only
best-effort and never blocks the publisher.

## Restart semantics

The ETS table is owned by this gen_server; if the gen_server dies the
table dies with it. On supervisor restart, `init/1` creates a fresh
empty table — **all in-memory subscriptions are silently lost**.
Subscribers receive no further events and have no way to detect the
loss; their `SubRef` becomes a dead reference.

There is no recovery protocol. Operators should either set the
supervisor's `intensity` so the dispatcher effectively never restarts,
or design subscribers to periodically validate liveness (e.g., a
heartbeat publish that exercises the subscription). The substrate
does not police this.
""").

-define(TABLE, bondy_oplog_core_dispatcher_tab).

-record(sub, {
    ref :: reference(),
    ns :: atom(),
    pid :: pid(),
    monitor :: reference(),
    pattern :: pattern()
}).

-record(state, {
    %% Fresh `make_ref()` per gen_server start. Exposed via
    %% `current_epoch/0` and broadcast on `bondy_oplog_core_events` under
    %% topic `bondy_oplog_core_dispatcher_started`. Subscribers cache the
    %% epoch and treat a change as "dispatcher was restarted; re-subscribe".
    epoch :: reference()
}).

-type pattern() ::
    all
    | {prefix, binary() | list()}
    | {match, fun((term()) -> boolean())}
    | {exact, term()}.

-export_type([pattern/0]).

-export([child_spec/0]).
-export([start_link/0]).

-export([subscribe/2]).
-export([unsubscribe/1]).
-export([publish/4]).
-export([publish_merge/5]).
-export([subscription_count/0]).
-export([subscription_count/1]).

%% Restart-recovery protocol.
-export([current_epoch/0]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% =============================================================================
%% API
%% =============================================================================

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec subscribe(atom(), pattern()) -> {ok, reference()}.

subscribe(NS, Pattern) when is_atom(NS) ->
    gen_server:call(?MODULE, {subscribe, NS, self(), Pattern}).

-spec unsubscribe(reference()) -> ok.

unsubscribe(Ref) when is_reference(Ref) ->
    gen_server:call(?MODULE, {unsubscribe, Ref}).

-doc """
Publish an event to every matching subscriber. Walk runs in the caller
process — no gen_server round-trip. Returns `ok` whether or not any
subscriber was matched.
""".
-spec publish(atom(), term(), bondy_oplog_hlc:hlc(), term()) -> ok.

publish(NS, Key, Hlc, Op) ->
    fanout({bondy_oplog_core_event, NS, Key, Hlc, Op}, NS, Key).

-doc """
Publish a **remote-merge** event to every matching subscriber: a cell whose
value changed on this node because anti-entropy merged a peer's write (not a
local `bondy_db:apply/4`). Node-local reactors that must react to a
peer-originated change (e.g. close a user's sessions when the user is deleted on
another node) subscribe and handle this message; purely local writes never
deliver it.

Subscribers receive `{bondy_oplog_core_merge_event, NS, Key, Hlc, Op, Old}` —
the same `(Key, Op)` shape as a local event plus the pre-merge cell value
(`Old`, `undefined` when the cell did not exist), so a reactor can diff what
the merge replaced.
""".
-spec publish_merge(
    NS :: atom(),
    Key :: term(),
    Hlc :: bondy_oplog_hlc:hlc(),
    Op :: term(),
    Old :: term() | undefined
) -> ok.

publish_merge(NS, Key, Hlc, Op, Old) ->
    fanout({bondy_oplog_core_merge_event, NS, Key, Hlc, Op, Old}, NS, Key).

%% @private
%% Shared publish hot path: select the namespace's subscriptions and send `Msg`
%% to those whose pattern matches `Key`. Runs in the caller process — no
%% gen_server round-trip, best-effort `Pid ! Msg`.
fanout(Msg, NS, Key) ->
    Subs = ets:select(?TABLE, [{#sub{ns = NS, _ = '_'}, [], ['$_']}]),
    lists:foreach(
        fun(#sub{pid = Pid, pattern = Pat}) ->
            case matches(Pat, Key) of
                true -> Pid ! Msg;
                false -> ok
            end
        end,
        Subs
    ),
    ok.

-spec subscription_count() -> non_neg_integer().

subscription_count() ->
    ets:info(?TABLE, size).

-doc """
Number of live subscriptions for the given namespace. The walk uses the
same match-spec as the per-publish select, so this is `O(table_size)`
in the worst case; intended for low-frequency callers (metrics tick).
""".
-spec subscription_count(atom()) -> non_neg_integer().

subscription_count(NS) when is_atom(NS) ->
    ets:select_count(
        ?TABLE,
        [{#sub{ns = NS, _ = '_'}, [], [true]}]
    ).

-doc """
Return the current epoch reference. A new epoch is allocated on each
gen_server start and broadcast on
`bondy_oplog_core_events:notify(bondy_oplog_core_dispatcher_started, Epoch)`.
Subscribers cache the epoch and treat any change as "dispatcher was
restarted; re-subscribe".
""".
-spec current_epoch() -> reference().

current_epoch() ->
    gen_server:call(?MODULE, current_epoch).

%% =============================================================================
%% Telemetry
%% =============================================================================

emit_subscribe_event(NS, Pattern) ->
    PatType = pattern_type(Pattern),
    Current = subscription_count(NS),
    telemetry:execute(
        [bondy_oplog_core, subscribe],
        #{},
        #{
            namespace => NS,
            pattern_type => PatType,
            current_subscribers => Current
        }
    ).

pattern_type(all) -> all;
pattern_type({prefix, _}) -> prefix;
pattern_type({match, _}) -> match;
pattern_type({exact, _}) -> exact;
pattern_type(_) -> unknown.

%% =============================================================================
%% Pattern matching
%% =============================================================================

matches(all, _Key) ->
    true;
matches({prefix, P}, Key) when is_binary(P), is_binary(Key) ->
    Sz = byte_size(P),
    byte_size(Key) >= Sz andalso binary:part(Key, 0, Sz) =:= P;
matches({prefix, P}, Key) when is_list(P), is_list(Key) ->
    lists:prefix(P, Key);
matches({prefix, _}, _Key) ->
    false;
matches({match, F}, Key) when is_function(F, 1) ->
    try F(Key) of
        true -> true;
        _ -> false
    catch
        _:_ -> false
    end;
matches({exact, T}, Key) ->
    Key =:= T;
matches(_, _) ->
    false.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([]) ->
    _ = ets:new(?TABLE, [
        set,
        public,
        named_table,
        {keypos, #sub.ref},
        {read_concurrency, true}
    ]),
    Epoch = erlang:make_ref(),
    self() ! {broadcast_started, Epoch},
    {ok, #state{epoch = Epoch}}.

handle_call({subscribe, NS, Pid, Pattern}, _From, State) ->
    Ref = erlang:make_ref(),
    Mon = erlang:monitor(process, Pid),
    Row = #sub{
        ref = Ref,
        ns = NS,
        pid = Pid,
        monitor = Mon,
        pattern = Pattern
    },
    true = ets:insert(?TABLE, Row),
    emit_subscribe_event(NS, Pattern),
    {reply, {ok, Ref}, State};
handle_call({unsubscribe, Ref}, _From, State) ->
    case ets:lookup(?TABLE, Ref) of
        [#sub{monitor = Mon}] ->
            true = erlang:demonitor(Mon, [flush]),
            true = ets:delete(?TABLE, Ref);
        [] ->
            ok
    end,
    {reply, ok, State};
handle_call(current_epoch, _From, #state{epoch = E} = State) ->
    {reply, E, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info({broadcast_started, Epoch}, State) ->
    try
        bondy_oplog_core_events:notify(
            bondy_oplog_core_dispatcher_started, Epoch
        )
    catch
        _:_ -> ok
    end,
    {noreply, State};
handle_info({'DOWN', Mon, process, _Pid, _Reason}, State) ->
    MS = [{#sub{monitor = Mon, _ = '_'}, [], [true]}],
    _ = ets:select_delete(?TABLE, MS),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.
