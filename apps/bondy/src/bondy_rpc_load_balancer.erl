%% =============================================================================
%%  bondy_load_balancer.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
%% @doc This module implements a distributed load balancer, providing the
%% different load balancing strategies used by bondy_dealer to choose
%% the Callee and Procedure to invoke when handling a WAMP Call.
%%
%% At the moment the load balancing state is local and not replicated
%% across the nodes in the cluster. However, each node has access to a local
%% replica of the global registry and thus can load balance between local and
%% remote Callees.
%%
%% ## Supported Load Balancing Strategies
%%
%% Bondy supports all WAMP Basic and Advanced Profile load balancing
%% strategies for Shared Registrations and extends those with additional
%% strategies.
%%
%% ### Single
%%
%% ### First
%%
%% ### Last
%%
%% ### Random
%%
%% ### Round Robin
%%
%% ### Jump Consistent Hash
%%
%% ### Queue Least Loaded
%%
%% ### Queue Least Loaded Sample
%%
%%
%% In the future we will explore implementing distributed load balancing
%% algorithms such as Ant Colony, Particle Swarm Optimization and Biased Random
%% Sampling [See references](https://pdfs.semanticscholar.org/b9a9/52ed1b8bfae2e976b5c0106e894bd4c41d89.pdf)
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_rpc_load_balancer).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(RPC_STATE_TABLE, bondy_rpc_state).
-define(OPTS_SPEC, #{
    %% BONDY extension
    %% TODO this should be a map
    %% #{strategy => #{id => queue_least_loaded, force_locality}}
    strategy => #{
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => {in, [
            %% WAMP
            single, ?INVOKE_SINGLE,
            first, ?INVOKE_FIRST,
            last, ?INVOKE_LAST,
            random, ?INVOKE_RANDOM,
            round_robin, ?INVOKE_ROUND_ROBIN,
            %% BONDY extensions
            jump_consistent_hash, ?INVOKE_JUMP_CONSISTENT_HASH,
            queue_least_loaded, ?INVOKE_QUEUE_LEAST_LOADED,
            queue_least_loaded_sample, ?INVOKE_QUEUE_LEAST_LOADED_SAMPLE
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
    'x_force_locality' => #{
        required => true,
        allow_null => false,
        allow_undefined => false,
        default => true,
        datatype => boolean
    },
    'x_routing_key' => #{
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    }
}).

-record(last_invocation, {
    key             ::  {uri(), uri()},
    value           ::  id()
}).

-record(iterator, {
    strategy        ::  strategy(),
    entries         ::  entries(),
    options = #{}   ::  map()
}).

-type entries()             ::  [bondy_registry_entry:t()].
-type strategy()            ::  single | first | last | random | round_robin
                                | jump_consistent_hash
                                | queue_least_loaded
                                | queue_least_loaded_sample.
-type opts()                ::  #{
    strategy := strategy(),
    'x_force_locality' => boolean(),
    'x_routing_key' => binary()
}.
-opaque iterator()          ::  #iterator{}.


-export_type([iterator/0]).


-export([iterate/1]).
-export([iterate/2]).
-export([get/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get(entries(), opts()) -> bondy_registry_entry:t() | {error, noproc}.

get(Entries, Opts) when is_list(Entries) ->
    Node = bondy_config:node(),
    do_get(iterate(Entries, Opts), Node).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec iterate(entries(), opts()) ->
    {bondy_registry_entry:t(), iterator()}
    | '$end_of_table'
    | {error, noproc | map()} .

iterate(Entries, Opts0) when is_list(Entries) ->
    try
        Opts = validate_options(Opts0),
        iterate(iterator(Entries, Opts))
    catch
        error:Error when is_map(Error) ->
            {error, Error}
    end.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
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
    %%  single, first, last
    next(Iter).



%% =============================================================================
%% PRIVATE
%% =============================================================================


validate_options(Opts0) ->
    case maps_utils:validate(Opts0, ?OPTS_SPEC) of
        #{strategy := jump_consistent_hash, 'x_routing_key' := _} = Opts ->
            Opts;
        #{strategy := jump_consistent_hash} ->
            ErrorMap = bondy_error:map({
                <<"missing_option">>,
                <<"A value for option 'x_routing_key' or 'rkey' is required">>
            }),
            error(ErrorMap);
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
prepare_entries(Entries, #{strategy := jump_consistent_hash}) ->
    lists:keysort(1, Entries);

prepare_entries(Entries, #{strategy := queue_least_loaded_sample}) ->
    lists_utils:shuffle(Entries);

prepare_entries(Entries, #{strategy := last, force_locality := Flag}) ->
    lists:reverse(maybe_sort_by_locality(Flag, Entries));

prepare_entries(Entries, #{strategy := last}) ->
    lists:reverse(maybe_sort_by_locality(true, Entries));

prepare_entries(Entries, #{strategy := single}) ->
    %% There should only be one entry here, but instead of failing
    %% we would consistently pick the first one, regardless of location.
    lists:keysort(1, Entries);

prepare_entries(Entries, _) ->
    maybe_sort_by_locality(true, Entries).


%% @private
maybe_sort_by_locality(true, L) ->
    Node = bondy_config:node(),
    Fun = fun(A, B) ->
        case {bondy_registry_entry:node(A), bondy_registry_entry:node(B)} of
            {Node, _} -> true;
            {_, Node} -> false;
            _ -> A =< B % to keep order of remaining elements
        end
    end,
    lists:sort(Fun, L);

maybe_sort_by_locality(false, L) ->
    L.


%% @private
do_get('$end_of_table', _) ->
    {error, noproc};

do_get({error, _} = Error, _) ->
    Error;

do_get({Entry, Iter}, Node) ->
    case bondy_registry_entry:node(Entry) =:= Node of
        true ->
            %% The wamp peer is local, so we should have a peer
            %% Callback peers are not allowed to be used on shared registration
            Pid = bondy_registry_entry:pid(Entry),

            case erlang:is_process_alive(Pid) of
                true ->
                    Entry;
                false ->
                    %% This should happen when the WAMP Peer
                    %% disconnected between the time we read the entry
                    %% and now. We contine trying with other entries.
                    do_get(iterate(Iter), Node)
            end;
        false ->
            %% This wamp peer is remote.
            %% We cannot check the remote node as we might not have
            %% a direct connection, so we trust we have an up-todate state.
            %% Any failover strategy should be handled by the user.
            Entry
    end.





%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec next(iterator()) ->
    {bondy_registry_entry:t(), iterator()} | '$end_of_table'.

next(#iterator{entries = [H|T]} = Iter) ->
    {H, Iter#iterator{entries = T}};

next(#iterator{entries = []}) ->
    '$end_of_table'.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec next_round_robin(iterator()) ->
    {bondy_registry_entry:t(), iterator()} | '$end_of_table'.

next_round_robin(Iter) ->
    First = hd(Iter#iterator.entries),
    Uri = bondy_registry_entry:uri(First),
    RealmUri = bondy_registry_entry:realm_uri(First),
    next_round_robin(Iter, last_invocation(RealmUri, Uri)).


next_round_robin(#iterator{entries = [H|T]} = Iter, undefined) ->
    %% We never invoked this procedure before or we reordered the round
    NewIter = Iter#iterator{entries = T},

    case bondy_config:node() =:= bondy_registry_entry:node(H) of
        true ->
            %% The pid of the connection process
            Pid = pid(H),
            case erlang:is_process_alive(Pid) of
                true ->
                    %% We update the invocation state
                    ok = set_last_invocation(
                        bondy_registry_entry:realm_uri(H),
                        bondy_registry_entry:uri(H),
                        bondy_registry_entry:id(H)
                    ),
                    %% We return the entry and the remaining ones
                    {H, NewIter};
                false ->
                    %% The peer connection must have been closed between
                    %% the time we read and now.
                    next_round_robin(NewIter, undefined)
            end;
        false ->
            %% A remote callee
            %% We update the invocation state
            ok = set_last_invocation(
                bondy_registry_entry:realm_uri(H),
                bondy_registry_entry:uri(H),
                bondy_registry_entry:id(H)
            ),
            %% We return the entry and the remaining ones
            {H, NewIter}
    end;

next_round_robin(Iter, #last_invocation{value = LastId}) ->
    Pred = fun(E) -> LastId =:= bondy_registry_entry:id(E) end,
    Entries = lists_utils:rotate_right_with(Pred, Iter#iterator.entries),
    next_round_robin(Iter#iterator{entries = Entries}, undefined);

next_round_robin(#iterator{entries = []}, undefined) ->
    '$end_of_table'.


pid(Entry) ->
    Pid = bondy_registry_entry:pid(Entry),

    case bondy_registry_entry:is_proxy(Entry) of
        true ->
            Pid;
        false ->
            case bondy_registry_entry:session_id(Entry) of
                undefined ->
                    Pid;
                SessionId ->
                    bondy_session:pid(SessionId)
            end
    end.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec next_consistent_hash(Iter :: iterator(), Algo :: atom()) ->
    {bondy_registry_entry:t(), iterator()} | '$end_of_table'.

next_consistent_hash(#iterator{entries = []}, _) ->
    '$end_of_table';

next_consistent_hash(Iter, Algo) ->
    Key = maps:get('x_routing_key', Iter#iterator.options),
    Buckets = length(Iter#iterator.entries),
    Bucket = bondy_consistent_hashing:bucket(Key, Buckets, Algo),
    Entries = Iter#iterator.entries,

    %% Bucket is zero-based while lists position numbering starts at 1.
    Entry = lists:nth(Bucket + 1, Entries),
    EntryKey = bondy_registry_entry:key(Entry),

    NewIter = Iter#iterator{entries = lists:keydelete(EntryKey, 1, Entries)},
    {Entry, NewIter}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec next_queue_least_loaded(iterator(), SampleSize :: integer()) ->
    {bondy_registry_entry:t(), iterator()} | '$end_of_table'.

next_queue_least_loaded([], _) ->
    '$end_of_table';

next_queue_least_loaded(Iter, SampleSize) ->
    next_queue_least_loaded(Iter, SampleSize, 0, undefined).


%% @private
next_queue_least_loaded(Iter, SampleSize, Count, {_, Entry})
when SampleSize == Count ->
    {Entry, Iter};

next_queue_least_loaded(
    #iterator{entries = [H|T]} = Iter, SampleSize, Count, Chosen) ->
    NewIter = Iter#iterator{entries = T},

    case bondy_registry_entry:is_local(H) of
        true ->
            %% The pid of the connection process
            Pid = bondy_session:pid(bondy_registry_entry:session_id(H)),
            case erlang:process_info(Pid, [message_queue_len]) of
                undefined ->
                    %% Process died, we continue iterating
                    next_queue_least_loaded(NewIter, SampleSize, Count, Chosen);
                [{message_queue_len, Len}] when Chosen == undefined ->
                    next_queue_least_loaded(
                        NewIter, SampleSize, Count + 1, {Len, H});
                [{message_queue_len, Len}] ->
                    NewChosen = case Chosen of
                        {Val, _} when Val =< Len -> Chosen;
                        _ -> {Len, H}
                    end,
                    next_queue_least_loaded(
                        NewIter, SampleSize, Count + 1, NewChosen)
            end;
        false ->
            %% We already covered all local callees,
            %% pick the first remote callee (in effect randomnly as we already
            %% shuffled the list of entries)
            {H, NewIter}
    end;

next_queue_least_loaded(#iterator{entries = []}, _, _, undefined) ->
    '$end_of_table';

next_queue_least_loaded(#iterator{entries = []}, _, _, Entry) ->
    Entry.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% A table that persists calls and maintains the state of the load
%% balancing of invocations
%% @end
%% -----------------------------------------------------------------------------
rpc_state_table(RealmUri, Uri) ->
    tuplespace:locate_table(?RPC_STATE_TABLE, {RealmUri, Uri}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
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




