%% Stage 12: crypto validator tests.

-module(bondy_oplog_validator_crypto_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

%% =============================================================================
%% UNIT TESTS — direct against the validator module
%% =============================================================================

sign_then_verify_test() ->
    {Pub, Priv} = generate_keypair(),
    Origin = origin_from_pubkey(Pub),
    {ok, SState} = init_state({Pub, Priv}, #{Origin => Pub}),
    Event = mk_event(Origin, 1),
    {Signed, _SState1} =
        bondy_oplog_validator_crypto:sign_event(Event, SState),
    %% Signed event has both fields populated.
    ?assert(is_binary(bondy_oplog_event:prev_hash(Signed))),
    ?assert(is_binary(bondy_oplog_event:signature(Signed))),
    %% A peer with the same pub key map can verify it.
    {ok, VState} = init_state(undefined, #{Origin => Pub}),
    ?assertEqual(
        ok,
        bondy_oplog_validator_crypto:verify_event(Signed, VState)
    ).

verify_rejects_tampered_payload_test() ->
    {Pub, Priv} = generate_keypair(),
    Origin = origin_from_pubkey(Pub),
    {ok, SState} = init_state({Pub, Priv}, #{Origin => Pub}),
    Event = mk_event(Origin, 1),
    {Signed, _} =
        bondy_oplog_validator_crypto:sign_event(Event, SState),
    %% Tamper with the op.
    Tampered = bondy_oplog_event:new(
        bondy_oplog_event:key(Signed),
        {tampered_op},
        bondy_oplog_event:meta(Signed),
        bondy_oplog_event:prev_hash(Signed),
        bondy_oplog_event:signature(Signed)
    ),
    {ok, VState} = init_state(undefined, #{Origin => Pub}),
    ?assertEqual(
        {error, invalid_signature},
        bondy_oplog_validator_crypto:verify_event(Tampered, VState)
    ).

verify_rejects_tampered_signature_test() ->
    {Pub, Priv} = generate_keypair(),
    Origin = origin_from_pubkey(Pub),
    {ok, SState} = init_state({Pub, Priv}, #{Origin => Pub}),
    Event = mk_event(Origin, 1),
    {Signed, _} =
        bondy_oplog_validator_crypto:sign_event(Event, SState),
    BadSig = crypto:strong_rand_bytes(64),
    Tampered = bondy_oplog_event:set_signature(Signed, BadSig),
    {ok, VState} = init_state(undefined, #{Origin => Pub}),
    ?assertEqual(
        {error, invalid_signature},
        bondy_oplog_validator_crypto:verify_event(Tampered, VState)
    ).

verify_rejects_unknown_origin_by_default_test() ->
    {Pub, Priv} = generate_keypair(),
    Origin = origin_from_pubkey(Pub),
    {ok, SState} = init_state({Pub, Priv}, #{Origin => Pub}),
    Event = mk_event(Origin, 1),
    {Signed, _} =
        bondy_oplog_validator_crypto:sign_event(Event, SState),
    %% Verifier knows nothing about this origin.
    {ok, VState} = init_state(undefined, #{}),
    ?assertMatch(
        {error, {unknown_origin, _}},
        bondy_oplog_validator_crypto:verify_event(Signed, VState)
    ).

verify_accepts_unknown_origin_when_opted_in_test() ->
    {Pub, Priv} = generate_keypair(),
    Origin = origin_from_pubkey(Pub),
    {ok, SState} = init_state({Pub, Priv}, #{Origin => Pub}),
    Event = mk_event(Origin, 1),
    {Signed, _} =
        bondy_oplog_validator_crypto:sign_event(Event, SState),
    {ok, VState} =
        bondy_oplog_validator_crypto:init(<<"i">>, #{
            peer_pubkeys => #{},
            accept_unknown_origin => true
        }),
    ?assertEqual(
        ok,
        bondy_oplog_validator_crypto:verify_event(Signed, VState)
    ).

hash_chain_links_consecutive_events_test() ->
    {Pub, Priv} = generate_keypair(),
    Origin = origin_from_pubkey(Pub),
    {ok, S0} = init_state({Pub, Priv}, #{Origin => Pub}),
    E1 = mk_event(Origin, 1),
    {Signed1, S1} =
        bondy_oplog_validator_crypto:sign_event(E1, S0),
    E2 = mk_event(Origin, 2),
    {Signed2, _S2} =
        bondy_oplog_validator_crypto:sign_event(E2, S1),
    %% Signed2's prev_hash must equal hash(Signed1).
    ExpectedPrev = sha_hash(
        canonical_blob(Signed1),
        bondy_oplog_event:signature(Signed1)
    ),
    ?assertEqual(ExpectedPrev, bondy_oplog_event:prev_hash(Signed2)).

equivocation_detected_for_distinct_signatures_at_same_key_test() ->
    {Pub, Priv} = generate_keypair(),
    Origin = origin_from_pubkey(Pub),
    {ok, S0} = init_state({Pub, Priv}, #{Origin => Pub}),
    E = mk_event(Origin, 1),
    {Signed, _} =
        bondy_oplog_validator_crypto:sign_event(E, S0),
    %% Synthesise a "fork": same key, different op, signed with the
    %% same private key.
    EFork = bondy_oplog_event:new(
        bondy_oplog_event:key(E),
        {forked_op},
        undefined
    ),
    {Signed2, _} =
        bondy_oplog_validator_crypto:sign_event(EFork, S0),
    ?assertNotEqual(
        bondy_oplog_event:signature(Signed),
        bondy_oplog_event:signature(Signed2)
    ),
    ?assertMatch(
        {equivocation, #{origin := Origin}},
        bondy_oplog_validator_crypto:detect_equivocation(
            Signed, Signed2
        )
    ).

equivocation_returns_ok_for_identical_events_test() ->
    {Pub, Priv} = generate_keypair(),
    Origin = origin_from_pubkey(Pub),
    {ok, S0} = init_state({Pub, Priv}, #{Origin => Pub}),
    E = mk_event(Origin, 1),
    {Signed, _} =
        bondy_oplog_validator_crypto:sign_event(E, S0),
    %% Same event passed twice — Ed25519 is deterministic, so signatures
    %% match and detect_equivocation must NOT flag it.
    ?assertEqual(
        ok,
        bondy_oplog_validator_crypto:detect_equivocation(
            Signed, Signed
        )
    ).

%% =============================================================================
%% INTEGRATION — wire the crypto validator into a real instance
%% =============================================================================

integration_setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

integration_cleanup(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

integration_test_() ->
    {setup, fun integration_setup/0, fun integration_cleanup/1, [
        fun instance_with_crypto_validator_signs_events/0,
        fun instance_rejects_tampered_remote_event/0,
        fun crypto_validator_refresh_adds_peer_pubkey/0,
        fun crypto_validator_refresh_returns_error_without_env/0
    ]}.

%% Bring up an instance configured with the crypto validator. Verify
%% that local appends produce signed events with non-empty prev_hash
%% and signature.
instance_with_crypto_validator_signs_events() ->
    {Pub, Priv} = generate_keypair(),
    Origin = origin_from_pubkey(Pub),
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        origin => Origin,
        validator => bondy_oplog_validator_crypto,
        validator_opts => #{
            keypair => {Pub, Priv},
            peer_pubkeys => #{Origin => Pub}
        },
        crdt_module => bondy_oplog_test_counter
    }),
    K = bondy_oplog:append(Id, {inc, 7}),
    {ok, Stored} = bondy_oplog:get(Id, K),
    ?assert(is_binary(bondy_oplog_event:signature(Stored))),
    ?assert(is_binary(bondy_oplog_event:prev_hash(Stored))),
    ok = bondy_oplog:stop_instance(Id).

%% Two instances configured with mutual public keys. A tampered
%% remote event delivered via append_remote/2 is rejected.
instance_rejects_tampered_remote_event() ->
    {PubA, PrivA} = generate_keypair(),
    {PubB, PrivB} = generate_keypair(),
    OriginA = origin_from_pubkey(PubA),
    OriginB = origin_from_pubkey(PubB),
    Pubkeys = #{OriginA => PubA, OriginB => PubB},
    IdA = mk_id(),
    IdB = mk_id(),
    {ok, _} = bondy_oplog:start_instance(IdA, #{
        origin => OriginA,
        validator => bondy_oplog_validator_crypto,
        validator_opts => #{
            keypair => {PubA, PrivA},
            peer_pubkeys => Pubkeys
        }
    }),
    {ok, _} = bondy_oplog:start_instance(IdB, #{
        origin => OriginB,
        validator => bondy_oplog_validator_crypto,
        validator_opts => #{
            keypair => {PubB, PrivB},
            peer_pubkeys => Pubkeys
        }
    }),
    %% B appends → has a signed event.
    Key = bondy_oplog:append(IdB, {inc, 1}),
    {ok, BEvent} = bondy_oplog:get(IdB, Key),
    %% Tamper: rewrite the op while keeping the signature.
    Tampered = bondy_oplog_event:new(
        bondy_oplog_event:key(BEvent),
        {evil_op},
        bondy_oplog_event:meta(BEvent),
        bondy_oplog_event:prev_hash(BEvent),
        bondy_oplog_event:signature(BEvent)
    ),
    %% A receives — must reject.
    ?assertEqual(
        {error, invalid_signature},
        bondy_oplog:append_remote(IdA, Tampered)
    ),
    %% A's MST is unchanged.
    ?assertEqual(0, bondy_oplog:size(IdA)),
    ok.

%% An operator can add a peer's public key at runtime by publishing
%% the new `peer_pubkeys` under the per-instance app env key and
%% calling `refresh_validator/1`. A's snapshot is rotated without a
%% subtree restart and the previously-rejected B event is accepted on
%% retry.
crypto_validator_refresh_adds_peer_pubkey() ->
    {PubA, PrivA} = generate_keypair(),
    {PubB, PrivB} = generate_keypair(),
    OriginA = origin_from_pubkey(PubA),
    OriginB = origin_from_pubkey(PubB),
    IdA = mk_id(),
    IdB = mk_id(),
    %% A starts knowing only itself. B has both keys so it can sign.
    {ok, _} = bondy_oplog:start_instance(IdA, #{
        origin => OriginA,
        validator => bondy_oplog_validator_crypto,
        validator_opts => #{
            keypair => {PubA, PrivA},
            peer_pubkeys => #{OriginA => PubA}
        }
    }),
    {ok, _} = bondy_oplog:start_instance(IdB, #{
        origin => OriginB,
        validator => bondy_oplog_validator_crypto,
        validator_opts => #{
            keypair => {PubB, PrivB},
            peer_pubkeys => #{OriginA => PubA, OriginB => PubB}
        }
    }),
    %% B signs a local event then forwards it to A — must be rejected
    %% because A doesn't know B's pubkey yet.
    Key1 = bondy_oplog:append(IdB, {inc, 1}),
    {ok, Signed1} = bondy_oplog:get(IdB, Key1),
    ?assertMatch(
        {error, {unknown_origin, _}},
        bondy_oplog:append_remote(IdA, Signed1)
    ),
    %% Operator pushes B's pubkey into A's rotation config and
    %% triggers refresh.
    application:set_env(
        bondy_oplog,
        {validator_crypto, IdA},
        #{peer_pubkeys => #{OriginA => PubA, OriginB => PubB}}
    ),
    ok = bondy_oplog_instance:refresh_validator(IdA, add_peer_b),
    %% Synchronise on the applier so the cast is processed before
    %% the retry.
    ApplierPid = bondy_oplog_registry:applier_pid(IdA),
    ?assert(is_pid(ApplierPid)),
    _ = sys:get_state(ApplierPid),
    %% B signs a second event (the first was per-Origin chain head;
    %% reusing it would equivocate on prev_hash). A accepts it.
    Key2 = bondy_oplog:append(IdB, {inc, 2}),
    {ok, Signed2} = bondy_oplog:get(IdB, Key2),
    ?assertEqual(ok, bondy_oplog:append_remote(IdA, Signed2)),
    application:unset_env(bondy_oplog, {validator_crypto, IdA}),
    ok.

%% Without a published env key, `refresh/1` returns
%% `{error, no_refreshed_config}` and the applier keeps its old
%% snapshot. We observe the no-op behaviourally: the previously-
%% rejecting validator continues to reject.
crypto_validator_refresh_returns_error_without_env() ->
    {PubA, PrivA} = generate_keypair(),
    {PubB, PrivB} = generate_keypair(),
    OriginA = origin_from_pubkey(PubA),
    OriginB = origin_from_pubkey(PubB),
    IdA = mk_id(),
    IdB = mk_id(),
    {ok, _} = bondy_oplog:start_instance(IdA, #{
        origin => OriginA,
        validator => bondy_oplog_validator_crypto,
        validator_opts => #{
            keypair => {PubA, PrivA},
            peer_pubkeys => #{OriginA => PubA}
        }
    }),
    {ok, _} = bondy_oplog:start_instance(IdB, #{
        origin => OriginB,
        validator => bondy_oplog_validator_crypto,
        validator_opts => #{
            keypair => {PubB, PrivB},
            peer_pubkeys => #{OriginA => PubA, OriginB => PubB}
        }
    }),
    %% Ensure no env key is set.
    application:unset_env(bondy_oplog, {validator_crypto, IdA}),
    %% Refresh cast is delivered, applier logs the error, keeps old
    %% snapshot. Verify behaviourally: B's event is still rejected.
    ok = bondy_oplog_instance:refresh_validator(IdA, no_env_check),
    ApplierPid = bondy_oplog_registry:applier_pid(IdA),
    ?assert(is_pid(ApplierPid)),
    _ = sys:get_state(ApplierPid),
    Key = bondy_oplog:append(IdB, {inc, 1}),
    {ok, Signed} = bondy_oplog:get(IdB, Key),
    ?assertMatch(
        {error, {unknown_origin, _}},
        bondy_oplog:append_remote(IdA, Signed)
    ),
    ok.

%% =============================================================================
%% HELPERS
%% =============================================================================

generate_keypair() ->
    crypto:generate_key(eddsa, ed25519).

origin_from_pubkey(Pub) ->
    %% The WAL's segment header stores a 16-byte origin; truncate the
    %% sha256 hash so the test's derived origin satisfies that fixed
    %% width. Collision probability across a single test run is
    %% negligible.
    binary:part(crypto:hash(sha256, Pub), 0, 16).

init_state(Keypair, PeerPubkeys) ->
    bondy_oplog_validator_crypto:init(<<"test_inst">>, #{
        keypair => Keypair,
        peer_pubkeys => PeerPubkeys
    }).

mk_event(Origin, Seq) ->
    Hlc = bondy_oplog_hlc:encode(1_700_000_000_000 + Seq, 0),
    Key = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(Key, {op, Seq}, undefined).

mk_id() ->
    list_to_binary(
        "cv_" ++
            integer_to_list(
                erlang:unique_integer([positive, monotonic])
            )
    ).

canonical_blob(Event) ->
    erlang:term_to_binary(
        {
            bondy_oplog_event:key(Event),
            bondy_oplog_event:op(Event),
            bondy_oplog_event:meta(Event),
            bondy_oplog_event:prev_hash(Event)
        },
        [{minor_version, 2}]
    ).

sha_hash(Payload, Sig) ->
    crypto:hash(sha256, <<Payload/binary, Sig/binary>>).
