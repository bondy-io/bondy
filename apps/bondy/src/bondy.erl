%% =============================================================================
%%  bondy.erl -
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


%% =============================================================================
%% @doc
%%
%% @end
%% =============================================================================
-module(bondy).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(CALL_TIMEOUT, 20000).

-type wamp_error_map() :: #{
    error_uri => uri(),
    details => map(),
    arguments => list(),
    arguments_kw => map()
}.

-export_type([wamp_error_map/0]).


-export([call/5]).
-export([publish/5]).
-export([subscribe/4]).
-export([start/0]).



%% =============================================================================
%% API
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% Starts bondy
%% @end
%% -----------------------------------------------------------------------------
start() ->
    application:ensure_all_started(bondy).




%% =============================================================================
%% API - SESSION
%% =============================================================================




%% =============================================================================
%% API - SUBSCRIBER ROLE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Calls bondy_broker:subscribe/4.
%% @end
%% -----------------------------------------------------------------------------
subscribe(RealmUri, Opts, TopicUri, Fun) ->
    bondy_broker:subscribe(RealmUri, Opts, TopicUri, Fun).



%% =============================================================================
%% API - PUBLISHER ROLE
%% =============================================================================


publish(Opts, TopicUri, Args, ArgsKw, CtxtOrRealm) ->
    bondy_broker:publish(Opts, TopicUri, Args, ArgsKw, CtxtOrRealm).



%% =============================================================================
%% API - CALLER ROLE
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% A blocking call.
%% @end
%% -----------------------------------------------------------------------------
-spec call(
    binary(),
    map(),
    list() | undefined,
    map() | undefined,
    bondy_context:t()) ->
    {ok, map(), bondy_context:t()}
    | {error, wamp_error_map(), bondy_context:t()}.

call(ProcedureUri, Opts, Args, ArgsKw, Ctxt0) ->
    %% @TODO ID should be session scoped and not global
    %% TODO we need to fix the wamp.hrl timeout
    %% TODO also, according to WAMP the default is 0 which deactivates
    %% the Call Timeout Feature
    Timeout = case maps:get(timeout, Opts, ?CALL_TIMEOUT) of
        0 -> ?CALL_TIMEOUT;
        Val -> Val
    end,
    ReqId = bondy_utils:get_id(global),

    M = wamp_message:call(ReqId, Opts, ProcedureUri, Args, ArgsKw),

    case bondy_router:forward(M, Ctxt0) of
        {ok, Ctxt1} ->
            receive
                {?BONDY_PEER_REQUEST, Pid, Ref, #result{} = R} ->
                    ok = bondy_wamp_peer:ack(Pid, Ref),
                    {ok, message_to_map(R), Ctxt1};
                {?BONDY_PEER_REQUEST, Pid, Ref, #error{} = R} ->
                    ok = bondy_wamp_peer:ack(Pid, Ref),
                    {error, message_to_map(R), Ctxt1}
            after
                Timeout ->
                    Mssg = iolist_to_binary(
                        io_lib:format(
                            "The operation could not be completed in time "
                            " (~p milliseconds).",
                            [Timeout]
                        )
                    ),
                    Args = [Mssg],
                    ArgsKw = #{
                        procedure_uri => ProcedureUri,
                        timeout => Timeout
                    },
                    Error = wamp_message:error(
                        ?CALL, ReqId, #{}, ?BONDY_ERROR_TIMEOUT, Args, ArgsKw),
                    ok = bondy_event_manager:notify({wamp, Error, Ctxt1}),
                    {error, message_to_map(Error), Ctxt1}
            end;
        {reply, #error{} = Error, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            {error, message_to_map(Error), Ctxt1};
        {reply, _, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            Error = wamp_message:error(
                ?CALL, ReqId, #{}, ?BONDY_INCONSISTENCY_ERROR,
                [<<"Inconsistency error">>]
            ),
            ok = bondy_event_manager:notify({wamp, Error, Ctxt1}),
            {error, message_to_map(Error), Ctxt1};
        {stop, #error{} = Error, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            ok = bondy_event_manager:notify({wamp, Error, Ctxt1}),
            {error, message_to_map(Error), Ctxt1};
        {stop, _, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            Error = wamp_message:error(
                ?CALL, ReqId, #{}, ?BONDY_INCONSISTENCY_ERROR,
                [<<"Inconsistency error">>]
            ),
            ok = bondy_event_manager:notify({wamp, Error, Ctxt1}),
            {error, message_to_map(Error), Ctxt1}
    end.



%% =============================================================================
%% API - CALLEE ROLE
%% =============================================================================






%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
message_to_map(#result{} = M) ->
    #result{
        request_id = Id,
        details = Details,
        arguments = Args,
        arguments_kw = ArgsKw
    } = M,
    #{
        request_id => Id,
        details => Details,
        arguments => args(Args),
        arguments_kw => args_kw(ArgsKw)
    };

message_to_map(#error{} = M) ->
    #error{
        request_type = Type,
        request_id = Id,
        details = Details,
        error_uri = Uri,
        arguments = Args,
        arguments_kw = ArgsKw
    } = M,
    %% We need these keys to be binaries, becuase we will
    %% inject this in a mops context.
    #{
        request_type => Type,
        request_id => Id,
        details => Details,
        error_uri => Uri,
        arguments => args(Args),
        arguments_kw => args_kw(ArgsKw)
    }.


%% @private
args(undefined) -> [];
args(L) -> L.

%% @private
args_kw(undefined) -> #{};
args_kw(M) -> M.
