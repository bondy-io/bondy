%% =============================================================================
%%  bondy_load_balancer.erl -
%%
%%  Copyright (c) 2016-2018 Ngineo Limited t/a Leapsight. All rights reserved.
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
    strategy => #{
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => {in, [single, first, last, random, round_robin]}
    },
    force_locality => #{
        required => true,
        allow_null => false,
        allow_undefined => false,
        default => true,
        datatype => boolean
    }
}).

-record(last_invocation, {
    key     ::  {uri(), uri()},
    value   ::  id()
}).

-type entries()             ::  [bondy_registry_entry:t()].
-type strategy()            ::  single | first | last | random | round_robin.
-type opts()                ::  #{
    strategy => strategy(),
    force_locality => boolean()
}.
-opaque continuation()        ::  {strategy(), entries()}.


-export_type([continuation/0]).


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
    Node = bondy_peer_service:mynode(),
    do_get(iterate(Entries, Opts), Node).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec iterate(entries(), opts()) ->
    {bondy_registry_entry:t(), continuation()} | '$end_of_table'.

iterate(Entries0, Opts0) when is_list(Entries0) ->
    #{
        strategy := Strat,
        force_locality := Loc
    } = maps_utils:validate(Opts0, ?OPTS_SPEC),

    Entries = maybe_sort_entries(Loc, Entries0),

    case Strat of
        single when length(Entries) == 1 ->
            next(Entries);
        first ->
            next(Entries);
        last ->
            next(lists:reverse(Entries));
        random ->
            next(lists_utils:shuffle(Entries));
        round_robin ->
            get_round_robin(Entries);
        _ ->
            error(badarg)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec iterate(continuation()) ->
    {bondy_registry_entry:t(), continuation()} | {error, noproc}.

iterate({round_robin, Entries}) ->
    get_round_robin(Entries);

iterate({_, Entries}) ->
    next(Entries).



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
do_get('$end_of_table', _) ->
    {error, noproc};

do_get({Entry, Cont}, Node) ->
    case bondy_registry_entry:node(Entry) =:= Node of
        true ->
            %% The wamp peer is local
            SessionId = bondy_registry_entry:session_id(Entry),
            Pid = bondy_session:pid(SessionId),
            case erlang:is_process_alive(Pid) of
                true ->
                    Entry;
                false ->
                    %% This should happen when the WAMP Peer
                    %% disconnected between the time we read the entry
                    %% and now. We contine trying with other entries.
                    do_get(iterate(Cont), Node)
            end;
        false ->
            %% This wamp peer is remote.
            %% We cannot check the remote node as we might not have
            %% a direct connection, so we trust we have an uptodate state.
            %% Any failover strategy should be handled by the user.
            Entry
    end.


%% @private
maybe_sort_entries(true, L) ->
    Node = bondy_peer_service:mynode(),
    Fun = fun(A, B) ->
        case {bondy_registry_entry:node(A), bondy_registry_entry:node(B)} of
            {Node, _} -> true;
            {_, Node} -> false;
            _ -> A =< B % to keep order of remaining elements
        end
    end,
    lists:sort(Fun, L);

maybe_sort_entries(false, L) ->
    L.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec next(entries()) ->
    {bondy_registry_entry:t(), entries()} | '$end_of_table'.

next([H|T]) ->
    {H, T};

next([]) ->
    '$end_of_table'.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_round_robin(entries()) ->
    {bondy_registry_entry:t(), entries()} | '$end_of_table'.

get_round_robin(Entries) ->
    First = hd(Entries),
    Uri = bondy_registry_entry:uri(First),
    RealmUri = bondy_registry_entry:realm_uri(First),
    get_round_robin(last_invocation(RealmUri, Uri), Entries).


get_round_robin(undefined, [H|T]) ->
    %% We never invoke this procedure before or we reordered the round
    Pid = bondy_session:pid(bondy_registry_entry:session_id(H)),
    case process_info(Pid) of
        undefined ->
            %% The peer connection must have been closed between
            %% the time we read and now.
            get_round_robin(undefined, T);
        _ ->
            %% We update the invocation state
            ok = set_last_invocation(
                bondy_registry_entry:realm_uri(H),
                bondy_registry_entry:uri(H),
                bondy_registry_entry:id(H)
            ),
            %% We return the entry and the remaining ones
            {H, T}
    end;

get_round_robin(#last_invocation{value = LastId}, Entries0) ->
    Pred = fun(E) -> LastId =:= bondy_registry_entry:id(E) end,
    Entries1 = lists_utils:rotate_right_with(Pred, Entries0),
    get_round_robin(undefined, Entries1);

get_round_robin(undefined, []) ->
    '$end_of_table'.


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


