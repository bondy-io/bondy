%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_retained_event).
-include_lib("wamp/include/wamp.hrl").

-define(DB_PREFIX(Realm), {retained_events, Realm}).


-record(bondy_retained_event, {
    valid_to            ::  pos_integer(),
    publication_id      ::  id(),
    match_opts          ::  map(),
    %% Decoded payload
    details             ::  map(),
    arguments           ::  list() | undefined,
    arguments_kw        ::  map() | undefined,
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

-type t()               ::  #bondy_retained_event{}.
-type continuation()    ::  #bondy_retained_continuation{}.
-type match_opts()      ::  #{
    eligible => [id()],
    exclude => [id()]
}.

-export_type([t/0]).
-export_type([match_opts/0]).


-export([evict_expired/0]).
-export([put/4]).
-export([put/5]).
-export([get/2]).
-export([match/1]).
-export([match/4]).
-export([match/5]).
-export([to_event/2]).



%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(Realm :: uri(), Topic :: uri()) -> t() | undefined.

get(Realm, Topic) ->
    plum_db:get(?DB_PREFIX(Realm), Topic).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(continuation()) -> [t()] | continuation().

match(Cont) ->
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
    [t()] | {[t()], continuation()}.

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
    [t()] | {[t()], continuation()}.

match(Realm, Topic, SessionId, <<"exact">>, _) ->
    Result = get(Realm, Topic),
    element(1, maybe_append(Result, SessionId, {[], 0}));


match(Realm, Topic, SessionId, <<"prefix">> = Strategy, Opts0) ->
    Len = byte_size(Topic),
    Opts = key_value:set(first, key_value:get(first, Opts0, Topic), Opts0),
    Limit = key_value:get(limit, Opts, 100),

    Fun = fun
        ({{_, <<Prefix:Len/binary, _/binary>>}, Obj}, {_, Cnt} = Acc)
        when Prefix =:= Topic andalso Cnt =< Limit ->
            Result = plum_db_object:value(plum_db_object:resolve(Obj, lww)),
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
            throw({break, List})
    end,
    plum_db:fold_elements(Fun, {[], 0}, ?DB_PREFIX(Realm), Opts);

match(Realm, Topic, SessionId, <<"wildcard">> = Strategy, Opts0) ->
    {First, MatchFun} = wildcard_opts(Topic),
    Opts = key_value:set(first, key_value:get(first, Opts0, First), Opts0),
    Limit = key_value:get(limit, Opts, 100),

    Fun = fun
        ({{_, Key}, Obj}, {List, Cnt} = Acc) when Cnt =< Limit ->
            case MatchFun(Key) of
                true ->
                    Result = plum_db_object:value(
                        plum_db_object:resolve(Obj, lww)
                    ),
                    maybe_append(Result, SessionId, Acc);
                false ->
                    Acc;
                done ->
                    throw({break, List})
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
    plum_db:fold_elements(Fun, {[], 0}, ?DB_PREFIX(Realm), Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec put(
    Realm :: uri(),
    Topic :: uri(),
    Event :: wamp_event(),
    MatchOpts :: match_opts()) -> ok.

put(Realm, Topic, Event = #event{}, MatchOpts) ->
    Retained = new(Event, MatchOpts, 0),
    plum_db:put(?DB_PREFIX(Realm), Topic, Retained).


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
    plum_db:put(?DB_PREFIX(Realm), Topic, Retained).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec to_event(Retained :: t(), SubscriptionId :: id()) -> wamp_event().

to_event(Retained, SubscriptionId) ->
    wamp_message:event(
        SubscriptionId,
        Retained#bondy_retained_event.publication_id,
        maps:put(retained, true, Retained#bondy_retained_event.details),
        Retained#bondy_retained_event.arguments,
        Retained#bondy_retained_event.arguments_kw
    ).


%% -----------------------------------------------------------------------------
%% @doc Evict expired retained events from all realms.
%% @end
%% -----------------------------------------------------------------------------
-spec evict_expired() -> non_neg_integer().

evict_expired() ->
    evict_expired('_').


%% -----------------------------------------------------------------------------
%% @doc Evict expired retained events from realm `Realm'.
%% @end
%% -----------------------------------------------------------------------------
-spec evict_expired(uri() | '_') -> non_neg_integer().

evict_expired(Realm) when is_binary(Realm) orelse Realm == '_' ->
    Now = erlang:system_time(second),
    Fun = fun({{FP, Key}, Obj}, Acc) ->
        case plum_db_object:value(plum_db_object:resolve(Obj, lww)) of
            #bondy_retained_event{valid_to = T}
            when T > 0 andalso T =< Now  ->
                _ = plum_db:delete(FP, Key),
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
    #bondy_retained_event{
        valid_to = valid_to(TTL),
        publication_id = Event#event.publication_id,
        match_opts = MatchOps,
        details = Event#event.details,
        arguments = Event#event.arguments,
        arguments_kw = Event#event.arguments_kw
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
maybe_append(#bondy_retained_event{} = Event, SessionId, {List, Cnt} = Acc) ->
    Opts = Event#bondy_retained_event.match_opts,
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
            %% Non eligible! Most probably a mistake but we need to
            %% respect the semantics
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
is_expired(#bondy_retained_event{valid_to = T}) ->
    T > 0 andalso T =< erlang:system_time(second).


%% %% @private
%% wildcard_regex() ->
%%     Regex = persistent_term:get({?MODULE, pattern}, undefined),
%%     wildcard_regex(Rule, Regex).


%% %% @private
%% wildcard_regex(undefined) ->
%%     %% End = ^([^*]*[^\.])[\.]+$
%%     %% Start = ^[\.]+[^*]*$
%%     %% Inset = ^([^*]*)[\.]{2}[^*]*$
%%     {ok, Regex} = re:compile("^[\.]+[^*]*$|^([^*]*)[\.]{2}[^*]*$|^([^*]*[^\.])[\.]+$"),
%%     ok = persistent_term:put({?MODULE, pattern}, Regex),
%%     Regex;

%% wildcard_regex(Regex) ->
%%     Regex.