%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_status).

-moduledoc """
Where a message is, and whether it has been sent before.

Two questions with one answer: both are about *locating* a small, short-lived
record, so both are solved by addressing rather than by storage. Nothing here
is replicated and nothing is written to disk.

## Message ids are self-locating

An id is `<<Node/binary, $/, Token/binary>>`. The node is the one that accepted
the message and therefore holds its record, so `get/2` can route from the id
alone and any node in the cluster can answer for any message. `/` is the
separator because it cannot occur in an Erlang node name, which makes the split
unambiguous.

For an unkeyed request the token is random. For a request carrying an
idempotency key it is a digest of the realm and that key, which is what makes
the id -- and so the record -- findable again by a caller who only knows the
key they sent.

## Idempotency is cluster-wide, not node-local

Node-local dedupe would under-deliver what the field implies: a client whose
`send_async` timed out retries against whichever node its connection lands on,
and a second node has never heard of the key. So a keyed request is routed to
an owner chosen by rendezvous hashing over cluster membership (`owner/2`), and
the dedupe check happens there.

The hop is paid only by callers who ask for idempotency. An unkeyed request is
always accepted locally.

**During membership change the guarantee is weaker.** Membership does not
change atomically across a cluster, so for a short window two nodes can both
believe they own a key, or a retry can select a new owner while the old one is
still holding the record. A duplicate is possible in that window. This is
inherent to coordination-free ownership, and the alternative -- consensus on a
per-message key -- costs far more than the duplicate it prevents.

## A claim is consumed when the message reaches a worker

Once a message has been handed to a delivery worker, a later request carrying
the same key is answered with the recorded outcome rather than sent again --
including when that outcome is `failed`. Bondy cannot distinguish a relay that
never saw the message from one that accepted it and then dropped the
connection, so a failure is not an invitation to send twice. A caller that
genuinely wants another attempt uses a new key.

A message that never reached a worker -- a full queue, for instance -- releases
its claim, because refusing to retry something that was never attempted would
be a lie.

## What is never recorded

No bodies, no subjects, no recipients. A status record holds an id, a realm, a
relay name, a state, an attempt count and an error class. `get/2` answers
`unknown` for a realm that does not own the message, so a caller cannot probe
another realm's traffic by guessing ids.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mail.hrl").

-define(TAB, ?MODULE).
-define(SEP, ~"/").

%% The longest a sweep may be deferred. The table is bounded by TTL, so this
%% only decides how promptly expired entries stop occupying memory.
-define(MAX_SWEEP_INTERVAL, 60000).

%% How long a routed call may take beyond the request's own budget. Covers the
%% hop and the remote node's validation, not its delivery attempt.
-define(NODE_TIMEOUT, 5000).

%% Held on the accepting node only. Deliberately narrow: an operator debugging
%% a delivery needs the id, the relay and the error class, and none of the three
%% is sensitive. A subject line is.
-record(bondy_mail_status, {
    id :: binary(),
    realm :: binary(),
    relay :: binary(),
    status :: queued | sent | failed,
    attempts :: non_neg_integer(),
    nature :: optional(permanent | transient),
    error_class :: optional(atom()),
    created_at :: integer(),
    updated_at :: integer(),
    %% Monotonic, so a wall-clock adjustment cannot extend or curtail a TTL.
    expires_at :: integer()
}).

-record(state, {
    ttl :: pos_integer(),
    max_size :: pos_integer(),
    interval :: pos_integer()
}).

-type info() :: #{
    id := binary(),
    status := queued | sent | failed | unknown,
    relay => binary(),
    attempts => non_neg_integer(),
    nature => permanent | transient,
    error_class => atom(),
    created_at => integer(),
    updated_at => integer()
}.

-export_type([info/0]).

%% API
-export([claim/1]).
-export([get/2]).
-export([new_id/2]).
-export([node_of/1]).
-export([owner/2]).
-export([release/1]).
-export([start_link/0]).
-export([update/2]).

%% REMOTE CALLBACKS
-export([local_get/2]).

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

-doc "Start the status table's owner, registered as `bondy_mail_status`.".
-spec start_link() -> {ok, pid()} | {error, any()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Mint a message id for a request in `RealmUri`.

Without an idempotency key the id is random and unique. With one it is a digest
of the realm and the key, so the same key always names the same message -- which
is how a retry finds the original rather than creating a second one. The realm
is mixed in, so two realms using the same key do not collide.

The node component is always this node, because this node is the one that will
hold the record. Ownership is decided by `owner/2` before a request gets here.
""".
-spec new_id(RealmUri :: binary(), Key :: optional(binary())) -> binary().

new_id(RealmUri, undefined) when is_binary(RealmUri) ->
    encode(crypto:strong_rand_bytes(16));
new_id(RealmUri, Key) when is_binary(RealmUri) andalso is_binary(Key) ->
    encode(binary:part(crypto:hash(sha256, [RealmUri, 0, Key]), 0, 16)).

-doc """
Return the node holding the record for `Id`.

`error` for anything this node cannot resolve to a node it has heard of --
including a well-formed id naming a node that has never been in the cluster.
Minting an atom for a caller-supplied string would let a caller fill the atom
table, so an unrecognised node is simply unknown.
""".
-spec node_of(Id :: binary()) -> {ok, node()} | error.

node_of(Id) when is_binary(Id) ->
    case binary:split(Id, ?SEP) of
        [Node, Token] when byte_size(Node) > 0 andalso byte_size(Token) > 0 ->
            try
                {ok, binary_to_existing_atom(Node, utf8)}
            catch
                error:badarg -> error
            end;
        _ ->
            error
    end;
node_of(_) ->
    error.

-doc """
Decide which node owns a request.

`local` when the request carries no idempotency key: there is nothing to
deduplicate, so the accepting node keeps it and no hop is paid.

With a key, rendezvous hashing over cluster membership picks one node. Every
node computes the same answer from the same membership without exchanging
anything, which is what makes the dedupe check meet a single record.

The candidate set is the whole cluster. A relay declaration is expected to be
identical on every node -- it comes from `bondy.conf`, like a listener -- and a
node that has not been given the relay answers `no_such_relay` rather than
guessing. That is a loud, correct answer to a genuinely broken configuration.
""".
-spec owner(RealmUri :: binary(), Key :: optional(binary())) ->
    local | {remote, node()}.

owner(_RealmUri, undefined) ->
    local;
owner(RealmUri, Key) when is_binary(RealmUri) andalso is_binary(Key) ->
    Self = this_node(),
    case cluster_nodes(Self) of
        [Self] ->
            local;
        Nodes ->
            case lrw:top({RealmUri, Key}, Nodes, 1) of
                [Self] -> local;
                [Node] -> {remote, Node};
                _ -> local
            end
    end.

-doc """
Record a request as queued, unless its key has already been claimed.

Answers `{ok, claimed}` when this request may proceed, or
`{ok, {duplicate, Info}}` when the key names a message already accepted -- in
which case the caller must not send, and reports `Info` instead.

The two paths fail differently on purpose. A keyed request whose claim cannot
be recorded is refused with a transient error: the caller asked for a guarantee
this node can no longer provide, and sending anyway would quietly break it. An
unkeyed request is never refused for want of a status record, because nothing
was promised and a tracking failure is not a reason to drop mail.
""".
-spec claim(Request :: bondy_mail_request:t()) ->
    {ok, claimed} | {ok, {duplicate, info()}} | {error, any()}.

claim(Request) ->
    Id = bondy_mail_request:message_id(Request),
    Entry = new_entry(Request, Id),
    case bondy_mail_request:id(Request) of
        undefined ->
            %% Best effort: an untracked message is still a sent message.
            _ = catch ets:insert(?TAB, Entry),
            {ok, claimed};
        _Key ->
            %% One atomic insert, not a lookup followed by one. The window
            %% between the two is exactly where a client's parallel retries
            %% land, and it is wide enough to send the same message twice.
            try ets:insert_new(?TAB, Entry) of
                true ->
                    {ok, claimed};
                false ->
                    {ok, {duplicate, lookup(Id)}}
            catch
                error:badarg ->
                    {error, {transient, status_unavailable, Id}}
            end
    end.

-doc """
Give up a claim for a message that never reached a worker.

Only a record still in `queued` is removed, so this cannot race with a worker
that has already reported an outcome.
""".
-spec release(Request :: bondy_mail_request:t()) -> ok.

release(Request) ->
    Id = bondy_mail_request:message_id(Request),
    MS = [{#bondy_mail_status{id = Id, status = queued, _ = '_'}, [], [true]}],
    _ = catch ets:select_delete(?TAB, MS),
    ok.

-doc """
Record the outcome of a delivery attempt.

Takes the worker's result verbatim so the caller has nothing to translate.
Best effort throughout: a message that was delivered but whose record has
already been swept is not worth failing over.
""".
-spec update(Id :: binary(), Result :: {ok, map()} | {error, any()}) -> ok.

update(Id, {ok, Result}) when is_map(Result) ->
    write(Id, [
        {#bondy_mail_status.status, sent},
        {#bondy_mail_status.attempts, maps:get(attempts, Result, 1)}
    ]);
update(Id, {error, {Nature, Class, _}}) when
    Nature == permanent orelse Nature == transient
->
    write(Id, [
        {#bondy_mail_status.status, failed},
        {#bondy_mail_status.nature, Nature},
        {#bondy_mail_status.error_class, Class}
    ]);
update(Id, {error, _}) ->
    write(Id, [
        {#bondy_mail_status.status, failed},
        {#bondy_mail_status.nature, permanent},
        {#bondy_mail_status.error_class, unknown}
    ]).

-doc """
Return what is known about a message.

Routes by the node embedded in `Id`, so any node answers for any message.

`#{status := unknown}` covers every case where this cluster cannot say: an id
that never existed, one whose record has been swept, one belonging to another
realm, and one whose owning node is unreachable. The last of these is the
truthful answer rather than a guess -- the queue is in memory, so a node that
went away took its unsent messages with it, and nothing here knows what it had
managed to deliver first.
""".
-spec get(RealmUri :: binary(), Id :: binary()) -> info().

get(RealmUri, Id) when is_binary(RealmUri) andalso is_binary(Id) ->
    case node_of(Id) of
        error ->
            unknown(Id);
        {ok, Node} ->
            case Node == this_node() of
                true ->
                    local_get(RealmUri, Id);
                false ->
                    remote_get(Node, RealmUri, Id)
            end
    end;
get(_, Id) ->
    unknown(Id).

%% =============================================================================
%% REMOTE CALLBACKS
%% =============================================================================

-doc false.
%% The far end of `get/2`. Exported because a peer calls it by name.
-spec local_get(RealmUri :: binary(), Id :: binary()) -> info().

local_get(RealmUri, Id) ->
    case lookup(Id) of
        #{realm := RealmUri} = Info ->
            maps:remove(realm, Info);
        _ ->
            %% Not found, or found in another realm. Answering the same way for
            %% both is what stops a caller learning that an id exists.
            unknown(Id)
    end.

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

-doc false.
init([]) ->
    Ttl = bondy_mail_config:status_ttl(),
    _ = ets:new(?TAB, [
        set,
        public,
        named_table,
        {keypos, #bondy_mail_status.id},
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    State = #state{
        ttl = Ttl,
        max_size = bondy_mail_config:status_max_size(),
        interval = max(1000, min(Ttl div 4, ?MAX_SWEEP_INTERVAL))
    },
    {ok, schedule(State)}.

-doc false.
handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {noreply, State}.

-doc false.
handle_cast(Event, State) ->
    ?LOG_WARNING(#{reason => unsupported_event, event => Event}),
    {noreply, State}.

-doc false.
handle_info(sweep, State) ->
    ok = sweep(State),
    {noreply, schedule(State)};
handle_info(Info, State) ->
    ?LOG_DEBUG(#{reason => unsupported_event, event => Info}),
    {noreply, State}.

-doc false.
terminate(_Reason, _State) ->
    ok.

-doc false.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
encode(Bytes) ->
    Node = atom_to_binary(this_node(), utf8),
    Token = binary:encode_hex(Bytes, lowercase),
    <<Node/binary, ?SEP/binary, Token/binary>>.

%% @private
%% Partisan's name is the identity the rest of the cluster knows this node by,
%% and `bondy_app` starts Partisan before this application, so that is what a
%% running node uses. The fallback covers `bondy_mail` running on its own,
%% where there is no cluster for the distinction to matter to -- and, because
%% `cluster_nodes/1` falls back in step, a node without Partisan simply owns
%% every key it is given.
this_node() ->
    try partisan:node() of
        Node when is_atom(Node) -> Node;
        _ -> erlang:node()
    catch
        _:_ -> erlang:node()
    end.

%% @private
cluster_nodes(Self) ->
    try
        [Self | partisan:nodes()]
    catch
        _:_ -> [Self]
    end.

%% @private
new_entry(Request, Id) ->
    Now = erlang:system_time(millisecond),
    #bondy_mail_status{
        id = Id,
        realm = bondy_mail_request:realm(Request),
        relay = bondy_mail_request:relay(Request),
        status = queued,
        attempts = 0,
        nature = undefined,
        error_class = undefined,
        created_at = Now,
        updated_at = Now,
        expires_at =
            erlang:monotonic_time(millisecond) +
                bondy_mail_config:status_ttl()
    }.

%% @private
%% `update_element/3` rather than read-modify-write: a worker reporting an
%% outcome must not be able to resurrect a record the sweep has just removed,
%% and must not overwrite a concurrent update wholesale.
write(Id, Updates) ->
    All = [
        {#bondy_mail_status.updated_at, erlang:system_time(millisecond)}
        | Updates
    ],
    _ = catch ets:update_element(?TAB, Id, All),
    ok.

%% @private
lookup(Id) ->
    try ets:lookup(?TAB, Id) of
        [Entry] -> to_info(Entry);
        [] -> unknown(Id)
    catch
        error:badarg -> unknown(Id)
    end.

%% @private
%% `realm` is included here and removed by `local_get/2` after the check. It is
%% never part of what a caller receives.
to_info(#bondy_mail_status{} = E) ->
    Base = #{
        id => E#bondy_mail_status.id,
        realm => E#bondy_mail_status.realm,
        relay => E#bondy_mail_status.relay,
        status => E#bondy_mail_status.status,
        attempts => E#bondy_mail_status.attempts,
        created_at => E#bondy_mail_status.created_at,
        updated_at => E#bondy_mail_status.updated_at
    },
    case E#bondy_mail_status.status of
        failed ->
            Base#{
                nature => E#bondy_mail_status.nature,
                error_class => E#bondy_mail_status.error_class
            };
        _ ->
            Base
    end.

%% @private
unknown(Id) ->
    #{id => Id, status => unknown}.

%% @private
%% An unreachable owner is `unknown`, not an error: the question was answerable
%% in principle and this cluster cannot answer it, which is exactly what
%% `unknown` says.
remote_get(Node, RealmUri, Id) ->
    Args = [RealmUri, Id],
    try partisan_rpc:call(Node, ?MODULE, local_get, Args, ?NODE_TIMEOUT) of
        #{status := _} = Info ->
            Info;
        _ ->
            unknown(Id)
    catch
        _:_ ->
            unknown(Id)
    end.

%% @private
schedule(#state{interval = Interval} = State) ->
    _ = erlang:send_after(Interval, self(), sweep),
    State.

%% @private
sweep(#state{max_size = Max, ttl = Ttl}) ->
    Now = erlang:monotonic_time(millisecond),
    _ = expire(Now),
    case ets:info(?TAB, size) of
        Size when is_integer(Size) andalso Size > Max ->
            %% Every entry is given the same TTL, so expiry order is insertion
            %% order and "half the TTL from now" removes the older half without
            %% having to sort anything.
            Dropped = expire(Now + (Ttl div 2)),
            ?LOG_WARNING(#{
                description =>
                    "Mail status table over its bound, dropped oldest entries. "
                    "Message status and idempotency are best effort while this "
                    "persists. Raise mail.status.max_size or lower "
                    "mail.status.ttl.",
                size => Size,
                max_size => Max,
                dropped => Dropped
            }),
            ok;
        _ ->
            ok
    end.

%% @private
expire(Cutoff) ->
    MS = [
        {
            #bondy_mail_status{expires_at = '$1', _ = '_'},
            [{'=<', '$1', Cutoff}],
            [true]
        }
    ],
    ets:select_delete(?TAB, MS).
