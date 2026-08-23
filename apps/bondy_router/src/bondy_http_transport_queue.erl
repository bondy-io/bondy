%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_transport_queue).
-moduledoc """
A bounded, ETS-based parking place for messages routed to a WAMP session whose
transport is HTTP long-poll or SSE.

## Why this exists

Every WAMP egress passes through one fork in `bondy:do_send/3`:

```
case maybe_enqueue(SessionKey, M, Opts) of
    true  -> ok;                                  % parked here
    false -> Pid ! request(self(), RealmUri, M)   % straight to the connection
end
```

`bondy:maybe_enqueue/3` takes the first branch only when
`bondy_session:transport_id/1` returns a binary, and that field is set in
exactly two places — `bondy_http_longpoll_handler` and `bondy_http_sse_handler`.
A WebSocket or raw-socket session leaves it `undefined` and never reaches this
module.

The asymmetry is structural, not incidental. A WebSocket or raw-socket session
has one process owning its socket from HELLO to GOODBYE, so "deliver" means
"send to that process" and the queue is that process's mailbox. The two HTTP
transports have no such process:

- **long-poll** — between `/receive` requests the client is not connected at
  all. A message routed to it in that gap has nowhere to go. Without somewhere
  to park it, it is dropped, and neither the router nor the client learns that
  it was.
- **SSE** — a stream process exists while the stream is open, but it can drop
  and reconnect while the SESSION survives. What the reconnected stream drains
  is this queue.

So this is what decouples session lifetime from connection lifetime. It is the
mechanism that lets a WAMP session outlive the HTTP request that is carrying it,
which is the whole premise of running WAMP over long-poll.

The second reason is bounding. A process mailbox has no bound, which is
tolerable when a live socket applies back-pressure — and is not tolerable for a
client that may simply never come back. A disconnected transport's backlog needs
a ceiling and a shelf life, which is what `max_messages`, `max_bytes` and
`message_ttl` are.

## Who wakes it

Enqueuing does not deliver anything by itself. `bondy:maybe_enqueue/3` calls
`bondy_http_transport_session:notify_enqueue/1` immediately afterwards, which
sends `queue_ready` to the session process. That process then either replies to
a parked `/receive`, or sends `drain_queue` to an attached SSE stream, or does
nothing at all — leaving the messages here until a client next asks. The third
case is the one this module exists for.

## What it is NOT

- Not the queue for WebSocket or raw-socket sessions. Those use the connection
  process mailbox, bounded by nothing this module configures.
- Not the router's ingress queue. `bondy_router_flow_sup`'s flow pool orders
  work coming IN, per WAMP flow, and sheds under its own capacity bound. A
  message passes through that pool once on ingress and arrives here only if its
  DESTINATION is an HTTP transport.
- Not one of two queues per session any more. `bondy_http_transport_session`
  used to keep the synchronous replies separately and drain them first; they
  come here now, so there is one order and one set of bounds.

## One queue

A transport's output has two producers: the router, through `bondy:do_send/3`,
and the protocol itself, which answers some inbound messages synchronously
(`bondy_wamp_protocol:handle_inbound/2` returning `{reply, Bins, _}` — an
inline ERROR, a throttle rejection). Both are output for the same client on
the same transport, so both come here.

They used to be separate: `bondy_http_transport_session` kept the synchronous
replies in a `reply_buffer` field and drained it BEFORE this queue. That made
the transport not a FIFO pipe — a reply produced later was delivered first —
and left that half unbounded, outside every limit below.

## Sharding

Transports are distributed across ETS partitions using
`bondy_consistent_hashing:bucket/2` (Jump Consistent Hash). All entries for a
given `TransportId` reside in the same ETS table, so per-transport operations
(`count`, `evict_oldest`, `dequeue_batch`) are partition-local.

## Key design

The ETS key is `{TransportId, Seq}` where `Seq` is generated via
`erlang:unique_integer([monotonic])`. Because ETS `ordered_set` sorts tuples
element-by-element, all entries for a transport form a contiguous range ordered
by insertion time.

## Bounding

Three layers, all configured under `wamp.http_transport.queue.*`:

1. **Message count** — on enqueue when `count >= max_messages`
2. **Byte size** — on enqueue when `bytes + msg_size > max_bytes`
3. **TTL expiry** — background sweep every `eviction_interval`

The first two evict the OLDEST entry for that transport to make room; there is
no configurable policy, because there is only one that makes sense for a stream
a client will read in order.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

%% Atomics slot indices
-define(COUNT_SLOT, 1).
-define(BYTES_SLOT, 2).
-define(LAST_DEQUEUE_SEQ_SLOT, 3).

%% Number of entries to evict per batch
-define(EVICTION_BATCH_SIZE, 100).

%% persistent_term key for the partition ring
-define(RING_KEY, {?MODULE, ring}).

%% persistent_term key for the meta table name
-define(META_TAB, bondy_http_transport_queue_meta).

-record(bondy_http_transport_queue_entry, {
    key :: bondy_http_transport_queue_key(),
    message :: queued(),
    enqueued_at :: pos_integer(),
    size_bytes :: non_neg_integer()
}).

-record(bondy_http_transport_queue_meta, {
    transport_id :: binary(),
    atomics :: atomics:atomics_ref(),
    realm_uri :: uri(),
    session_id :: bondy_session_id:t()
}).

-type bondy_http_transport_queue_key() :: {
    TransportId :: binary(), Seq :: integer()
}.
-type enqueue_opts() :: #{}.

-doc """
What a transport can hold for a client: a WAMP record the router delivered,
or a reply the protocol already encoded.

Both, because both are output for the same client on the same transport, and
splitting them across two structures is what let a reply produced LATER be
delivered FIRST. See the `One queue` section above.
""".
-type queued() :: wamp_message() | {encoded, binary()}.

-export_type([enqueue_opts/0]).
-export_type([queued/0]).

%% API
-export([init/0]).
-export([init_transport/3]).
-export([delete_transport/1]).
-export([enqueue/3]).
-export([dequeue_batch/2]).
-export([evict_expired_all/0]).
-export([count/1]).
-export([byte_size/1]).
-export([tables/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Initialises the sharded queue tables and the metadata table.

Creates `NumPartitions` anonymous ETS tables registered with
`bondy_table_manager` under `{?MODULE, partition, Bucket}` keys. The
tables are owned by `bondy_table_manager` so they survive the caller
(typically `bondy_http_transport_queue_manager`) crashing and being restarted
by its supervisor — in-flight queued messages are not lost.

The partition ring maps `Bucket -> ets:tid()` and is stored in
`persistent_term` for zero-cost lookup on the hot path.

Partitions are anonymous (no `named_table`) so that no atoms are allocated
per bucket — the table identifier is an opaque `ets:tid()`. The function
is idempotent: re-running it on a manager restart finds the existing
tables rather than recreating them.

This function must be called once at startup, typically from
`bondy_http_transport_queue_manager:init/1`.
""".
-spec init() -> ok.

init() ->
    NumPartitions = bondy_config:get(
        [http_transport, queue, partitions],
        erlang:system_info(schedulers)
    ),

    %% Sharded queue tables — anonymous, owned by bondy_table_manager so
    %% they survive the transport_queue_manager crashing and being
    %% restarted by its supervisor. Idempotent: existing tables are
    %% returned as-is on re-init.
    PartitionOpts = [
        ordered_set,
        {keypos, #bondy_http_transport_queue_entry.key},
        public,
        {read_concurrency, true},
        {write_concurrency, true},
        {decentralized_counters, true}
    ],
    Ring = lists:foldl(
        fun(Bucket, Acc) ->
            Key = {?MODULE, partition, Bucket},
            {ok, Tab} = bondy_table_manager:get_or_create_anonymous(
                Key, PartitionOpts
            ),
            Acc#{Bucket => Tab}
        end,
        #{},
        lists:seq(0, NumPartitions - 1)
    ),

    %% Store the ring in persistent_term for zero-cost lookup
    persistent_term:put(?RING_KEY, Ring),

    %% Metadata table — named (single static atom, not a per-bucket leak)
    %% and also owned by bondy_table_manager. Idempotent.
    MetaOpts = [
        set,
        {keypos, #bondy_http_transport_queue_meta.transport_id},
        named_table,
        public,
        {read_concurrency, true},
        {write_concurrency, true},
        {decentralized_counters, true}
    ],
    {ok, _} = bondy_table_manager:get_or_create(?META_TAB, MetaOpts),

    ok.

-doc """
Initialises the queue metadata for a transport.

Creates an atomics reference with 3 slots (count, bytes, last_dequeue_seq)
and inserts the metadata entry into the meta table. Must be called before
the first `enqueue/3` for this transport.
""".
-spec init_transport(
    TransportId :: binary(),
    RealmUri :: uri(),
    SessionId :: bondy_session_id:t()
) -> ok | {error, already_exists}.

init_transport(TransportId, RealmUri, SessionId) when
    is_binary(TransportId) andalso is_binary(RealmUri)
->
    AtomicsRef = atomics:new(3, [{signed, true}]),
    Meta = #bondy_http_transport_queue_meta{
        transport_id = TransportId,
        atomics = AtomicsRef,
        realm_uri = RealmUri,
        session_id = SessionId
    },
    case ets:insert_new(?META_TAB, Meta) of
        true ->
            ok;
        false ->
            {error, already_exists}
    end.

-doc """
Removes all queue entries and the metadata entry for a transport.
""".
-spec delete_transport(TransportId :: binary()) -> ok.

delete_transport(TransportId) when is_binary(TransportId) ->
    Tab = locate_table(TransportId),

    %% Delete all entries for this transport using a match spec
    MS = [
        {
            #bondy_http_transport_queue_entry{
                key = {TransportId, '_'},
                _ = '_'
            },
            [],
            [true]
        }
    ],
    _ = ets:select_delete(Tab, MS),

    %% Delete the metadata entry
    _ = ets:delete(?META_TAB, TransportId),
    ok.

-doc """
Enqueues a message for a transport.

Checks bounds before inserting and evicts oldest entries if the queue exceeds
`max_messages` or `max_bytes`. Counters are updated atomically.
""".
-spec enqueue(
    TransportId :: binary(),
    Message :: queued(),
    Opts :: enqueue_opts()
) -> ok | {error, Reason :: term()}.

enqueue(TransportId, Message, _Opts) when
    is_binary(TransportId)
->
    %% 1. Locate the metadata entry (cached atomics ref)
    case lookup_meta(TransportId) of
        {ok, Meta} ->
            do_enqueue(TransportId, Message, Meta);
        error ->
            {error, transport_not_found}
    end.

-doc """
Dequeues up to `MaxN` non-expired messages for a transport.

Messages are returned in insertion order (oldest first). Expired messages
(past their TTL) are skipped. Each dequeued message is removed from the table
and counters are decremented atomically.
""".
-spec dequeue_batch(
    TransportId :: binary(),
    MaxN :: pos_integer()
) -> [wamp_message()].

dequeue_batch(TransportId, MaxN) when
    is_binary(TransportId) andalso is_integer(MaxN) andalso MaxN > 0
->
    case lookup_meta(TransportId) of
        {ok, Meta} ->
            do_dequeue_batch(TransportId, MaxN, Meta);
        error ->
            []
    end.

-doc """
Removes expired messages across all partitions.

Called periodically by `bondy_http_transport_queue_manager`. Iterates over all
sharded tables and removes entries whose `enqueued_at + message_ttl` has
elapsed.
""".
-spec evict_expired_all() -> ok.

evict_expired_all() ->
    Now = erlang:system_time(millisecond),
    Tables = tables(),
    lists:foreach(
        fun(Tab) -> evict_expired_partition(Tab, Now) end,
        Tables
    ).

-doc """
Returns the current message count for a transport.
""".
-spec count(TransportId :: binary()) -> non_neg_integer().

count(TransportId) when is_binary(TransportId) ->
    case lookup_meta(TransportId) of
        {ok, #bondy_http_transport_queue_meta{atomics = Ref}} ->
            max(0, atomics:get(Ref, ?COUNT_SLOT));
        error ->
            0
    end.

-doc """
Returns the current cumulative byte size for a transport.
""".
-spec byte_size(TransportId :: binary()) -> non_neg_integer().

byte_size(TransportId) when is_binary(TransportId) ->
    case lookup_meta(TransportId) of
        {ok, #bondy_http_transport_queue_meta{atomics = Ref}} ->
            max(0, atomics:get(Ref, ?BYTES_SLOT));
        error ->
            0
    end.

-doc """
Returns the list of all sharded queue table identifiers.
""".
-spec tables() -> [ets:tid()].

tables() ->
    Ring = persistent_term:get(?RING_KEY),
    maps:values(Ring).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% `max_bytes' is a byte bound, so an already-encoded reply is measured as the
%% bytes it is. `erlang:external_size/1' on the same binary reports the size of
%% its EXTERNAL TERM encoding, larger and for no purpose here; it stays for a
%% record, where there is nothing better to measure until a consumer encodes it.
size_of({encoded, Bin}) ->
    %% `erlang:' qualified: this module exports its own `byte_size/1', so the
    %% bare call is an ambiguous auto-import.
    erlang:byte_size(Bin);
size_of(Message) ->
    erlang:external_size(Message).

%% @private
do_enqueue(TransportId, Message, Meta) ->
    #bondy_http_transport_queue_meta{atomics = AtomicsRef} = Meta,

    %% Compute message size
    MsgSize = size_of(Message),

    %% Allocate a sequence number (scheduler-local, zero contention)
    Seq = erlang:unique_integer([monotonic]),

    %% Check bounds BEFORE inserting
    MaxMessages = bondy_config:get([http_transport, queue, max_messages], 1000),
    MaxBytes = bondy_config:get([http_transport, queue, max_bytes], 10485760),

    CurrentCount = atomics:get(AtomicsRef, ?COUNT_SLOT),
    CurrentBytes = atomics:get(AtomicsRef, ?BYTES_SLOT),

    %% Evict oldest if bounds are exceeded
    case CurrentCount >= MaxMessages orelse CurrentBytes + MsgSize > MaxBytes of
        true ->
            evict_oldest(TransportId, AtomicsRef, MsgSize);
        false ->
            ok
    end,

    %% Insert the entry
    Tab = locate_table(TransportId),
    Entry = #bondy_http_transport_queue_entry{
        key = {TransportId, Seq},
        message = Message,
        enqueued_at = erlang:system_time(millisecond),
        size_bytes = MsgSize
    },
    ets:insert(Tab, Entry),

    %% Update counters (atomic)
    atomics:add(AtomicsRef, ?COUNT_SLOT, 1),
    atomics:add(AtomicsRef, ?BYTES_SLOT, MsgSize),
    ok.

%% @private
evict_oldest(TransportId, AtomicsRef, _NeededBytes) ->
    Tab = locate_table(TransportId),

    %% Select the oldest N entries for this transport using a match spec.
    %% Because the key is {TransportId, Seq} in an ordered_set, the
    %% smallest Seq values (oldest) appear first in iteration order.
    MS = [
        {
            #bondy_http_transport_queue_entry{
                key = {TransportId, '_'}, _ = '_'
            },
            [],
            ['$_']
        }
    ],

    %% Fetch a small batch of oldest entries
    case ets:select(Tab, MS, ?EVICTION_BATCH_SIZE) of
        '$end_of_table' ->
            ok;
        {Entries, _Cont} ->
            lists:foreach(
                fun(
                    #bondy_http_transport_queue_entry{
                        key = Key, size_bytes = Sz
                    }
                ) ->
                    case ets:take(Tab, Key) of
                        [_] ->
                            atomics:sub(AtomicsRef, ?COUNT_SLOT, 1),
                            atomics:sub(AtomicsRef, ?BYTES_SLOT, Sz);
                        [] ->
                            %% Already removed by concurrent dequeue
                            ok
                    end
                end,
                Entries
            )
    end.

%% @private
do_dequeue_batch(TransportId, MaxN, Meta) ->
    Tab = locate_table(TransportId),
    #bondy_http_transport_queue_meta{atomics = AtomicsRef} = Meta,

    %% Select up to MaxN non-expired entries for this transport
    Now = erlang:system_time(millisecond),
    MessageTTL = bondy_config:get([http_transport, queue, message_ttl], 300000),

    MS = [
        {
            #bondy_http_transport_queue_entry{
                key = {TransportId, '$1'},
                enqueued_at = '$2',
                message = '$3',
                size_bytes = '$4'
            },
            [{'>', {'+', '$2', {const, MessageTTL}}, {const, Now}}],
            [{{'$1', '$3', '$4'}}]
        }
    ],

    case ets:select(Tab, MS, MaxN) of
        '$end_of_table' ->
            [];
        {Entries, _Cont} ->
            lists:map(
                fun({Seq, Msg, Sz}) ->
                    Key = {TransportId, Seq},
                    ets:delete(Tab, Key),
                    atomics:sub(AtomicsRef, ?COUNT_SLOT, 1),
                    atomics:sub(AtomicsRef, ?BYTES_SLOT, Sz),
                    %% Track last dequeued seq for resumption
                    atomics:put(AtomicsRef, ?LAST_DEQUEUE_SEQ_SLOT, Seq),
                    Msg
                end,
                Entries
            )
    end.

%% @private
evict_expired_partition(Tab, Now) ->
    MessageTTL = bondy_config:get([http_transport, queue, message_ttl], 300000),

    %% Match all entries where enqueued_at + TTL <= Now
    MS = [
        {
            #bondy_http_transport_queue_entry{
                key = '$1',
                enqueued_at = '$2',
                size_bytes = '$3',
                _ = '_'
            },
            [{'=<', {'+', '$2', {const, MessageTTL}}, {const, Now}}],
            [{{'$1', '$3'}}]
        }
    ],

    case ets:select(Tab, MS, ?EVICTION_BATCH_SIZE) of
        '$end_of_table' ->
            ok;
        {Expired, Cont} ->
            do_evict_expired_entries(Expired),
            evict_expired_cont(Cont)
    end.

%% @private
evict_expired_cont('$end_of_table') ->
    ok;
evict_expired_cont({Expired, Cont}) ->
    do_evict_expired_entries(Expired),
    evict_expired_cont(ets:select(Cont)).

%% @private
do_evict_expired_entries(Expired) ->
    lists:foreach(
        fun({Key = {TransportId, _Seq}, Sz}) ->
            Tab = locate_table(TransportId),
            case ets:take(Tab, Key) of
                [_] ->
                    case lookup_meta(TransportId) of
                        {ok, #bondy_http_transport_queue_meta{} = Meta} ->
                            Ref = Meta#bondy_http_transport_queue_meta.atomics,
                            atomics:sub(Ref, ?COUNT_SLOT, 1),
                            atomics:sub(Ref, ?BYTES_SLOT, Sz);
                        error ->
                            ok
                    end;
                [] ->
                    ok
            end
        end,
        Expired
    ).

%% @private
locate_table(TransportId) ->
    Ring = persistent_term:get(?RING_KEY),
    NumPartitions = maps:size(Ring),
    Bucket = bondy_consistent_hashing:bucket(TransportId, NumPartitions),
    maps:get(Bucket, Ring).

%% @private
lookup_meta(TransportId) ->
    case ets:lookup(?META_TAB, TransportId) of
        [#bondy_http_transport_queue_meta{} = Meta] ->
            {ok, Meta};
        [] ->
            error
    end.
