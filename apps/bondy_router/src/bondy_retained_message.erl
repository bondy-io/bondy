%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_retained_message).
-moduledoc """
Storage for WAMP retained events: the most recent event published to a topic,
kept so that a session subscribing later receives it at once.

A realm holds at most one retained message per topic, keyed by the topic URI in
the durable `main` database. Keys are byte-ordered, which is what makes the
three WAMP matching policies range scans rather than table walks: `exact` is a
point read, `prefix` scans from the topic and stops at the first key that no
longer carries it, and `wildcard` scans from the fixed prefix preceding the
pattern's first wildcard component.

Delivery constraints travel with the message rather than being resolved when it
is stored. Each retained message carries the publisher's `eligible` / `exclude`
session lists and its expiry, and both are applied when a subscriber matches, so
a message stops being deliverable without anyone rewriting it. Expiry is
therefore lazy: an expired message occupies its cell until `evict_expired/1`
sweeps it, and is filtered out of every match until then.

Start from `put/5` to retain an event, `match/4` to collect the messages a
subscribing session should receive, and `to_event/2` to turn one back into the
EVENT that session is sent. `match/4` answers one page and a continuation;
`match/1` resumes from that continuation.

**Experimental. The implementation does not scale to high publication rates.**
""".
-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
%% For the `?EOT` end-of-table sentinel.
-include("bondy_db_tables.hrl").

%% The bondy_db table name (declared in `bondy_namespace_catalog:tables/0`,
%% durable `main` DB). The realm is the bondy_db shard/realm argument, not part
%% of the key.
-define(TABLE, retained_messages).

-record(bondy_retained_message, {
    valid_to :: pos_integer(),
    publication_id :: id(),
    match_opts :: map(),
    %% Decoded payload
    details :: map(),
    args :: list() | undefined,
    kwargs :: map() | undefined,
    partial :: bondy_wamp_message:partial(),
    %% Encoded payload
    payload :: binary() | undefined
}).

-record(bondy_retained_continuation, {
    realm :: binary(),
    topic :: binary(),
    session_id :: id(),
    strategy :: binary(),
    opts :: list()
}).

-doc """
A retained event together with the delivery constraints it was stored under.
""".
-type t() :: #bondy_retained_message{}.

-doc "The sentinel that ends a paged match: no further page follows.".
-type eot() :: ?EOT.

-doc """
An opaque resume point for a paged match. Pass it to `match/1` to continue the
scan; it is only meaningful to the realm, topic, session and policy that
produced it.
""".
-type continuation() :: #bondy_retained_continuation{}.

-doc """
The publisher's delivery constraints, in WAMP terms: `eligible` restricts
delivery to the listed sessions, `exclude` withholds it from them. An empty
`eligible` list excludes every session, which WAMP treats as intentional rather
than as an omitted option.
""".
-type match_opts() :: #{
    eligible => [id()],
    exclude => [id()]
}.

-doc """
Scan controls for a paged match: `first` is the inclusive key to resume from,
`limit` the maximum number of messages in a page.
""".
-type scan_opts() :: [{first, binary()} | {limit, pos_integer()}].

-doc "Called with the realm and each message an eviction sweep removes.".
-type evict_fun() :: fun((uri(), t()) -> ok).

-export_type([t/0]).
-export_type([match_opts/0]).
-export_type([scan_opts/0]).
-export_type([eot/0]).
-export_type([continuation/0]).

-export([evict_expired/0]).
-export([evict_expired/1]).
-export([evict_expired/2]).
-export([put/4]).
-export([put/5]).
-export([get/2]).
-export([remove_all/1]).
-export([take/2]).
-export([match/1]).
-export([match/4]).
-export([match/5]).
-export([to_event/2]).
-export([size/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Returns the message retained for `Topic` in `Realm`, or `undefined` when the
topic has none.

The message is returned whatever its expiry or delivery constraints say; this
is the raw read. Use `match/4` to obtain only what a given session may receive.
""".
-spec get(Realm :: uri(), Topic :: uri()) -> t() | undefined.

get(Realm, Topic) ->
    case bondy_db:read(table(), Realm, Topic) of
        {ok, {Value, _Hlc}} -> Value;
        {error, not_found} -> undefined
    end.

-doc """
Returns the message retained for `Topic` in `Realm` and clears it, so the topic
retains nothing afterwards. Returns `undefined` when there was none.

The read and the clear are separate operations, so a concurrent `put/5` on the
same topic can be lost.
""".
-spec take(Realm :: uri(), Topic :: uri()) -> t() | undefined.

take(Realm, Topic) ->
    Table = table(),
    case bondy_db:read(Table, Realm, Topic) of
        {ok, {Value, _Hlc}} ->
            ok = bondy_db:apply(Table, Realm, Topic, clear),
            Value;
        {error, not_found} ->
            undefined
    end.

-doc """
Returns the heap size of `Mssg` in bytes, the unit the per-realm memory counter
and the `max_message_size` limit are expressed in.
""".
-spec size(t()) -> integer().

size(Mssg) ->
    term_size(Mssg).

-doc """
Returns the next page of a match started by `match/4` or `match/5`.

Answers `?EOT` for a continuation that has no successor, so a caller can loop on
the result until it is the sentinel.
""".
-spec match(continuation() | eot()) -> {[t()] | continuation()} | eot().

match(?EOT) ->
    ?EOT;
match(#bondy_retained_continuation{opts = undefined}) ->
    ?EOT;
match(#bondy_retained_continuation{} = Cont) ->
    Realm = Cont#bondy_retained_continuation.realm,
    Topic = Cont#bondy_retained_continuation.topic,
    SessionId = Cont#bondy_retained_continuation.session_id,
    Strategy = Cont#bondy_retained_continuation.strategy,
    Opts = Cont#bondy_retained_continuation.opts,
    match(Realm, Topic, SessionId, Strategy, Opts).

-doc """
Returns the first page of retained messages that session `SessionId` should
receive on subscribing to `Topic` under matching policy `Strategy`, at most 100
per page. Equivalent to `match/5` with that limit.
""".
-spec match(
    Realm :: uri(),
    Topic :: uri(),
    SessionId :: id(),
    Strategy :: binary()
) ->
    {[t()], continuation()} | eot().

match(Realm, Topic, SessionId, Strategy) ->
    match(Realm, Topic, SessionId, Strategy, [{limit, 100}]).

-doc """
Returns a page of the retained messages that session `SessionId` should receive
on subscribing to `Topic`, and a continuation for the rest.

`Strategy` is the WAMP matching policy — `exact`, `prefix` or `wildcard` — and
selects how the topic space is scanned. Only messages the session is entitled
to are returned: expired ones and those its id is excluded from (or not eligible
for) are skipped, and they consume no page budget.

A page holds at most `limit` messages, defaulting to 100. The second element is
a continuation to pass to `match/1`, or `?EOT` when the scan reached the end of
the matching key range. A `wildcard` `Topic` that contains no wildcard component
raises `{invalid_wildcard_pattern, Topic}`.
""".
-spec match(
    Realm :: uri(),
    Topic :: uri(),
    SessionId :: id(),
    Strategy :: binary(),
    Opts :: scan_opts()
) ->
    {[t()], continuation()} | eot().

match(Realm, Topic, SessionId, <<"exact">>, _) ->
    case get(Realm, Topic) of
        #bondy_retained_message{} = Msg ->
            case session_eligible(Msg, SessionId) of
                true -> {[Msg], ?EOT};
                false -> {[], ?EOT}
            end;
        undefined ->
            {[], ?EOT}
    end;
match(Realm, Topic, SessionId, <<"prefix">> = Strategy, Opts0) ->
    Len = byte_size(Topic),
    Lo = key_value:get(first, Opts0, Topic),
    Limit = key_value:get(limit, Opts0, 100),
    Opts = key_value:set(limit, Limit, Opts0),
    %% Keys are byte-ordered: once a key no longer carries the Topic prefix,
    %% no later key can either, so we stop with ?EOT.
    Classify = fun
        (<<Prefix:Len/binary, _/binary>>) when Prefix =:= Topic -> keep;
        (_) -> done
    end,
    MkCont = mk_cont_fun(Realm, Topic, SessionId, Strategy, Opts),
    scan(table(), Realm, Lo, Classify, SessionId, Limit, MkCont);
match(Realm, Topic, SessionId, <<"wildcard">> = Strategy, Opts0) ->
    {First, MatchFun} = wildcard_opts(Topic),
    Lo = key_value:get(first, Opts0, First),
    Limit = key_value:get(limit, Opts0, 100),
    Opts = key_value:set(limit, Limit, Opts0),
    Classify = fun(Key) ->
        case MatchFun(Key) of
            true -> keep;
            false -> skip;
            done -> done
        end
    end,
    MkCont = mk_cont_fun(Realm, Topic, SessionId, Strategy, Opts),
    scan(table(), Realm, Lo, Classify, SessionId, Limit, MkCont).

-doc """
Retains `Event` as the current message for `Topic`, with no expiry. Equivalent
to `put/5` with a TTL of `0`.
""".
-spec put(
    Realm :: uri(),
    Topic :: uri(),
    Event :: wamp_event(),
    MatchOpts :: match_opts()
) -> ok.

put(Realm, Topic, Event, MatchOpts) ->
    put(Realm, Topic, Event, MatchOpts, 0).

-doc """
Retains `Event` as the current message for `Topic` in `Realm`, replacing
whatever that topic retained before.

`MatchOpts` records the publisher's `eligible` / `exclude` session lists, which
are evaluated on each later match rather than now. `TTL` is a lifetime in
seconds from the call; `0` means the message never expires. An expired message
is withheld from every match and removed by the next `evict_expired/1` sweep.

Maintains the realm's retained-message count and memory counters. Those are
node-local and updated from a read followed by a write, so two concurrent calls
on one topic can leave them approximate.
""".
-spec put(
    Realm :: uri(),
    Topic :: uri(),
    Event :: wamp_event(),
    MatchOpts :: match_opts(),
    TTL :: non_neg_integer()
) -> ok.

put(Realm, Topic, #event{} = Event, MatchOpts, TTL) ->
    Retained = new(Event, MatchOpts, TTL),
    Size = term_size(Retained),
    Table = table(),
    %% The memory counter tracks a delta, so the message being replaced has to
    %% be read to subtract its size. bondy_db offers no read-modify-write, hence
    %% the separate read; counters drifting under a same-topic write race is
    %% accepted here and affects neither routing nor delivery. Counters are
    %% node-local: a replicated write does not adjust them on the node that
    %% receives it.
    _ =
        case bondy_db:read(Table, Realm, Topic) of
            {ok, {#bondy_retained_message{} = Old, _Hlc}} ->
                ok = bondy_retained_message_manager:decr_counters(
                    Realm, 1, term_size(Old)
                ),
                bondy_retained_message_manager:incr_counters(Realm, 1, Size);
            {error, not_found} ->
                bondy_retained_message_manager:incr_counters(Realm, 1, Size)
        end,
    bondy_db:apply(Table, Realm, Topic, {set, Retained}).

-doc """
Returns the WAMP EVENT to send to a subscriber for `Retained`, under
`SubscriptionId`.

The event's details carry `retained => true`, which is how a subscriber tells a
replayed message from one published while it was subscribed. The publication id
is the original publisher's, not a fresh one.
""".
-spec to_event(Retained :: t(), SubscriptionId :: id()) -> wamp_event().

to_event(Retained, SubscriptionId) ->
    Details = maps:put(retained, true, Retained#bondy_retained_message.details),
    #event{
        subscription_id = SubscriptionId,
        publication_id = Retained#bondy_retained_message.publication_id,
        details = Details,
        args = Retained#bondy_retained_message.args,
        kwargs = Retained#bondy_retained_message.kwargs,
        partial = Retained#bondy_retained_message.partial
    }.

-doc """
Removes the expired retained messages of every realm and returns how many were
removed.
""".
-spec evict_expired() -> non_neg_integer().

evict_expired() ->
    evict_expired('_').

-doc """
Removes the expired retained messages of `Realm` and returns how many were
removed.
""".
-spec evict_expired(uri() | '_') -> non_neg_integer().

evict_expired(Realm) ->
    evict_expired(Realm, undefined).

-doc """
Removes the expired retained messages of `Realm`, or of every realm when
`Realm` is `'_'`, and returns how many were removed.

`EvictFun` is called with the realm and each removed message, which is how the
per-realm counters are kept in step with the sweep; pass `undefined` to remove
without a callback. A message with no TTL never expires and is never swept.
""".
-spec evict_expired(uri() | '_', evict_fun() | undefined) -> non_neg_integer().

evict_expired(Realm, EvictFun) when
    is_binary(Realm) andalso
        (EvictFun == undefined orelse is_function(EvictFun, 2))
->
    do_evict_realm(table(), Realm, EvictFun);
evict_expired('_', EvictFun) when
    EvictFun == undefined orelse is_function(EvictFun, 2)
->
    %% Storage is realm-scoped and offers no whole-store fold, so "all realms"
    %% means enumerating the realm registry and sweeping each. Cost is linear in
    %% the number of retained messages either way.
    Table = table(),
    lists:foldl(
        fun(Realm0, Acc) ->
            case bondy_realm:uri(Realm0) of
                undefined -> Acc;
                Uri -> Acc + do_evict_realm(Table, Uri, EvictFun)
            end
        end,
        0,
        bondy_realm:list()
    ).

-doc """
Removes every retained message of `Realm`, expired or not, and returns how many
were removed.

This is realm teardown rather than maintenance: retained messages are per-realm
state keyed by topic, so any left behind would be delivered to the subscribers
of whatever realm next claims the URI. Use `evict_expired/1` for the routine
sweep.
""".
-spec remove_all(Realm :: uri()) -> non_neg_integer().

remove_all(Realm) when is_binary(Realm) ->
    EvictFun = fun(R, Msg) ->
        bondy_retained_message_manager:decr_counters(R, 1, term_size(Msg))
    end,
    do_remove_realm(table(), Realm, fun(_) -> true end, EvictFun).

%% =============================================================================
%% PRIVATE
%% =============================================================================

-spec new(
    Event :: wamp_event(), MatchOps :: map(), TTL :: non_neg_integer()
) -> t().

new(#event{} = Event, MatchOps, TTL) when
    is_map(MatchOps) andalso is_integer(TTL) andalso TTL >= 0
->
    %% Todo manage alternative when event has encoded payload in the future
    #bondy_retained_message{
        valid_to = valid_to(TTL),
        publication_id = Event#event.publication_id,
        match_opts = MatchOps,
        details = Event#event.details,
        args = Event#event.args,
        kwargs = Event#event.kwargs,
        partial = Event#event.partial
    }.

%% @private
valid_to(0) ->
    0;
valid_to(TTL) ->
    erlang:system_time(second) + TTL.

%% @private
-spec wildcard_opts(binary()) -> {binary(), fun((binary()) -> boolean())}.

wildcard_opts(<<$., _/binary>> = Bin) ->
    Components = binary:split(Bin, [<<$.>>], [global]),
    {<<>>, match_fun(Components)};
wildcard_opts(Bin) ->
    case binary:match(Bin, [<<"..">>]) of
        nomatch ->
            error({invalid_wildcard_pattern, Bin});
        {Pos, 2} ->
            First = binary:part(Bin, 0, Pos + 1),
            Components = binary:split(Bin, [<<$.>>], [global]),
            {First, match_fun(Components)}
    end.

match_fun(Components) ->
    Len = length(Components),
    fun(Key) ->
        KeyComponents = binary:split(Key, [<<$.>>], [global]),
        case length(Components) of
            KeyLen when KeyLen =:= Len ->
                subsumes(Components, KeyComponents);
            KeyLen when KeyLen < Len ->
                false;
            _ ->
                done
        end
    end.

%% @private
%% Whether each component of the pattern subsumes the corresponding component of
%% the key: a component subsumes one that is equal to it, and the empty binary —
%% the wildcard component — subsumes any.
subsumes(Term, Term) ->
    true;
subsumes(H1, H2) when length(H1) =/= length(H2) ->
    false;
subsumes([H | T1], [H | T2]) ->
    subsumes(T1, T2);
subsumes([<<>> | T1], [_ | T2]) ->
    subsumes(T1, T2);
subsumes([], []) ->
    true;
subsumes(_, _) ->
    false.

%% @private
%% The bondy_db table handle for retained messages (durable `main` DB).
table() ->
    case bondy_namespace_catalog:table(?TABLE) of
        undefined -> error(retained_messages_not_provisioned);
        Table -> Table
    end.

%% @private
%% Whether `Msg` should be delivered to session `SessionId`: not expired, not
%% excluded and, when an `eligible` list is set, eligible. Applied per match
%% rather than per write, so a message's audience can narrow without a rewrite.
session_eligible(#bondy_retained_message{match_opts = Opts} = Msg, SessionId) ->
    not is_expired(Msg) andalso
        not is_excluded(SessionId, Opts) andalso
        is_eligible(SessionId, Opts).

%% @private
%% The continuation closure shared by the prefix / wildcard matchers: it pins
%% the resume key into `opts` so `match/1` resumes the scan there (inclusive).
mk_cont_fun(Realm, Topic, SessionId, Strategy, Opts) ->
    fun(Key) ->
        #bondy_retained_continuation{
            realm = Realm,
            topic = Topic,
            session_id = SessionId,
            strategy = Strategy,
            opts = key_value:set(first, Key, Opts)
        }
    end.

%% @private
%% Chunked, key-ordered scan of a realm's retained messages from `Lo`
%% (inclusive) to the end of the realm band. `Classify(Key)` returns
%% `keep | skip | done`, where `done` means no later key can match and the scan
%% stops with ?EOT. Gathers up to `Limit` session-eligible messages; the first
%% `keep` key seen after that becomes the resume point, unprocessed, via
%% `MkCont/1`. Returns `{[t()], continuation() | eot()}`.
scan(Table, Realm, Lo, Classify, SessionId, Limit, MkCont) ->
    do_scan(Table, Realm, Lo, Classify, SessionId, Limit, MkCont, []).

%% @private
do_scan(Table, Realm, Lo, Classify, SessionId, Limit, MkCont, Acc) ->
    %% Fetch at least Limit + 1 rows so a full page plus its successor (the
    %% continuation key) usually arrives in one round-trip.
    Chunk = erlang:max(Limit + 1, 64),
    case bondy_db:range_all(Table, Realm, Lo, infinity, #{limit => Chunk}) of
        {ok, []} ->
            {lists:reverse(Acc), ?EOT};
        {ok, Rows} ->
            case scan_rows(Rows, Classify, SessionId, Limit, MkCont, Acc) of
                {stop, Result} ->
                    Result;
                {more, Acc1} when length(Rows) < Chunk ->
                    %% Short chunk ⇒ the realm band is exhausted.
                    {lists:reverse(Acc1), ?EOT};
                {more, Acc1} ->
                    {LastKey, _, _} = lists:last(Rows),
                    Lo1 = <<LastKey/binary, 0>>,
                    do_scan(
                        Table,
                        Realm,
                        Lo1,
                        Classify,
                        SessionId,
                        Limit,
                        MkCont,
                        Acc1
                    )
            end;
        {error, _} = Error ->
            ?LOG_WARNING(#{
                description => "Retained message scan failed",
                realm_uri => Realm,
                reason => Error
            }),
            {lists:reverse(Acc), ?EOT}
    end.

%% @private
%% `Acc` holds accepted messages newest-first. Returns `{stop, Result}` (a
%% `done` key or the page is full — `Result` is the final `{List, Cont}`) or
%% `{more, Acc1}` (chunk exhausted, the caller advances the window).
scan_rows([], _Classify, _SessionId, _Limit, _MkCont, Acc) ->
    {more, Acc};
scan_rows([{Key, Msg, _Hlc} | Rest], Classify, SessionId, Limit, MkCont, Acc) ->
    case Classify(Key) of
        done ->
            {stop, {lists:reverse(Acc), ?EOT}};
        skip ->
            scan_rows(Rest, Classify, SessionId, Limit, MkCont, Acc);
        keep when length(Acc) >= Limit ->
            %% Page full; this matching-but-unprocessed key is the resume point.
            {stop, {lists:reverse(Acc), MkCont(Key)}};
        keep ->
            Acc1 =
                case session_eligible(Msg, SessionId) of
                    true -> [Msg | Acc];
                    false -> Acc
                end,
            scan_rows(Rest, Classify, SessionId, Limit, MkCont, Acc1)
    end.

%% @private
%% Evict expired retained messages from a single realm, deleting each and
%% evaluating `EvictFun` (e.g. the counter decrement). Returns the count.
do_evict_realm(Table, Realm, EvictFun) ->
    do_remove_realm(Table, Realm, fun is_expired/1, EvictFun).

%% @private
%% Delete the retained messages of a single realm for which `Pred` holds,
%% evaluating `EvictFun` on each. Returns the count.
do_remove_realm(Table, Realm, Pred, EvictFun) ->
    case bondy_db:list(Table, Realm) of
        {ok, Rows} ->
            lists:foldl(
                fun
                    ({Topic, #bondy_retained_message{} = Msg, _Hlc}, Acc) ->
                        case Pred(Msg) of
                            true ->
                                ok = bondy_db:apply(
                                    Table, Realm, Topic, clear
                                ),
                                ok = maybe_eval(Realm, EvictFun, Msg),
                                Acc + 1;
                            false ->
                                Acc
                        end;
                    (_, Acc) ->
                        Acc
                end,
                0,
                Rows
            );
        {error, _} = Error ->
            ?LOG_WARNING(#{
                description => "Retained message scan failed",
                realm_uri => Realm,
                reason => Error
            }),
            0
    end.

%% @private
is_eligible(SessionId, Opts) ->
    case maps:find(eligible, Opts) of
        {ok, []} ->
            %% Non eligible! The empty list is not probably a mistake
            %% but we need to respect the semantics
            false;
        {ok, List} ->
            lists:member(SessionId, List);
        error ->
            true
    end.

%% @private
is_excluded(SessionId, Opts) ->
    case maps:find(exclude, Opts) of
        {ok, []} ->
            false;
        {ok, List} ->
            lists:member(SessionId, List);
        error ->
            false
    end.

%% @private
is_expired(#bondy_retained_message{valid_to = T}) ->
    T > 0 andalso T =< erlang:system_time(second).

%% @private
maybe_eval(_, undefined, _) ->
    ok;
maybe_eval(Realm, Fun, Mssg) ->
    try
        Fun(Realm, Mssg)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while evaluating user function",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

%% @private
term_size(Term) ->
    erts_debug:flat_size(Term) * erlang:system_info(wordsize).
