%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
-module(bondy_interface_SUITE).

-moduledoc """
The interface metadata store under the PRODUCT model, driven on a booted
node: interface documents are versioned artifacts published out of band —
loading a document's next version replaces the previous one, one entry
belongs to exactly one document, deleting the document removes its entries
— and the `wamp.reflection.*` procedures are the read side: readable with
`bondy_mcp` stopped (the store is a Bondy capability, MCP one consumer),
advertised as the `reflection` feature, and RBAC-projected per the
specification's "authorized to access or provide".

A REGISTER deliberately has NO metadata channel: `'_interface'` is not a
declared extended option, so it is dropped at message validation and the
store never hears about it — interface lifetime is the document's, never a
session's.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").

-define(OPEN_REALM, <<"com.bondy.iface.open">>).
-define(RBAC_REALM, <<"com.bondy.iface.rbac">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        load_replaces_the_previous_version,
        load_is_atomic_on_an_invalid_entry,
        cross_document_ownership_is_exclusive,
        delete_removes_the_documents_entries,
        register_carries_no_interface_channel,
        reflection_reads_without_bondy_mcp,
        welcome_advertises_reflection,
        reflection_list_is_rbac_projected
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Realm = bondy_realm:create(?OPEN_REALM),
    ok = bondy_realm:disable_security(Realm),
    _ = bondy_realm:create(#{
        uri => ?RBAC_REALM,
        description => <<"Reflection RBAC projection">>,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        groups => [#{name => <<"apigroup">>}],
        grants => [
            %% The subject may call the reflection procedures themselves...
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"wamp.reflection.">>,
                match => <<"prefix">>,
                roles => [<<"apigroup">>]
            },
            %% ...and exactly ONE of the two described procedure subtrees.
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"com.acme.visible.">>,
                match => <<"prefix">>,
                roles => [<<"apigroup">>]
            }
        ],
        users => [
            #{username => <<"user_1">>, groups => [<<"apigroup">>], meta => #{}}
        ]
    }),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

%% =============================================================================
%% CASES
%% =============================================================================

load_replaces_the_previous_version(_Config) ->
    V1 = doc(<<"com.acme.billing">>, <<"1">>, [
        entry(<<"procedure">>, <<"com.bondy.iface.keep">>, <<"v1 kept">>),
        entry(<<"procedure">>, <<"com.bondy.iface.dropped">>, <<"v1 only">>)
    ]),
    ?assertEqual(ok, bondy_interface:load(V1)),
    ?assertMatch(
        {ok, #{description := <<"v1 only">>}},
        bondy_interface:describe(
            ?OPEN_REALM, procedure, <<"com.bondy.iface.dropped">>
        )
    ),

    %% Version 2 drops one entry, updates the other, adds a third. Loading
    %% it REPLACES version 1: the dropped entry is gone — nobody has to
    %% remember to delete it — and every survivor reads at v2.
    V2 = doc(<<"com.acme.billing">>, <<"2">>, [
        entry(<<"procedure">>, <<"com.bondy.iface.keep">>, <<"v2 updated">>),
        entry(<<"topic">>, <<"com.bondy.iface.added">>, <<"v2 new">>)
    ]),
    ?assertEqual(ok, bondy_interface:load(V2)),

    ?assertEqual(
        {error, not_found},
        bondy_interface:describe(
            ?OPEN_REALM, procedure, <<"com.bondy.iface.dropped">>
        )
    ),
    ?assertMatch(
        {ok, #{
            description := <<"v2 updated">>, source := <<"com.acme.billing">>
        }},
        bondy_interface:describe(
            ?OPEN_REALM, procedure, <<"com.bondy.iface.keep">>
        )
    ),
    ?assertMatch(
        {ok, #{description := <<"v2 new">>}},
        bondy_interface:describe(
            ?OPEN_REALM, topic, <<"com.bondy.iface.added">>
        )
    ),

    %% The stored document is the v2 SOURCE, as loaded.
    ?assertMatch(
        {ok, #{<<"version">> := <<"2">>}},
        bondy_interface:get(<<"com.acme.billing">>)
    ),
    ok = cleanup_docs().

load_is_atomic_on_an_invalid_entry(_Config) ->
    %% One invalid entry rejects the whole document: nothing is written.
    Invalid = doc(<<"com.acme.atomic">>, <<"1">>, [
        entry(<<"topic">>, <<"com.bondy.iface.t1">>, <<"ok">>),
        (entry(<<"procedure">>, <<"com.bondy.iface.p1">>, <<"bad">>))#{
            <<"format">> => <<"proto3">>
        }
    ]),
    ?assertMatch({error, _}, bondy_interface:load(Invalid)),
    ?assertEqual(
        {error, not_found},
        bondy_interface:describe(?OPEN_REALM, topic, <<"com.bondy.iface.t1">>)
    ),
    ?assertEqual(
        {error, not_found}, bondy_interface:get(<<"com.acme.atomic">>)
    ),

    %% Same for an entry naming a realm that does not exist.
    NoRealm = doc(<<"com.acme.atomic">>, <<"1">>, [
        entry(<<"topic">>, <<"com.bondy.iface.t1">>, <<"ok">>),
        (entry(<<"procedure">>, <<"com.bondy.iface.p1">>, <<"bad">>))#{
            <<"realm">> => <<"com.bondy.iface.ghost">>
        }
    ]),
    ?assertMatch(
        {error, {no_such_realm, <<"com.bondy.iface.ghost">>}},
        bondy_interface:load(NoRealm)
    ),
    ?assertEqual(
        {error, not_found},
        bondy_interface:describe(?OPEN_REALM, topic, <<"com.bondy.iface.t1">>)
    ).

cross_document_ownership_is_exclusive(_Config) ->
    %% One entry belongs to exactly one document: a second document claiming
    %% a key the first owns is rejected WHOLE — including the entries that
    %% did not conflict.
    A = doc(<<"com.acme.a">>, <<"1">>, [
        entry(<<"procedure">>, <<"com.bondy.iface.owned">>, <<"a's">>)
    ]),
    ?assertEqual(ok, bondy_interface:load(A)),

    B = doc(<<"com.acme.b">>, <<"1">>, [
        entry(<<"procedure">>, <<"com.bondy.iface.owned">>, <<"b's">>),
        entry(<<"procedure">>, <<"com.bondy.iface.b_only">>, <<"b's own">>)
    ]),
    ?assertMatch(
        {error, {conflict, #{owner := <<"com.acme.a">>}}},
        bondy_interface:load(B)
    ),
    ?assertMatch(
        {ok, #{description := <<"a's">>}},
        bondy_interface:describe(
            ?OPEN_REALM, procedure, <<"com.bondy.iface.owned">>
        )
    ),
    ?assertEqual(
        {error, not_found},
        bondy_interface:describe(
            ?OPEN_REALM, procedure, <<"com.bondy.iface.b_only">>
        )
    ),

    %% A document colliding with ITSELF is a mistake, not an override.
    Dup = doc(<<"com.acme.dup">>, <<"1">>, [
        entry(<<"procedure">>, <<"com.bondy.iface.twice">>, <<"one">>),
        entry(<<"procedure">>, <<"com.bondy.iface.twice">>, <<"two">>)
    ]),
    ?assertEqual({error, duplicate_entries}, bondy_interface:load(Dup)),
    ok = cleanup_docs().

delete_removes_the_documents_entries(_Config) ->
    Doc = doc(<<"com.acme.gone">>, <<"1">>, [
        entry(<<"procedure">>, <<"com.bondy.iface.g1">>, <<"g1">>),
        entry(<<"error">>, <<"com.bondy.iface.g2">>, <<"g2">>)
    ]),
    ?assertEqual(ok, bondy_interface:load(Doc)),
    ?assertEqual(ok, bondy_interface:delete(<<"com.acme.gone">>)),

    ?assertEqual(
        {error, not_found},
        bondy_interface:describe(
            ?OPEN_REALM, procedure, <<"com.bondy.iface.g1">>
        )
    ),
    ?assertEqual(
        {error, not_found},
        bondy_interface:describe(?OPEN_REALM, error, <<"com.bondy.iface.g2">>)
    ),
    ?assertEqual({error, not_found}, bondy_interface:get(<<"com.acme.gone">>)),
    %% Deleting an absent document is a named refusal, not a crash.
    ?assertEqual(
        {error, not_found}, bondy_interface:delete(<<"com.acme.gone">>)
    ).

register_carries_no_interface_channel(_Config) ->
    %% The write model is the document, so a REGISTER has NO metadata
    %% channel: `'_interface'` is not a declared extended option, the
    %% options validator drops it at message construction (the same
    %% validation the decoder runs), and the store never hears about the
    %% registration.
    Meta = #{<<"description">> => <<"never arrives">>},
    M = bondy_wamp_message:register(
        1, #{<<"_interface">> => Meta}, <<"com.bondy.iface.reg">>
    ),
    ?assertNot(maps:is_key('_interface', M#register.options)),
    ?assertNot(maps:is_key(<<"_interface">>, M#register.options)),

    Reply = forward(?OPEN_REALM, session(?OPEN_REALM, #{}), M),
    ?assertMatch(#registered{}, Reply),
    ?assertEqual(
        {error, not_found},
        bondy_interface:describe(
            ?OPEN_REALM, procedure, <<"com.bondy.iface.reg">>
        )
    ).

reflection_reads_without_bondy_mcp(_Config) ->
    %% The store is a Bondy capability and MCP one consumer of it: a second
    %% consumer reads a schema through wamp.reflection.procedure.describe
    %% with `bondy_mcp` NOT running.
    Doc = doc(<<"com.acme.solo">>, <<"1">>, [
        (entry(<<"procedure">>, <<"com.bondy.iface.solo">>, <<"read me">>))#{
            <<"kwargs_schema">> => #{<<"type">> => <<"object">>}
        }
    ]),
    ?assertEqual(ok, bondy_interface:load(Doc)),
    ok = application:stop(bondy_mcp),
    try
        Reply = call(?OPEN_REALM, ?WAMP_REFLECTION_PROC_DESCRIBE, [
            <<"com.bondy.iface.solo">>
        ]),
        ?assertMatch(
            #result{
                args = [
                    #{
                        <<"description">> := <<"read me">>,
                        <<"kwargs_schema">> := #{<<"type">> := <<"object">>},
                        <<"kind">> := <<"procedure">>,
                        <<"format">> := <<"json_schema_2020_12">>
                    }
                ]
            },
            Reply
        )
    after
        {ok, _} = application:ensure_all_started(bondy_mcp)
    end,
    ok = cleanup_docs().

welcome_advertises_reflection(_Config) ->
    %% `bondy_config:setup_wamp/0` seats `?DEALER_FEATURES` /
    %% `?BROKER_FEATURES` into `[wamp, Role, features, _]` — the single
    %% source both WELCOME and `is_feature_implemented/1` read — so this is
    %% the announcement, flipped in the same increment as the procedures.
    ?assertEqual(true, bondy_config:get([wamp, dealer, features, reflection])),
    ?assertEqual(true, bondy_config:get([wamp, broker, features, reflection])).

reflection_list_is_rbac_projected(_Config) ->
    %% The specification's own wording: a peer lists what it "is authorized
    %% to access or provide". `u1` may call `com.acme.visible.*` and nothing
    %% under `com.acme.hidden.*`, so the projected list holds exactly the
    %% visible URI — and a describe of the hidden one answers as absent, not
    %% as denied, so the reply is no existence oracle.
    Doc = #{
        <<"id">> => <<"com.acme.rbac">>,
        <<"entries">> => [
            (entry(<<"procedure">>, <<"com.acme.visible.p1">>, <<"seen">>))#{
                <<"realm">> => ?RBAC_REALM
            },
            (entry(<<"procedure">>, <<"com.acme.hidden.p2">>, <<"unseen">>))#{
                <<"realm">> => ?RBAC_REALM
            }
        ]
    },
    ?assertEqual(ok, bondy_interface:load(Doc)),

    Session = session(?RBAC_REALM, #{
        authid => <<"user_1">>,
        is_anonymous => false,
        security_enabled => true,
        authroles => [<<"apigroup">>]
    }),

    ?assertMatch(
        #result{args = [[<<"com.acme.visible.p1">>]]},
        call_as(Session, ?WAMP_REFLECTION_PROC_LIST, [])
    ),
    ?assertMatch(
        #result{args = [#{<<"description">> := <<"seen">>}]},
        call_as(Session, ?WAMP_REFLECTION_PROC_DESCRIBE, [
            <<"com.acme.visible.p1">>
        ])
    ),
    ?assertMatch(
        #error{},
        call_as(Session, ?WAMP_REFLECTION_PROC_DESCRIBE, [
            <<"com.acme.hidden.p2">>
        ])
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

doc(Id, Version, Entries) ->
    #{<<"id">> => Id, <<"version">> => Version, <<"entries">> => Entries}.

entry(Kind, Uri, Description) ->
    #{
        <<"realm">> => ?OPEN_REALM,
        <<"kind">> => Kind,
        <<"uri">> => Uri,
        <<"description">> => Description
    }.

%% Cases share the node, so each removes the documents it loaded.
cleanup_docs() ->
    lists:foreach(
        fun(#{<<"id">> := Id}) -> ok = bondy_interface:delete(Id) end,
        bondy_interface:list()
    ).

call(RealmUri, Proc, Args) ->
    call_as(session(RealmUri, #{}), Proc, Args).

call_as(Session, Proc, Args) ->
    forward(
        bondy_session:realm_uri(Session),
        Session,
        bondy_wamp_message:call(1, #{}, Proc, Args)
    ).

%% Forwards `M` through the real dealer path as `Session` and returns the
%% routed reply (the `bondy_session_get_cluster_SUITE` idiom: an unstored
%% session bound to the calling process).
forward(_RealmUri, Session, M) ->
    Ctxt = bondy_context:new(
        {{127, 0, 0, 1}, 10999}, {ws, text, json}, #{session => Session}
    ),
    ok = bondy_dealer:forward(M, Ctxt),
    receive
        {'$bondy_request', _, _, Reply} -> Reply
    after 15000 ->
        error(timeout)
    end.

session(RealmUri, Overrides) ->
    Base = #{
        peer => {{127, 0, 0, 1}, 10999},
        authid => <<"iface-tester">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}, callee => #{}}
    },
    bondy_session:new(RealmUri, maps:merge(Base, Overrides)).
