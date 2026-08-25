%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Falsifiers for `bondy_mcp_spec:hash/1` — the §7.5 content-addressed entry
%% hash. The property under test is the hash's BOUNDARY: it must cover
%% exactly the normative content (name, kind, schemas, WAMP binding,
%% annotations) — a change inside moves it, a change outside does not —
%% because pinning and drift detection are only as good as that boundary.
%% (`compile/2` reads the interface store and is exercised by
%% `bondy_mcp_gateway_SUITE` on a booted node.)
-module(bondy_mcp_spec_test).

-include_lib("eunit/include/eunit.hrl").

entry() ->
    #{
        realm => <<"com.acme.app1">>,
        name => <<"create_invoice">>,
        kind => tool,
        procedure => <<"com.acme.billing.create_invoice">>,
        annotations => #{<<"destructive_hint">> => true},
        wamp_options => #{<<"timeout">> => 60000},
        description => <<"Create a draft invoice">>,
        version => <<"1.0">>,
        source => #{overlay => <<"doc_1">>},
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"customer">> => #{<<"type">> => <<"string">>},
                <<"amount">> => #{<<"type">> => <<"integer">>}
            }
        }
    }.

hash_shape_test() ->
    <<"sha256:", Hex/binary>> = bondy_mcp_spec:hash(entry()),
    ?assertEqual(64, byte_size(Hex)),
    ?assertMatch(
        [],
        [
            C
         || <<C>> <= Hex,
            not ((C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f))
        ]
    ).

hash_is_independent_of_construction_order_test() ->
    %% The same content assembled in a different insertion order must hash
    %% identically — the canonical form, not the map's history, is hashed.
    E = entry(),
    Rebuilt = maps:fold(fun(K, V, Acc) -> Acc#{K => V} end, #{}, E),
    Reordered = lists:foldl(
        fun({K, V}, Acc) -> Acc#{K => V} end,
        #{},
        lists:reverse(maps:to_list(E))
    ),
    ?assertEqual(bondy_mcp_spec:hash(E), bondy_mcp_spec:hash(Rebuilt)),
    ?assertEqual(bondy_mcp_spec:hash(E), bondy_mcp_spec:hash(Reordered)).

non_normative_fields_do_not_move_the_hash_test() ->
    %% §7.5 names the normative set; description, version and provenance
    %% are outside it — prose can be corrected without re-approving the
    %% tool — and the realm is the pinning scope, not pinned content.
    H = bondy_mcp_spec:hash(entry()),
    ?assertEqual(
        H, bondy_mcp_spec:hash((entry())#{description => <<"Edited">>})
    ),
    ?assertEqual(H, bondy_mcp_spec:hash((entry())#{version => <<"2.0">>})),
    ?assertEqual(
        H,
        bondy_mcp_spec:hash((entry())#{source => #{overlay => <<"doc_2">>}})
    ),
    ?assertEqual(
        H, bondy_mcp_spec:hash((entry())#{realm => <<"com.acme.app2">>})
    ),
    ?assertEqual(H, bondy_mcp_spec:hash(maps:remove(description, entry()))),
    %% The §14.3 audit redaction policy is capture policy, not tool
    %% content — outside the hash (an open ruling, recorded in the spec
    %% module and the design doc).
    ?assertEqual(
        H,
        bondy_mcp_spec:hash((entry())#{
            redaction => #{fields => [<<"ssn">>]}
        })
    ).

normative_fields_move_the_hash_test() ->
    H = bondy_mcp_spec:hash(entry()),
    Moved = [
        (entry())#{name => <<"create_invoice_v2">>},
        (entry())#{kind => resource_template},
        (entry())#{procedure => <<"com.acme.billing.other">>},
        (entry())#{annotations => #{<<"destructive_hint">> => false}},
        (entry())#{annotations => #{}},
        (entry())#{wamp_options => #{<<"timeout">> => 30000}},
        %% A silent schema change is exactly the drift §7.5 exists to expose.
        maps_update_path(entry()),
        maps:remove(input_schema, entry()),
        (entry())#{output_schema => #{<<"type">> => <<"object">>}}
    ],
    _ = [?assertNotEqual(H, bondy_mcp_spec:hash(E)) || E <- Moved],
    %% All distinct from one another too.
    Hs = [bondy_mcp_spec:hash(E) || E <- Moved],
    ?assertEqual(length(Hs), length(lists:usort(Hs))).

%% One nested edit: amount integer -> number.
maps_update_path(E) ->
    #{input_schema := #{<<"properties">> := Props} = Schema} = E,
    Amount = maps:get(<<"amount">>, Props),
    E#{
        input_schema := Schema#{
            <<"properties">> := Props#{
                <<"amount">> := Amount#{<<"type">> := <<"number">>}
            }
        }
    }.
