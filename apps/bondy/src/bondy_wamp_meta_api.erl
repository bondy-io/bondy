%% =============================================================================
%%  bondy_wamp_meta_api.erl -
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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_wamp_meta_api).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy_uris.hrl").



-export([handle_call/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_call(M :: wamp_message:call(), Ctxt :: bony_context:t()) ->
    ok
    | continue
    | {continue, uri()}
    | {reply, wamp_messsage:result() | wamp_message:error()}.


handle_call(#call{procedure_uri = ?WAMP_SESSION_GET} = M, Ctxt) ->

% To use as {lookup, redirect_uri(?WAMP_SESSION_GET, SessionId)};
% redirect_uri(<<"wamp.session.", Rest/binary>>, Id) when is_integer(Id) ->
%     <<"wamp.session.", (integer_to_binary(Id))/binary, $., Rest>>.

    [RealmUri, SessionId] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),

    %% TODO to be replaced by
    %% {lookup, <<"wamp.session.", (integer_to_binary(Id))/binary, ".get">>};
    %%
    %%

    case bondy_session:lookup(RealmUri, SessionId) of
        {error, not_found} ->
            E = bondy_wamp_utils:no_such_session_error(SessionId),
            {reply, E};
        Session ->
            R = wamp_message:result(
                M#call.request_id,
                #{},
                [bondy_session:info(Session)]
            ),
            {reply, R}
    end;


%% -----------------------------------------------------------------------------
%% WAMP REGISTRATION META PROCEDURES
%% -----------------------------------------------------------------------------
handle_call(#call{procedure_uri = ?WAMP_REG_LIST} = M, Ctxt) ->
    [RealmUri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),
    case summary(registration, RealmUri) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(#call{procedure_uri = ?WAMP_REG_LOOKUP} = M, Ctxt)  ->
    %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Opts]
    L = bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3),

    case lookup(registration, L) of
        ok ->
            R = wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(#call{procedure_uri = ?WAMP_REG_MATCH} = M, Ctxt) ->
    %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Opts]
    L = bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3),

    case match(registration, L) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(#call{procedure_uri = ?WAMP_REG_GET} = M, Ctxt) ->
    %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Details]
    L = bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3),

    case get(registration, L) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;


handle_call(#call{procedure_uri = ?WAMP_LIST_CALLEES} = M, Ctxt) ->
    [RealmUri, RegId] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    case list_registration_callees(RealmUri, RegId) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;


handle_call(#call{procedure_uri = ?WAMP_COUNT_CALLEES} = M, Ctxt) ->
    [RealmUri, RegId] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    case count_callees(RealmUri, RegId) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;


handle_call(#call{procedure_uri = ?BONDY_REGISTRY_LIST} = M, Ctxt) ->
    [RealmUri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),
    case list(registration, RealmUri) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;


handle_call(#call{procedure_uri = ?BONDY_WAMP_CALLEE_LIST} = M, Ctxt) ->
        %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Details]
    L = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),

    case list_callees(L) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

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

handle_call(#call{procedure_uri = ?WAMP_SUBSCRIPTION_LIST} = M, Ctxt) ->
    [RealmUri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),
    case summary(subscription, RealmUri) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(#call{procedure_uri = ?BONDY_SUBSCRIPTION_LIST} = M, Ctxt) ->
    [RealmUri] = bondy_wamp_utils:validate_call_args(M, Ctxt, 1),
    case list(subscription, RealmUri) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(#call{procedure_uri = ?WAMP_SUBSCRIPTION_LOOKUP} = M, Ctxt) ->
    %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Opts]
    L0 = bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3),
    L = [subscription] ++ L0,
    case lookup(subscription, L) of
        ok ->
            R = wamp_message:result(M#call.request_id, #{}),
            {reply, R};
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;


handle_call(#call{procedure_uri = ?WAMP_SUBSCRIPTION_MATCH} = M, Ctxt) ->
    %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Opts]
    L = bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3),

    case match(subscription, L) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;


handle_call(#call{procedure_uri = ?WAMP_SUBSCRIPTION_GET} = M, Ctxt) ->
    %% L can be [RealmUri, ProcUri] or [RealmUri, ProcUri, Details]
    L = bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3),

    case get(subscription, L) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;


handle_call(
    #call{procedure_uri = ?WAMP_SUBSCRIPTION_LIST_SUBSCRIBERS} = M, Ctxt) ->
    [RealmUri, RegId] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    case list_subscription_subscribers(RealmUri, RegId) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(
    #call{procedure_uri = ?WAMP_SUBSCRIPTION_COUNT_SUBSCRIBERS} = M, Ctxt) ->
    [RealmUri, RegId] = bondy_wamp_utils:validate_call_args(M, Ctxt, 2),
    case count_subscribers(RealmUri, RegId) of
        {ok, Result} ->
            R = wamp_message:result(M#call.request_id, #{}, [Result]),
            {reply, R};
        {error, Reason} ->
            E = bondy_wamp_utils:error(Reason, M),
            {reply, E}
    end;

handle_call(#call{} = M, _) ->
    E = bondy_wamp_utils:no_such_procedure_error(M),
    {reply, E}.



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
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Retrieves subscription IDs listed according to match policies.
%% Res :=
%%   {
%%       "exact": subscription_ids|list,
%%       "prefix": subscription_ids|list,
%%       "wildcard": subscription_ids|list
%%   }
%% @end
%% -----------------------------------------------------------------------------
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
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.


%% @private
get(Type, [_, _] = L) ->
    get(Type, L ++ [#{}]);

get(Type, [RealmUri, RegId, Details]) ->
    try
        case bondy_registry:lookup(Type, RegId, RealmUri, Details) of
            {error, not_found} ->
                {error, bondy_wamp_utils:no_such_registration_error(RegId)};
            Entry ->
                {ok, bondy_registry_entry:to_details_map(Entry)}
        end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.


%% @private
lookup(Type, [_, _] = L) ->
    lookup(Type, L ++ [#{}]);

lookup(Type, [RealmUri, Uri, Opts]) ->
    try
        case bondy_registry:match(Type, Uri, RealmUri, Opts) of
            {[], '$end_of_table'} ->
                ok;
            {Entries, '$end_of_table'} ->
                {ok, bondy_registry_entry:id(hd(Entries))}
        end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.


%% @private
match(Type, [_, _] = L) ->
    match(Type, L ++ [#{}]);

match(Type, [RealmUri, Uri, Opts]) ->
    try
        case bondy_registry:match(Type, Uri, RealmUri, Opts) of
            {[], '$end_of_table'} ->
                {ok, []};
            {Entries, '$end_of_table'} ->
                {ok, [bondy_registry_entry:id(E) || E <- Entries]}
        end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.


%% @private
list_callees([RealmUri]) ->
    try
        case bondy_dealer:callees(RealmUri) of
            [] ->
                {ok, []};
            Callees ->
                {ok, Callees}
        end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end;

list_callees([RealmUri, ProcedureUri]) ->
    try
        case bondy_dealer:callees(RealmUri, ProcedureUri) of
            [] ->
                {ok, []};
            Callees ->
                {ok, Callees}
        end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
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


list_subscription_subscribers(_RealmUri, _RegId) ->
    {error, not_implemented}.


count_subscribers(_RealmUri, _RegId) ->
    {error, not_implemented}.


