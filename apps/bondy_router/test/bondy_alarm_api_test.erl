%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% EUnit coverage for `bondy_alarm_api`'s rendering — the part that has to hold
%% for terms nobody anticipated.
%%
%% An alarm's description and details are whatever its producer put there:
%% `bondy_http_connector_http_pool` stores `reason => LastError`, which has held
%% tuples. If one of those reached the encoder the caller's session would die
%% while asking about a fault somewhere else, so every test below is aimed at
%% that: hand the renderer a term the wire cannot carry and assert the result
%% still encodes.
%%
%% The inputs are built by driving `bondy_alarm_handler` rather than by writing
%% alarm maps here, so a field added to the record is rendered by these tests
%% without anyone remembering to update them.
-module(bondy_alarm_api_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% TESTS — the wire form of an id
%% =============================================================================

atom_id_renders_as_its_name_test() ->
    ?assertEqual(~"bondy_db_main_unavailable", wire(bondy_db_main_unavailable)).

tuple_id_renders_as_a_list_test() ->
    ?assertEqual(
        [~"mail_relay_down", ~"smtp"], wire({mail_relay_down, ~"smtp"})
    ).

%% The three-element MCP collision id, which is what makes the wire form a list
%% rather than a `Head/Discriminator` string: a string form would have to pick
%% a separator, and a realm URI already contains dots.
three_element_id_renders_as_a_three_element_list_test() ->
    ?assertEqual(
        [~"bondy_mcp_name_collision", ~"com.example", ~"dup"],
        wire({bondy_mcp_name_collision, ~"com.example", ~"dup"})
    ).

%% =============================================================================
%% TESTS — encodability
%% =============================================================================

%% The load-bearing one. A tuple, a pid and a ref in the details map are all
%% terms JSON cannot carry; each must arrive as a printed binary rather than
%% reaching the encoder.
non_encodable_terms_are_rendered_test() ->
    A = alarm(?FUNCTION_NAME, ~"desc", #{
        details => #{
            reason => {error, econnrefused},
            owner => self(),
            marker => make_ref()
        }
    }),
    R = bondy_alarm_api:render_alarm(A),
    Details = maps:get(~"details", R),
    ?assertEqual(~"{error,econnrefused}", maps:get(~"reason", Details)),
    ?assert(is_binary(maps:get(~"owner", Details))),
    ?assert(is_binary(maps:get(~"marker", Details))),
    ?assert(encodes(R)).

%% A description that is itself a term, not a binary — `bondy_oplog_applier`
%% passes a MAP as its description and the HTTP connector passes one holding
%% the last error.
map_description_with_a_tuple_inside_encodes_test() ->
    A = alarm(?FUNCTION_NAME, #{service => ~"billing", reason => {tcp, closed}}),
    R = bondy_alarm_api:render_alarm(A),
    ?assertEqual(
        ~"{tcp,closed}", maps:get(~"reason", maps:get(~"description", R))
    ),
    ?assert(encodes(R)).

%% Every key on the wire is a binary, whatever the producer used.
keys_are_binaries_test() ->
    A = alarm(?FUNCTION_NAME, ~"desc", #{details => #{some_atom_key => 1}}),
    R = bondy_alarm_api:render_alarm(A),
    ?assert(lists:all(fun is_binary/1, maps:keys(R))),
    ?assert(
        lists:all(fun is_binary/1, maps:keys(maps:get(~"details", R)))
    ).

%% Numbers and booleans stay themselves — rendering them as strings would make
%% `raised_at` unusable for arithmetic and `affects_ready` unusable as a filter.
numbers_and_booleans_survive_test() ->
    A = alarm(?FUNCTION_NAME, ~"desc", #{}),
    R = bondy_alarm_api:render_alarm(A),
    ?assert(is_integer(maps:get(~"raised_at", R))),
    ?assertEqual(false, maps:get(~"affects_ready", R)),
    ?assert(encodes(R)).

%% A charlist becomes a string. Without this an `io_lib:format/2` result left
%% unflattened would arrive as an array of code points.
charlist_renders_as_a_string_test() ->
    A = alarm(?FUNCTION_NAME, ~"desc", #{details => #{note => "cannot open"}}),
    R = bondy_alarm_api:render_alarm(A),
    ?assertEqual(
        ~"cannot open", maps:get(~"note", maps:get(~"details", R))
    ).

%% `[]` stays a list. It far more often means "no elements" than "empty
%% string", and rendering it as `""` would make an empty list of anything read
%% as a string on the wire.
empty_list_stays_a_list_test() ->
    A = alarm(?FUNCTION_NAME, ~"desc", #{details => #{peers => []}}),
    R = bondy_alarm_api:render_alarm(A),
    ?assertEqual([], maps:get(~"peers", maps:get(~"details", R))).

%% =============================================================================
%% TESTS — the other two renderings
%% =============================================================================

catalogue_renders_and_encodes_test() ->
    Entries = [
        bondy_alarm_api:render_entry(E)
     || E <- bondy_alarm_catalogue:list()
    ],
    ?assertEqual(9, length(Entries)),
    ?assert(encodes(#{~"entries" => Entries})),
    %% The wildcard survives into the wire form: an operator reading the
    %% catalogue must be able to see WHICH element varies per instance.
    [Conn] = [
        E
     || #{~"id_pattern" := [~"http_connector_service_down" | _]} = E <- Entries
    ],
    ?assertEqual(
        [~"http_connector_service_down", ~"_"], maps:get(~"id_pattern", Conn)
    ),
    ?assertEqual(~"integration", maps:get(~"class", Conn)).

history_event_renders_and_encodes_test() ->
    {ok, S0} = bondy_alarm_handler:init([]),
    {ok, S1} = bondy_alarm_handler:handle_event(
        {set_alarm, {{mail_relay_down, ~"smtp"}, ~"down"}}, S0
    ),
    {ok, [Event], S1} = bondy_alarm_handler:handle_call(history, S1),
    R = bondy_alarm_api:render_event(Event),
    ?assertEqual([~"mail_relay_down", ~"smtp"], maps:get(~"id", R)),
    ?assertEqual(~"raised", maps:get(~"action", R)),
    ?assertEqual(~"major", maps:get(~"severity", R)),
    ?assert(encodes(R)).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
wire(Id) ->
    bondy_alarm_api:wire_id(Id).

%% @private
alarm(Id, Desc) ->
    alarm(Id, Desc, #{}).

%% @private
%% Built by the handler so the renderer is fed a real record.
alarm(Id, Desc, Opts) ->
    {ok, S0} = bondy_alarm_handler:init([]),
    {ok, S1} = bondy_alarm_handler:handle_event(
        {set_alarm, {Id, Desc, Opts}}, S0
    ),
    {ok, [Alarm], S1} = bondy_alarm_handler:handle_call(list, S1),
    Alarm.

%% @private
%% The actual contract: not "looks encodable" but "the encoder accepts it".
encodes(Term) ->
    is_binary(iolist_to_binary(json:encode(Term))).
