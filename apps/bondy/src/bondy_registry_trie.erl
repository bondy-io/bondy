%% =============================================================================
%%  bondy_registry_trie .erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
-include("bondy_plum_db.hrl").

-record(bondy_registry_trie, {
    %% Stores registrations w/match_policy == exact
    %% (ets bag)
    proc_tab                    ::  ets:tab(),
    %% Stores registrations w/match_policy =/= exact
    proc_art                    ::  art:t(),
    %% Stores local subscriptions w/match_policy == exact (ets bag)
    topic_tab                   ::  ets:tab(),
    %% Stores local subscriptions w/match_policy =/= exact
    topic_art                   ::  art:t(),
    %% Stores remote subscriptions w/match_policy == exact (ets set)
    topic_remote_tab            ::  ets:tab(),
    %% Stores counter per URI, used to distinguish on_create vs
    %% on_register|on_subscribe
    counters                    ::  ets:tab()
}).

-record(trie_continuation, {
    type                        ::  entry_type(),
    realm_uri                   ::  uri(),
    function                    ::  atom(),
    proc_tab                    ::  optional(ets:continuation() | eot()),
    proc_art                    ::  optional(term() | eot()),
    topic_tab                   ::  optional(ets:continuation() | eot()),
    topic_art                   ::  optional(term() | eot()),
    topic_remote_tab            ::  optional(ets:continuation() | eot())
}).

-record(proc_index, {
    key                         ::  index_key(),
    invoke                      ::  invoke(),
    entry_key                   ::  entry_key()
}).

-record(topic_idx, {
    key                         ::  index_key(),
    protocol_session_id         ::  id(),
    entry_key                   ::  entry_key()
}).

-record(topic_remote_idx, {
    key                         ::  index_key(),
    node                        ::  node(),
    ref_count                   ::  non_neg_integer()
}).

-type t()                       ::  #bondy_registry_trie{}.
-type index_key()               ::  {RealmUri :: uri(), Uri :: uri()}.
-type invoke()                  ::  binary().
-type registration_match()      ::  {index_key(), invoke(), entry_key()}.
-type registration_match_res()  ::  [registration_match()].
-type registration_match_opts() ::  #{
                                        %% WAMP match policy
                                        match => wildcard(binary()),
                                        %% WAMP invocation policy
                                        invoke => wildcard(binary())
                                    }.
-type subscription_match()      ::  {index_key(), entry_key()}.
-type subscription_match_res()  ::  {
                                        Local :: [subscription_match()],
                                        Remote :: [node()]
                                    }.
-type subscription_match_opts() ::  #{
                                        nodestring => wildcard(nodestring()),
                                        node => wildcard(node()),
                                        eligible => [id()],
                                        exclude => [id()]
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

%% Aliases
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
-export([match/1]).
-export([match/5]).
-export([match_exact/1]).
-export([match_exact/5]).
-export([match_pattern/1]).
-export([match_pattern/5]).
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
-spec add(Entry :: bondy_registry_entry:t(), Trie :: t()) ->
    {ok, bondy_registry_entry:t(), IsFirstEntry :: boolean()}.

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

        {registration, _} ->
            add_pattern_entry(Entry, Trie);

        {subscription, ?EXACT_MATCH} when IsLocal == true ->
            add_exact_subscription(Entry, Trie);

        {subscription, ?EXACT_MATCH} when IsLocal == false ->
            add_remote_exact_subscription(Entry, Trie);

        {subscription, _} ->
            add_pattern_entry(Entry, Trie)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec delete(Entry :: bondy_registry_entry:t(), Trie :: t()) ->
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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(continuation() | eot()) -> match_res().

match(?EOT) ->
    ?EOT;

match(#trie_continuation{} = C) ->
    FunctionName = C#trie_continuation.function,
    ?MODULE:FunctionName(C).


%% -----------------------------------------------------------------------------
%% @doc only safe to be called concurrently if option match is ?MATCH_EXACT
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
    %% The match policy for shared subscriptions (registrations)
    Match = maps:get(match, Opts, '_'),

    case {Match, Type} of
        {'_', registration} ->
            match_registration(RealmUri, Uri, Opts, Trie);

        {'_', subscription} ->
            match_subscription(RealmUri, Uri, Opts, Trie);

        {?EXACT_MATCH, registration} ->
            match_exact(registration, RealmUri, Uri, Opts, Trie);

        {?EXACT_MATCH, subscription} ->
            match_exact(subscription, RealmUri, Uri, Opts, Trie);

        {_, registration} ->
            match_pattern_registration(RealmUri, Uri, Opts, Trie);

        {_, subscription} ->
            match_pattern_subscription(RealmUri, Uri, Opts, Trie)
    end.



%% -----------------------------------------------------------------------------
%% @doc Can be access concurrently as it uses ets tables.
%% @end
%% -----------------------------------------------------------------------------
-spec match_exact(
    Type :: entry_type(),
    RealmUri :: uri(),
    Uri :: uri(),
    Opts :: map(),
    Trie :: t()
    ) -> match_res().

match_exact(registration, RealmUri, Uri, Opts, #bondy_registry_trie{} = Trie) ->
    NewOpts = Opts#{invoke => maps:get(invoke, Opts, '_')},
    match_exact_registration(RealmUri, Uri, NewOpts, Trie);

match_exact(subscription, RealmUri, Uri, Opts, #bondy_registry_trie{} = Trie) ->
    match_exact_subscription(RealmUri, Uri, Opts, Trie).


%% -----------------------------------------------------------------------------
%% @doc Can be access concurrently as it uses ets tables.
%% @end
%% -----------------------------------------------------------------------------
-spec match_exact(continuation() | eot()) -> match_res().

match_exact(?EOT) ->
    ?EOT;

match_exact(#trie_continuation{} = C) ->
    case C#trie_continuation.function of
        match_exact_registration ->
            match_exact_registration(C);
        match_exact_subscription ->
            match_exact_subscription(C);
        _ ->
            error(badarg)
    end.


%% -----------------------------------------------------------------------------
%% @doc Since it uses art and at doesn't support concurrent readers at the
%% moment we need to synchronise access via a bondy_registry_partition
%% @end
%% -----------------------------------------------------------------------------
-spec match_pattern(
    Type :: entry_type(),
    RealmUri :: uri(),
    Uri :: uri(),
    Opts :: map(),
    Trie :: t()
    ) -> match_res().

match_pattern(registration, RealmUri, Uri, Opts, #bondy_registry_trie{} = T) ->
    NewOpts = Opts#{invoke => maps:get(invoke, Opts, '_')},
    match_pattern_registration(RealmUri, Uri, NewOpts, T);

match_pattern(subscription, RealmUri, Uri, Opts, #bondy_registry_trie{} = T) ->
    match_pattern_subscription(RealmUri, Uri, Opts, T).


%% -----------------------------------------------------------------------------
%% @doc Since it uses art and at doesn't support concurrent readers at the
%% moment we need to synchronise access via a bondy_registry_partition
%% @end
%% -----------------------------------------------------------------------------
-spec match_pattern(continuation()) -> match_res().

match_pattern(#trie_continuation{} = C) ->
    case C#trie_continuation.function of
        match_pattern_registration ->
            match_pattern_registration(C);
        match_pattern_subscription ->
            match_pattern_subscription(C);
        _ ->
            error(badarg)
    end.


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
%% PRIVATE: MATCH
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
match_registration(RealmUri, Uri, RegOpts, Trie) ->
    merge_match_res(
        registration,
        ?FUNCTION_NAME,
        match_exact_registration(RealmUri, Uri, RegOpts, Trie),
        match_pattern_registration(RealmUri, Uri, RegOpts, Trie)
    ).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_exact_registration(uri(), uri(), map(), t()) ->
    registration_match_res().

match_exact_registration(RealmUri, Uri, Opts, Trie) ->
    %% This option might be passed for admin purposes, not during a call
    Invoke = maps:get(invoke, Opts, '_'),
    Tab = Trie#bondy_registry_trie.proc_tab,
    Pattern = #proc_index{
        key = {RealmUri, Uri},
        invoke = '$1',
        entry_key = '$2'
    },
    Conds =
        case Invoke of
            '_' ->
                [];
            _ ->
                [{'=:=', '$1', Invoke}]
        end,

    MS = [
        { Pattern, Conds, [{{{{RealmUri, Uri}}, '$1', '$2'}}] }
    ],

    case maps:find(limit, Opts) of
        {ok, N} ->
            case ets:select(Tab, MS, N)  of
                ?EOT ->
                    ?EOT;
                {L0, Cont} ->
                    C = #trie_continuation{
                        type = registration,
                        realm_uri = RealmUri,
                        function = ?FUNCTION_NAME,
                        topic_tab = Cont
                    },
                    {L0, C}
            end;

        error ->
            ets:select(Tab, MS)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_exact_registration(continuation() | eot()) ->
    registration_match_res().


match_exact_registration(?EOT) ->
    ?EOT;

match_exact_registration(#trie_continuation{proc_tab = Cont0} = C0) ->
    case ets:select(Cont0) of
        ?EOT ->
            ?EOT;
        {L0, Cont} ->
            C = C0#trie_continuation{
                proc_tab = Cont
            },
            {L0, C}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
 match_subscription(RealmUri, Uri, Opts, Trie) ->
    merge_match_res(
        subscription,
        ?FUNCTION_NAME,
        match_exact_subscription(RealmUri, Uri, Opts, Trie),
        match_pattern_subscription(RealmUri, Uri, Opts, Trie)
    ).

%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_exact_subscription(uri(), uri(), map(), t()) ->
    subscription_match_res().

match_exact_subscription(RealmUri, Uri, Opts, Trie) ->
    L = match_local_exact_subscription(RealmUri, Uri, Opts, Trie),
    R = match_remote_exact_subscription(RealmUri, Uri, Opts, Trie),
    match_exact_subscription(L, R).


%% @private
match_exact_subscription(L, R) when is_list(L), is_list(R) ->
    {L, R};

match_exact_subscription(?EOT, ?EOT) ->
    ?EOT;

match_exact_subscription({L, C0}, ?EOT) ->
    C = C0#trie_continuation{function = ?FUNCTION_NAME},
    {{L, []}, C};

match_exact_subscription(?EOT, {R, C0}) ->
    C = C0#trie_continuation{function = ?FUNCTION_NAME},
    {{[], R}, C};

match_exact_subscription({L, C0}, {R, C1}) ->
    C = C0#trie_continuation{
        function = ?FUNCTION_NAME,
        topic_remote_tab = C1#trie_continuation.topic_remote_tab
    },
    {{L, R}, C}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_exact_subscription(ets:continuation()) ->
    subscription_match_res().

match_exact_subscription(#trie_continuation{} = C0) ->
    {L, C1} =
        case C0#trie_continuation.topic_tab of
            undefined ->
                {[], C0};
            Tab1 ->
                case ets:select(Tab1) of
                    ?EOT ->
                        {[], C0};
                    {L0, LCont} ->
                        {L0, C0#trie_continuation{topic_tab = LCont}}
                end
        end,

    {R, C} =
        case C1#trie_continuation.topic_remote_tab of
            undefined ->
                {[], C1};
            Tab2 ->
                case ets:select(Tab2)  of
                    ?EOT ->
                        {[], C1};
                    {R0, RCont} ->
                        {R0, C1#trie_continuation{topic_remote_tab = RCont}}
                end
        end,

    case {L, R} of
        {[], []} ->
            ?EOT;
        Res ->
            {Res, C}
    end.


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
        entry_key = '$2'
    },

    Return = [{{{{RealmUri, Uri}}, '$2'}}],

    MS = [{Pattern, Conds, Return}],

    case maps:find(limit, Opts) of
        {ok, N} ->
            case ets:select(Tab, MS, N) of
                ?EOT ->
                    ?EOT;
                {L, ETSCont} ->
                    C = #trie_continuation{
                        type = subscription,
                        realm_uri = RealmUri,
                        topic_tab = ETSCont
                    },
                    {L, C}
            end;
        error ->
            ets:select(Tab, MS)
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
                        realm_uri = RealmUri,
                        topic_remote_tab = ETSCont
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
-spec match_pattern_registration(uri(), uri(), map(), t()) ->
    registration_match().

match_pattern_registration(_RealmUri, _Uri, _Opts, _Trie) ->
    ?EOT.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_pattern_registration(continuation()) ->
    registration_match().

match_pattern_registration(#trie_continuation{}) ->
    %% ART does not support limits yet
    ?EOT.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_pattern_subscription(uri(), uri(), map(), t()) ->
    subscription_match().

match_pattern_subscription(RealmUri, Uri, Opts, Trie) ->
    ART = Trie#bondy_registry_trie.topic_art,
    Pattern = <<RealmUri/binary, $., Uri/binary>>,
    ArtOpts = #{
        match_spec => art_ms(Opts),
        first => <<RealmUri/binary, $.>>
    },
    %% Always sync at the moment
    All = art_find_matches(Pattern, ArtOpts, ART, 0),
    split_remote(All).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_pattern_subscription(continuation()) ->
    subscription_match().

match_pattern_subscription(#trie_continuation{}) ->
    %% ART does not support limits yet
    ?EOT.


%% @private
split_remote([]) ->
    {[], []};

split_remote(All) when is_list(All) ->
    Nodestring = partisan:nodestring(),

    {L, R} = lists:foldl(
        fun
            ({{_, NS, _, _, _}, _}, {L, R}) when NS =/= Nodestring ->
                %% A remote subscription, we just append the nodestring on the
                %% right-hand side acc
                Node = binary_to_atom(NS, utf8),
                {L, sets:add_element(Node, R)};

            ({{Bin, _, _, _, _}, EntryKey}, {L, R}) ->
                %% See trie_key to understand how we generated Bin
                RealmUri = bondy_registry_entry:realm_uri(EntryKey),
                Sz = byte_size(RealmUri),
                <<RealmUri:Sz/binary, $., Uri0/binary>> = Bin,
                Uri = string:trim(Uri0, trailing, "*"),

                %% We project the expected triple
                Match = {{RealmUri, Uri}, EntryKey},
                {[Match|L], R}
        end,
        {[], sets:new()},
        All
    ),
    {lists:reverse(L), sets:to_list(R)};

split_remote(?EOT) ->
    ?EOT;

split_remote({All, Cont}) ->
    {split_remote(All), Cont}.


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
merge_match_res(registration, _, L1, L2) when is_list(L1), is_list(L2) ->
    lists:append(L1, L2);

merge_match_res(subscription, _, {L1, R1}, {L2, R2})
when is_list(L1), is_list(R1), is_list(L2), is_list(R2) ->
    {lists:append(L1, L2), lists:append(R1, R2)};

merge_match_res(_, _, ?EOT, ?EOT) ->
    ?EOT;

merge_match_res(_, _, ?EOT, Res) ->
    Res;

merge_match_res(_, _, Res, ?EOT) ->
    Res;

merge_match_res(registration, FN, {L1, C1}, {L2, C2})
when is_list(L1), is_list(L2) ->
    C = merge_continuation(FN, C1, C2),
    {lists:append(L1, L2), C};


merge_match_res(subscription, FN, {{L1, R1}, C1}, {{L2, R2}, C2})
when is_list(L1), is_list(R1), is_list(L2), is_list(R2) ->
    C = merge_continuation(FN, C1, C2),
    {{lists:append(L1, L2), lists:append(R1, R2)}, C}.


%% @private
merge_continuation(FN, A, B) ->
    #trie_continuation{
        type = T1,
        realm_uri = R1,
        proc_tab = Tab1a,
        proc_art = Tab2a,
        topic_tab = Tab3a,
        topic_art = Tab4a,
        topic_remote_tab = Tab5a
    } = A,

    #trie_continuation{
        type = T2,
        realm_uri = R2,
        proc_tab = Tab1b,
        proc_art = Tab2b,
        topic_tab = Tab3b,
        topic_art = Tab4b,
        topic_remote_tab = Tab5b
    } = B,

    (T1 == T2 andalso R1 == R2) orelse error(badarg),

    A#trie_continuation{
        function = FN,
        proc_tab = merge_continuation_tab(Tab1a, Tab1b),
        proc_art = merge_continuation_tab(Tab2a, Tab2b),
        topic_tab = merge_continuation_tab(Tab3a, Tab3b),
        topic_art = merge_continuation_tab(Tab4a, Tab4b),
        topic_remote_tab = merge_continuation_tab(Tab5a, Tab5b)
    }.


%% @private
merge_continuation_tab(undefined, undefined) ->
    undefined;

merge_continuation_tab(undefined, Value) ->
    Value;

merge_continuation_tab(Value, undefined) ->
    Value.






%% =============================================================================
%% PRIVATE: CRUD
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
    Invoke = bondy_registry_entry:get_option(invoke, Entry, ?INVOKE_SINGLE),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),

    Object = #proc_index{
        key = {RealmUri, Uri},
        invoke = Invoke,
        entry_key = EntryKey
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
    Invoke = bondy_registry_entry:get_option(invoke, Entry, ?INVOKE_SINGLE),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),
    Object = #proc_index{
        key = {RealmUri, Uri},
        invoke = Invoke,
        entry_key = EntryKey
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
add_exact_subscription(Entry, Trie) ->
    Tab = Trie#bondy_registry_trie.topic_tab,
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    EntryKey = bondy_registry_entry:key(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),

    Object = #topic_idx{
        key = {RealmUri, Uri},
        entry_key = EntryKey
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
    MatchPolicy = bondy_registry_entry:match_policy(Entry),

    Object = #topic_idx{
        key = {RealmUri, Uri},
        entry_key = EntryKey
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
add_pattern_entry(Entry, Trie) ->
    case bondy_registry_entry:type(Entry) of
        registration ->
            {error, unsupported_match_policy};

        subscription ->
            Uri = bondy_registry_entry:uri(Entry),
            EntryKey = bondy_registry_entry:key(Entry),
            MatchPolicy = bondy_registry_entry:match_policy(Entry),

            TrieKey = art_key(Entry),

            _ = art:set(TrieKey, EntryKey, Trie#bondy_registry_trie.topic_art),

            IsFirstEntry = incr_counter(Uri, MatchPolicy, 1, Trie) =:= 1,

            {ok, Entry, IsFirstEntry}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
del_pattern_entry(Entry, Trie) ->
    ART = case bondy_registry_entry:type(Entry) of
        registration ->
            Trie#bondy_registry_trie.proc_art;

        subscription ->
            Trie#bondy_registry_trie.topic_art
    end,

    Uri = bondy_registry_entry:uri(Entry),
    MatchPolicy = bondy_registry_entry:match_policy(Entry),

    TrieKey = art_key(Entry),
    ok = art:delete(TrieKey, ART),

    _ = decr_counter(Uri, MatchPolicy, 1, Trie),

    ok.



%% =============================================================================
%% PRIVATE: URI COUNTERS
%% =============================================================================

%% TODO we should remove the use of these counters. We use them becuase
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
art_find_matches(Pattern, Opts, ART, 0) ->
    case art:find_matches(Pattern, Opts, ART) of
        {error, badarg} ->
            [];
        {error, Reason} ->
            error(Reason);
        Result ->
            Result
    end;

art_find_matches(Pattern, Opts, ART, N) when N > 0 ->
    try
        art:find_matches(Pattern, Opts, ART)
    catch
        error:badarg ->
            %% retry
            art_find_matches(Pattern, Opts, ART, N - 1);
        _:Reason ->
            error(Reason)
    end.


%% @private
-spec art_ms(map()) -> ets:match_spec() | undefined.

art_ms(Opts) ->
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

    Conds1 = case maps:find(eligible, Opts) of
        error ->
            %% Not provided
            [];
        {ok, []} ->
            %% Idem as not provided
            [];

        {ok, EligibleIds} ->
            %% We include the provided ProtocolSessionIds
            [
                maybe_or(
                    [
                        {'=:=', '$3', {const, integer_to_binary(S)}}
                        || S <- EligibleIds
                    ]
                )
            ]
    end,

    Conds2 = case maps:find(exclude, Opts) of
        error ->
            Conds1;

        {ok, []} ->
            Conds1;

        {ok, ExcludedIds} ->
            %% We exclude the provided ProtocolSessionIds
            ExclConds = maybe_and(
                [
                    {'=/=', '$3', {const, integer_to_binary(S)}}
                    || S <- ExcludedIds
                ]
            ),
            [ExclConds | Conds1]
    end,

    case Conds2 of
        [] ->
            undefined;

        [_] ->
            % {Key, Node, ProtocolSessionId, SessionId, EntryIdBin}
            [{ {{'_', Node, '$3', '_', '_'}, '_'}, Conds2, ['$_'] }];

        _ ->
            Conds3 = [list_to_tuple(['andalso' | Conds2])],
            [{ {{'_', Node, '$3', '_', '_'}, '_'}, Conds3, ['$_'] }]
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


%% @private
-spec art_key(bondy_registry_entry:t_or_key()) -> art:key().

art_key(Entry) ->
    Policy = bondy_registry_entry:match_policy(Entry),
    art_key(Entry, Policy).


%% @private
-spec art_key(bondy_registry_entry:t_or_key(), binary()) -> art:key().

art_key(Entry, Policy) ->
    RealmUri = bondy_registry_entry:realm_uri(Entry),
    Uri = bondy_registry_entry:uri(Entry),
    SessionId0 = bondy_registry_entry:session_id(Entry),
    Nodestring = bondy_registry_entry:nodestring(Entry),


    {ProtocolSessionId, SessionId, Id} = case bondy_registry_entry:id(Entry) of
        _ when SessionId0 == '_' ->
            %% As we currently do not support wildcard matching in art:match,
            %% we turn this into a prefix matching query
            %% TODO change when wildcard matching is enabled in art.
            {<<>>, <<>>, <<>>};
        Id0 when SessionId0 == undefined ->
            {<<"undefined">>, <<"undefined">>, term_to_trie_key_part(Id0)};
        Id0 when is_binary(SessionId0) ->
            ProtocolSessionId0 = bondy_session_id:to_external(SessionId0),
            {
                term_to_trie_key_part(ProtocolSessionId0),
                term_to_trie_key_part(SessionId0),
                term_to_trie_key_part(Id0)
            }
    end,

    %% RealmUri is always ground, so we join it with URI using a $. as any
    %% other separator will not work with art:find_matches/2
    Key = <<RealmUri/binary, $., Uri/binary>>,

    %% We add Nodestring for cases where SessionId == <<>>
    case Policy of
        ?PREFIX_MATCH ->
            %% art lib uses the star char to explicitely denote a prefix
            {<<Key/binary, $*>>, Nodestring, ProtocolSessionId, SessionId, Id};
        _ ->
            {Key, Nodestring, ProtocolSessionId, SessionId, Id}
    end.


%% @private
term_to_trie_key_part('_') ->
    <<>>;

term_to_trie_key_part(Term) when is_atom(Term) ->
    atom_to_binary(Term, utf8);

term_to_trie_key_part(Term) when is_integer(Term) ->
    integer_to_binary(Term);

term_to_trie_key_part(Term) when is_binary(Term) ->
    Term.


%% trie_key_realm_procedure(RealmUri, {Key, _, _, _, _}) ->
%%     <<RealmUri:(byte_size(RealmUri))/binary, $., Uri/binary>> = Key,
%%     Uri.


