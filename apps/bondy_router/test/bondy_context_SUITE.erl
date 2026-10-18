%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% The four `bondy_context` setters that must agree with a session once one
%% is set: `set_session_id/2`, `set_realm_uri/2`, `set_security_enabled/2`
%% and `set_authid/2`. Each sets its key on a sessionless context, returns
%% the context untouched when the session already carries the same value,
%% and raises `badarg` when it carries a different one. A session needs a
%% realm, hence CT. The suite also covers `local_context/1` over a missing realm
%% and `close/1` over contexts with and without a peer.

-module(bondy_context_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(AUTHID, <<"context_suite_user">>).

all() ->
    [
        setters_set_the_key_without_a_session,
        setters_keep_a_context_whose_session_agrees,
        setters_reject_a_value_the_session_contradicts,
        local_context_of_a_missing_realm_keeps_security_on,
        close_flushes_a_peer_and_ignores_a_peerless_context
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Realm = bondy_realm:create(<<"bondy.context.suite">>),
    ok = bondy_realm:enable_security(Realm),
    [{realm_uri, bondy_realm:uri(Realm)} | Config].

end_per_suite(_Config) ->
    ok.

setters_set_the_key_without_a_session(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Ctxt0 = bondy_context:new(),
    SessionId = bondy_session_id:new(),
    Ctxt1 = bondy_context:set_session_id(Ctxt0, SessionId),
    ?assertEqual(SessionId, bondy_context:session_id(Ctxt1)),
    Ctxt2 = bondy_context:set_realm_uri(Ctxt1, RealmUri),
    ?assertEqual(RealmUri, bondy_context:realm_uri(Ctxt2)),
    Ctxt3 = bondy_context:set_security_enabled(Ctxt2, true),
    ?assertEqual(true, bondy_context:is_security_enabled(Ctxt3)),
    Ctxt4 = bondy_context:set_authid(Ctxt3, ?AUTHID),
    ?assertEqual(?AUTHID, bondy_context:authid(Ctxt4)).

setters_keep_a_context_whose_session_agrees(Config) ->
    {Session, Ctxt} = context_with_session(Config),
    ?assertEqual(
        Ctxt, bondy_context:set_session_id(Ctxt, bondy_session:id(Session))
    ),
    ?assertEqual(
        Ctxt,
        bondy_context:set_realm_uri(Ctxt, bondy_session:realm_uri(Session))
    ),
    ?assertEqual(
        Ctxt,
        bondy_context:set_security_enabled(
            Ctxt, bondy_session:is_security_enabled(Session)
        )
    ),
    ?assertEqual(
        Ctxt, bondy_context:set_authid(Ctxt, bondy_session:authid(Session))
    ).

setters_reject_a_value_the_session_contradicts(Config) ->
    {Session, Ctxt} = context_with_session(Config),
    ?assertError(
        badarg, bondy_context:set_session_id(Ctxt, bondy_session_id:new())
    ),
    ?assertError(
        badarg, bondy_context:set_realm_uri(Ctxt, <<"bondy.context.other">>)
    ),
    ?assertError(
        badarg,
        bondy_context:set_security_enabled(
            Ctxt, not bondy_session:is_security_enabled(Session)
        )
    ),
    ?assertError(
        badarg, bondy_context:set_authid(Ctxt, <<"someone_else">>)
    ).

%% `bondy_realm:fetch/1` raises `{not_found, Uri}` for this realm.
local_context_of_a_missing_realm_keeps_security_on(_Config) ->
    Ctxt = bondy_context:local_context(<<"bondy.context.suite.missing">>),
    ?assertEqual(true, maps:get(security_enabled, Ctxt)).

close_flushes_a_peer_and_ignores_a_peerless_context(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Peerless = bondy_context:local_context(RealmUri),
    ?assertEqual(ok, bondy_context:close(Peerless)),
    {_Session, Ctxt} = context_with_session(Config),
    ?assertEqual(ok, bondy_context:close(Ctxt)).

%% =============================================================================
%% HELPERS
%% =============================================================================

context_with_session(Config) ->
    RealmUri = ?config(realm_uri, Config),
    Peer = {{127, 0, 0, 1}, 52100},
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => ?AUTHID,
        is_anonymous => false,
        security_enabled => true,
        roles => #{caller => #{features => #{}}}
    }),
    Ctxt = bondy_context:new(Peer, {ws, text, json}, #{session => Session}),
    {Session, Ctxt}.
