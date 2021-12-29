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
-export([add_via/2]).
-export([call/5]).
-export([cast/5]).
-export([check_response/4]).
-export([peek_via/1]).
-export([prepare_send/2]).
-export([prepare_send/3]).
-export([publish/5]).
-export([publish/6]).
-export([request/3]).
-export([send/2]).
-export([send/3]).
-export([subscribe/3]).
-export([subscribe/4]).
-export([take_via/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
aae_exchanges() ->
    partisan_plumtree_broadcast:exchanges().


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
-spec send(Ref :: bondy_ref:t(), Msg :: wamp_message(), Opts :: map()) ->
    ok | no_return().

send(To, Msg, Opts) ->
    %% We validate the message
    wamp_message:is_message(Msg)
        orelse error(invalid_wamp_message),

    case bondy_ref:is_local(To) of
        true ->
            do_send(To, Msg, Opts);

        false ->
            case peek_via(Opts) of
                Relay when Relay == undefined ->
                    error({badarg, [{ref, To}, {via, Relay}]});

                Relay ->
                    Type = bondy_ref:type(Relay),
                    IsLocalRelay = bondy_ref:is_local(Relay),

                    case {Type, IsLocalRelay} of
                        {bridge_relay, true} ->
                            %% We consume the relay from stack
                            {Relay, Opts1} = take_via(Opts),
                            do_send(Relay, {forward, To, Msg, Opts1}, Opts1);

                        {bridge_relay, false} ->
                            %% We cannot send directly, we need to go through
                            %% the cluster so we use a relay, this means we do
                            %% not consume from stack.
                            Node = bondy_ref:node(Relay),
                            PeerMsg = {forward, To, Msg, Opts},
                            bondy_peer_wamp_relay:forward(Node, PeerMsg);

                        {_, _} ->
                            error({badarg, [{via, Relay}]})
                    end
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec prepare_send(To :: bondy_ref:t(), Opts :: map()) ->
    {bondy_ref:t(), map()}.

prepare_send(Ref, #{via := undefined} = Opts) ->
    prepare_send(Ref, maps:without([via], Opts));

prepare_send(Ref, Opts) ->
    prepare_send(Ref, undefined, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec prepare_send(
    To :: bondy_ref:t(),
    Origin :: maybe(bondy_ref:client() | bondy_ref:internal()),
    Opts :: map()) -> {bondy_ref:t(), map()}.

prepare_send(undefined, Ref, Opts) ->
    prepare_send(Ref, undefined, Opts);

prepare_send(Ref, undefined, Opts) ->
    %% We keep 'via' as it has the route back to the origin
    {Ref, Opts};
    % case bondy_ref:is_local(Ref) of
    %     true ->
    %         %% We keep 'via' as it has the route back to the origin
    %         {Ref, Opts};
    %     false when is_map_key(via, Opts), map_get(via, Opts) =/= undefined ->
    %         {Ref, Opts};
    %     false ->
    %         %% Ref is located in another peer node,
    %         %% we need to use a relay
    %         RealmUri = bondy_ref:realm_uri(Ref),
    %         Relay = bondy_peer_wamp_relay:ref(RealmUri),
    %         {Ref, add_via(Relay, Opts)}
    %     end;

prepare_send(Ref, Origin, Opts) ->
    %% We do not check if ref is relay or bridge_relay here, that will happen
    %% in send/3
    {Origin, add_via(Ref, Opts)}.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
add_via(Relay, #{via := undefined} = Opts) ->
    add_via(Relay, Opts#{via => queue:new()});

add_via(Relay, #{via := Term} = Opts) when is_map(Opts) ->
    Q0 = case queue:is_queue(Term) of
        true ->
            Term;
        false ->
            queue:from_list([Term])
    end,

    Q1 = queue:in(Relay, Q0),
    Opts#{via => Q1};
    % case bondy_ref:is_local(Relay) of
    %     true ->
    %         bondy_ref:is_relay(Relay)
    %             orelse bondy_ref:is_bridge_relay(Relay)
    %             orelse error({badarg, Relay}),

    %         Q1 = queue:in(Relay, Q0),
    %         Opts#{via => Q1};

    %     false ->
    %         bondy_ref:is_bridge_relay(Relay)
    %             orelse error({badarg, Relay}),

    %         Q1 = queue:in(Relay, Q0),

    %         %% We need to route this through a peer relay
    %         RealmUri = bondy_ref:realm_uri(Relay),
    %         PeerRelay = bondy_peer_wamp_relay:ref(RealmUri),
    %         Q2 = queue:in(PeerRelay, Q1),

    %         Opts#{via => Q2}
    % end;

add_via(Relay, Opts) ->
    add_via(Relay, Opts#{via => queue:new()}).


%% -----------------------------------------------------------------------------
%% @doc Removes and returns the first relay reference of the 'via' option stack.
%% @end
%% -----------------------------------------------------------------------------
take_via(#{via := Term} = Opts) ->
    case queue:is_queue(Term) of
        true ->
            case queue:out_r(Term) of
                {empty, Q} ->
                    {undefined, Opts#{via => Q}};
                {{value, Relay}, Q} ->
                    {Relay, Opts#{via => Q}}
            end;
        false ->
            {Term, maps:without([via], Opts)}
    end;

take_via(Opts) ->
    {undefined, Opts}.


%% -----------------------------------------------------------------------------
%% @doc Returns the last relay reference of the 'via' option stack. This
%% reference represents the final relay the message will need to go through to
%% be send using {@link send/3}.
%% @end
%% -----------------------------------------------------------------------------
peek_via(#{via := undefined}) ->
    undefined;

peek_via(#{via := Term}) ->
    case queue:is_queue(Term) of
        true ->
            case queue:peek_r(Term) of
                empty ->
                    undefined;
                {value, Relay} ->
                    Relay
            end;
        false ->
            Term
    end;

peek_via(_) ->
    undefined.


%% =============================================================================
%% API - DEPRECATED
%% =============================================================================



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
    % case maps:get(enqueue, Opts, false),
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

