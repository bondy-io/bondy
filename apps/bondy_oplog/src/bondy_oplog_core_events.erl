%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_core_events).

-behaviour(gen_server).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Lightweight intra-node pub/sub for substrate lifecycle events.

The substrate's `bondy_oplog_core_registry` and `bondy_oplog_core_dispatcher`
gen_servers each own an in-memory ETS table whose lifetime is tied to
the process. If they crash and the supervisor restarts them, the table
is wiped and any prior `register/4` or `subscribe/2` calls are lost.
Without a signal, owners (registered shard-managing processes) and
subscribers (event consumers) have no way to detect the loss.

This module is the missing signal. Each substrate gen_server `notify/2`s
on its own `init/1`, sending a `{bondy_oplog_core_event, Topic, Payload}`
message to every process subscribed to the topic. Consumers register
once at startup, receive the message after every (re)start, and re-arm
their state (re-register, re-subscribe, refresh cached `epoch`s).

## Topics

| Topic                            | Payload                | When emitted                       |
|---|---|---|
| `bondy_oplog_core_registry_started`  | `Epoch :: reference()` | `bondy_oplog_core_registry` init       |
| `bondy_oplog_core_dispatcher_started`| `Epoch :: reference()` | `bondy_oplog_core_dispatcher` init     |

The `Epoch` is a fresh `make_ref/0` each time the originating gen_server
starts. It is monotonic (a later epoch is never `=:=` an earlier one).
Consumers cache the epoch alongside their cached refs and treat a new
epoch as a discontinuity.

## Owner pattern

```erlang
owner_init(NS, Idx, Shard, Config) ->
    ok = bondy_oplog_core_events:subscribe(bondy_oplog_core_registry_started),
    ok = re_register(NS, Idx, Shard, Config),
    {NS, Idx, Shard, Config}.

owner_loop(State = {NS, Idx, Shard, Config}) ->
    receive
        {bondy_oplog_core_event, bondy_oplog_core_registry_started, _Epoch} ->
            ok = re_register(NS, Idx, Shard, Config),
            owner_loop(State);
        ...
    end.

re_register(NS, Idx, Shard, Config) ->
    bondy_oplog_core_registry:register(NS, Idx, Shard, Config).
```

## Subscriber pattern (dispatcher)

```erlang
subscriber_init(NS, Pattern) ->
    ok = bondy_oplog_core_events:subscribe(bondy_oplog_core_dispatcher_started),
    {ok, Ref} = bondy_oplog_core:subscribe(NS, Pattern),
    {NS, Pattern, Ref}.

subscriber_loop({NS, Pattern, _OldRef} = State) ->
    receive
        {bondy_oplog_core_event, bondy_oplog_core_dispatcher_started, _Epoch} ->
            {ok, NewRef} = bondy_oplog_core:subscribe(NS, Pattern),
            subscriber_loop({NS, Pattern, NewRef});
        ...
    end.
```

## Restart semantics

The events module itself is a gen_server. If it dies, its subscription
table dies — silently — and consumers' subscriptions are gone with it.
The pattern terminates at this module: it does *not* notify of its own
restart. Operators should set the supervisor's `intensity` so this
module effectively never restarts; it is small and has no side-effects,
so the operational cost is minimal.

The events module starts before `bondy_oplog_core_registry` and
`bondy_oplog_core_dispatcher` in `bondy_oplog_sup` so the substrate
modules can notify on their first init.
""").

-define(SERVER, ?MODULE).
-define(TAB, bondy_oplog_core_events_tab).

-record(state, {}).

-record(sub, {
    %% `{Topic, Pid}` as the key keeps lookups O(1) per (topic, subscriber).
    key :: {topic(), pid()},
    monitor :: reference()
}).

-type topic() :: atom().
-type payload() :: term().

-export_type([topic/0, payload/0]).

-export([child_spec/0]).
-export([start_link/0]).

-export([subscribe/1]).
-export([unsubscribe/1]).
-export([notify/2]).
-export([topics/0]).
-export([subscribers/1]).

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

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

?DOC("""
Subscribe the calling process to `Topic`. Idempotent: subscribing twice
from the same process leaves a single subscription in place.
""").
-spec subscribe(topic()) -> ok.

subscribe(Topic) when is_atom(Topic) ->
    gen_server:call(?SERVER, {subscribe, Topic, self()}).

?DOC("""
Drop the calling process's subscription to `Topic`. Idempotent: removing
an absent subscription is a no-op.
""").
-spec unsubscribe(topic()) -> ok.

unsubscribe(Topic) when is_atom(Topic) ->
    gen_server:call(?SERVER, {unsubscribe, Topic, self()}).

?DOC("""
Broadcast `Payload` to every process subscribed to `Topic`. Each
subscriber receives `{bondy_oplog_core_event, Topic, Payload}` via the
bare send operator. Returns `ok` whether or not any subscriber matched.

The walk runs in the caller's process — no gen_server round-trip — so
the notify path stays out of the events module's own mailbox.
""").
-spec notify(topic(), payload()) -> ok.

notify(Topic, Payload) when is_atom(Topic) ->
    Msg = {bondy_oplog_core_event, Topic, Payload},
    Subs = ets:select(
        ?TAB,
        [{#sub{key = {Topic, '$1'}, _ = '_'}, [], ['$1']}]
    ),
    lists:foreach(fun(Pid) -> Pid ! Msg end, Subs),
    ok.

?DOC("""
List every topic that has at least one subscriber. Intended for
diagnostics.
""").
-spec topics() -> [topic()].

topics() ->
    MS = [{#sub{key = {'$1', '_'}, _ = '_'}, [], ['$1']}],
    lists:usort(ets:select(?TAB, MS)).

?DOC("""
Return the subscribers for a topic. Intended for diagnostics and tests.
""").
-spec subscribers(topic()) -> [pid()].

subscribers(Topic) when is_atom(Topic) ->
    ets:select(?TAB, [{#sub{key = {Topic, '$1'}, _ = '_'}, [], ['$1']}]).

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([]) ->
    _ = ets:new(?TAB, [
        set,
        public,
        named_table,
        {keypos, #sub.key},
        {read_concurrency, true}
    ]),
    {ok, #state{}}.

handle_call({subscribe, Topic, Pid}, _From, State) ->
    case ets:lookup(?TAB, {Topic, Pid}) of
        [#sub{}] ->
            %% Already subscribed; leave existing monitor in place.
            {reply, ok, State};
        [] ->
            Mon = erlang:monitor(process, Pid),
            true = ets:insert(?TAB, #sub{key = {Topic, Pid}, monitor = Mon}),
            {reply, ok, State}
    end;
handle_call({unsubscribe, Topic, Pid}, _From, State) ->
    case ets:lookup(?TAB, {Topic, Pid}) of
        [#sub{monitor = Mon}] ->
            true = erlang:demonitor(Mon, [flush]),
            true = ets:delete(?TAB, {Topic, Pid});
        [] ->
            ok
    end,
    {reply, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Mon, process, _Pid, _Reason}, State) ->
    %% Drop every row whose monitor matches; a single process can be
    %% subscribed to multiple topics, but each subscription holds its
    %% own monitor — so this only removes one row in practice.
    _ = ets:select_delete(
        ?TAB,
        [{#sub{monitor = Mon, _ = '_'}, [], [true]}]
    ),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.
