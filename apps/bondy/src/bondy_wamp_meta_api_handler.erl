%% =============================================================================
%%  bondy_wamp_meta_api_handler.erl -
%%
%%  Copyright (c) 2016-2019 Ngineo Limited t/a Leapsight. All rights reserved.
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
-module(bondy_wamp_meta_api_handler).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(BONDY_REG_LIST, <<"bondy.registration.list">>).
-define(BONDY_CALLEE_LIST, <<"bondy.callee.list">>).
-define(BONDY_CALLEE_GET, <<"bondy.callee.get">>).
-define(WAMP_REG_LIST, <<"wamp.registration.list">>).
-define(WAMP_REG_LOOKUP, <<"wamp.registration.lookup">>).
-define(WAMP_REG_MATCH, <<"wamp.registration.match">>).
-define(WAMP_REG_GET, <<"wamp.registration.get">>).
-define(WAMP_LIST_CALLEES, <<"wamp.registration.list_callees">>).
-define(WAMP_COUNT_CALLEES, <<"wamp.registration.count_callees">>).

-export([handle_call/2]).



%% =============================================================================
%% API
%% =============================================================================



-spec handle_call(M :: wamp_message(), Ctxt :: map()) -> ok | no_return().


%% -----------------------------------------------------------------------------
%% WAMP REGISTRATION META PROCEDURES
%% -----------------------------------------------------------------------------
handle_call(#call{procedure_uri = ?WAMP_REG_LIST} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [RealmUri]} ->
            summary(registration, RealmUri);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), bondy_wamp_utils:maybe_error(R, M));


handle_call(#call{procedure_uri = ?WAMP_REG_LOOKUP} = M, Ctxt)  ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3) of
        {ok, [RealmUri, ProcUri]} ->
            lookup(RealmUri, ProcUri, #{});
        {ok, [RealmUri, ProcUri, Opts]} ->
            lookup(RealmUri, ProcUri, Opts);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), bondy_wamp_utils:maybe_error(R, M));

handle_call(#call{procedure_uri = ?WAMP_REG_MATCH} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3) of
        {ok, [RealmUri, ProcUri]} ->
            match(RealmUri, ProcUri, #{});
        {ok, [RealmUri, ProcUri, Opts]} ->
            match(RealmUri, ProcUri, Opts);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), bondy_wamp_utils:maybe_error(R, M));

handle_call(#call{procedure_uri = ?WAMP_REG_GET} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3) of
        {ok, [RealmUri, RegId]} ->
            get(RealmUri, RegId, #{});
        {ok, [RealmUri, RegId, Details]} ->
            get(RealmUri, RegId, Details);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), bondy_wamp_utils:maybe_error(R, M));


handle_call(#call{procedure_uri = ?WAMP_LIST_CALLEES} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [RealmUri, RegId]} ->
            list_registration_callees(RealmUri, RegId);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), bondy_wamp_utils:maybe_error(R, M));


handle_call(#call{procedure_uri = ?WAMP_COUNT_CALLEES} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [RealmUri, RegId]} ->
            count_callees(RealmUri, RegId);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), bondy_wamp_utils:maybe_error(R, M));

handle_call(#call{procedure_uri = ?BONDY_REG_LIST} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [RealmUri]} ->
            list(registration, RealmUri);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), bondy_wamp_utils:maybe_error(R, M));


handle_call(#call{procedure_uri = ?BONDY_CALLEE_LIST} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [RealmUri]} ->
            list_callees(RealmUri);
        {ok, [RealmUri, ProcedureUri]} ->
            list_callees(RealmUri, ProcedureUri);

        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), bondy_wamp_utils:maybe_error(R, M));

%% -----------------------------------------------------------------------------
%% WAMP SUBSCRIPTION META PROCEDURES
%% -----------------------------------------------------------------------------

%% -----------------------------------------------------------------------------
%% Handles the following META API wamp calls:
%%
%% * "wamp.subscription.list": Retrieves subscription IDs listed according to match policies.
%% * "wamp.subscription.lookup": Obtains the subscription (if any) managing a topic, according to some match policy.
%% * "wamp.subscription.match": Retrieves a list of IDs of subscriptions matching a topic URI, irrespective of match policy.
%% * "wamp.subscription.get": Retrieves information on a particular subscription.
%% * "wamp.subscription.list_subscribers": Retrieves a list of session IDs for sessions currently attached to the subscription.
%% * "wamp.subscription.count_subscribers": Obtains the number of sessions currently attached to the subscription.
%% @end
%% -----------------------------------------------------------------------------
handle_call(#call{procedure_uri = <<"bondy.subscription.list">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [RealmUri]} ->
            list(subscription, RealmUri);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), bondy_wamp_utils:maybe_error(R, M));

handle_call(#call{procedure_uri = <<"wamp.subscription.list">>} = M, Ctxt) ->
    %% Retrieves subscription IDs listed according to match policies.
    %% Res :=
    %%   {
    %%       "exact": subscription_ids|list,
    %%       "prefix": subscription_ids|list,
    %%       "wildcard": subscription_ids|list
    %%   }
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [RealmUri]} ->
            summary(subscription, RealmUri);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), bondy_wamp_utils:maybe_error(R, M));


handle_call(#call{procedure_uri = <<"wamp.subscription.lookup">>} = M, Ctxt) ->
    % #{<<"topic">> := TopicUri} = Args = M#call.arguments,
    % Opts = maps:get(<<"options">>, Args, #{}),
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), M);

handle_call(#call{procedure_uri = <<"wamp.subscription.match">>} = M, Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), M);

handle_call(#call{procedure_uri = <<"wamp.subscription.get">>} = M, Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), M);

handle_call(
    #call{procedure_uri = <<"wamp.subscription.list_subscribers">>} = M,
    Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), M);

handle_call(
    #call{procedure_uri = <<"wamp.subscription.count_subscribers">>} = M,
    Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), M);

handle_call(#call{} = M, Ctxt) ->
    Error = bondy_wamp_utils:no_such_procedure_error(M),
    bondy:send(bondy_context:peer_id(Ctxt), Error).



%% =============================================================================
%% PRIVATE
%% =============================================================================



list(Type, RealmUri) ->
    list(Type, RealmUri, fun bondy_registry_entry:to_map/1).


list(Type, RealmUri, Fun) ->
    try
        case bondy_registry:entries(Type, RealmUri, '_', '_') of
            [] ->
                {ok, []};
            Entries ->
                {ok, [Fun(E) || E <- Entries]}
        end
    catch
        ?EXCEPTION(_, Reason, Stacktrace) ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, ?STACKTRACE(Stacktrace)]
            ),
            {error, Reason}
    end.



summary(Type, RealmUri) ->
    Default = #{
        ?EXACT_MATCH => [],
        ?PREFIX_MATCH => [],
        ?WILDCARD_MATCH => []
    },
    try
        case bondy_registry:entries(Type, RealmUri, '_', '_') of
            [] ->
                {ok, Default};
            Entries ->
                Tuples = [
                    {
                        bondy_registry_entry:id(E),
                        bondy_registry_entry:match_policy(E)
                    } || E <- Entries
                ],
                Summary = leap_tuples:summarize(
                    Tuples, {2, {function, collect, [1]}}, #{}),
                Map = maps:merge(Default, maps:from_list(Summary)),
                {ok, Map}
        end
    catch
        ?EXCEPTION(_, Reason, Stacktrace) ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, ?STACKTRACE(Stacktrace)]
            ),
            {error, Reason}
    end.


%% @private
get(RealmUri, RegId, Details) ->
    try
        case bondy_registry:lookup(registration, RegId, RealmUri, Details) of
            {error, not_found} ->
                {error, bondy_wamp_utils:no_such_registration_error(RegId)};
            Entry ->
                {ok, bondy_registry_entry:to_details_map(Entry)}
        end
    catch
        ?EXCEPTION(_, Reason, Stacktrace) ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, ?STACKTRACE(Stacktrace)]
            ),
            {error, Reason}
    end.


%% @private
lookup(RealmUri, Uri, Opts) ->
    try
        case bondy_registry:match(registration, Uri, RealmUri, Opts) of
            {[], '$end_of_table'} ->
                ok;
            {Entries, '$end_of_table'} ->
                {ok, bondy_registry_entry:id(hd(Entries))}
        end
    catch
        ?EXCEPTION(_, Reason, Stacktrace) ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, ?STACKTRACE(Stacktrace)]
            ),
            {error, Reason}
    end.


%% @private
match(RealmUri, Uri, Opts) ->
    try
        case bondy_registry:match(registration, Uri, RealmUri, Opts) of
            {[], '$end_of_table'} ->
                ok;
            {Entries, '$end_of_table'} ->
                {ok, [bondy_registry_entry:id(E) || E <- Entries]}
        end
    catch
        ?EXCEPTION(_, Reason, Stacktrace) ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, ?STACKTRACE(Stacktrace)]
            ),
            {error, Reason}
    end.


%% @private
list_callees(RealmUri) ->
    try
        case bondy_dealer:callees(RealmUri) of
            [] ->
                {ok, []};
            Callees ->
                {ok, Callees}
        end
    catch
        ?EXCEPTION(_, Reason, Stacktrace) ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, ?STACKTRACE(Stacktrace)]
            ),
            {error, Reason}
    end.

list_callees(RealmUri, ProcedureUri) ->
    try
        case bondy_dealer:callees(RealmUri, ProcedureUri) of
            [] ->
                {ok, []};
            Callees ->
                {ok, Callees}
        end
    catch
        ?EXCEPTION(_, Reason, Stacktrace) ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, ?STACKTRACE(Stacktrace)]
            ),
            {error, Reason}
    end.


%% @private
list_registration_callees(_RealmUri, _RegId) ->
    %% try
    %%     case bondy_registry:entries(registration, RealmUri, '_', '_') of
    %%         {[], '$end_of_table'} ->
    %% {error, bondy_wamp_utils:no_such_registration_error(RegId)};
    %%         {[Entries], '$end_of_table'} ->
    %%             Sessions = [bondy_registry_entry:session_id(E) || E <- Entries],
    %%             {ok, Sessions}
    %%     end
    %% catch
    %%     _:Reason ->
    %%         {error, Reason}
    %% end.
    {error, not_implemented}.


count_callees(_RealmUri, _Uri) ->
    %% try
    %%     case bondy_registry:match(registration, Uri, RealmUri) of
    %%         {[], '$end_of_table'} ->
    %%             {ok, 0};
    %%         {[Entries], '$end_of_table'} ->
    %%             {ok, length(Entries)}
    %%     end
    %% catch
    %%     _:Reason ->
    %%         {error, Reason}
    %% end.
    {error, not_implemented}.