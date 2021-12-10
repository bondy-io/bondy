%% =============================================================================
%%  bondy.erl -
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
-module(bondy).
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-type wamp_error_map() :: #{
    error_uri => uri(),
    details => map(),
    args => list(),
    kwargs => map(),
    payload => binary()
}.

-export_type([wamp_error_map/0]).

-export([aae_exchanges/0]).
-export([ack/2]).
-export([call/5]).
-export([cast/5]).
-export([check_response/4]).
-export([publish/5]).
-export([publish/6]).
-export([send/2]).
-export([send/3]).
-export([send/4]).
-export([start/0]).
-export([subscribe/3]).
-export([subscribe/4]).
-export([request/3]).


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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
aae_exchanges() ->
    plumtree_broadcast:exchanges().


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec request(Pid :: pid(), RealmUri :: uri(), M :: wamp_message:t()) ->
    tuple().

request(Pid, RealmUri, M) ->
    {?BONDY_PEER_REQUEST, Pid, RealmUri, M}.


%% -----------------------------------------------------------------------------
%% @doc
%% Sends a message to a WAMP peer.
%% It calls `send/3' with a an empty map for Options.
%% @end
%% -----------------------------------------------------------------------------
-spec send(bondy_ref:t(), wamp_message()) -> ok.

send(Ref, M) ->
    send(Ref, M, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% Sends a message to a local WAMP peer.
%% If the transport is not open it fails with an exception.
%% This function is used by the router (dealer | broker) to send WAMP messages
%% to local peers.
%% Opts is a map with the following keys:
%%
%% * timeout - timeout in milliseconds (defaults to 10000)
%% * enqueue (boolean) - if the peer is not reachable and this value is true,
%% bondy will enqueue the message so that the peer can resume the session and
%% consume all enqueued messages.
%%
%% @end
%% -----------------------------------------------------------------------------
-spec send(To :: bondy_ref:t(), Msg :: wamp_message(), Opts :: map()) ->
    ok | no_return().

send(To, M, Opts0) ->
    bondy_ref:is_local(To)
        orelse error(not_my_node),

    wamp_message:is_message(M)
        orelse error(invalid_wamp_message),

    Opts = validate_send_opts(Opts0),

    do_send(To, M, Opts).


-spec send(
    From :: bondy_ref:t(),
    To :: bondy_ref:t(),
    Msg :: wamp_message(),
    Opts :: map()) -> ok | no_return().

send(From, To, M, Opts0) ->

    bondy_ref:is_local(From)
        orelse error(not_my_node),

    bondy_ref:realm_uri(From) =:= bondy_ref:realm_uri(To)
        orelse error(not_same_realm),

    %% We validate the message and the opts
    wamp_message:is_message(M)
        orelse error(invalid_wamp_message),

    Opts = validate_send_opts(Opts0),

    case bondy_ref:is_local(To) of
        true ->
            do_send(To, M, Opts);
        false ->
            bondy_peer_wamp_forwarder:forward(From, To, M, Opts)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Acknowledges the reception of a WAMP message. This function should be used by
%% the peer transport module to acknowledge the reception of a message sent with
%% {@link send/3}.
%% @end
%% -----------------------------------------------------------------------------
-spec ack(pid(), reference()) -> ok.

ack(Pid, _) when Pid =:= self()  ->
    %% We do not need to send an ack (implicit ack send case)
    ok;

ack(Pid, Ref) when is_pid(Pid), is_reference(Ref) ->
    Pid ! {?BONDY_PEER_ACK, Ref},
    ok.


%% =============================================================================
%% API - SESSION
%% =============================================================================




%% =============================================================================
%% API - SUBSCRIBER ROLE
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Calls bondy_broker:subscribe/3.
%% @end
%% -----------------------------------------------------------------------------
subscribe(RealmUri, Opts, TopicUri) ->
    bondy_broker:subscribe(RealmUri, Opts, TopicUri).


%% -----------------------------------------------------------------------------
%% @doc Calls bondy_broker:subscribe/4.
%% @end
%% -----------------------------------------------------------------------------
subscribe(RealmUri, Opts, TopicUri, Fun) ->
    bondy_broker:subscribe(RealmUri, Opts, TopicUri, Fun).



%% =============================================================================
%% API - PUBLISHER ROLE
%% =============================================================================



publish(Opts, TopicUri, Args, KWArgs, CtxtOrRealm) ->
    bondy_broker:publish(Opts, TopicUri, Args, KWArgs, CtxtOrRealm).


publish(ReqId, Opts, TopicUri, Args, KWArgs, CtxtOrRealm) ->
    bondy_broker:publish(ReqId, Opts, TopicUri, Args, KWArgs, CtxtOrRealm).


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
    {ok, map()} | {error, wamp_error_map()}.

call(Uri, Opts, Args, KWArgs, Ctxt0) ->
    Timeout = case maps:find(timeout, Opts) of
        {ok, 0} -> bondy_config:get(wamp_call_timeout);
        {ok, Val} -> Val;
        error -> bondy_config:get(wamp_call_timeout)
    end,

    case cast(Uri, Opts, Args, KWArgs, Ctxt0) of
        {ok, ReqId} ->
            check_response(Uri, ReqId, Timeout, Ctxt0);
        {error, _} = Error ->
            Error
    end.


check_response(Uri, ReqId, Timeout, Ctxt) ->
    receive
        {?BONDY_PEER_REQUEST, _Pid, _RealmUri, #result{} = R}
        when R#result.request_id == ReqId ->
            %% ok = bondy:ack(Pid, Ref),
            {ok, message_to_map(R)};
        {?BONDY_PEER_REQUEST, _Pid, _RealmUri, #error{} = R}
        when R#error.request_id == ReqId ->
            %% ok = bondy:ack(Pid, Ref),
            {error, message_to_map(R)}
    after
        Timeout ->
            Mssg = iolist_to_binary(
                io_lib:format(
                    "The operation could not be completed in time"
                    " (~p milliseconds).",
                    [Timeout]
                )
            ),
            ErrorDetails = maps:new(),
            ErrorArgs = [Mssg],
            ErrorKWArgs = #{
                procedure_uri => Uri,
                timeout => Timeout
            },
            Error = wamp_message:error(
                ?CALL,
                ReqId,
                ErrorDetails,
                ?BONDY_ERROR_TIMEOUT,
                ErrorArgs,
                ErrorKWArgs
            ),
            ok = bondy_event_manager:notify({wamp, Error, Ctxt}),
            {error, message_to_map(Error)}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% A non-blocking call.
%% @end
%% -----------------------------------------------------------------------------
-spec cast(
    binary(),
    map(),
    list() | undefined,
    map() | undefined,
    bondy_context:t()) ->
    ok | {error, wamp_error_map()}.

cast(ProcedureUri, Opts, Args, KWArgs, Ctxt0) ->
    %% @TODO ID should be session scoped and not global
    %% FIXME we need to fix the wamp.hrl timeout
    %% TODO also, according to WAMP the default is 0 which deactivates
    %% the Call Timeout Feature
    ReqId = bondy_context:get_id(Ctxt0, session),

    M = wamp_message:call(ReqId, Opts, ProcedureUri, Args, KWArgs),

    case bondy_router:forward(M, Ctxt0) of
        {ok, _} ->
            {ok, ReqId};

        {reply, #error{} = Error, _} ->
            %% A sync reply (should not ever happen with calls)
            {error, message_to_map(Error)};

        {reply, _, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            Error = wamp_message:error(
                ?CALL, ReqId, #{}, ?BONDY_ERROR_INCONSISTENCY_ERROR,
                [<<"Inconsistency error">>]
            ),
            ok = bondy_event_manager:notify({wamp, Error, Ctxt1}),
            {error, message_to_map(Error)};

        {stop, #error{} = Error, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            ok = bondy_event_manager:notify({wamp, Error, Ctxt1}),
            {error, message_to_map(Error)};

        {stop, _, Ctxt1} ->
            %% A sync reply (should not ever happen with calls)
            Error = wamp_message:error(
                ?CALL, ReqId, #{}, ?BONDY_ERROR_INCONSISTENCY_ERROR,
                [<<"Inconsistency error">>]
            ),
            ok = bondy_event_manager:notify({wamp, Error, Ctxt1}),
            {error, message_to_map(Error)}
    end.



%% =============================================================================
%% API - CALLEE ROLE
%% =============================================================================





%% =============================================================================
%% PRIVATE
%% =============================================================================



validate_send_opts(Opts) ->
    maps_utils:validate(Opts, #{
        timeout => #{
            required => true,
            datatype => timeout,
            default => ?SEND_TIMEOUT
        },
        enqueue => #{
            required => true,
            datatype => boolean,
            default => false
        }
    }).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
do_send(To, M, Opts) ->
    RealmUri = bondy_ref:realm_uri(To),
    Pid = bondy_ref:pid(To),

    case bondy_ref:is_self(To) of
        true ->
            Pid ! request(Pid, RealmUri, M),
            ok;
        false ->
            SessionId = bondy_ref:session_id(To),

            case maybe_enqueue(SessionId, M, Opts) of
                true ->
                    ok;
                false ->
                    case erlang:is_process_alive(Pid) of
                        true ->
                            Pid ! request(self(), RealmUri, M),
                            ok;
                        false ->
                            ?LOG_DEBUG(#{
                                description => "Cannot deliver message",
                                reason => noproc,
                                message_type => element(1, M)
                            }),
                            ok
                    end
            end
    end.


%% @private
maybe_enqueue(undefined, _, _) ->
    false;

maybe_enqueue(_SessionId, _M, _Opts) ->
    % case maps:get(enqueue, Opts),
    %     true ->
    %         %% TODO Enqueue events only for session resumption
    %         true;
    %     false ->
    %         false
    % end.

    false.


%% @private
message_to_map(#result{} = M) ->
    #result{
        request_id = Id,
        details = Details,
        args = Args,
        kwargs = KWArgs
    } = M,
    #{
        request_id => Id,
        details => Details,
        args => args(Args),
        kwargs => kwargs(KWArgs)
    };

message_to_map(#error{} = M) ->
    #error{
        request_type = Type,
        request_id = Id,
        details = Details,
        error_uri = Uri,
        args = Args,
        kwargs = KWArgs
    } = M,
    %% We need these keys to be binaries, becuase we will
    %% inject this in a mops context.
    #{
        request_type => Type,
        request_id => Id,
        details => Details,
        error_uri => Uri,
        args => args(Args),
        kwargs => kwargs(KWArgs)
    }.


%% @private
args(undefined) -> [];
args(L) -> L.

%% @private
kwargs(undefined) -> #{};
kwargs(M) -> M.
