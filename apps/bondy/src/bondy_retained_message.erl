%% =============================================================================
%%  bondy_retained_message.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc When publishing an event a topic the Publisher can ask the Broker to
%% retain the event being published as the most-recent event on this topic.
%%
%% <strong>This is experimental and does not scale with high traffic at the
%% moment.</strong>
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_retained_message).
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(DB_PREFIX(Realm), {retained_messages, Realm}).

-record(bondy_retained_message, {
    valid_to            ::  pos_integer(),
    publication_id      ::  id(),
    match_opts          ::  map(),
    %% Decoded payload
    details             ::  map(),
    args                ::  list() | undefined,
    kwargs              ::  map() | undefined,
    %% Encoded payload
    payload             ::  binary() | undefined
}).

-record(bondy_retained_continuation, {
    realm               ::  binary(),
    topic               ::  binary(),
    session_id          ::  id(),
    strategy            ::  binary(),
    opts                ::  list()
}).

-define(RESOLVER, lww).

-type t()               ::  #bondy_retained_message{}.
-type eot()             ::  ?EOT.
-type continuation()    ::  #bondy_retained_continuation{}.
-type match_opts()      ::  #{
    eligible => [id()],
    exclude => [id()]
}.
-type evict_fun()       ::  fun((uri(), t()) -> ok).

-export_type([t/0]).
-export_type([match_opts/0]).
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



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Realm :: uri(), Topic :: uri()) -> t() | undefined.

get(Realm, Topic) ->
    Opts = [{resolver, ?RESOLVER}],
    plum_db:get(?DB_PREFIX(Realm), Topic, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec take(Realm :: uri(), Topic :: uri()) -> t() | undefined.

take(Realm, Topic) ->
    Opts = [{resolver, ?RESOLVER}],
    plum_db:take(?DB_PREFIX(Realm), Topic, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec size(t()) -> integer().

size(Mssg) ->
    term_size(Mssg).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(
    Realm :: uri(),
    Topic :: uri(),
    SessionId :: id(),
    Strategy :: binary()) ->
    {[t()], continuation()} | eot().

match(Realm, Topic, SessionId, Strategy) ->
    match(Realm, Topic, SessionId, Strategy, [{limit, 100}]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(
    Realm :: uri(),
    Topic :: uri(),
    SessionId :: id(),
    Strategy :: binary(),
    Opts :: plum_db:fold_opts()) ->
    {[t()], continuation()} | eot().

match(Realm, Topic, SessionId, <<"exact">>, _) ->
    Result = get(Realm, Topic),
    {Matches, _} = maybe_append(Result, SessionId, {[], 0}),
    {Matches, ?EOT};

match(Realm, Topic, SessionId, <<"prefix">> = Strategy, Opts0) ->
    Len = byte_size(Topic),
    Opts = key_value:set(first, key_value:get(first, Opts0, Topic), Opts0),
    Limit = key_value:get(limit, Opts, 100),

    Fun = fun
        ({{_, <<Prefix:Len/binary, _/binary>>}, Obj}, {_, Cnt} = Acc)
        when Prefix =:= Topic andalso Cnt < Limit ->
            Result = plum_db_object:value(
                plum_db_object:resolve(Obj, ?RESOLVER)
            ),
            maybe_append(Result, SessionId, Acc);
        ({{_, <<Prefix:Len/binary, _/binary>> = Key}, _}, {List, _})
        when Prefix =:= Topic ->
            Cont = #bondy_retained_continuation{
                realm = Realm,
                topic = Topic,
                session_id = SessionId,
                strategy  = Strategy,
                opts = key_value:set(first, Key, Opts)
            },
            throw({break, {List, Cont}});
        (_, {List, _}) ->
            throw({break, {List, ?EOT}})
    end,
    case plum_db:fold_elements(Fun, {[], 0}, ?DB_PREFIX(Realm), Opts) of
        {L, N} when is_integer(N) ->
            {L, ?EOT};
        Other ->
            Other
    end;

match(Realm, Topic, SessionId, <<"wildcard">> = Strategy, Opts0) ->
    {First, MatchFun} = wildcard_opts(Topic),
    Opts = key_value:set(first, key_value:get(first, Opts0, First), Opts0),
    Limit = key_value:get(limit, Opts, 100),

    Fun = fun
        ({{_, Key}, Obj}, {List, Cnt} = Acc) when Cnt < Limit ->
            case MatchFun(Key) of
                true ->
                    Result = plum_db_object:value(
                        plum_db_object:resolve(Obj, ?RESOLVER)
                    ),
                    maybe_append(Result, SessionId, Acc);
                false ->
                    Acc;
                done ->
                    throw({break, {List, ?EOT}})
            end;
        ({{_, Key}, _}, {List, _}) ->
            Cont = #bondy_retained_continuation{
                realm = Realm,
                topic = Topic,
                session_id = SessionId,
                strategy  = Strategy,
                opts = key_value:set(first, Key, Opts)
            },
            throw({break, {List, Cont}})
    end,

    case plum_db:fold_elements(Fun, {[], 0}, ?DB_PREFIX(Realm), Opts) of
        {L, N} when is_integer(N) ->
            {L, ?EOT};
        Other ->
            Other
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec put(
    Realm :: uri(),
    Topic :: uri(),
    Event :: wamp_event(),
    MatchOpts :: match_opts()) -> ok.

put(Realm, Topic, Event, MatchOpts) ->
    put(Realm, Topic, Event, MatchOpts, 0).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec put(
    Realm :: uri(),
    Topic :: uri(),
    Event :: wamp_event(),
    MatchOpts :: match_opts(),
    TTL :: non_neg_integer()) -> ok.


put(Realm, Topic, #event{} = Event, MatchOpts, TTL) ->
    Retained = new(Event, MatchOpts, TTL),
    %% We abuse the Modifier to get cheap access to the existing value if any
    Size = term_size(Retained),

    Modifier = fun
        (Value) when Value == undefined orelse Value == '$deleted' ->
            bondy_retained_message_manager:incr_counters(Realm, 1, Size),
            Retained;
        (Values) ->
            ok = bondy_retained_message_manager:decr_counters(
                Realm, 1, term_size(Values)
            ),
            ok = bondy_retained_message_manager:incr_counters(
                Realm, 1, Size
            ),
            Retained
    end,



    %% TODO This will never scale as plumdb (due to replication and
    %% multi-versioning) cannot scale to high-frequency writes.
    %% We should either implement a partial replication mechanism and sessions
    %% will need to find the replicas for this topic in the cluster or we carry
    %% on replicating the messages in all the cluster but using a monotonic
    %% queue with windowing in front of the put, so that we throttle puts.
    %% This would be in effect a resolution parameter i.e. how many samples per
    %% minute do we want as resolution.

    plum_db:put(?DB_PREFIX(Realm), Topic, Modifier).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec to_event(Retained :: t(), SubscriptionId :: id()) -> wamp_event().

to_event(Retained, SubscriptionId) ->
    wamp_message:event(
        SubscriptionId,
        Retained#bondy_retained_message.publication_id,
        maps:put(retained, true, Retained#bondy_retained_message.details),
        Retained#bondy_retained_message.args,
        Retained#bondy_retained_message.kwargs
    ).


%% -----------------------------------------------------------------------------
%% @doc Evict expired retained messages from all realms.
%% @end
%% -----------------------------------------------------------------------------
-spec evict_expired() -> non_neg_integer().

evict_expired() ->
    evict_expired('_').


%% -----------------------------------------------------------------------------
%% @doc Evict expired retained messages from realm `Realm'.
%% @end
%% -----------------------------------------------------------------------------
-spec evict_expired(uri() | '_') -> non_neg_integer().

evict_expired(Realm) ->
    evict_expired(Realm, undefined).


%% -----------------------------------------------------------------------------
%% @doc Evict expired retained messages from realm `Realm' or all realms if
%% wildcard '_' is used.
%% Evaluates function Fun for each entry passing Realm and Entry as arguments.
%% @end
%% -----------------------------------------------------------------------------
-spec evict_expired(uri() | '_', evict_fun() | undefined) -> non_neg_integer().

evict_expired(Realm, EvictFun)
when is_binary(Realm) orelse Realm == '_'
andalso is_function(EvictFun, 2) ->
    Now = erlang:system_time(second),
    Fun = fun({{FP, Key}, Obj}, Acc) ->
        case plum_db_object:value(plum_db_object:resolve(Obj, ?RESOLVER)) of
            #bondy_retained_message{valid_to = T} = Mssg
            when T > 0 andalso T =< Now  ->
                _ = plum_db:delete(FP, Key),
                ok = maybe_eval(Realm, EvictFun, Mssg),
                Acc + 1;
            _ ->
                Acc
        end
    end,
    plum_db:fold_elements(Fun, 0, ?DB_PREFIX(Realm)).


%% =============================================================================
%% PRIVATE
%% =============================================================================



-spec new(
    Event :: wamp_event(), MatchOps :: map(), TTL :: non_neg_integer()) -> t().

new(#event{} = Event, MatchOps, TTL)
when is_map(MatchOps) andalso is_integer(TTL) andalso TTL >= 0 ->
    %% Todo manage alternative when event has encoded payload in the future
    #bondy_retained_message{
        valid_to = valid_to(TTL),
        publication_id = Event#event.publication_id,
        match_opts = MatchOps,
        details = Event#event.details,
        args = Event#event.args,
        kwargs = Event#event.kwargs
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


%% -----------------------------------------------------------------------------
%% @private
%% @doc Returns true if both lists have the same length and if each element of
%% the first list subsumes the corresponding element on the second list.
%% A term subsumes another term when is equal or when the first term is the
%% empty binary (wildcard).
%% @end
%% -----------------------------------------------------------------------------
subsumes(Term, Term) ->
    true;

subsumes(H1, H2) when length(H1) =/= length(H2) ->
    false;

subsumes([H|T1], [H|T2]) ->
    subsumes(T1, T2);

subsumes([<<>>|T1], [_|T2]) ->
    subsumes(T1, T2);

subsumes([], []) ->
    true;

subsumes(_, _) ->
    false.


%% @private
maybe_append(#bondy_retained_message{} = Event, SessionId, {List, Cnt} = Acc) ->
    Opts = Event#bondy_retained_message.match_opts,
    try
        not is_expired(Event) orelse throw(break),
        not is_excluded(SessionId, Opts) orelse throw(break),
        is_eligible(SessionId, Opts) orelse throw(break),
        {[Event | List], Cnt + 1}
    catch
        throw:break ->
            Acc
    end;

maybe_append(_, _, Acc) ->
    Acc.



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