%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_retained_message).
-moduledoc """
When publishing an event a topic the Publisher can ask the Broker to
retain the event being published as the most-recent event on this topic.

Retained events are stored in `bondy_db` (the durable `main` DB), keyed by
topic within a realm and matched via key-ordered `bondy_db:range_all/5` prefix /
wildcard scans.

**This is experimental and does not scale with high traffic at the
moment.**
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

-type t() :: #bondy_retained_message{}.
-type eot() :: ?EOT.
-type continuation() :: #bondy_retained_continuation{}.
-type match_opts() :: #{
    eligible => [id()],
    exclude => [id()]
}.
%% The key_value options threaded through match/5 and its continuation:
%% first (the inclusive resume key) and limit (max messages per page).
-type scan_opts() :: [{first, binary()} | {limit, pos_integer()}].
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
-export([take/2]).
-export([match/1]).
-export([match/4]).
-export([match/5]).
-export([to_event/2]).
-export([size/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec get(Realm :: uri(), Topic :: uri()) -> t() | undefined.

get(Realm, Topic) ->
    case bondy_db:read(table(), Realm, Topic) of
        {ok, {Value, _Hlc}} -> Value;
        {error, not_found} -> undefined
    end.

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

-spec size(t()) -> integer().

size(Mssg) ->
    term_size(Mssg).

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

-spec match(
    Realm :: uri(),
    Topic :: uri(),
    SessionId :: id(),
    Strategy :: binary()
) ->
    {[t()], continuation()} | eot().

match(Realm, Topic, SessionId, Strategy) ->
    match(Realm, Topic, SessionId, Strategy, [{limit, 100}]).

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

-spec put(
    Realm :: uri(),
    Topic :: uri(),
    Event :: wamp_event(),
    MatchOpts :: match_opts()
) -> ok.

put(Realm, Topic, Event, MatchOpts) ->
    put(Realm, Topic, Event, MatchOpts, 0).

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
    %% Counter delta: read the existing value (if any) so we can subtract its
    %% size before adding the new one. bondy_db has no put-modifier, so we
    %% read-then-apply. Single-node, experimental feature — approximate counters
    %% under a concurrent same-topic write race are acceptable (the trie /
    %% routing path is unaffected). The remote-replication counter sync is
    %% deferred until bondy_db anti-entropy reconciles the counters.
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
Evict expired retained messages from all realms.
""".
-spec evict_expired() -> non_neg_integer().

evict_expired() ->
    evict_expired('_').

-doc """
Evict expired retained messages from realm `Realm`.
""".
-spec evict_expired(uri() | '_') -> non_neg_integer().

evict_expired(Realm) ->
    evict_expired(Realm, undefined).

-doc """
Evict expired retained messages from realm `Realm` or all realms if
wildcard `'_'` is used.
Evaluates function `Fun` for each entry passing `Realm` and `Entry` as arguments.
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
    %% bondy_db is realm-scoped, so "all realms" enumerates the realm registry
    %% and evicts each (the plum_db `{'_', '_'}` whole-store fold has no direct
    %% analogue). Same O(retained messages) cost as before.
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
-doc """
Returns true if both lists have the same length and if each element of
the first list subsumes the corresponding element on the second list.
A term subsumes another term when is equal or when the first term is the
empty binary (wildcard).
""".
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
%% excluded and (if an `eligible` list is set) eligible. The old plum_db fold
%% expressed this through `maybe_append/3`.
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
%% (inclusive) to the end of the realm band, replacing the old plum_db
%% `fold_elements/4` + `throw({break, _})` loop. `Classify(Key)` returns
%% `keep | skip | done` (`done` = no later key can match, stop with ?EOT).
%% Gathers up to `Limit` session-eligible messages; the first `keep` key seen
%% once `Limit` are gathered becomes the (unprocessed) resume point via
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
    Now = erlang:system_time(second),
    case bondy_db:list(Table, Realm) of
        {ok, Rows} ->
            lists:foldl(
                fun
                    (
                        {Topic, #bondy_retained_message{valid_to = T} = Msg,
                            _Hlc},
                        Acc
                    ) when T > 0 andalso T =< Now ->
                        ok = bondy_db:apply(Table, Realm, Topic, clear),
                        ok = maybe_eval(Realm, EvictFun, Msg),
                        Acc + 1;
                    (_, Acc) ->
                        Acc
                end,
                0,
                Rows
            );
        {error, _} = Error ->
            ?LOG_WARNING(#{
                description => "Retained message eviction scan failed",
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
