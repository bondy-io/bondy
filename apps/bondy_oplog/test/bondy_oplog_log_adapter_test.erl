%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% The oplog adapter's `bondy_log_identity` contract: the bytes it puts in
%% the segment header's two identity fields, the errors it reports for a
%% context it cannot encode, and the order in which `verify_identity/2`
%% names a mismatch. The record callbacks are exercised by every WAL test;
%% the byte-identity probe pins their output.
%% =============================================================================
-module(bondy_oplog_log_adapter_test).

-include_lib("eunit/include/eunit.hrl").

instance_id() -> <<"test-instance-1">>.
origin() -> <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>.
ctx() -> #{instance_id => instance_id(), origin => origin()}.

%% =============================================================================
%% encode_identity/1
%% =============================================================================

encode_identity_is_hash8_and_origin_test() ->
    {ok, #{hash8 := Hash8, id16 := Id16}} =
        bondy_oplog_log_adapter:encode_identity(ctx()),
    ?assertEqual(8, byte_size(Hash8)),
    ?assertEqual(
        binary:part(crypto:hash(sha256, instance_id()), 0, 8), Hash8
    ),
    ?assertEqual(origin(), Id16).

instance_id_hash_is_stable_test() ->
    ?assertEqual(
        bondy_oplog_log_adapter:instance_id_hash(<<"abc">>),
        bondy_oplog_log_adapter:instance_id_hash(<<"abc">>)
    ),
    ?assertNotEqual(
        bondy_oplog_log_adapter:instance_id_hash(<<"abc">>),
        bondy_oplog_log_adapter:instance_id_hash(<<"abd">>)
    ).

encode_identity_requires_an_origin_test() ->
    ?assertEqual(
        {error, {missing_opt, origin}},
        bondy_oplog_log_adapter:encode_identity(#{
            instance_id => instance_id()
        })
    ).

encode_identity_validates_the_origin_test() ->
    ?assertEqual(
        {error, {invalid_origin, invalid_origin}},
        bondy_oplog_log_adapter:encode_identity((ctx())#{origin => <<>>})
    ),
    ?assertEqual(
        {error, {invalid_origin, invalid_origin}},
        bondy_oplog_log_adapter:encode_identity((ctx())#{origin => 42})
    ).

%% =============================================================================
%% verify_identity/2
%% =============================================================================

verify_identity_match_test() ->
    {ok, Identity} = bondy_oplog_log_adapter:encode_identity(ctx()),
    ?assertEqual(ok, bondy_oplog_log_adapter:verify_identity(Identity, ctx())).

verify_identity_instance_mismatch_test() ->
    {ok, Identity} = bondy_oplog_log_adapter:encode_identity(ctx()),
    ?assertEqual(
        {error, instance_id_hash_mismatch},
        bondy_oplog_log_adapter:verify_identity(
            Identity, (ctx())#{instance_id => <<"other-instance">>}
        )
    ).

verify_identity_origin_mismatch_test() ->
    {ok, Identity} = bondy_oplog_log_adapter:encode_identity(ctx()),
    Other = <<16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1>>,
    ?assertEqual(
        {error, origin_mismatch},
        bondy_oplog_log_adapter:verify_identity(
            Identity, (ctx())#{origin => Other}
        )
    ).

%% Both fields wrong: the origin is named, as before the seam existed.
verify_identity_names_the_origin_first_test() ->
    {ok, Identity} = bondy_oplog_log_adapter:encode_identity(ctx()),
    Other = <<16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1>>,
    ?assertEqual(
        {error, origin_mismatch},
        bondy_oplog_log_adapter:verify_identity(Identity, #{
            instance_id => <<"other-instance">>, origin => Other
        })
    ).
