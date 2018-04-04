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
%% @doc
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
        datatype => {in, [first, last, random, round_robin]}
    }
}).

-record(last_invocation, {
    key     ::  {uri(), uri()},
    value   ::  id()
}).

-type entries()             ::  [bondy_registry_entry:t()].
-type strategy()            ::  first | last | random | round_robin.
-type opts()                ::  #{strategy => strategy()}.



-export([get_entry/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_entry(entries(), opts()) -> bondy_registry_entry:t().
get_entry(Entries, Opts0) when is_list(Entries) ->
    #{strategy := Strat} = maps_utils:validate(Opts0, ?OPTS_SPEC),
    case Strat of
        first ->
            get_first(Entries);
        last ->
            get_first(lists:reverse(Entries));
        random ->
            get_first(lists_utils:shuffle(Entries));
        round_robin ->
            get_round_robin(Entries)
    end.





%% =============================================================================
%% PRIVATE
%% =============================================================================



get_first([H|T]) ->
    Pid = bondy_session:pid(bondy_registry_entry:session_id(H)),
    case process_info(Pid) == undefined of
        true ->
            get_first(T);
        false ->
            H
    end;

get_first([]) ->
    not_found.


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
            %% We return the entry
            H
    end;

get_round_robin(#last_invocation{value = LastId}, Entries0) ->
    Pred = fun(E) -> LastId =:= bondy_registry_entry:id(E) end,
    Entries1 = lists_utils:rotate_right_with(Pred, Entries0),
    get_round_robin(undefined, Entries1);

get_round_robin(undefined, []) ->
    not_found.


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


