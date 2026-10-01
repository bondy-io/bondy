%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_session_get_routing_SUITE).
-moduledoc """
Tests the `wamp.session.get` routing rework: instead of one exact per-session
registration (`wamp.session.{ExtId}.get`), each node registers a single wildcard
`wamp.session.{NodeHash}..get` per realm and routes by the self-locating session
id (`{NodeHash}.{Rest}`). Covers: the wildcard is registered once per realm (not
per session), it matches the rewritten routing URI, and the callback resolves the
session realm-scoped.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

%% =============================================================================
%% CT CALLBACKS
%% =============================================================================

all() ->
    [
        wildcard_registered_once,
        wildcard_matches_routing_uri,
        callback_returns_session,
        callback_realm_isolation,
        callback_unknown_guid,
        callback_non_binary_guid,
        meta_api_decodes_partial_payload,
        meta_api_forwards_only_the_guid,
        internal_api_refuses_payload_passthru
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Realm = bondy_realm:create(<<"session.get.routing.test">>),
    RealmUri = bondy_realm:uri(Realm),
    ok = bondy_realm:disable_security(Realm),
    [{realm_uri, RealmUri} | Config].

end_per_suite(Config) ->
    Config.

%% =============================================================================
%% TESTS
%% =============================================================================

wildcard_registered_once(Config) ->
    RealmUri = ?config(realm_uri, Config),

    %% Several opens in the same realm.
    GuidA = open_session(RealmUri),
    GuidB = open_session(RealmUri),
    _ = open_session(RealmUri),

    %% Each session's routing URI must resolve to the SAME single registration —
    %% one shared per-node wildcard, not one exact entry per session.
    [EntryA] = match_routing(RealmUri, GuidA),
    [EntryB] = match_routing(RealmUri, GuidB),
    ?assertEqual(
        bondy_registry_entry:id(EntryA),
        bondy_registry_entry:id(EntryB)
    ),
    ok.

wildcard_matches_routing_uri(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Guid = open_session(RealmUri),

    %% The rewritten routing URI (what the meta API builds) is matched by the
    %% per-node wildcard — this is the routing guarantee.
    ?assertMatch([_], match_routing(RealmUri, Guid)),
    ok.

callback_returns_session(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Guid = open_session(RealmUri),

    %% The dealer applies the callback as get(RealmUri, Guid, Options).
    Result = bondy_session_api:get(RealmUri, Guid, #{}),
    ?assertMatch({ok, _, [_], _}, Result),
    {ok, _, [Ext], _} = Result,
    ?assert(is_map(Ext)),
    ok.

callback_realm_isolation(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Guid = open_session(RealmUri),

    %% Same guid, different realm: the lookup is realm-scoped, so a caller in
    %% another realm co-located on this node cannot read the session.
    Result = bondy_session_api:get(<<"other.realm.not.owning">>, Guid, #{}),
    ?assertMatch({error, ?WAMP_NO_SUCH_SESSION, _, _, _}, Result),
    ok.

callback_unknown_guid(Config) ->
    RealmUri = ?config(realm_uri, Config),

    %% Well-formed but never-opened guid.
    Guid = bondy_session_id:new(),
    Result = bondy_session_api:get(RealmUri, Guid, #{}),
    ?assertMatch({error, ?WAMP_NO_SUCH_SESSION, _, _, _}, Result),
    ok.

callback_non_binary_guid(Config) ->
    RealmUri = ?config(realm_uri, Config),

    %% A non-binary identifier (e.g. a legacy integer external id) must be
    %% rejected cleanly rather than crash the callback.
    Result = bondy_session_api:get(RealmUri, 123456789, #{}),
    ?assertMatch({error, ?WAMP_NO_SUCH_SESSION, _, _, _}, Result),
    ok.

%% A CALL decoded off the wire (JSON or CBOR) reaches the meta API with its
%% arguments still encoded in `partial` and `args = undefined`. The meta API
%% must decode them before validating arity, or every `wamp.session.get` from
%% a JSON or CBOR client is refused with `invalid_argument`.
meta_api_decodes_partial_payload(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Guid = open_session(RealmUri),
    Ctxt = bondy_context:local_context(RealmUri),
    Uri = routing_uri(Guid),
    lists:foreach(
        fun(Enc) ->
            Call = off_the_wire(Enc, [Guid]),
            ?assertEqual(undefined, Call#call.args),
            ?assertMatch({Enc, _}, bondy_wamp_message:partial(Call)),
            ?assertMatch(
                {continue, #call{procedure_uri = Uri}, _},
                bondy_wamp_meta_api:handle_call(Call, Ctxt)
            )
        end,
        [json, cbor]
    ).

%% The routing callback is registered with `callback_args => [RealmUri]` and
%% takes `(RealmUri, Guid)`, so the rewritten CALL must carry exactly `[Guid]`
%% whether the caller sent `[Guid]` or `[RealmUri, Guid]`; forwarding the
%% caller's own arguments -- directly, or through a `partial` left on the
%% CALL -- hands the callback three when the realm was named.
meta_api_forwards_only_the_guid(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Guid = open_session(RealmUri),
    Ctxt = bondy_context:local_context(RealmUri),
    Uri = routing_uri(Guid),
    lists:foreach(
        fun({Enc, Args}) ->
            Call = off_the_wire(Enc, Args),
            %% The dealer decodes `partial` again before invoking the callback,
            %% so a stale one would restore the caller's arguments.
            ?assertMatch(
                {continue,
                    #call{
                        procedure_uri = Uri, args = [Guid], partial = undefined
                    },
                    _},
                bondy_wamp_meta_api:handle_call(Call, Ctxt)
            )
        end,
        [{Enc, Args} || Enc <- [json, cbor], Args <- [[Guid], [RealmUri, Guid]]]
    ).

%% A CALL in Payload Passthru Mode carries a payload Bondy must not interpret,
%% so a procedure Bondy implements refuses it instead of decoding it, on both
%% API families.
internal_api_refuses_payload_passthru(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Guid = open_session(RealmUri),
    Ctxt = bondy_context:local_context(RealmUri),
    lists:foreach(
        fun({Mod, Proc}) ->
            Call = bondy_wamp_message:call(
                1, #{ppt_scheme => ~"x_custom"}, Proc, [Guid]
            ),
            ?assertMatch(
                {reply, #error{error_uri = ?WAMP_INVALID_ARGUMENT}},
                Mod:handle_call(Call, Ctxt)
            )
        end,
        [
            {bondy_wamp_meta_api, ?WAMP_SESSION_GET},
            {bondy_wamp_api, ~"bondy.session.get"}
        ]
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% A `wamp.session.get` CALL as the WebSocket path hands it on: encoded, then
%% decoded with partial decoding on, so its arguments are still in `partial`.
off_the_wire(Enc, Args) ->
    Call = bondy_wamp_message:call(1, #{}, ?WAMP_SESSION_GET, Args),
    Bin = iolist_to_binary(bondy_wamp_encoding:encode(Call, Enc)),
    {[Decoded], <<>>} = bondy_wamp_encoding:decode(subprotocol(Enc), Bin),
    Decoded.

%% @private
subprotocol(json) -> {ws, text, json};
subprotocol(cbor) -> {ws, binary, cbor}.

%% @private
open_session(RealmUri) ->
    Id = bondy_session_id:new(),
    {ok, Session} = bondy_session_manager:open(Id, RealmUri, session_opts()),
    bondy_session:id(Session).

%% @private
routing_uri(Guid) ->
    %% Exactly what bondy_wamp_meta_api builds from the session id.
    <<"wamp.session.", Guid/binary, ".get">>.

%% @private
%% Resolve a session's rewritten routing URI to matching registrations the way
%% the dealer does: find_matches/4 with all match policies (exact/prefix/
%% wildcard). Plain match/4 is not equivalent — its wildcard branch does an
%% exact pattern-key lookup, whereas find_matches traverses concrete-URI →
%% wildcard-pattern (what routing needs).
match_routing(RealmUri, Guid) ->
    Result = bondy_registry:find_matches(
        registration, RealmUri, routing_uri(Guid), #{match => '_', limit => 100}
    ),
    case Result of
        '$end_of_table' -> [];
        {Entries, _Cont} when is_list(Entries) -> Entries;
        Entries when is_list(Entries) -> Entries
    end.

%% @private
session_opts() ->
    #{
        peer => {{127, 0, 0, 1}, 10000},
        authid => <<"anonymous">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => true,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}, subscriber => #{}}
    }.
