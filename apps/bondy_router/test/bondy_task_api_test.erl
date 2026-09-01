%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_task_api_test).

-moduledoc """
`bondy_task_api:render/1`'s encodability contract, without standing up a
session.

The contract is TOTALITY: every value a catalogue entry could carry has an
encodable image, so a shape nobody anticipated renders rather than raising
inside `maps:fold/3` and killing the session of whoever asked what they may do.
The catalogue is a literal table today, so nothing here is reachable from a
real entry — which is the point. The rendering is the last thing between the
table and a JSON encoder, and a table is edited by hand.

`render/1` was exported for this module and this module did not exist
(found 2026-09-01). The gap was not free: `key/1` had lost its total clause and
the encoder claimed a totality it did not have, which is exactly what the first
case below now pins.
""".

-include_lib("eunit/include/eunit.hrl").

%% The defect this module was missing. `encodable/1`'s last clause renders any
%% value, but a map's KEYS go through `key/1` — so a non-atom, non-binary key
%% raised `function_clause` from inside the fold, which no `encodable/1` clause
%% could catch. A tuple key is the shape a hand-edited table most plausibly
%% grows.
a_map_key_that_is_neither_atom_nor_binary_renders_test() ->
    R = bondy_task_api:render(#{args => [#{{1, 2} => ~"odd"}]}),
    [Arg] = maps:get(~"args", R),
    ?assertEqual([~"{1,2}"], maps:keys(Arg)).

%% The ordinary shapes, so the case above cannot pass by rendering everything.
atoms_and_binaries_are_the_normal_keys_test() ->
    R = bondy_task_api:render(#{impact => benign, id => ~"bondy.mail.test"}),
    ?assertEqual(~"benign", maps:get(~"impact", R)),
    ?assertEqual(~"bondy.mail.test", maps:get(~"id", R)).

%% Booleans must NOT become the strings "true"/"false": `idempotent` and
%% `dry_run` are booleans an agent policy branches on, and a string is truthy
%% in most of the languages that will read this.
booleans_survive_as_booleans_test() ->
    R = bondy_task_api:render(#{idempotent => true, dry_run => false}),
    ?assertEqual(true, maps:get(~"idempotent", R)),
    ?assertEqual(false, maps:get(~"dry_run", R)).

%% `args` is a list of JSON Schema maps and `observe_with` a list of
%% `{kind, ref}` maps, so nesting has to survive to arbitrary depth rather than
%% being rendered as a printed term one level down.
nested_structures_are_walked_test() ->
    R = bondy_task_api:render(#{
        observe_with => [#{kind => procedure, ref => ~"bondy.mail.relay.list"}]
    }),
    ?assertEqual(
        [#{~"kind" => ~"procedure", ~"ref" => ~"bondy.mail.relay.list"}],
        maps:get(~"observe_with", R)
    ).

%% A pid, a ref or a fun has no JSON image at all. Rendering it is the only
%% total option; raising would take the session with it.
a_value_with_no_json_image_renders_test() ->
    R = bondy_task_api:render(#{summary => self()}),
    ?assert(is_binary(maps:get(~"summary", R))).

%% The whole point, end to end: every entry the shipped catalogue declares
%% renders, and renders to something the JSON encoder accepts. `json:encode/1`
%% raises on a term it cannot represent, so this is the real oracle rather than
%% an inspection of the rendered shape.
every_shipped_entry_encodes_test() ->
    Entries = [bondy_task_api:render(E) || E <- bondy_task_catalogue:list()],
    %% Vacuity guard: an empty catalogue would pass trivially.
    ?assert(length(Entries) >= 10),
    _ = [?assert(is_binary(iolist_to_binary(json:encode(E)))) || E <- Entries],
    ok.
