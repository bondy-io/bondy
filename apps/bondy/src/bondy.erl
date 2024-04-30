%% =============================================================================
%%  bondy.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-type send_opts()       ::  #{
                                from := bondy_ref:t(),
                                realm_uri := uri(),
                                via => optional(queue:queue())
                            }.

-type wamp_error_map() ::  #{
                                error_uri => uri(),
                                details => map(),
                                args => list(),
                                kwargs => map(),
                                payload => binary()
                            }.
-type metadata()        ::  #{
                                authrealm => uri(),
                                protocol_session_id => id(),
                                realm_uri => uri(),
                                session_id => bondy_session_id:t(),
                                authid => bondy_rbac_user:username(),
                                atom() => term()
                            }.

-export_type([wamp_error_map/0]).
-export_type([send_opts/0]).
-export_type([metadata/0]).


-export([aae_exchanges/0]).
-export([ack/2]).
-export([add_via/2]).
-export([call/5]).
-export([cast/5]).
-export([check_response/4]).
-export([get_process_metadata/0]).
-export([lrw_nodes/2]).
-export([peek_via/1]).
-export([prepare_send/2]).
-export([prepare_send/3]).
-export([request/3]).
-export([send/3]).
-export([send/4]).
-export([set_process_metadata/1]).
-export([set_process_metadata/2]).
-export([take_via/1]).
-export([unset_process_metadata/0]).
-export([update_process_metadata/2]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Returns the N top set of connected nodes sorted in increasing order of
%% their weight for a given key according to the Lowest Random Weight hashing
%% algorithm (a.k.a Rendezvous hashing).
%% @end
%% -----------------------------------------------------------------------------
-spec lrw_nodes(Key :: any(), N :: non_neg_integer()) -> [node()].

lrw_nodes(Key, N) ->
    lrw:top(Key, partisan:nodes(), N).


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
    {?BONDY_REQ, Pid, RealmUri, M}.


%% -----------------------------------------------------------------------------
%% @doc
%% Sends a message to a WAMP peer.
%% It calls `send/3' with a an empty map for Options.
%% @end
%% -----------------------------------------------------------------------------
-spec send(RealmUri :: uri(), bondy_ref:t(), wamp_message()) ->
    ok | no_return().

send(RealmUri, Ref, M) ->
    send(RealmUri, Ref, M, #{}).


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
-spec send(
    RealmUri :: uri(),
    Ref :: bondy_ref:t(),
    Msg :: wamp_message(),
    Opts :: send_opts()) ->
    ok | no_return().

send(RealmUri, To, Msg, Opts) ->
    %% We validate the message
    wamp_message:is_message(Msg)
        orelse error({invalid_wamp_message, Msg}),

    case bondy_ref:is_local(To) of
        true ->
            do_send(To, Msg, Opts#{realm_uri => RealmUri});

        false ->

            case peek_via(Opts) of
                Relay when Relay == undefined ->
                    %% Here we could validate if destination is a cluster peer
                    %% node, but that would penalise performance and also if we
                    %% are using Hyparview we only have a partial view of the
                    %% cluster. SO we trust the prepase_send or caller is doing
                    %% the correct thing.
                    Node = bondy_ref:node(To),
                    relay_message(RealmUri, Node, To, Msg, Opts);

                Relay ->
                    Type = bondy_ref:type(Relay),
                    IsLocalRelay = bondy_ref:is_local(Relay),

                    case {Type, IsLocalRelay} of
                        {bridge_relay, true} ->
                            %% We consume the relay from via stack
                            {Relay, Opts1} = take_via(Opts),
                            Opts2 = Opts1#{realm_uri => RealmUri},
                            RelayMsg = {forward, To, Msg, Opts2},
                            do_send(Relay, RelayMsg, Opts2);

                        {bridge_relay, false} ->
                            %% We cannot send directly to Bridge Relay
                            %% we need to go through a router relay, this
                            %% means we do not consume from via stack.
                            Node = bondy_ref:node(Relay),
                            relay_message(RealmUri, Node, To, Msg, Opts);

                        {_, _} ->
                            error({badarg, [{ref, To}, {via, Relay}]})
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
    Origin :: optional(bondy_ref:client() | bondy_ref:internal()),
    Opts :: map()) -> {bondy_ref:t(), map()}.

prepare_send(undefined, Ref, Opts) ->
    prepare_send(Ref, undefined, Opts);

prepare_send(Ref, undefined, Opts) ->
    %% We keep 'via' as it has the route back to the origin
    {Ref, Opts};

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



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec set_process_metadata(Meta :: metadata()) -> ok.

set_process_metadata(Meta) ->
    set_process_metadata(Meta, []).


%% -----------------------------------------------------------------------------
%% @doc Set metadata on the process dictionary.
%% If `LogKeys' is a list of keys found in `Meta' then Logger shall
%% automatically insert those keys and their values in all log events produced
%% on the current process.
%% Subsequent calls to this function overwrites previous data set. To update
%% existing data instead of overwriting it, see
%% {@link update_process_metadata/2}.
%% @end
%% -----------------------------------------------------------------------------
-spec set_process_metadata(Meta :: metadata(), LogKeys :: [atom()]) -> ok.

set_process_metadata(Meta0, LogKeys0) when is_map(Meta0), is_list(LogKeys0) ->
    {LogKeys, Meta} = case maps:take('$log_keys', Meta0) of
        {LogKeys1, Meta1} ->
            L = sets:to_list(
                sets:union(sets:from_list(LogKeys0), sets:from_list(LogKeys1))
            ),
            {L, Meta1};
        error ->
            {LogKeys0, Meta0}
    end,
    {Logger, Bondy} = maps_utils:split(LogKeys, Meta),
    _ = put(?BONDY_META_KEY, Bondy),
    ok = logger:update_process_metadata(Logger);

set_process_metadata(undefined, _LogKeys) ->
    ok;

set_process_metadata(Meta, LogKeys) ->
    erlang:error(badarg, [Meta, LogKeys]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update_process_metadata(Meta :: metadata(), LogKeys :: [atom()]) -> ok.

update_process_metadata(Meta0, LogKeys0)
when is_map(Meta0), is_list(LogKeys0) ->
    {LogKeys, Meta} = case maps:take('$log_keys', Meta0) of
        {LogKeys1, Meta1} ->
            L = sets:to_list(
                sets:union(sets:from_list(LogKeys0), sets:from_list(LogKeys1))
            ),
            {L, Meta1};
        error ->
            {LogKeys0, Meta0}
    end,
    {Logger, Bondy} = maps_utils:split(LogKeys, Meta),

    case get(?BONDY_META_KEY) of
        undefined ->
            put(?BONDY_META_KEY, Bondy);
        Bondy0 ->
            put(?BONDY_META_KEY, maps:merge(Bondy0, Bondy))
    end,

    case logger:get_process_metadata() of
        undefined ->
            logger:update_process_metadata(Logger);
        Logger0 ->
            logger:update_process_metadata(maps:merge(Logger0, Logger))
    end,
    ok;

update_process_metadata(Meta, LogKeys) ->
    erlang:error(badarg, [Meta, LogKeys]).


%% -----------------------------------------------------------------------------
%% @doc Retrieve data set with {@link set_process_metadata/1},
%% {@link set_process_metadata/2} or {@link update_process_metadata/2}.
%% @end
%% -----------------------------------------------------------------------------
-spec get_process_metadata() -> Meta :: metadata() | undefined.

get_process_metadata() ->
    Bondy = get(?BONDY_META_KEY),
    Logger = logger:get_process_metadata(),

    case {Bondy, Logger} of
        {undefined, undefined} ->
            undefined;
        {undefined, _} ->
            maps:put('$log_keys', maps:keys(Logger), Logger);
        {_, undefined} ->
            Bondy;
        {_, _} ->
            maps:put('$log_keys', maps:keys(Logger), maps:merge(Logger, Bondy))
    end.


%% -----------------------------------------------------------------------------
%% @doc Delete data set with {@link set_process_metadata/1},
%% {@link set_process_metadata/2} or {@link update_process_metadata/2}.
%% @end
%% -----------------------------------------------------------------------------
-spec unset_process_metadata() -> ok.

unset_process_metadata() ->
    _ = erase(?BONDY_META_KEY),
    ok = logger:unset_process_metadata().



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
    Pid ! {?BONDY_ACK, Ref},
    ok.


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
    Timeout = case maps_utils:get_any([<<"timeout">>, timeout], Opts, 0) of
        0 -> bondy_config:get(wamp_call_timeout);
        Val -> Val
    end,

    case cast(Uri, Opts, Args, KWArgs, Ctxt0) of
        {ok, ReqId} ->
            check_response(Uri, ReqId, Timeout, Ctxt0);
        {error, _} = Error ->
            Error
    end.


check_response(Uri, ReqId, Timeout, Ctxt) ->
    receive
        {?BONDY_REQ, _Pid, _RealmUri, #result{} = R}
        when R#result.request_id == ReqId ->
            %% ok = bondy:ack(Pid, Ref),
            {ok, message_to_map(R)};
        {?BONDY_REQ, _Pid, _RealmUri, #error{} = R}
        when R#error.request_id == ReqId ->
            %% ok = bondy:ack(Pid, Ref),
            {error, message_to_map(R)};
        Other ->
            {error, Other}
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
    ReqId = bondy_context:gen_message_id(Ctxt0, session),

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
relay_message(RealmUri, Node, To, Msg, Opts) ->
    From = maps:get(from, Opts, undefined),
    RelayMsg = {forward, To, Msg, Opts#{realm_uri => RealmUri}},

    RelayOpts =
        case bondy_config:get([bridge_relay, forward]) of
            #{ack := true} = RelayOpts0 ->
                RelayOpts0#{partition_key => erlang:phash2({From, To})};
            #{ack := false} = RelayOpts0 ->
                RelayOpts0
        end,

    bondy_relay:forward(Node, RelayMsg, RelayOpts).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
do_send(To, M, #{realm_uri := RealmUri} = Opts) ->
    Pid = bondy_ref:pid(To),

    case bondy_ref:is_self(To) of
        true ->
            Pid ! request(Pid, RealmUri, M),
            ok;
        false ->
            SessionKey = bondy_ref:session_id(To),

            case maybe_enqueue(SessionKey, M, Opts) of
                true ->
                    ok;
                false ->
                    %% bondy_dealer (using bondy_rpc_load_balancer) is already
                    %% checking if process is alive, so for RPC this is a
                    %% double check, not expensive but a waste anyway.
                    %% TODO Consider avoiding this check here.
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
    %% We need these keys to be binaries, because we will
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

