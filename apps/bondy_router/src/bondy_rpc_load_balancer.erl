%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_load_balancer).
-moduledoc """
This module implements a distributed load balancer, providing the
different load balancing strategies used by bondy_dealer to choose
the Callee and Procedure to invoke when handling a WAMP Call.

At the moment the load balancing state is local and not replicated
across the nodes in the cluster. However, each node has access to a local
replica of the global registry and thus can load balance between local and
remote Callees.

## Supported Load Balancing Strategies

Bondy supports all WAMP Basic and Advanced Profile load balancing
strategies for Shared Registrations and extends those with additional
strategies.

### Single

### First

### Last

### Random

### Round Robin

### Jump Consistent Hash

### Queue Least Loaded

### Queue Least Loaded Sample


In the future we will explore implementing distributed load balancing
algorithms such as Ant Colony, Particle Swarm Optimization and Biased Random
Sampling [See references](https://pdfs.semanticscholar.org/b9a9/52ed1b8bfae2e976b5c0106e894bd4c41d89.pdf)
""".
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-define(RPC_STATE_TABLE, bondy_rpc_state).
-define(OPTS_SPEC, #{
    %% BONDY extension
    %% TODO this should be a map
    %% #{strategy => #{id => queue_least_loaded, _prefer_local}}
    strategy => #{
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype =>
            {in, [
                %% WAMP
                single,
                ?INVOKE_SINGLE,
                first,
                ?INVOKE_FIRST,
                last,
                ?INVOKE_LAST,
                random,
                ?INVOKE_RANDOM,
                round_robin,
                ?INVOKE_ROUND_ROBIN,
                %% BONDY extensions
                jump_consistent_hash,
                ?INVOKE_JUMP_CONSISTENT_HASH,
                queue_least_loaded,
                ?INVOKE_QUEUE_LEAST_LOADED,
                queue_least_loaded_sample,
                ?INVOKE_QUEUE_LEAST_LOADED_SAMPLE
            ]},
        validator => fun
            (?INVOKE_ROUND_ROBIN) ->
                %% We are picky with style
                {ok, round_robin};
            (Val) when is_binary(Val) ->
                {ok, binary_to_existing_atom(Val, utf8)};
            (Val) when is_atom(Val) ->
                true
        end
    },
    '_prefer_local' => #{
        required => true,
        allow_null => false,
        allow_undefined => false,
        default => true,
        datatype => boolean
    },
    '_routing_key' => #{
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    }
}).

-record(last_invocation, {
    key :: {uri(), uri()},
    value :: id()
}).

-record(iterator, {
    strategy :: strategy(),
    entries :: entries(),
    options = #{} :: map()
}).

-type entries() :: [bondy_registry_entry:t()].
-type strategy() ::
    single
    | first
    | last
    | random
    | round_robin
    | jump_consistent_hash
    | queue_least_loaded
    | queue_least_loaded_sample.
-type opts() :: #{
    strategy := strategy(),
    '_prefer_local' => boolean(),
    '_routing_key' => binary()
}.
-opaque iterator() :: #iterator{}.

-export_type([iterator/0]).

-export([iterate/1]).
-export([iterate/2]).
-export([select/2]).
-export([select_node/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec select(entries(), opts()) ->
    {ok, bondy_registry_entry:t()} | {error, noproc | map()}.

select(Entries, Opts) when is_list(Entries) ->
    do_select(iterate(Entries, Opts)).

-spec iterate(entries(), opts()) ->
    {bondy_registry_entry:t(), iterator()}
    | '$end_of_table'
    | {error, noproc | map()}.

iterate(Entries, Opts0) when is_list(Entries) ->
    try
        Opts = validate_options(Opts0),
        iterate(iterator(Entries, Opts))
    catch
        error:Error when is_map(Error) ->
            {error, Error}
    end.

-spec iterate(iterator()) ->
    {bondy_registry_entry:t(), iterator()} | {error, noproc} | 'end_of_table'.

iterate(#iterator{strategy = round_robin} = Iter) ->
    next_round_robin(Iter);
iterate(#iterator{strategy = jump_consistent_hash} = Iter) ->
    next_consistent_hash(Iter, jch);
iterate(#iterator{strategy = queue_least_loaded} = Iter) ->
    next_queue_least_loaded(Iter, length(Iter#iterator.entries));
iterate(#iterator{strategy = queue_least_loaded_sample} = Iter) ->
    next_queue_least_loaded(Iter, 2);
iterate(#iterator{} = Iter) ->
    %%  single, first, last, random
    next(Iter).

%% =============================================================================
%% PRIVATE
%% =============================================================================

validate_options(Opts0) ->
    case maps_utils:validate(Opts0, ?OPTS_SPEC) of
        #{strategy := jump_consistent_hash, '_routing_key' := _} = Opts ->
            Opts;
        #{strategy := jump_consistent_hash} ->
            error(
                bondy_error:new(missing_required_value, #{
                    message =>
                        ~"A value for option '_routing_key' or 'rkey' is required",
                    details => #{key => ~"_routing_key"}
                })
            );
        Opts ->
            Opts
    end.

%% @private
iterator(Entries, Opts) ->
    #iterator{
        strategy = maps:get(strategy, Opts),
        entries = prepare_entries(Entries, Opts),
        options = maps:without([strategy], Opts)
    }.

%% @private
prepare_entries(Entries, #{strategy := single}) ->
    %% There should only be one entry here, but instead of failing
    %% we would consistently select the first one, regardless of location.
    Entries;
prepare_entries(Entries, #{strategy := jump_consistent_hash}) ->
    lists:keysort(1, Entries);
prepare_entries(Entries, #{strategy := queue_least_loaded_sample}) ->
    lists_utils:shuffle(Entries);
prepare_entries(Entries, #{'_prefer_local' := Flag}) ->
    maybe_sort_by_locality(Flag, Entries);
prepare_entries(Entries, _) ->
    maybe_sort_by_locality(false, Entries).

%% @private
maybe_sort_by_locality(true, L) ->
    %% We always sort first by most general (required by WAMP) then by locality
    %% and then by time.
    TimeComp = bondy_registry_entry:time_comparator(),
    LocComp = bondy_registry_entry:locality_comparator(TimeComp),
    Comp = bondy_registry_entry:mg_comparator(LocComp),
    lists:sort(Comp, L);
maybe_sort_by_locality(false, L) ->
    %% We assume entries are already sorted
    L.

%% @private
-doc """
No synchronous liveness check on the chosen entry: the registry
removes entries on session death and `bondy_dealer:flush/2` fast-fails
any in-flight promises for the dead callee, so the narrow TOCTOU race
that a check would have covered is bounded by the same failure path.
""".
do_select('$end_of_table') ->
    {error, noproc};
do_select({error, _} = Error) ->
    Error;
do_select({Entry, _Iter}) ->
    {ok, Entry}.

-doc """
The NODE stage of hierarchical (RIB) selection: picks one node among the
units advertising a procedure, honouring the invocation policy over the
units' routing summaries. Each unit is `{self | Nodestring, Summary}` where
`Summary` carries `count` (the selection weight), `earliest` and `latest`.
The winning node completes the selection among its own live local
registrations (owner-side completion), which is what makes the two-stage
distribution equivalent to the single-stage one.

Node-local state only (the round-robin cursor lives in this node's rpc
state table), mirroring the per-caller-node semantics of `select/2`.
""".
-spec select_node(
    Units :: [{self | binary(), map()}],
    Opts :: map()
) -> {ok, self | binary()} | {error, noproc}.

select_node([], _) ->
    {error, noproc};
select_node([{Id, _}], _) ->
    {ok, Id};
select_node(Units0, Opts) ->
    %% Deterministic base order: `self` (an atom) sorts before nodestrings.
    Units = lists:keysort(1, Units0),

    case node_strategy(maps:get(strategy, Opts, ?INVOKE_SINGLE)) of
        Extremal when Extremal == single orelse Extremal == first ->
            %% `single`: at most one unit exists in steady state; a
            %% conflicting duplicate (partition heal) tie-breaks on the
            %% oldest registration, mirroring first-wins resolution.
            {ok, element(1, extremal_unit(earliest, fun erlang:min/2, Units))};
        last ->
            {ok, element(1, extremal_unit(latest, fun erlang:max/2, Units))};
        round_robin ->
            {ok, weighted_rotation(Units, Opts)};
        jump_consistent_hash ->
            case maps:get('_routing_key', Opts, undefined) of
                undefined ->
                    {ok, weighted_random(Units)};
                Key ->
                    Bucket = bondy_consistent_hashing:bucket(
                        Key, length(Units), jch
                    ),
                    {ok, element(1, lists:nth(Bucket + 1, Units))}
            end;
        _ ->
            %% random | queue_least_loaded[_sample]: the caller cannot probe
            %% remote mailboxes, so the node stage is weighted random; the
            %% owner stage applies the accurate local policy.
            {ok, weighted_random(Units)}
    end.

%% @private
%% Accepts the WAMP invoke option (binary) or the internal strategy atom.
node_strategy(?INVOKE_SINGLE) -> single;
node_strategy(?INVOKE_ROUND_ROBIN) -> round_robin;
node_strategy(?INVOKE_RANDOM) -> random;
node_strategy(?INVOKE_FIRST) -> first;
node_strategy(?INVOKE_LAST) -> last;
node_strategy(B) when is_binary(B) -> binary_to_existing_atom(B, utf8);
node_strategy(A) when is_atom(A) -> A.

%% @private
%% The unit with the extremal (min/max) summary `Field`; ties keep the
%% earlier unit in the deterministic base order.
extremal_unit(Field, MinMax, [H | T]) ->
    lists:foldl(
        fun({_, S} = U, {_, SAcc} = Acc) ->
            A = maps:get(Field, S, 0),
            B = maps:get(Field, SAcc, 0),
            case A =/= B andalso MinMax(A, B) == A of
                true -> U;
                false -> Acc
            end
        end,
        H,
        T
    ).

%% @private
weighted_random([{Id, _}]) ->
    Id;
weighted_random(Units) ->
    Total = lists:sum([weight(S) || {_, S} <- Units]),
    nth_weighted(rand:uniform(Total) - 1, Units).

%% @private
%% A deterministic weighted rotation: a per-(realm, uri) counter walks the
%% cumulative weights, so each unit is visited `count` times per cycle.
weighted_rotation(Units, Opts) ->
    RealmUri = maps:get(realm_uri, Opts),
    Uri = maps:get(uri, Opts),
    Tab = rpc_state_table(RealmUri, Uri),
    %% The rpc state table keys on ELEMENT 2 (its other rows are records),
    %% so the counter row is a 3-tuple: tag, key, counter. The key carries
    %% the `rib_rr` discriminator so it can never collide with the
    %% `#last_invocation{}` rows keyed `{RealmUri, Uri}` in the same table.
    Key = {rib_rr, RealmUri, Uri},
    N = ets:update_counter(Tab, Key, {3, 1}, {rib_rr_counter, Key, -1}),
    Total = lists:sum([weight(S) || {_, S} <- Units]),
    nth_weighted(N rem Total, Units).

%% @private
%% The unit owning zero-based position `N` on the cumulative weight line.
nth_weighted(N, [{Id, S} | T]) ->
    case weight(S) of
        W when N < W -> Id;
        W -> nth_weighted(N - W, T)
    end.

%% @private
weight(Summary) ->
    max(1, maps:get(count, Summary, 1)).

%% @private
-spec next(iterator()) ->
    {bondy_registry_entry:t(), iterator()} | '$end_of_table'.

next(#iterator{entries = [H | T]} = Iter) ->
    {H, Iter#iterator{entries = T}};
next(#iterator{entries = []}) ->
    '$end_of_table'.

%% @private
% @TODO take into consideration force_locality
-spec next_round_robin(iterator()) ->
    {bondy_registry_entry:t(), iterator()} | '$end_of_table'.

next_round_robin(#iterator{entries = []}) ->
    '$end_of_table';
next_round_robin(Iter) ->
    First = hd(Iter#iterator.entries),
    Uri = bondy_registry_entry:uri(First),
    RealmUri = bondy_registry_entry:realm_uri(First),
    next_round_robin(Iter, last_invocation(RealmUri, Uri)).

%% @private
next_round_robin(#iterator{entries = [H | T]} = Iter, undefined) ->
    %% We never invoked this procedure before or we reordered the round.
    %% No synchronous liveness check — see do_select/1.
    NewIter = Iter#iterator{entries = T},
    ok = set_last_invocation(
        bondy_registry_entry:realm_uri(H),
        bondy_registry_entry:uri(H),
        bondy_registry_entry:id(H)
    ),
    {H, NewIter};
next_round_robin(Iter, #last_invocation{value = LastId}) ->
    Pred = fun(E) -> LastId =:= bondy_registry_entry:id(E) end,
    Entries = lists_utils:rotate_right_with(Pred, Iter#iterator.entries),
    next_round_robin(Iter#iterator{entries = Entries}, undefined);
next_round_robin(#iterator{entries = []}, undefined) ->
    '$end_of_table'.

%% @private
-spec next_consistent_hash(Iter :: iterator(), Algo :: atom()) ->
    {bondy_registry_entry:t(), iterator()} | '$end_of_table'.

next_consistent_hash(#iterator{entries = []}, _) ->
    '$end_of_table';
next_consistent_hash(Iter, Algo) ->
    Key = maps:get('_routing_key', Iter#iterator.options),
    Buckets = length(Iter#iterator.entries),
    Bucket = bondy_consistent_hashing:bucket(Key, Buckets, Algo),
    Entries = Iter#iterator.entries,

    %% Bucket is zero-based while lists position numbering starts at 1.
    Entry = lists:nth(Bucket + 1, Entries),
    EntryKey = bondy_registry_entry:key(Entry),

    NewIter = Iter#iterator{entries = lists:keydelete(EntryKey, 1, Entries)},
    {Entry, NewIter}.

%% @private
-spec next_queue_least_loaded(iterator(), SampleSize :: integer()) ->
    {bondy_registry_entry:t(), iterator()} | '$end_of_table'.

next_queue_least_loaded([], _) ->
    '$end_of_table';
next_queue_least_loaded(Iter, SampleSize) ->
    next_queue_least_loaded(Iter, SampleSize, 0, undefined).

%% @private
next_queue_least_loaded(Iter, SampleSize, Count, {_, Entry}) when
    SampleSize == Count
->
    {Entry, Iter};
next_queue_least_loaded(
    #iterator{entries = [H | T]} = Iter, SampleSize, Count, Chosen
) ->
    NewIter = Iter#iterator{entries = T},

    case bondy_registry_entry:is_local(H) of
        true ->
            %% The pid of the connection process
            Pid = bondy_registry_entry:pid(H),

            case erlang:process_info(Pid, [message_queue_len]) of
                undefined ->
                    %% Process died, we continue iterating
                    next_queue_least_loaded(NewIter, SampleSize, Count, Chosen);
                [{message_queue_len, Len}] when Chosen == undefined ->
                    next_queue_least_loaded(
                        NewIter, SampleSize, Count + 1, {Len, H}
                    );
                [{message_queue_len, Len}] ->
                    NewChosen =
                        case Chosen of
                            {Val, _} when Val =< Len -> Chosen;
                            _ -> {Len, H}
                        end,
                    next_queue_least_loaded(
                        NewIter, SampleSize, Count + 1, NewChosen
                    )
            end;
        false ->
            %% We already covered all local callees,
            %% select the first remote callee (in effect randomnly as we already
            %% shuffled the list of entries)
            {H, NewIter}
    end;
next_queue_least_loaded(#iterator{entries = []}, _, _, undefined) ->
    '$end_of_table';
next_queue_least_loaded(#iterator{entries = []}, _, _, Entry) ->
    Entry.

%% @private
-doc """
A table that persists calls and maintains the state of the load
balancing of invocations.
""".
rpc_state_table(RealmUri, Uri) ->
    tuplespace:locate_table(?RPC_STATE_TABLE, {RealmUri, Uri}).

-spec last_invocation(uri(), uri()) -> bondy_registry_entry:t() | undefined.

last_invocation(RealmUri, Uri) ->
    case ets:lookup(rpc_state_table(RealmUri, Uri), {RealmUri, Uri}) of
        [] -> undefined;
        [Entry] -> Entry
    end.

set_last_invocation(RealmUri, Uri, Val) ->
    Entry = #last_invocation{key = {RealmUri, Uri}, value = Val},
    true = ets:insert(rpc_state_table(RealmUri, Uri), Entry),
    ok.
