%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_promise).
-moduledoc """
A promise is used to implement a capability and a feature:
- the capability to match the callee response (`wamp_yield()` or `wamp_error()`)
back to the origin `wamp_call()` and Caller
- the call_timeout feature at the dealer level
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-define(TABLES, tuplespace:tables(bondy_rpc_promise)).
-define(TAB(RealmUri), tuplespace:locate_table(bondy_rpc_promise, RealmUri)).

-record(bondy_rpc_promise, {
    key :: key(),
    %% We have the procedure so that we can reference it when performing
    %% authorization of user requests like CANCEL.
    procedure_uri :: optional(uri()),
    callee :: bondy_ref:t(),
    caller :: bondy_ref:t(),
    via :: optional(queue:queue(bondy_ref:t())),
    timeout :: optional(timeout()),
    timestamp :: pos_integer(),
    info :: optional(map())
}).

%% Wildcards are allowed only when key is used as pattern.
%% All lookups are ets:select/3 over the (realm_uri, type)-bound prefix of
%% this ordered_set: the most common patterns (YIELD | ERROR ground
%% callee_session_id and invocation_id; CANCEL grounds caller_session_id
%% and call_id) leave earlier key fields as wildcards, so every match is a
%% scan of that prefix region, bounded by the realm partition's in-flight
%% promises of that type. Progressive call results repeat the YIELD lookup
%% once per progressive result, so under heavy streaming with many
%% in-flight promises this is the first place to revisit (e.g. a
%% callee-first key or a secondary index).
%% We opted to have a single entry for all use cases but this might change
%% in the future.
-record(bondy_rpc_promise_key, {
    realm_uri :: uri(),
    type :: call | invocation,
    caller_session_id :: wildcard(bondy_session_id:t()),
    call_id :: wildcard(id()),
    callee_session_id :: wildcard(bondy_session_id:t()),
    invocation_id :: wildcard(optional(id())),
    expiry :: wildcard(optional(timeout()))
}).

-opaque t() :: #bondy_rpc_promise{}.
-type key() :: #bondy_rpc_promise_key{}.
-type info() :: map().
-type take_fun() :: fun((error | {ok, t()}) -> any()).
-type evict_fun() :: fun((t()) -> ok).
-type wildcard(T) :: T | '_'.
-type status() :: all | active | expired.
-type opts() :: #{
    call_id => id(),
    procedure_uri => uri(),
    %% For call promises: the resolved remote/bridged callee target, so a
    %% CANCEL (user-issued or caller-death) can be routed to the callee's
    %% node.
    callee => bondy_ref:t(),
    via =>
        bondy_ref:relay()
        | bondy_ref:bridge_relay(),
    timeout => timeout(),
    %% Absolute expiry cap in milliseconds (system time). Progressive
    %% results slide the expiry (see refresh/1) but never past this.
    deadline => pos_integer() | infinity
}.

-export_type([t/0]).
-export_type([key/0]).
-export_type([take_fun/0]).
-export_type([evict_fun/0]).

-export([add/1]).
-export([call_id/1]).
-export([call_key_pattern/3]).
-export([callee/1]).
-export([caller/1]).
-export([evict_expired/1]).
-export([expiry/1]).
-export([count_by_procedure/0]).
-export([find/1]).
-export([find_all/1]).
-export([flush/2]).
-export([flush/3]).
-export([get/2]).
-export([get/3]).
-export([info/1]).
-export([invocation_id/1]).
-export([invocation_key_pattern/5]).
-export([key/1]).
-export([new_call/4]).
-export([new_invocation/6]).
-export([procedure_uri/1]).
-export([realm_uri/1]).
-export([refresh/1]).
-export([take/1]).
-export([take/2]).
-export([timeout/1]).
-export([timestamp/1]).
-export([type/1]).
-export([via/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Creates a new promise.
""".
-spec new_call(
    RealmUri :: uri(),
    Caller :: bondy_ref:t(),
    CallId :: id(),
    Opts :: opts()
) -> t().

new_call(RealmUri, Caller, CallId, Opts) ->
    %% We validate the arguments
    bondy_ref:is_type(Caller) orelse
        error({badarg, {caller, Caller}}),

    Callee = maps:get(callee, Opts, undefined),
    Callee == undefined orelse
        bondy_ref:is_type(Callee) orelse
        error({badarg, {callee, Callee}}),

    Via =
        case maps:get(via, Opts, undefined) of
            undefined ->
                queue:new();
            Term ->
                case queue:is_queue(Term) of
                    true ->
                        Term;
                    false ->
                        bondy_ref:is_type(Term) orelse
                            error({badarg, {via, Term}}),
                        queue:from_list([Term])
                end
        end,

    Uri = maps:get(procedure_uri, Opts, undefined),
    is_binary(Uri) orelse
        Uri == undefined orelse
        error({badarg, {procedure_uri, Uri}}),

    TTL = maps:get(timeout, Opts, undefined),
    (is_integer(TTL) andalso TTL > 0) orelse
        TTL == undefined orelse
        TTL == infinity orelse
        error({badarg, {timeout, TTL}}),

    %% We create the key
    CallerSessionId = bondy_ref:session_id(Caller),

    Now = erlang:system_time(millisecond),
    %% min/2 works because integer() < infinity in term order
    Expiry = min(
        calc_expiry(TTL, Now), maps:get(deadline, Opts, infinity)
    ),

    Key = #bondy_rpc_promise_key{
        realm_uri = RealmUri,
        type = call,
        caller_session_id = CallerSessionId,
        call_id = CallId,
        expiry = Expiry
    },

    %% We create the promise
    Keys = [callee, via, procedure_uri, timeout],
    Info = maps:without(Keys, Opts),

    #bondy_rpc_promise{
        key = Key,
        procedure_uri = Uri,
        caller = Caller,
        callee = Callee,
        via = Via,
        info = Info,
        timeout = TTL,
        timestamp = Now
    }.

-doc """
Creates a new promise.
""".
-spec new_invocation(
    RealmUri :: uri(),
    Caller :: bondy_ref:t(),
    CallId :: id(),
    Callee :: bondy_ref:t(),
    InvocationId :: id(),
    Opts :: opts()
) -> t().

new_invocation(RealmUri, Caller, CallId, Callee, InvocationId, Opts) when
    is_binary(RealmUri), is_integer(InvocationId), is_integer(CallId)
->
    %% We validate the arguments
    bondy_ref:is_type(Callee) orelse
        error({badarg, {callee, Callee}}),

    bondy_ref:is_type(Caller) orelse
        error({badarg, {caller, Caller}}),

    Via =
        case maps:get(via, Opts, undefined) of
            undefined ->
                queue:new();
            Term ->
                case queue:is_queue(Term) of
                    true ->
                        Term;
                    false ->
                        bondy_ref:is_type(Term) orelse
                            error({badarg, {via, Term}}),
                        queue:from_list([Term])
                end
        end,

    Uri = maps:get(procedure_uri, Opts, undefined),
    is_binary(Uri) orelse
        Uri == undefined orelse
        error({badarg, {procedure_uri, Uri}}),

    TTL = maps:get(timeout, Opts, undefined),
    (is_integer(TTL) andalso TTL > 0) orelse
        TTL == undefined orelse
        TTL == infinity orelse
        error({badarg, {timeout, TTL}}),

    %% We create the key
    CalleeSessionId = bondy_ref:session_id(Callee),
    CallerSessionId = bondy_ref:session_id(Caller),

    Now = erlang:system_time(millisecond),
    %% min/2 works because integer() < infinity in term order
    Expiry = min(
        calc_expiry(TTL, Now), maps:get(deadline, Opts, infinity)
    ),

    Key = #bondy_rpc_promise_key{
        realm_uri = RealmUri,
        type = invocation,
        caller_session_id = CallerSessionId,
        call_id = CallId,
        callee_session_id = CalleeSessionId,
        invocation_id = InvocationId,
        expiry = Expiry
    },

    %% We create the promise
    Keys = [via, procedure_uri, timeout],
    Info = maps:without(Keys, Opts),

    #bondy_rpc_promise{
        key = Key,
        procedure_uri = Uri,
        caller = Caller,
        callee = Callee,
        via = Via,
        info = Info,
        timeout = TTL,
        timestamp = Now
    }.

-doc "Returns the realm of the promise.".
-spec key(t()) -> key().

key(#bondy_rpc_promise{key = Val}) ->
    Val.

-doc "Returns the promise type.".
-spec type(t()) -> call | invocation.

type(#bondy_rpc_promise{key = Key}) ->
    Key#bondy_rpc_promise_key.type.

-doc "Returns the realm of the promise.".
-spec realm_uri(t()) -> uri().

realm_uri(#bondy_rpc_promise{key = Key}) ->
    Key#bondy_rpc_promise_key.realm_uri.

-doc "Returns the invocation request identifier.".
-spec invocation_id(t()) -> optional(id()).

invocation_id(#bondy_rpc_promise{key = Key}) ->
    Key#bondy_rpc_promise_key.invocation_id.

-doc "Returns the call request identifier.".
-spec call_id(t()) -> optional(id()).

call_id(#bondy_rpc_promise{key = Key}) ->
    Key#bondy_rpc_promise_key.call_id.

-doc """
Returns the callee (`bondy_ref:t()`) that is the target of this
promise.
""".
-spec callee(t()) -> optional(bondy_ref:t()).

callee(#bondy_rpc_promise{callee = Val}) ->
    Val.

-doc """
Returns the caller (`bondy_ref:t()`) who made the call request
associated with this invocation promise.
""".
-spec caller(t()) -> bondy_ref:t().

caller(#bondy_rpc_promise{caller = Val}) ->
    Val.

-doc """
Returns the queue of relays that are needed to forward an invocation
result to the caller.
""".
-spec via(t()) -> queue:queue(bondy_ref:relay() | bondy_ref:bridge_relay()).

via(#bondy_rpc_promise{via = Val}) ->
    Val.

-spec procedure_uri(t()) -> optional(uri()).

procedure_uri(#bondy_rpc_promise{procedure_uri = Val}) ->
    Val.

-spec timeout(t()) -> optional(timeout()).

timeout(#bondy_rpc_promise{timeout = Val}) ->
    Val.

-spec info(t()) -> info().

info(#bondy_rpc_promise{info = Val}) ->
    Val.

-spec get(Key :: any(), t()) -> any() | no_return().

get(Key, #bondy_rpc_promise{info = Info}) ->
    maps:get(Key, Info).

-spec get(Key :: any(), t(), Default :: any()) -> any().

get(Key, #bondy_rpc_promise{info = Info}, Default) ->
    maps:get(Key, Info, Default).

-spec expiry(t()) -> optional(timeout()).

expiry(#bondy_rpc_promise{key = Key}) ->
    Key#bondy_rpc_promise_key.expiry.

-spec timestamp(t()) -> pos_integer().

timestamp(#bondy_rpc_promise{timestamp = Val}) ->
    Val.

-doc """
Pattern for looking up promises on the promise table.
""".
-spec call_key_pattern(
    RealmUri :: uri(),
    Caller :: wildcard(bondy_ref:t()),
    CallId :: wildcard(id())
) -> key().

call_key_pattern(RealmUri, Caller, CallId) when is_binary(RealmUri) ->
    CallId == '_' orelse is_integer(CallId) orelse
        error({badarg, {invocation_id, CallId}}),

    CallerSessionId =
        case Caller of
            '_' when CallId =/= '_' ->
                %% We need the caller to get the session_id in order to
                %% disambiguate the call_id
                error({badarg, {caller, Caller}});
            '_' ->
                '_';
            _ ->
                bondy_ref:session_id(Caller)
        end,

    #bondy_rpc_promise_key{
        realm_uri = RealmUri,
        type = call,
        caller_session_id = CallerSessionId,
        call_id = CallId,
        callee_session_id = '_',
        invocation_id = '_',
        expiry = '_'
    }.

-doc """
Pattern for looking up promises on the promise table.
""".
-spec invocation_key_pattern(
    RealmUri :: uri(),
    Caller :: wildcard(bondy_ref:t()),
    CallId :: wildcard(id()),
    Callee :: wildcard(bondy_ref:t()),
    InvocationId :: wildcard(id())
) -> key().

invocation_key_pattern(RealmUri, Caller, CallId, Callee, InvocationId) when
    is_binary(RealmUri)
->
    InvocationId == '_' orelse is_integer(InvocationId) orelse
        error({badarg, {invocation_id, InvocationId}}),

    CallId == '_' orelse is_integer(CallId) orelse
        error({badarg, {invocation_id, CallId}}),

    CalleeSessionId =
        case Callee of
            '_' when InvocationId =/= '_' ->
                %% We need the callee to get the session_id in order to
                %% disambiguate the invocation_id
                error({badarg, {callee, Callee}});
            '_' ->
                '_';
            _ ->
                bondy_ref:session_id(Callee)
        end,

    CallerSessionId =
        case Caller of
            '_' when CallId =/= '_' ->
                %% We need the caller to get the session_id in order to
                %% disambiguate the call_id
                error({badarg, {caller, Caller}});
            '_' ->
                '_';
            _ ->
                bondy_ref:session_id(Caller)
        end,

    #bondy_rpc_promise_key{
        realm_uri = RealmUri,
        type = invocation,
        caller_session_id = CallerSessionId,
        call_id = CallId,
        callee_session_id = CalleeSessionId,
        invocation_id = InvocationId,
        expiry = '_'
    }.

-doc """
Returns the count of in-flight promises per procedure URI across all
partitions.

A scrape-time aggregation (used by `bondy_prometheus_collector` for the
`bondy_rpc_inflight_invocations` family): computed from the live
promise store with a match-spec select, so it can never drift the way a
hot-path inc/dec gauge would on a missed settlement path. Cost is
O(in-flight promises), paid by the scraper.
""".
-spec count_by_procedure() -> #{uri() => pos_integer()}.

count_by_procedure() ->
    MS = [
        {
            #bondy_rpc_promise{procedure_uri = '$1', _ = '_'},
            [{is_binary, '$1'}],
            ['$1']
        }
    ],
    lists:foldl(
        fun(Tab, Acc0) ->
            try ets:select(Tab, MS) of
                Uris ->
                    lists:foldl(
                        fun(Uri, Acc) ->
                            maps:update_with(Uri, fun(N) -> N + 1 end, 1, Acc)
                        end,
                        Acc0,
                        Uris
                    )
            catch
                _:_ ->
                    Acc0
            end
        end,
        #{},
        ?TABLES
    ).

-doc """
Adds the promise `P` to the promise table.

If the promise is not taken before `Timeout` milliseconds, the caller
will receive an error with reason `wamp.error.timeout`.
""".
-spec add(t() | [t()]) -> ok | no_return().

add(#bondy_rpc_promise{} = T) ->
    add([T]);
add([]) ->
    ok;
add([#bondy_rpc_promise{key = Key} | _] = L) ->
    RealmUri = Key#bondy_rpc_promise_key.realm_uri,

    IsValid = fun
        (#bondy_rpc_promise{key = K}) ->
            RealmUri == K#bondy_rpc_promise_key.realm_uri;
        (_) ->
            false
    end,

    lists:all(IsValid, L) orelse error(badarg),

    %% Atomically add the list of promises
    case ets:insert_new(?TAB(RealmUri), L) of
        true -> ok;
        false -> error({badarg, {duplicates, L}})
    end.

-doc """
Return and removes the promise that matches key pattern.
""".
-spec take(Pattern :: key()) -> {ok, t()} | error.

take(Pattern) ->
    take(Pattern, active).

-doc """
Return and removes the promise that matches key pattern.
""".
-spec take(Pattern :: key(), Status :: status()) -> {ok, t()} | error.

take(#bondy_rpc_promise_key{} = Pattern, Status) when
    Status == all orelse Status == active orelse Status == expired
->
    %% Key is a pattern so we need to do a find followed by a delete.
    case do_find(Pattern, Status) of
        {ok, #bondy_rpc_promise{key = Key}} = OK ->
            Tab = ?TAB(Key#bondy_rpc_promise_key.realm_uri),
            true = ets:delete(Tab, Key),
            OK;
        error ->
            error
    end.

-doc """
Reads the active promise that matches the key pattern.
""".
-spec find(key()) -> {ok, t()} | error.

find(#bondy_rpc_promise_key{} = Key) ->
    do_find(Key, active).

-doc """
Reads ALL active promises matching the key pattern, in one pass.

Use this — never repeated `find/1` calls — when iterating promises that
the iteration does not consume: `find/1` on the same pattern returns the
same promise again, so a read-only loop over it never terminates (the
kill-mode CANCEL did exactly that, machine-gunning INTERRUPTs at the
callee until the callee's ERROR settled the promise).
""".
-spec find_all(key()) -> [t()].

find_all(#bondy_rpc_promise_key{} = Key) ->
    Tab = ?TAB(Key#bondy_rpc_promise_key.realm_uri),
    MS = match_spec(Key, active),
    ets:select(Tab, MS).

-doc """
Slides the promise's expiry forward to `now + timeout`, capped by the
promise's absolute deadline (the `deadline` option given at creation, if
any).

Used for progressive call results: per the WAMP spec, for a progressive
call the timeout is the limit between the call and the first result and
between results thereafter, so each progressive result restarts it.

A promise without a timeout is left untouched. A promise that was settled
concurrently is a no-op (`error`).
""".
-spec refresh(t()) -> ok | error.

refresh(#bondy_rpc_promise{key = Key, timeout = TTL} = P0) when
    is_integer(TTL) andalso TTL > 0
->
    Now = erlang:system_time(millisecond),
    Deadline = maps:get(deadline, P0#bondy_rpc_promise.info, infinity),
    %% min/2 works because integer() < infinity in term order
    Expiry = min(TTL + Now, Deadline),
    Tab = ?TAB(Key#bondy_rpc_promise_key.realm_uri),

    %% The expiry is part of the key, so a refresh is a take + insert of
    %% the updated record. Not atomic; the only concurrent writer for a
    %% given promise is its settlement, in which case we must not
    %% resurrect it.
    case ets:take(Tab, Key) of
        [#bondy_rpc_promise{} = P1] ->
            P = P1#bondy_rpc_promise{
                key = Key#bondy_rpc_promise_key{expiry = Expiry}
            },
            true = ets:insert(Tab, P),
            ok;
        [] ->
            error
    end;
refresh(#bondy_rpc_promise{}) ->
    ok.

-doc """
Removes all expired items.
If the option `on_evict` was set, the bound function will be called passing
the expired item as argument.
An expired item is one for which its expiry (millisecs) has been reached.
Returns the atom `ok`.
""".
-spec evict_expired(
    Opts :: #{parallel => boolean(), on_evict => evict_fun()}
) -> ok.

evict_expired(Opts) ->
    %% No parallelism at the moment

    OnEvict = maps:get(on_evict, Opts, undefined),

    is_function(OnEvict, 1) orelse
        undefined == OnEvict orelse
        error({badarg, {on_evict, OnEvict}}),

    _ = [do_evict_expired(Tab, OnEvict) || Tab <- ?TABLES],

    ok.

-doc """
Removes all pending promises from the queue for the reference.
Equivalent to `flush(RealmUri, Ref, #{})`.
""".
-spec flush(RealmUri :: uri(), bondy_ref:t() | '_') -> ok.

flush(RealmUri, Ref) ->
    flush(RealmUri, Ref, #{}).

-doc """
Removes all pending promises from the queue for the reference.

When `Ref` is a concrete `bondy_ref:t()`, two optional callbacks in `Opts`
are invoked once per matching promise before it is deleted:

- `on_callee_flush` — invoked per `invocation` promise where `Ref` is the
callee. Used by the dealer to fast-fail in-flight calls when the callee
session dies, avoiding waits up to the call timeout.
- `on_caller_flush` — invoked per promise where `Ref` is the caller: for
`invocation` promises the callee is local; for `call` promises the callee
is remote or bridged (its ref is in the promise when known). Used by the
dealer to INTERRUPT callees still working on behalf of a caller session
that died (e.g. a callee producing progressive results that no one will
consume).

No callback is invoked when `Ref` is `_` (bulk flush).
""".
-spec flush(
    RealmUri :: uri(),
    bondy_ref:t() | '_',
    Opts :: #{
        on_callee_flush => fun((t()) -> ok),
        on_caller_flush => fun((t()) -> ok)
    }
) -> ok.

flush(RealmUri, '_', _Opts) ->
    Tab = ?TAB(RealmUri),
    KeyPattern = #bondy_rpc_promise_key{
        realm_uri = RealmUri,
        type = '_',
        caller_session_id = '_',
        call_id = '_',
        callee_session_id = '_',
        invocation_id = '_',
        expiry = '_'
    },
    _ = do_flush(Tab, KeyPattern),
    ok;
flush(RealmUri, Ref, Opts) ->
    Tab = ?TAB(RealmUri),
    OnCalleeFlush = maps:get(on_callee_flush, Opts, undefined),
    OnCallerFlush = maps:get(on_caller_flush, Opts, undefined),

    is_function(OnCalleeFlush, 1) orelse
        undefined == OnCalleeFlush orelse
        error({badarg, {on_callee_flush, OnCalleeFlush}}),

    is_function(OnCallerFlush, 1) orelse
        undefined == OnCallerFlush orelse
        error({badarg, {on_caller_flush, OnCallerFlush}}),

    %% As caller — call promises (remote/bridged callee) and in-flight
    %% invocation promises (local callee): optionally notify so the dealer
    %% can INTERRUPT the callee. The caller itself is gone — there is
    %% nothing to send it.
    _ = do_flush_with_callback(
        Tab, call_key_pattern(RealmUri, Ref, '_'), OnCallerFlush
    ),
    _ = do_flush_with_callback(
        Tab,
        invocation_key_pattern(RealmUri, Ref, '_', '_', '_'),
        OnCallerFlush
    ),

    %% As callee — optionally invoke callback per promise before deletion
    _ = do_flush_with_callback(
        Tab,
        invocation_key_pattern(RealmUri, '_', '_', Ref, '_'),
        OnCalleeFlush
    ),

    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

do_find(#bondy_rpc_promise_key{} = Key, Status) ->
    Tab = ?TAB(Key#bondy_rpc_promise_key.realm_uri),
    MS = match_spec(Key, Status),

    case ets:select(Tab, MS, 1) of
        {[#bondy_rpc_promise{} = Promise], _Cont} ->
            {ok, Promise};
        '$end_of_table' ->
            error
    end.

%% @private
do_flush(Tab, Key) ->
    [{MatchPattern, _, _}] = match_spec(Key),
    MS = [{MatchPattern, [], ['true']}],
    ets:select_delete(Tab, MS).

%% @private
do_flush_with_callback(Tab, Key, undefined) ->
    do_flush(Tab, Key);
do_flush_with_callback(Tab, Key, OnFlush) ->
    [{MatchPattern, _, _}] = match_spec(Key),
    MS = [{MatchPattern, [], ['$_']}],
    do_flush_with_callback_loop(Tab, OnFlush, ets:select(Tab, MS, 100)).

%% @private
do_flush_with_callback_loop(_, _, '$end_of_table') ->
    ok;
do_flush_with_callback_loop(Tab, OnFlush, {Promises, Cont}) ->
    _ = [
        begin
            %% This is an ordered_set so take always returns
            %% at most 1 element
            case ets:take(Tab, K) of
                [Promise] ->
                    maybe_apply(OnFlush, Promise);
                [] ->
                    %% The item was removed by some other process since we
                    %% read it, as select followed by take is not atomic
                    ok
            end
        end
     || #bondy_rpc_promise{key = K} <- Promises
    ],
    do_flush_with_callback_loop(Tab, OnFlush, ets:select(Cont)).

%% @private
do_evict_expired(Tab, OnEvict) ->
    N = 100,
    MS = match_spec(undefined, expired),
    do_evict_expired(Tab, OnEvict, ets:select(Tab, MS, N)).

do_evict_expired(_, _, '$end_of_table') ->
    ok;
do_evict_expired(Tab, OnEvict, {Promises, Cont}) ->
    _ = [
        begin
            %% This is an ordered_set so take always returns
            %% at most 1 element
            case ets:take(Tab, Key) of
                [Promise] ->
                    maybe_apply(OnEvict, Promise);
                [] ->
                    %% The item was removed by some other process
                    %% since we read it, as select followed by take is
                    %% not atomic, do nothing
                    ok
            end
        end
     || #bondy_rpc_promise{key = Key} = Promise <- Promises
    ],

    do_evict_expired(Tab, OnEvict, ets:select(Cont)).

%% @private
maybe_apply(undefined, _) ->
    ok;
maybe_apply(Fun, V) ->
    try
        _ = Fun(V),
        ok
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                description => "Error while applying user callback",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            ok
    end.

%% @private
calc_expiry(infinity, _) ->
    infinity;
calc_expiry(undefined, _) ->
    infinity;
calc_expiry(TTL, Now) ->
    TTL + Now.

%% @private
match_pattern(Key) ->
    #bondy_rpc_promise{
        key = Key,
        procedure_uri = '_',
        callee = '_',
        caller = '_',
        via = '_',
        timeout = '_',
        timestamp = '_',
        info = '_'
    }.

%% @private
match_spec(Key0) ->
    match_spec(Key0, active).

%% @private
-spec match_spec(key(), active | expired | all) -> ets:match_spec().

match_spec(Key0, active) ->
    Now = erlang:system_time(millisecond),
    Key = Key0#bondy_rpc_promise_key{expiry = '$1'},
    MatchPattern = match_pattern(Key),
    Conditions = [{'>=', '$1', {const, Now}}],
    [{MatchPattern, Conditions, ['$_']}];
match_spec(undefined, expired) ->
    Key = #bondy_rpc_promise_key{
        realm_uri = '_',
        type = '_',
        caller_session_id = '_',
        call_id = '_',
        callee_session_id = '_',
        invocation_id = '_',
        expiry = '_'
    },
    match_spec(Key, expired);
match_spec(Key0, expired) ->
    Now = erlang:system_time(millisecond),
    Key = Key0#bondy_rpc_promise_key{expiry = '$1'},
    MatchPattern = match_pattern(Key),
    Conditions = [{'<', '$1', {const, Now}}],
    [{MatchPattern, Conditions, ['$_']}];
match_spec(Key, all) ->
    MatchPattern = match_pattern(Key),
    [{MatchPattern, [], ['$_']}].
