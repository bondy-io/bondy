%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% A JSON or CBOR message decoded off the wire keeps its payload encoded in
%% `partial` until something decodes it. Routing to an external peer forwards it
%% that way; wherever Bondy itself consumes the message, it must see the decoded
%% payload. Each case sends the message as the wire decodes it, over JSON and
%% CBOR, to one place where Bondy is the consumer.
-module(bondy_internal_decode_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").
-include("bondy_security.hrl").

-compile([export_all, nowarn_export_all]).

-define(ENCODINGS, [json, cbor]).
-define(ARGS, [<<"x">>]).
-define(KWARGS, #{<<"k">> => 1}).

all() ->
    [
        callback_args_survive_cluster_forward,
        callback_procedure_refuses_payload_passthru,
        router_error_to_payload_passthru_call,
        callback_subscriber_receives_payload,
        fun_subscriber_receives_payload,
        http_gateway_survives_encoded_event
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Realm = bondy_realm:create(<<"internal.decode.test">>),
    RealmUri = bondy_realm:uri(Realm),
    ok = bondy_realm:disable_security(Realm),
    Secure = bondy_realm:create(<<"internal.decode.secure">>),
    ok = bondy_realm:enable_security(Secure),
    [
        {realm_uri, RealmUri},
        {secure_realm_uri, bondy_realm:uri(Secure)}
        | Config
    ].

end_per_suite(Config) ->
    Config.

%% =============================================================================
%% TESTS
%% =============================================================================

%% A CALL bound to a remote callback entry carries the entry's static arguments
%% ahead of the caller's, and the receiving node's decode keeps both.
callback_args_survive_cluster_forward(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Uri = <<"com.example.internal.decode.callback">>,
    Ref = bondy_ref:new(internal, {?MODULE, on_call}),
    Entry = bondy_registry_entry:new(
        registration, RealmUri, Ref, Uri, #{callback_args => [cfg]}
    ),
    lists:foreach(
        fun(Enc) ->
            Call = off_the_wire(
                Enc, bondy_wamp_message:call(1, #{}, Uri, ?ARGS, ?KWARGS)
            ),
            Sent = bondy_dealer:with_callback_args(Call, Entry),
            Received = bondy_wamp_message:decode_partial(Sent),
            ?assertEqual([cfg | ?ARGS], Received#call.args),
            ?assertEqual(?KWARGS, Received#call.kwargs)
        end,
        ?ENCODINGS
    ).

%% A procedure Bondy implements as a callback cannot read a Payload Passthru
%% payload, so the caller gets an `invalid_argument` ERROR, not a crash.
callback_procedure_refuses_payload_passthru(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Uri = <<"com.example.internal.decode.ppt_callback">>,
    Ref = bondy_ref:new(internal, {?MODULE, on_call}),
    {ok, _} = bondy_dealer:register(
        Uri, #{callback_args => [cfg]}, RealmUri, Ref
    ),
    Call = bondy_wamp_message:call(
        7, #{ppt_scheme => <<"x_custom">>}, Uri, [<<"opaque">>]
    ),
    Error =
        case bondy_router:forward(Call, session_context(RealmUri)) of
            {reply, #error{} = E, _} ->
                E;
            {ok, _} ->
                receive
                    {?BONDY_REQ, _, _, #error{request_id = 7} = E} -> E
                after 5000 -> ct:fail(no_reply)
                end
        end,
    ?assertEqual(?WAMP_INVALID_ARGUMENT, Error#error.error_uri).

%% An ERROR the router itself raises for a Payload Passthru CALL, here an RBAC
%% refusal in a realm with security on, reaches the caller instead of crashing
%% the forward.
router_error_to_payload_passthru_call(Config) ->
    RealmUri = ?config(secure_realm_uri, Config),
    Call = bondy_wamp_message:call(
        8,
        #{ppt_scheme => <<"x_custom">>},
        <<"com.example.internal.decode.denied">>,
        [<<"opaque">>]
    ),
    Error =
        case bondy_router:forward(Call, session_context(RealmUri)) of
            {reply, #error{} = E, _} ->
                E;
            {ok, _} ->
                receive
                    {?BONDY_REQ, _, _, #error{request_id = 8} = E} -> E
                after 5000 -> ct:fail(no_reply)
                end
        end,
    ?assertEqual(?WAMP_NOT_AUTHORIZED, Error#error.error_uri).

%% A callback subscriber is applied with the published payload.
callback_subscriber_receives_payload(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Topic = <<"com.example.internal.decode.callback_sub">>,
    Ref = bondy_ref:new(internal, {?MODULE, on_event}),
    {ok, _} = bondy_broker:subscribe(
        RealmUri, #{callback_args => [self()]}, Topic, Ref
    ),
    lists:foreach(
        fun(Enc) ->
            ok = publish_off_the_wire(RealmUri, Enc, Topic),
            receive
                {callback_event, Args, KWArgs} ->
                    ?assertEqual(?ARGS, Args),
                    ?assertEqual(?KWARGS, KWArgs)
            after 5000 ->
                ct:fail({no_callback_event, Enc})
            end
        end,
        ?ENCODINGS
    ).

%% A fun subscriber (`bondy_subscriber`) receives the event decoded.
fun_subscriber_receives_payload(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Topic = <<"com.example.internal.decode.fun_sub">>,
    Self = self(),
    Fun = fun(_, Event) ->
        Self ! {fun_event, Event},
        ok
    end,
    {ok, {_, _}} = bondy_broker:subscribe(RealmUri, #{}, Topic, Fun),
    lists:foreach(
        fun(Enc) ->
            ok = publish_off_the_wire(RealmUri, Enc, Topic),
            receive
                {fun_event, #event{} = Event} ->
                    ?assertEqual(?ARGS, Event#event.args),
                    ?assertEqual(?KWARGS, Event#event.kwargs),
                    ?assertEqual(undefined, bondy_wamp_message:partial(Event))
            after 5000 ->
                ct:fail({no_fun_event, Enc})
            end
        end,
        ?ENCODINGS
    ).

%% The HTTP gateway reads the payload of the master realm's events it
%% subscribes to; an encoded one must not crash it.
http_gateway_survives_encoded_event(_) ->
    Pid = whereis(bondy_http_gateway),
    ?assert(is_pid(Pid)),
    lists:foreach(
        fun(Enc) ->
            Publish = off_the_wire(
                Enc,
                bondy_wamp_message:publish(
                    1, #{}, ?BONDY_REALM_DELETED, [<<"no.such.realm">>]
                )
            ),
            ok = bondy_broker:forward(
                Publish, publisher_context(?MASTER_REALM_URI)
            ),
            _ = sys:get_state(Pid),
            ?assertEqual(Pid, whereis(bondy_http_gateway))
        end,
        ?ENCODINGS
    ).

%% =============================================================================
%% CALLBACKS
%% =============================================================================

on_call(_Cfg, _Arg, _KWArgs, _Details) ->
    {ok, #{}, [], #{}}.

on_event(Pid, Arg, KWArgs, _Details) ->
    Pid ! {callback_event, [Arg], KWArgs},
    ok.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
publish_off_the_wire(RealmUri, Enc, Topic) ->
    Publish = off_the_wire(
        Enc, bondy_wamp_message:publish(1, #{}, Topic, ?ARGS, ?KWARGS)
    ),
    bondy_broker:forward(Publish, publisher_context(RealmUri)).

%% @private
%% A context carrying a real session owned by the calling process, as the
%% dealer's CALL path requires.
session_context(RealmUri) ->
    Opts = #{
        peer => {{127, 0, 0, 1}, 10000},
        authid => <<"anonymous">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}, subscriber => #{}}
    },
    {ok, Session} = bondy_session_manager:open(
        bondy_session_id:new(), RealmUri, Opts
    ),
    bondy_context:new(
        {{127, 0, 0, 1}, 10000}, {ws, binary, cbor}, #{session => Session}
    ).

%% @private
publisher_context(RealmUri) ->
    bondy_context:local_context(RealmUri, bondy_ref:new(internal, self())).

%% @private
%% `M` encoded, then decoded with partial decoding on, as the WebSocket path
%% hands it on.
off_the_wire(Enc, M) ->
    Bin = iolist_to_binary(bondy_wamp_encoding:encode(M, Enc)),
    {[Decoded], <<>>} = bondy_wamp_encoding:decode(subprotocol(Enc), Bin),
    ?assertMatch({Enc, _}, bondy_wamp_message:partial(Decoded)),
    Decoded.

%% @private
subprotocol(json) -> {ws, text, json};
subprotocol(cbor) -> {ws, binary, cbor}.
