%% =============================================================================
%%  bondy_registry_trie .erl -
%%
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
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
%% @doc A materialized view of the elements stored in the registry main store
%% (plum_db) that is used to match RPC procedures and Pub/Sub topics during the
%% registration/subscription and call/publish operations respectively.
%%
%% The trie consists of a number of a set of `ets' tables and `art' tries.
%%
%% == Local vs Remote Subscriptions ==
%% WARNING:In the case of remote exact matching subscriptions the trie only
%% stores the node. But in the case of remote pattern subscriptions it stores
%% the whole entry and on return projects only the node (by deduplicating
%% them). This means that if you are using limits (continuations) you might get
%% duplicates.
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_registry_trie).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_registry.hrl").

-record(bondy_registry_trie, {
    %% Stores registrations w/match_policy == exact
    %% (ets bag)
    proc_tab                    ::  ets:tab(),
    %% Stores registrations w/match_policy =/= exact
    proc_art                    ::  art:t(),
    %% Stores local subscriptions w/match_policy == exact (ets bag)
    topic_tab                   ::  ets:tab(),
    %% Stores remote subscriptions w/match_policy == exact (ets set)
    topic_remote_tab            ::  ets:tab(),
    %% Stores local subscriptions w/match_policy =/= exact
    topic_art                   ::  art:t(),
    %% Stores counter per URI, used to distinguish on_create vs
    %% on_register|on_subscribe
    counters                    ::  ets:tab()
}).

-record(proc_index, {
    key                         ::  index_key(),
    entry_key                   ::  var(entry_key()),
    is_proxy                    ::  var(boolean()),
    invoke                      ::  var(invoke()),
    timestamp                   ::  var(pos_integer())
}).

-record(topic_idx, {
    key                         ::  index_key(),
    protocol_session_id         ::  var(id()),
    entry_key                   ::  var(entry_key()),
    is_proxy                    ::  var(boolean())
}).

-record(topic_remote_idx, {
    key                         ::  index_key(),
    node                        ::  var(node()),
    ref_count                   ::  var(non_neg_integer())
}).

-record(trie_continuation, {
    type                        ::  entry_type(),
    function                    ::  find | match,
    policy                      ::  binary() | '_',
    realm_uri                   ::  uri(),
    uri                         ::  uri(),
    opts                        ::  map(),
    proc_cont                   ::  optional(ets:continuation() | eot()),
    proc_art_cont               ::  optional(term() | eot()),
    topic_cont                  ::  optional(ets:continuation() | eot()),
    topic_remote_cont           ::  optional(ets:continuation() | eot()),
    topic_art_cont              ::  optional(term() | eot()),
    trie                        ::  t()
}).


-type t()                       ::  #bondy_registry_trie{}.
-type index_key()               ::  {RealmUri :: uri(), Uri :: uri()}.
-type invoke()                  ::  binary().
-type registration_match()      ::  {
                                        index_key(),
                                        entry_key(),
                                        IsProxy :: boolean(),
                                        invoke(),
                                        Timestamp :: pos_integer()
                                    }.
-type registration_match_res()  ::  [registration_match()].
-type registration_match_opts() ::  #{
                                        %% WAMP match policy
                                        match => wildcard(binary()),
                                        %% WAMP invocation policy
                                        invoke => wildcard(binary()),
                                        sort =>
                                            bondy_registry_entry:comparator()
                                    }.
-type subscription_match()      ::  {
                                        index_key(),
                                        entry_key(),
                                        Isproxy :: boolean()
                                    }.
-type subscription_match_res()  ::  {
                                        Local :: [subscription_match()],
                                        Remote :: [node()]
                                    }.
-type subscription_match_opts() ::  #{
                                        nodestring => wildcard(nodestring()),
                                        node => wildcard(node()),
                                        eligible => [id()],
                                        exclude => [id()],
                                        sort =>
                                            bondy_registry_entry:comparator()
                                    }.
-type match_opts()              ::  registration_match_opts()
                                    | subscription_match_opts().
-type match_res()               ::  registration_match_res()
                                    | subscription_match_res()
                                    |   {
                                            registration_match_res(),
                                            eot() | continuation()
                                        }
                                    |   {
                                            subscription_match_res(),
                                            eot() | continuation()
                                        }
                                    | eot().

-opaque continuation()          ::  #trie_continuation{}.
-type eot()                     ::  ?EOT.
-type wildcard(T)               ::  T | '_'.
-type var(T)                    ::  wildcard(T) | '$1' | '$2' | '$3' | '$4'.


%% Aliases
-type entry()                   ::  bondy_registry_entry:t().
-type entry_type()              ::  bondy_registry_entry:entry_type().
-type entry_key()               ::  bondy_registry_entry:key().


-export_type([t/0]).
-export_type([continuation/0]).
-export_type([eot/0]).
-export_type([match_opts/0]).
-export_type([match_res/0]).
-export_type([registration_match/0]).
-export_type([registration_match_opts/0]).
-export_type([registration_match_res/0]).
-export_type([subscription_match/0]).
-export_type([subscription_match_opts/0]).
-export_type([subscription_match_res/0]).


%% API
-export([add/2]).
-export([delete/2]).
-export([format_error/2]).
-export([info/1]).
-export([find/1]).
-export([find/5]).
-export([match/1]).
-export([match/5]).
-export([new/1]).
-export([continuation_info/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(Index :: integer()) -> t().

new(Index) ->
    Opts = [
        named_table,
        public,
        {read_concurrency, true},
        {write_concurrency, true},
        {decentralized_counters, true}
    ],

    %% Stores registrations w/match_policy == exact
    {ok, T1} = bondy_table_owner:add_or_claim(
        gen_table_name(proc_tab, Index),
        [bag, {keypos, 2} | Opts]
    ),

    %% Stores registrations w/match_policy =/= exact
    T2 = art:new(gen_table_name(proc_art, Index), []),

    %% Stores local subscriptions w/match_policy == exact
    {ok, T3} = bondy_table_owner:add_or_claim(
        gen_table_name(topic_tab, Index),
        [bag, {keypos, 2} | Opts]
    ),

    %% Stores remote subscriptions (set)
    {ok, T4} = bondy_table_owner:add_or_claim(
        gen_table_name(topic_remote_tab, Index),
        [set, {keypos, 2} | Opts]
    ),

    %% Stores local subscriptions w/match_policy =/= exact
    T5 = art:new(gen_table_name(topic_art, Index), []),

    %% Stores realm/uri counters
    {ok, T6} = bondy_table_owner:add_or_claim(
        gen_table_name(counters, Index),
        [set, {keypos, 1} | Opts]
    ),

    #bondy_registry_trie{
        proc_tab = T1,
        proc_art = T2,
        topic_tab = T3,
        topic_remote_tab = T4,
        topic_art = T5,
        counters = T6
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec info(Trie :: t()) -> #{size => integer(), memory => integer()}.

info(#bondy_registry_trie{} = Trie) ->
    ArtInfo1 = art:info(Trie#bondy_registry_trie.proc_art),
    ArtInfo2 = art:info(Trie#bondy_registry_trie.topic_art),

    Size =
        key_value:get(nodes, ArtInfo1) +
        key_value:get(nodes, ArtInfo2) +
        ets:info(Trie#bondy_registry_trie.proc_tab, size) +
        ets:info(Trie#bondy_registry_trie.topic_tab, size) +
        ets:info(Trie#bondy_registry_trie.topic_remote_tab, size),

    Mem =
        key_value:get(memory, ArtInfo1) +
        key_value:get(memory, ArtInfo2) +
        ets:info(Trie#bondy_registry_trie.proc_tab, memory) +
        ets:info(Trie#bondy_registry_trie.topic_tab, memory) +
        ets:info(Trie#bondy_registry_trie.topic_remote_tab, memory),

    #{size => Size, memory => Mem}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec continuation_info(continuation()) ->
    #{type := entry_type(), realm_uri := uri()}.

continuation_info(#trie_continuation{type = Type, realm_uri = RealmUri}) ->
    #{type => Type, realm_uri => RealmUri}.



%% -----------------------------------------------------------------------------
%% @doc Adds and entry to the trie.
%% @end
%% -----------------------------------------------------------------------------
-spec add(Entry :: entry(), Trie :: t()) ->
    {ok, entry(), IsFirstEntry :: boolean()}.

add(Entry, #bondy_registry_trie{} = Trie) ->
    bondy_registry_entry:is_entry(Entry)
        orelse ?ERROR(badarg, [Entry], #{
            1 => "is not a bondy_registry_entry:t()"
        }),

    Type = bondy_registry_entry:type(Entry),
    IsLocal = bondy_registry_entry:is_local(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),

    case {Type, MatchPolicy} of
        {registration, ?EXACT_MATCH} ->
            add_exact_registration(Entry, Trie);

        {subscription, ?EXACT_MATCH} when IsLocal == true ->
            add_local_exact_subscription(Entry, Trie);

        {subscription, ?EXACT_MATCH} when IsLocal == false ->
            add_remote_exact_subscription(Entry, Trie);

        {_, ?PREFIX_MATCH} ->
            add_pattern_entry(Type, Entry, Trie);

        {_, ?WILDCARD_MATCH} ->
            add_pattern_entry(Type, Entry, Trie)

    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(Entry :: entry(), Trie :: t()) ->
    ok | {error, Reason :: any()}.

delete(Entry, #bondy_registry_trie{} = Trie) ->
    bondy_registry_entry:is_entry(Entry)
        orelse ?ERROR(badarg, [Entry], #{
            1 => "is not a bondy_registry_entry:t()"
        }),

    Type = bondy_registry_entry:type(Entry),
    IsLocal = bondy_registry_entry:is_local(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),

    case {Type, MatchPolicy} of
        {registration, ?EXACT_MATCH} ->
            del_exact_registration(Entry, Trie);

        {registration, _} ->
            del_pattern_entry(Entry, Trie);

        {subscription, ?EXACT_MATCH} when IsLocal == true ->
            del_exact_subscription(Entry, Trie);

        {subscription, ?EXACT_MATCH} when IsLocal == false ->
            del_remote_exact_subscription(Entry, Trie);

        {subscription, _} ->
            del_pattern_entry(Entry, Trie)
    end.


%% -----------------------------------------------------------------------------
%% @doc Matches the indices in the trie.
%% WARNING: Only safe to be called concurrently if option match is ?MATCH_EXACT.
%% @end
%% -----------------------------------------------------------------------------
-spec find(
    Type :: entry_type(),
    RealmUri :: uri(),
    Uri :: uri(),
    Opts :: map(),
    Trie :: t()
    ) -> match_res().

find(Type, RealmUri, Uri, Opts, #bondy_registry_trie{} = Trie) ->
    Policy = maps:get(match, Opts, '_'),
    Limit = maps:get(limit, Opts, undefined),

    case {Policy, Limit} of
        {'_', undefined} ->
            ExactRes = find_exact(Type, RealmUri, Uri, Opts, Trie),
            PatternRes = find_pattern(Type, RealmUri, Uri, Opts, Trie),
            merge_match_res(Type, find, ExactRes, PatternRes);

        {'_', _} ->
            case find_exact(Type, RealmUri, Uri, Opts, Trie) of
                ?EOT ->
                    find_pattern(Type, RealmUri, Uri, Opts, Trie);
                Result ->
                    Result
            end;

        {?EXACT_MATCH, _} ->
            find_exact(Type, RealmUri, Uri, Opts, Trie);

        {?PREFIX_MATCH, _} ->
            find_pattern(Type, RealmUri, Uri, Opts, Trie);

        {?WILDCARD_MATCH, _} ->
            find_pattern(Type, RealmUri, Uri, Opts, Trie)
    end.


%% -----------------------------------------------------------------------------
%% @doc Continues a match started with `find/5'. The next chunk of the size
%% specified in the initial `find/5' call is returned together with a new
%% `Continuation', which can be used in subsequent calls to this function.
%% When there are no more objects in the table, '$end_of_table' is returned.
%% @end
%% -----------------------------------------------------------------------------
-spec find(Continuation :: continuation() | eot()) -> match_res().

find(?EOT) ->
    ?EOT;

find(#trie_continuation{function = Name} = C) when Name =/= find ->
    error(badarg, [C]);

find(#trie_continuation{policy = '_'} = C0) ->
    case find_exact(C0) of
        ?EOT ->
            Type = C0#trie_continuation.type,
            RealmUri = C0#trie_continuation.realm_uri,
            Uri = C0#trie_continuation.uri,
            Opts = C0#trie_continuation.opts,
            Trie = C0#trie_continuation.trie,

            case find_pattern(Type, RealmUri, Uri, Opts, Trie) of
                ?EOT ->
                    ?EOT;

                {_, ?EOT} = Result ->
                    Result;

                {L, C1} when Type == registration ->
                    C = C1#trie_continuation{
                        proc_cont = ?EOT
                    },
                    {L, C};

                {L, C1} when Type == subscription ->
                    C = C1#trie_continuation{
                        topic_cont = ?EOT,
                        topic_remote_cont = ?EOT
                    },
                    {L, C}

            end;

        Result ->
            Result
    end;

find(#trie_continuation{policy = ?EXACT_MATCH} = C) ->
    find_exact(C);

find(#trie_continuation{} = C) ->
    find_pattern(C).


%% -----------------------------------------------------------------------------
%% @doc Matches the indices in the trie.
%% WARNING: Only safe to be called concurrently if option match is ?MATCH_EXACT.
%% @end
%% -----------------------------------------------------------------------------
-spec match(
    Type :: entry_type(),
    RealmUri :: uri(),
    Uri :: uri(),
    Opts :: map(),
    Trie :: t()
    ) -> match_res().

match(Type, RealmUri, Uri, Opts, #bondy_registry_trie{} = Trie) ->
    Policy = maps:get(match, Opts, '_'),
    Limit = maps:get(limit, Opts, undefined),

    case {Policy, Limit} of
        {'_', undefined} ->
            ExactRes = match_exact(Type, RealmUri, Uri, Opts, Trie),
            PatternRes = match_pattern(Type, RealmUri, Uri, Opts, Trie),
            merge_match_res(Type, match, ExactRes, PatternRes);

        {'_', _} ->
            case match_exact(Type, RealmUri, Uri, Opts, Trie) of
                ?EOT ->
                    match_pattern(Type, RealmUri, Uri, Opts, Trie);
                ExactRes ->
                    ExactRes
            end;

        {?EXACT_MATCH, _} ->
            match_exact(Type, RealmUri, Uri, Opts, Trie);

        {?PREFIX_MATCH, _} ->
            match_pattern(Type, RealmUri, Uri, Opts, Trie);

        {?WILDCARD_MATCH, _} ->
            match_pattern(Type, RealmUri, Uri, Opts, Trie)
    end.


%% -----------------------------------------------------------------------------
%% @doc Continues a match started with `match/5'. The next chunk of the size
%% specified in the initial `match/5' call is returned together with a new
%% `Continuation', which can be used in subsequent calls to this function.
%% When there are no more objects in the table, '$end_of_table' is returned.
%% @end
%% -----------------------------------------------------------------------------
-spec match(Continuation :: continuation() | eot()) -> match_res().

match(?EOT) ->
    ?EOT;

match(#trie_continuation{function = Name} = C) when Name =/= match ->
    error(badarg, [C]);

match(#trie_continuation{policy = '_'} = C0) ->
    case match_exact(C0) of
        ?EOT ->
            Type = C0#trie_continuation.type,
            RealmUri = C0#trie_continuation.realm_uri,
            Uri = C0#trie_continuation.uri,
            Opts = C0#trie_continuation.opts,
            Trie = C0#trie_continuation.trie,

            case match_pattern(Type, RealmUri, Uri, Opts, Trie) of
                ?EOT ->
                    ?EOT;

                {_, ?EOT} = Result ->
                    Result;

                {L, C1} when Type == registration ->
                    C = C1#trie_continuation{proc_cont = ?EOT},
                    {L, C};

                {L, C1} when Type == subscription ->
                    C = C1#trie_continuation{
                        topic_cont = ?EOT,
                        topic_remote_cont = ?EOT
                    },
                    {L, C}

            end;

        Result ->
            Result
    end;

match(#trie_continuation{policy = ?EXACT_MATCH} = C) ->
    match_exact(C);

match(#trie_continuation{} = C) ->
    match_pattern(C).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
format_error(Reason, [{_M, _F, _As, Info} | _]) ->
    ErrorInfo = proplists:get_value(error_info, Info, #{}),
    ErrorMap = maps:get(cause, ErrorInfo),
    ErrorMap#{
        %% general => "optional general information",
        reason => io_lib:format("~p: ~p", [?MODULE, Reason])
    }.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc Generates a dynamic ets table name given a generic name and and index
%% (partition number).
%% @end
%% -----------------------------------------------------------------------------
gen_table_name(Name, Index) when is_atom(Name), is_integer(Index) ->
    list_to_atom(
        "bondy_registry_" ++ atom_to_list(Name) ++ "_" ++ integer_to_list(Index)
    ).



%% =============================================================================
%% PRIVATE: FIND
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec find_exact(entry_type(), uri(), uri(), map(), t()) ->
    registration_match() | subscription_match().

find_exact(Type, RealmUri, Uri, Opts, Trie) ->
    case match_exact(Type, RealmUri, Uri, Opts, Trie) of
        {L, #trie_continuation{} = C} ->
            {L, C#trie_continuation{function = find}};
        Result ->
            Result
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
find_exact(?EOT) ->
    ?EOT;

find_exact(#trie_continuation{} = C0) ->
    case match_exact(C0#trie_continuation{function = match}) of
        {L, #trie_continuation{} = C} ->
            {L, C#trie_continuation{function = find}};
        Result ->
            Result
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec find_pattern(entry_type(), uri(), uri(), map(), t()) ->
    registration_match() | subscription_match().

find_pattern(Type, RealmUri, Uri, Opts, Trie) ->
    ART = art(Type, Trie),
    Limit = maps:get(limit, Opts, undefined),
    %% We do not use limit as ART does not support them yet.
    ARTOpts = #{
        %% We match the Uri exactly
        mode => exact,
        match_spec => art_ms(Type, Opts),
        first => <<RealmUri/binary, $.>>
    },

    Pattern = art_key_pattern(Type, RealmUri, Uri),

    %% Always sync at the moment
    %% We use art:match/3 instead of art:find_matches/3.
    %% Notice: Current art:match/3 differs from art:find_matches/3
    %% in args order!
    case art:match(Pattern, ART, ARTOpts) of
        {error, badarg} when Limit =/= undefined ->
            match_pattern_res(Type, ?EOT);

        {error, badarg} ->
            match_pattern_res(Type, []);

        {error, Reason} ->
            error(Reason);

        [] when Limit =/= undefined ->
            match_pattern_res(Type, ?EOT);

        [] ->
            match_pattern_res(Type, []);

        Result when Limit =/= undefined ->
            match_pattern_res(Type, {Result, ?EOT});

        Result ->
            match_pattern_res(Type, Result)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec find_pattern(continuation()) ->
    registration_match() | subscription_match().

find_pattern(#trie_continuation{}) ->
    %% ART does not support limits yet
    ?EOT.



%% =============================================================================
%% PRIVATE: MATCH
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_exact(entry_type(), uri(), uri(), map(), t()) ->
    registration_match_res().

match_exact(registration, RealmUri, Uri, Opts, Trie) ->
    %% This option might be passed for admin purposes, not during a call
    Invoke = maps:get(invoke, Opts, '_'),
    Tab = Trie#bondy_registry_trie.proc_tab,
    Pattern = #proc_index{
        key = {RealmUri, Uri},
        entry_key = '$1',
        is_proxy = '$2',
        invoke = '$3',
        timestamp = '$4'
    },
    Conds =
        case Invoke of
            '_' ->
                [];
            _ ->
                [{'=:=', '$3', Invoke}]
        end,

    MS = [
        { Pattern, Conds, [{{{{RealmUri, Uri}}, '$1', '$2', '$3', '$4'}}] }
    ],

    case maps:find(limit, Opts) of
        {ok, N} ->
            case ets:select(Tab, MS, N)  of
                ?EOT ->
                    ?EOT;

                {L, ETSCont} ->

                    Policy = maps:get(match, Opts, '_'),

                    C = #trie_continuation{
                        type = registration,
                        function = match,
                        realm_uri = RealmUri,
                        uri = Uri,
                        policy = Policy,
                        opts = Opts,
                        trie = Trie,
                        proc_cont = ETSCont
                    },
                    {L, C}
            end;

        error ->
            ets:select(Tab, MS)
    end;

match_exact(subscription, RealmUri, Uri, Opts, Trie) ->
    L = match_local_exact_subscription(RealmUri, Uri, Opts, Trie),
    R = match_remote_exact_subscription(RealmUri, Uri, Opts, Trie),
    zip_local_remote(L, R).


%% @private
match_exact(#trie_continuation{type = registration} = C0) ->
    case ets:select(C0#trie_continuation.proc_cont) of
        ?EOT ->
            Type = C0#trie_continuation.type,
            RealmUri = C0#trie_continuation.realm_uri,
            Uri = C0#trie_continuation.uri,
            Opts = C0#trie_continuation.opts,
            Trie = C0#trie_continuation.trie,

            case match_pattern(Type, RealmUri, Uri, Opts, Trie) of
                ?EOT ->
                    ?EOT;

                {_, ?EOT} = Result ->
                    Result;

                {L, C1} ->
                    C = C1#trie_continuation{proc_cont = ?EOT},
                    {L, C}
            end;

        {L, Cont} ->
            C = C0#trie_continuation{proc_cont = Cont},
            {L, C}
    end;

match_exact(#trie_continuation{type = subscription} = C) ->
    L = match_local_exact_subscription(C),
    R = match_remote_exact_subscription(C),
    zip_local_remote(L, R).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_local_exact_subscription(uri(), uri(), map(), t()) ->
    {[subscription_match()], continuation() | eot()} | eot().

match_local_exact_subscription(RealmUri, Uri, Opts, Trie) ->
    Tab = Trie#bondy_registry_trie.topic_tab,

    {Var, Conds} = topic_session_restrictions('$1', Opts),

    Pattern = #topic_idx{
        key = {RealmUri, Uri},
        protocol_session_id = Var,
        entry_key = '$2',
        is_proxy = '$3'
    },

    Return = [{{{{RealmUri, Uri}}, '$2', '$3'}}],

    MS = [{Pattern, Conds, Return}],

    case maps:find(limit, Opts) of
        {ok, N} ->
            case ets:select(Tab, MS, N) of
                ?EOT ->
                    ?EOT;

                {L, ETSCont} ->
                    C = #trie_continuation{
                        type = subscription,
                        function = match,
                        realm_uri = RealmUri,
                        uri = Uri,
                        opts = Opts,
                        trie = Trie,
                        topic_cont = ETSCont
                    },
                    {L, C}
            end;
        error ->
            ets:select(Tab, MS)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_local_exact_subscription(continuation()) ->
    subscription_match_res().

match_local_exact_subscription(#trie_continuation{} = C0) ->
     case ets:select(C0#trie_continuation.topic_cont) of
        ?EOT ->
            ?EOT;

        {L, ETSCont} ->
            {L, C0#trie_continuation{topic_cont = ETSCont}}
    end.

%% -----------------------------------------------------------------------------
%% @private
%% @doc Exact
%% @end
%% -----------------------------------------------------------------------------
-spec match_remote_exact_subscription(uri(), uri(), map(), t()) ->
    {[node()], continuation() | eot()} | eot().

match_remote_exact_subscription(RealmUri, Uri, Opts, Trie) ->
    Tab = Trie#bondy_registry_trie.topic_remote_tab,

    Pattern = #topic_remote_idx{
        key = {RealmUri, Uri},
        node = '$1',
        ref_count = '$2'
    },
    Conds = [{'>', '$2', 0}],
    Return = ['$1'],

    MS = [{Pattern, Conds, Return}],

    case maps:find(limit, Opts) of
        {ok, N} ->
            case ets:select(Tab, MS, N) of
                ?EOT ->
                    ?EOT;

                {L, ETSCont} ->
                    C = #trie_continuation{
                        type = subscription,
                        function = match,
                        realm_uri = RealmUri,
                        uri = Uri,
                        opts = Opts,
                        trie = Trie,
                        topic_remote_cont = ETSCont
                    },
                    {L, C}
            end;
        error ->
            ets:select(Tab, MS)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_remote_exact_subscription(ets:continuation()) ->
    subscription_match_res().

match_remote_exact_subscription(#trie_continuation{} = C0) ->
    case ets:select(C0#trie_continuation.topic_remote_cont) of
        ?EOT ->
            ?EOT;

        {L, ETSCont} ->
            C = C0#trie_continuation{topic_remote_cont = ETSCont},
            {L, C}
    end.


%% @private
zip_local_remote(L, R) when is_list(L), is_list(R) ->
    {L, R};

zip_local_remote(?EOT, ?EOT) ->
    ?EOT;

zip_local_remote({L, C}, ?EOT) ->
    {{L, []}, C};

zip_local_remote(?EOT, {R, C}) ->
    {{[], R}, C};

zip_local_remote({L, C0}, {R, C1}) ->
    C = C0#trie_continuation{
        topic_remote_cont = C1#trie_continuation.topic_remote_cont
    },
    {{L, R}, C}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_pattern(entry_type(), uri(), uri(), map(), t()) ->
    registration_match() | subscription_match().

match_pattern(Type, RealmUri, Uri, Opts, Trie) ->
    ART = art(Type, Trie),
    Limit = maps:get(limit, Opts, undefined),
    %% We do not use limit as ART does not support them yet.
    ARTOpts = #{
        match_spec => art_ms(Type, Opts),
        first => <<RealmUri/binary, $.>>
    },
    Pattern = <<RealmUri/binary, $., Uri/binary>>,

    %% Always sync at the moment
    case art:find_matches(Pattern, ARTOpts, ART) of
        {error, badarg} when Limit =/= undefined ->
            match_pattern_res(Type, ?EOT);

        {error, badarg} ->
            match_pattern_res(Type, []);

        {error, Reason} ->
            error(Reason);

        [] when Limit =/= undefined ->
            match_pattern_res(Type, ?EOT);

        [] ->
            match_pattern_res(Type, []);

        L when Limit =/= undefined ->
            match_pattern_res(Type, {L, ?EOT});

        L ->
            match_pattern_res(Type, L)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_pattern(continuation()) ->
    registration_match() | subscription_match().

match_pattern(#trie_continuation{}) ->
    %% ART does not support limits yet
    ?EOT.


%% @private
match_pattern_res(_, ?EOT) ->
    ?EOT;

match_pattern_res(subscription, []) ->
    {[], []};

match_pattern_res(subscription, All) when is_list(All) ->
    Nodestring = partisan:nodestring(),

    {L, R} = lists:foldl(
        fun
            ({{_, NS, _, _, _}, _}, {L, R}) when NS =/= Nodestring ->
                %% A remote subscription, we just append the nodestring on the
                %% right-hand side acc
                Node = binary_to_atom(NS, utf8),
                {L, sets:add_element(Node, R)};

            ({{Bin, _, _, _, _}, {EntryKey, IsProxy}}, {L, R}) ->
                %% We project the expected triple
                %% TODO this is projection subscriptions only at the moment,
                %% registrations need the Invoke field too.
                %% We will need to add INvoke Policy to the art value
                RealmUri = bondy_registry_entry:realm_uri(EntryKey),
                Uri = parse_index_key_uri(RealmUri, Bin),
                Match = {{RealmUri, Uri}, EntryKey, IsProxy},
                {[Match|L], R}
        end,
        {[], sets:new()},
        All
    ),
    {lists:reverse(L), sets:to_list(R)};

match_pattern_res(registration, All) when is_list(All) ->
    [
        begin
            RealmUri = bondy_registry_entry:realm_uri(EntryKey),
            Uri = parse_index_key_uri(RealmUri, Bin),
            {{RealmUri, Uri}, EntryKey, IsProxy, Invoke, TS}
        end
        || {{Bin, _, _, _, _}, {EntryKey, IsProxy, Invoke, TS}} <- All
    ];

match_pattern_res(Type, {All, Cont}) ->
    {match_pattern_res(Type, All), Cont}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc See trie_key to understand how we generated Bin
%% @end
%% -----------------------------------------------------------------------------
parse_index_key_uri(RealmUri, Bin) ->
    Sz = byte_size(RealmUri),
    <<RealmUri:Sz/binary, $., Uri0/binary>> = Bin,
    string:trim(Uri0, trailing, "*").


%% @private
topic_session_restrictions(Var, Opts) ->
    R = case maps:find(eligible, Opts) of
        error ->
            %% Not provided
            {'_', []};

        {ok, []} ->
            %% Idem as not provided
            {'_', []};

        {ok, EligibleIds} ->
            %% We include the provided ProtocolSessionIds
            Eligible = maybe_or(
                [
                    {'=:=', Var, {const, S}}
                    || S <- EligibleIds
                ]
            ),

            {Var, [Eligible]}
    end,

    case maps:find(exclude, Opts) of
        error ->
            R;

        {ok, []} ->
            R;

        {ok, ExcludedIds} ->

            %% We exclude the provided ProtocolSessionIds
            Excluded = maybe_and(
                [
                    {'=/=', Var, {const, S}}
                    || S <- ExcludedIds
                ]
            ),

            {_, Conds} = R,
            {Var, [Excluded | Conds]}
    end.


%% @private
merge_match_res(_, _, ?EOT, ?EOT) ->
    ?EOT;

merge_match_res(_, _, ?EOT, Res) ->
    Res;

merge_match_res(_, _, Res, ?EOT) ->
    Res;

merge_match_res(registration, _, L1, L2) when is_list(L1), is_list(L2) ->
    lists:append(L1, L2);

merge_match_res(registration, FN, {L1, C1}, {L2, C2})
when is_list(L1), is_list(L2) ->
    C = merge_continuation(FN, C1, C2),
    {lists:append(L1, L2), C};

merge_match_res(subscription, _, {L1, R1}, {L2, R2})
when is_list(L1), is_list(R1), is_list(L2), is_list(R2) ->
    {lists:append(L1, L2), lists:append(R1, R2)};

merge_match_res(subscription, FN, {{L1, R1}, C1}, {{L2, R2}, C2})
when is_list(L1), is_list(R1), is_list(L2), is_list(R2) ->
    C = merge_continuation(FN, C1, C2),
    {{lists:append(L1, L2), lists:append(R1, R2)}, C}.


%% @private
merge_continuation(_, ?EOT, ?EOT) ->
    ?EOT;

merge_continuation(FN, A, ?EOT) ->
    A#trie_continuation{function = FN};

merge_continuation(FN, ?EOT, B) ->
    B#trie_continuation{function = FN};

merge_continuation(FN, A, B) ->
    #trie_continuation{
        type = T1,
        realm_uri = R1,
        proc_cont = Cont1a,
        proc_art_cont = Cont2a,
        topic_cont = Cont3a,
        topic_art_cont = Cont4a,
        topic_remote_cont = Cont5a
    } = A,

    #trie_continuation{
        type = T2,
        realm_uri = R2,
        proc_cont = Cont1b,
        proc_art_cont = Cont2b,
        topic_cont = Cont3b,
        topic_art_cont = Cont4b,
        topic_remote_cont = Cont5b
    } = B,

    (T1 == T2 andalso R1 == R2) orelse error(badarg),

    A#trie_continuation{
        function = FN,
        proc_cont = merge_cont_value(Cont1a, Cont1b),
        proc_art_cont = merge_cont_value(Cont2a, Cont2b),
        topic_cont = merge_cont_value(Cont3a, Cont3b),
        topic_art_cont = merge_cont_value(Cont4a, Cont4b),
        topic_remote_cont = merge_cont_value(Cont5a, Cont5b)
    }.


%% @private
merge_cont_value(undefined, undefined) ->
    undefined;

merge_cont_value(undefined, Value) ->
    Value;

merge_cont_value(Value, undefined) ->
    Value.



%% =============================================================================
%% PRIVATE: ADD/DELETE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
add_exact_registration(Entry, Trie) ->
    Tab = Trie#bondy_registry_trie.proc_tab,
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    EntryKey = bondy_registry_entry:key(Entry),
    IsProxy = bondy_registry_entry:is_proxy(Entry),
    Invoke = bondy_registry_entry:get_option(invoke, Entry, ?INVOKE_SINGLE),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),
    Timestamp = bondy_registry_entry:created(Entry),

    Object = #proc_index{
        key = {RealmUri, Uri},
        entry_key = EntryKey,
        is_proxy = IsProxy,
        invoke = Invoke,
        timestamp = Timestamp
    },

    true = ets:insert(Tab, Object),

    IsFirstEntry = incr_counter(Uri, MatchPolicy, 1, Trie) =:= 1,

    {ok, Entry, IsFirstEntry}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
del_exact_registration(Entry, Trie) ->
    Tab = Trie#bondy_registry_trie.proc_tab,
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    EntryKey = bondy_registry_entry:key(Entry),
    IsProxy = bondy_registry_entry:is_proxy(Entry),
    Invoke = bondy_registry_entry:get_option(invoke, Entry, ?INVOKE_SINGLE),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),
    Timestamp = bondy_registry_entry:created(Entry),

    Object = #proc_index{
        key = {RealmUri, Uri},
        entry_key = EntryKey,
        is_proxy = IsProxy,
        invoke = Invoke,
        timestamp = Timestamp
    },

    %% We use match delete because Tab is a bag table
    true = ets:match_delete(Tab, Object),

    _ = decr_counter(Uri, MatchPolicy, 1, Trie),

    ok.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
add_local_exact_subscription(Entry, Trie) ->
    Tab = Trie#bondy_registry_trie.topic_tab,
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    EntryKey = bondy_registry_entry:key(Entry),
    IsProxy = bondy_registry_entry:is_proxy(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),

    Object = #topic_idx{
        key = {RealmUri, Uri},
        entry_key = EntryKey,
        is_proxy = IsProxy
    },

    true = ets:insert(Tab, Object),

    IsFirstEntry = incr_counter(Uri, MatchPolicy, 1, Trie) =:= 1,

    {ok, Entry, IsFirstEntry}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
del_exact_subscription(Entry, Trie) ->
    Tab = Trie#bondy_registry_trie.topic_tab,
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    EntryKey = bondy_registry_entry:key(Entry),
    IsProxy = bondy_registry_entry:is_proxy(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),

    Object = #topic_idx{
        key = {RealmUri, Uri},
        entry_key = EntryKey,
        is_proxy = IsProxy
    },

    %% We use match delete because Tab is a bag table
    true = ets:match_delete(Tab, Object),

    _ = decr_counter(Uri, MatchPolicy, 1, Trie),

    ok.


%% -----------------------------------------------------------------------------
%% @private
%% @doc increases the ref_count for entry's node by 1. If the node was not
%% present creates the entry on the table with ref_count = 1.
%% @end
%% -----------------------------------------------------------------------------
add_remote_exact_subscription(Entry, Trie) ->
    Tab = Trie#bondy_registry_trie.topic_remote_tab,
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    Key = {RealmUri, Uri},
    Default = #topic_remote_idx{
        key = Key,
        node = bondy_registry_entry:node(Entry),
        ref_count = 1
    },
    Incr = {#topic_remote_idx.ref_count, 1},

    _ = ets:update_counter(Tab, Key, Incr, Default),

    %% This is a remote entry, so the on_create event was already generated on
    %% its node.
    IsFirstEntry = false,
    {ok, Entry, IsFirstEntry}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc decreases the ref_count for entry's node by 1. If the node was not
%% present creates the entry on the table with ref_count = 1.
%% @end
%% -----------------------------------------------------------------------------
del_remote_exact_subscription(Entry, Trie) ->
    Tab = Trie#bondy_registry_trie.topic_remote_tab,
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    Key = {RealmUri, Uri},

    try
        Incr = {#topic_remote_idx.ref_count, -1},
        case ets:update_counter(Tab, Key, Incr) of
            0 ->
                %% Other process might have concurrently incremented the count,
                %% so we do a match delete
                Pattern = #topic_remote_idx{
                    key = Key,
                    node = bondy_registry_entry:node(Entry),
                    ref_count = 0
                },
                true = ets:match_delete(Tab, Pattern),
                ok;
            _ ->
                ok
        end
    catch
        error:badarg ->
            ok
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
add_pattern_entry(Type, Entry, Trie) ->
    ART = art(Type, Trie),
    Key = art_key(Entry),
    Value = art_value(Entry),

    _ = art:set(Key, Value, ART),

    Uri = bondy_registry_entry:uri(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),
    IsFirstEntry = incr_counter(Uri, MatchPolicy, 1, Trie) =:= 1,

    {ok, Entry, IsFirstEntry}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
del_pattern_entry(Entry, Trie) ->
    ART = art(bondy_registry_entry:type(Entry), Trie),
    TrieKey = art_key(Entry),
    ok = art:delete(TrieKey, ART),

    Uri = bondy_registry_entry:uri(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),
    _ = decr_counter(Uri, MatchPolicy, 1, Trie),

    ok.



%% =============================================================================
%% PRIVATE: URI COUNTERS
%% =============================================================================

%% TODO we should remove the use of these counters. We use them because
%% WAMP distinguishes between on_create|on_delete and on_subscribe|on_register
%% events.
%% In a distributed setting with no coordination this distinction is impossible
%% to guarantee and has absolutely no value to the user. At the moment two
%% nodes might trigger the on_create as the counters are not global. Even if we
%% used global CRDT counters there is a possibility of multiple nodes
%% triggering simultaneous on_create|on_delete events.

%% @private
incr_counter(Uri, MatchPolicy, N, Trie) ->
    Tab = Trie#bondy_registry_trie.counters,
    Key = {Uri, MatchPolicy},
    Default = {counter, Key, 0},
    ets:update_counter(Tab, Key, {3, N}, Default).


%% @private
decr_counter(Uri, MatchPolicy, N, Trie) ->
    Tab = Trie#bondy_registry_trie.counters,
    Key = {Uri, MatchPolicy},
    Default = {counter, Key, 0},

    case ets:update_counter(Tab, Key, {3, -N, 0, 0}, Default) of
        0 ->
            %% Other process might have concurrently incremented the counter,
            %% so we do a match delete
            true = ets:match_delete(Tab, Default),
            0;
        Val ->
            Val
    end.



%% =============================================================================
%% PRIVATE: ART UTILS
%% =============================================================================



%% @private
art(registration, Trie) ->
    Trie#bondy_registry_trie.proc_art;

art(subscription, Trie) ->
    Trie#bondy_registry_trie.topic_art.


%% @private
-spec art_key(bondy_registry_entry:t_or_key()) -> art:key().

art_key(Entry) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    SessionId0 = bondy_registry_entry:session_id(Entry),
    Nodestring = bondy_registry_entry:nodestring(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),


    {ProtocolSessionId, SessionId, Id} = case bondy_registry_entry:id(Entry) of
        _ when SessionId0 == '_' ->
            %% As we currently do not support wildcard matching in art:match,
            %% we turn this into a prefix matching query
            %% TODO change when wildcard matching is enabled in art.
            {<<>>, <<>>, <<>>};

        Id0 when SessionId0 == undefined ->
            {<<"undefined">>, <<"undefined">>, term_to_art_key_part(Id0)};

        Id0 when is_binary(SessionId0) ->
            ProtocolSessionId0 = bondy_session_id:to_external(SessionId0),
            {
                term_to_art_key_part(ProtocolSessionId0),
                term_to_art_key_part(SessionId0),
                term_to_art_key_part(Id0)
            }
    end,

    %% RealmUri is always ground, so we join it with URI using a $. as any
    %% other separator will not work with art:find_matches/2
    Key = <<RealmUri/binary, $., Uri/binary>>,

    %% We add Nodestring for cases where SessionId == <<>>
    case MatchPolicy of
        ?PREFIX_MATCH ->
            %% art lib uses the star char to explicitly denote a prefix
            {<<Key/binary, $*>>, Nodestring, ProtocolSessionId, SessionId, Id};

        _ ->
            {Key, Nodestring, ProtocolSessionId, SessionId, Id}
    end.


%% @private
art_key_pattern(_Type, RealmUri, Uri) ->
    {<<RealmUri/binary, $., Uri/binary>>, <<>>, <<>>, <<>>, <<>>}.


%% @private
term_to_art_key_part('_') ->
    <<>>;

term_to_art_key_part(Term) when is_atom(Term) ->
    atom_to_binary(Term, utf8);

term_to_art_key_part(Term) when is_integer(Term) ->
    integer_to_binary(Term);

term_to_art_key_part(Term) when is_binary(Term) ->
    Term.


%% @private
art_value(Entry) ->
    art_value(Entry, bondy_registry_entry:type(Entry)).


%% @private
art_value(Entry, registration) ->
    EntryKey = bondy_registry_entry:key(Entry),
    IsProxy = bondy_registry_entry:is_proxy(Entry),
    Invoke = bondy_registry_entry:get_option(invoke, Entry, ?INVOKE_SINGLE),
    Timestamp = bondy_registry_entry:created(Entry),
    {EntryKey, IsProxy, Invoke, Timestamp};

art_value(Entry, subscription) ->
    EntryKey = bondy_registry_entry:key(Entry),
    IsProxy = bondy_registry_entry:is_proxy(Entry),
    {EntryKey, IsProxy}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc This is match_spec that art applies after a match.
%% @end
%% -----------------------------------------------------------------------------
-spec art_ms(Type :: entry_type(), Opts :: map()) ->
    ets:match_spec() | undefined.

art_ms(registration, Opts) ->
    Nodestring =
        case maps:find(node, Opts) of
            {ok, Val} ->
                Val;

            error ->
                case maps:get(nodestring, Opts, '_') of
                    '_' ->
                        '_';
                    Bin ->
                        binary_to_atom(Bin, utf8)
                end
        end,

    Conds =
        case maps:get(invoke, Opts, '_') of
            '_' ->
                [];
            Invoke ->
                [{'=:=', '$3', Invoke}]
        end,

    case Conds of
        [] ->
            undefined;

        [_] ->
            %% {Key, Nodestring, ProtocolSessionId, SessionId, EntryIdBin}
            Key = {'_', Nodestring, '_', '_'},
            %% {EntryKey, IsProxy, Invoke}
            Value = {'_', '_', '$3', '_'},

            [{ {Key, Value}, Conds, ['$_'] }]
    end;

art_ms(subscription, Opts) ->
    %% {{$1, $2, $3, $4, $5}, $6},
    %% {{Key, Node, ProtocolSessionId, SessionId, EntryIdBin}, '_'},
    Node =
        case maps:find(node, Opts) of
            {ok, Val} ->
                Val;

            error ->
                case maps:get(nodestring, Opts, '_') of
                    '_' ->
                        '_';
                    Bin ->
                        binary_to_atom(Bin, utf8)
                end
        end,

    Conds1 =
        case maps:find(eligible, Opts) of
            error ->
                [];

            {ok, []} ->
                [];

            {ok, EligibleIds} ->
                [
                    maybe_or(
                        [
                            {'=:=', '$1', {const, integer_to_binary(S)}}
                            || S <- EligibleIds
                        ]
                    )
                ]
        end,

    Conds2 =
        case maps:find(exclude, Opts) of
            error ->
                Conds1;

            {ok, []} ->
                Conds1;

            {ok, ExcludedIds} ->
                ExclConds = maybe_and(
                    [
                        {'=/=', '$1', {const, integer_to_binary(S)}}
                        || S <- ExcludedIds
                    ]
                ),
                [ExclConds | Conds1]
        end,

    Conds =
        case Conds2 of
            [] ->
                [];
            [_] ->
                Conds2;
            _ ->
                [list_to_tuple(['andalso' | Conds2])]
        end,

    case Conds of
        [] ->
            undefined;

        _ ->
            %% {Key, Node, ProtocolSessionId, SessionId, EntryIdBin}
            Key = {'_', Node, '$1', '_', '_'},
            %% {EntryKey, IsProxy}.
            Value = {'_', '_'},

            [{ {Key, Value}, Conds, ['$_'] }]
    end.


%% @private
maybe_and([Clause]) ->
    Clause;

maybe_and(Clauses) ->
    list_to_tuple(['and' | Clauses]).


%% @private
maybe_or([Clause]) ->
    Clause;
maybe_or(Clauses) ->
    list_to_tuple(['or' | Clauses]).



