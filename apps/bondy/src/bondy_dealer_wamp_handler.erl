%% =============================================================================
%%  bondy_dealer_wamp_handler.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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


-module(bondy_dealer_wamp_handler).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(BONDY_REG_LIST, <<"com.leapsight.bondy.registration.list">>).
-define(BONDY_CALLEE_LIST, <<"com.leapsight.bondy.callee.list">>).
-define(BONDY_CALLEE_GET, <<"com.leapsight.bondy.callee.get">>).
-define(REG_LIST, <<"wamp.registration.list">>).
-define(REG_LOOKUP, <<"wamp.registration.lookup">>).
-define(REG_MATCH, <<"wamp.registration.match">>).
-define(REG_GET, <<"wamp.registration.get">>).
-define(LIST_CALLEES, <<"wamp.registration.list_callees">>).
-define(COUNT_CALLEES, <<"wamp.registration.count_callees">>).

-export([handle_call/2]).



%% =============================================================================
%% API
%% =============================================================================



-spec handle_call(M :: wamp_message(), Ctxt :: map()) -> ok | no_return().

%% -----------------------------------------------------------------------------
%% BONDY API GATEWAY META PROCEDURES
%% -----------------------------------------------------------------------------
handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.api_gateway.", _/binary>>} = M,
    Ctxt) ->
    bondy_api_gateway_wamp_handler:handle_call(M, Ctxt);

%% -----------------------------------------------------------------------------
%% BONDY SECURITY META PROCEDURES
%% -----------------------------------------------------------------------------
handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.security.", _/binary>>} = M,
    Ctxt) ->
    bondy_security_wamp_handler:handle_call(M, Ctxt);

%% -----------------------------------------------------------------------------
%% BONDY OAUTH2 META PROCEDURES
%% -----------------------------------------------------------------------------
handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.oauth2.", _/binary>>} = M,
    Ctxt) ->
    bondy_oauth2_wamp_handler:handle_call(M, Ctxt);

%% -----------------------------------------------------------------------------
%% BONDY BACKUP META PROCEDURES
%% -----------------------------------------------------------------------------
handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.backup.", _/binary>>} = M,
    Ctxt) ->
    bondy_backup_wamp_handler:handle_call(M, Ctxt);

%% -----------------------------------------------------------------------------
%% WAMP META PROCEDURES
%% -----------------------------------------------------------------------------
handle_call(#call{procedure_uri = ?REG_LIST} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [RealmUri]} ->
            summary(RealmUri);
        {error, WampError} ->
            WampError
    end,
    bondy_wamp_peer:send(
        bondy_context:peer(Ctxt), bondy_wamp_utils:maybe_error(R, M));


handle_call(#call{procedure_uri = ?REG_LOOKUP} = M, Ctxt)  ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3) of
        {ok, [RealmUri, ProcUri]} ->
            lookup(RealmUri, ProcUri, #{});
        {ok, [RealmUri, ProcUri, Opts]} ->
            lookup(RealmUri, ProcUri, Opts);
        {error, WampError} ->
            WampError
    end,
    bondy_wamp_peer:send(
        bondy_context:peer(Ctxt), bondy_wamp_utils:maybe_error(R, M));

handle_call(#call{procedure_uri = ?REG_MATCH} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3) of
        {ok, [RealmUri, ProcUri]} ->
            match(RealmUri, ProcUri, #{});
        {ok, [RealmUri, ProcUri, Opts]} ->
            match(RealmUri, ProcUri, Opts);
        {error, WampError} ->
            WampError
    end,
    bondy_wamp_peer:send(
        bondy_context:peer(Ctxt), bondy_wamp_utils:maybe_error(R, M));

handle_call(#call{procedure_uri = ?REG_GET} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2, 3) of
        {ok, [RealmUri, RegId]} ->
            get(RealmUri, RegId, #{});
        {ok, [RealmUri, RegId, Details]} ->
            get(RealmUri, RegId, Details);
        {error, WampError} ->
            WampError
    end,
    bondy_wamp_peer:send(
        bondy_context:peer(Ctxt), bondy_wamp_utils:maybe_error(R, M));


handle_call(#call{procedure_uri = ?LIST_CALLEES} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [RealmUri, RegId]} ->
            list_registration_callees(RealmUri, RegId);
        {error, WampError} ->
            WampError
    end,
    bondy_wamp_peer:send(
        bondy_context:peer(Ctxt), bondy_wamp_utils:maybe_error(R, M));


handle_call(#call{procedure_uri = ?COUNT_CALLEES} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [RealmUri, RegId]} ->
            count_callees(RealmUri, RegId);
        {error, WampError} ->
            WampError
    end,
    bondy_wamp_peer:send(
        bondy_context:peer(Ctxt), bondy_wamp_utils:maybe_error(R, M));

handle_call(#call{procedure_uri = ?BONDY_REG_LIST} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [RealmUri]} ->
            list(RealmUri);
        {error, WampError} ->
            WampError
    end,
    bondy_wamp_peer:send(
        bondy_context:peer(Ctxt), bondy_wamp_utils:maybe_error(R, M));


handle_call(#call{procedure_uri = ?BONDY_CALLEE_LIST} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [RealmUri]} ->
            list_callees(RealmUri);
        {ok, [RealmUri, ProcedureUri]} ->
            list_callees(RealmUri, ProcedureUri);

        {error, WampError} ->
            WampError
    end,
    bondy_wamp_peer:send(
        bondy_context:peer(Ctxt), bondy_wamp_utils:maybe_error(R, M));

handle_call(#call{} = M, Ctxt) ->
    Error = bondy_wamp_utils:no_such_procedure_error(M),
    bondy_wamp_peer:send(bondy_context:peer(Ctxt), Error).



%% =============================================================================
%% PRIVATE
%% =============================================================================



list(RealmUri) ->
    list(RealmUri, fun bondy_registry_entry:to_map/1).

list(RealmUri, Fun) ->
    Default = #{
        ?EXACT_MATCH => [],
        ?PREFIX_MATCH => [],
        ?WILDCARD_MATCH => []
    },
    try
        case bondy_registry:entries(registration, RealmUri, '_', '_') of
            [] ->
                {ok, Default};
            Entries ->
                {ok, [Fun(E) || E <- Entries]}
        end
    catch
        _:Reason ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, erlang:get_stacktrace()]
            ),
            {error, Reason}
    end.



summary(RealmUri) ->
    Default = #{
        ?EXACT_MATCH => [],
        ?PREFIX_MATCH => [],
        ?WILDCARD_MATCH => []
    },
    try
        case bondy_registry:entries(registration, RealmUri, '_', '_') of
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
        _:Reason ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, erlang:get_stacktrace()]
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
        _:Reason ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, erlang:get_stacktrace()]
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
        _:Reason ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, erlang:get_stacktrace()]
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
        _:Reason ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, erlang:get_stacktrace()]
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
        _:Reason ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, erlang:get_stacktrace()]
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
        _:Reason ->
            _ = lager:error(
                "Error; reason=~p, trace=~p",
                [Reason, erlang:get_stacktrace()]
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