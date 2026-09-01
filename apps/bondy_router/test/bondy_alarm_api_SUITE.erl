%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% The `bondy.alarm.*` read API, exercised through `bondy_wamp_api:handle_call/2`
%% rather than by calling `bondy_alarm_api` directly — a direct call would pass
%% with the dispatch clause unwired, which is the one thing that cannot be
%% checked any other way.
%%
%% Alarms are raised through the raw OTP `alarm_handler:set_alarm/1`, the
%% spelling every producer in the tree actually uses, so what these cases see is
%% what an operator sees.
%%
%% Three properties:
%%
%%   * DISPATCH — the four procedures resolve and answer.
%%   * AUTHORITY — a session in an ordinary realm is refused (D4: alarms are an
%%     operator concern; `realm_uri` on an alarm names the affected tenant, it
%%     does not grant that tenant access).
%%   * ENCODABILITY — a reply carrying a producer's arbitrary Erlang term still
%%     encodes. This is the end-to-end form of the contract
%%     `bondy_alarm_api_test` pins on the rendering functions alone.
%%   * PUBLICATION — the `bondy.alarm.{raised,updated,cleared}` topics, whose
%%     whole path is only observable here: the handler emits into
%%     `bondy_event_manager`, `bondy_event_wamp_publisher` demand-gates and
%%     enqueues, `bondy_jobs` runs the closure and `bondy_broker` routes it.
%%     Four processes, none of which can be checked from a unit test.
%% -----------------------------------------------------------------------------
-module(bondy_alarm_api_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.alarm_api_suite">>).

%% A catalogued id, so the reply carries the DECLARED class rather than the
%% handler's constant — `integration`, which differs from the `node` default and
%% is therefore evidence the catalogue join ran.
-define(ALARM_ID, {mail_relay_down, <<"ct_alarm_api">>}).

all() ->
    [
        list_returns_the_envelope,
        get_finds_an_alarm_by_its_wire_id,
        get_of_an_unknown_id_returns_an_empty_envelope,
        history_records_the_raise,
        a_page_that_fits_carries_no_cursor,
        a_limit_smaller_than_the_ring_pages,
        a_junk_cursor_is_refused,
        pagination_reads_both_kwarg_spellings,
        every_page_reports_the_nodes_it_did_not_reach,
        a_cursor_naming_a_node_that_left_walks_past_it,
        a_cursor_whose_head_left_restarts_that_position,
        a_progressive_call_streams_every_page,
        a_progressive_call_settles_exactly_once,
        a_stream_stops_at_the_deadline,
        a_stream_with_time_left_runs_to_the_end,
        catalogue_lists_every_declared_entry,
        catalogue_entries_carry_their_runbook,
        an_alarm_carries_its_catalogue_join_key,
        every_procedure_requires_the_master_realm,
        replies_encode_with_a_non_encodable_detail,
        no_subscriber_means_no_demand,
        raise_and_clear_reach_a_subscriber,
        only_a_real_change_publishes_an_update
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    R = bondy_realm:create(?REALM),
    ok = bondy_realm:disable_security(R),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

end_per_testcase(_, Config) ->
    ok = alarm_handler:clear_alarm(?ALARM_ID),
    Config.

%% =============================================================================
%% CASES
%% =============================================================================

%% The reply is an envelope, not a bare array: `nodes.answered` and
%% `nodes.silent` are what let a caller tell "this node has no alarms" from
%% "this node did not answer" once the fan-out lands.
list_returns_the_envelope(_) ->
    ok = raise(<<"relay is down">>),
    #{<<"alarms">> := Alarms, <<"nodes">> := Nodes} = call(
        ?MASTER_REALM_URI, list
    ),

    %% The envelope names its nodes with `atom_to_binary(partisan:node())`
    %% while each alarm is stamped with `partisan:nodestring()`. They must be
    %% the same string or the two halves of the reply cannot be joined.
    ?assertEqual([partisan:nodestring()], maps:get(<<"answered">>, Nodes)),
    ?assertEqual([], maps:get(<<"silent">>, Nodes)),

    [A] = [X || X <- Alarms, maps:get(<<"id">>, X) == wire_id()],
    ?assertEqual(<<"relay is down">>, maps:get(<<"description">>, A)),
    ?assertEqual(partisan:nodestring(), maps:get(<<"node">>, A)),
    %% The catalogue join, end to end: the producer raised through the OTP
    %% 2-tuple and named no class, so `integration` can only have come from
    %% `bondy_alarm_catalogue`.
    ?assertEqual(<<"integration">>, maps:get(<<"class">>, A)),
    ?assertEqual(<<"major">>, maps:get(<<"severity">>, A)),
    ?assertEqual(false, maps:get(<<"affects_ready">>, A)).

%% `get` answers with the same envelope as `list`, filtered — an alarm id can
%% be raised on several nodes at once, so the question is WHERE the condition
%% holds, not whether one node has it.
get_finds_an_alarm_by_its_wire_id(_) ->
    ok = raise(<<"relay is down">>),
    #{<<"alarms">> := [A], <<"nodes">> := Nodes} =
        call(?MASTER_REALM_URI, get, [wire_id()]),
    ?assertEqual(wire_id(), maps:get(<<"id">>, A)),
    ?assertEqual(<<"integration">>, maps:get(<<"class">>, A)),
    ?assertEqual([], maps:get(<<"silent">>, Nodes)).

%% A miss is an ordinary empty result, NOT an error. Once the answer can be
%% partial, "no active alarm with that id" stops being a fact the router can
%% assert — it is only true of the nodes that answered, and `silent` is what
%% says so. An error would state the opposite, and would put a normal question
%% ("is this still up?") on an agent's exception path.
get_of_an_unknown_id_returns_an_empty_envelope(_) ->
    #{<<"alarms">> := Alarms, <<"nodes">> := Nodes} =
        call(?MASTER_REALM_URI, get, [[<<"no_such_alarm">>, <<"x">>]]),
    ?assertEqual([], Alarms),
    %% Nothing silent, so on this cluster the empty result IS definitive.
    ?assertEqual([], maps:get(<<"silent">>, Nodes)),
    ?assertEqual([partisan:nodestring()], maps:get(<<"answered">>, Nodes)).

%% History is a PAGE, in the same shape every paginated `bondy.*` procedure
%% answers (`bondy_pagination:to_external/1`): `values`, `has_more`, and a
%% `cursor` only when there is more. Each event names the node whose ring
%% recorded it, because a page mixes rings.
history_records_the_raise(_) ->
    ok = raise(<<"relay is down">>),
    Page = call(?MASTER_REALM_URI, history),
    Events = maps:get(<<"values">>, Page),
    ?assert(is_boolean(maps:get(<<"has_more">>, Page))),
    Mine = [E || E <- Events, maps:get(<<"id">>, E) == wire_id()],
    ?assertMatch([_ | _], Mine),
    First = hd(Mine),
    ?assertEqual(<<"raised">>, maps:get(<<"action">>, First)),
    ?assertEqual(partisan:nodestring(), maps:get(<<"node">>, First)),
    ?assert(is_integer(maps:get(<<"seq">>, First))).

%% The whole page fits on one node here, so the walk must not have contacted a
%% peer to build it — the property the node-at-a-time order exists for. On a
%% single-node cluster there is no peer to contact, so what this actually pins
%% is the shape that makes it possible: a final page carries NO cursor.
a_page_that_fits_carries_no_cursor(_) ->
    ok = raise(<<"relay is down">>),
    Page = call(?MASTER_REALM_URI, history),
    ?assertEqual(false, maps:get(<<"has_more">>, Page)),
    ?assertEqual(error, maps:find(<<"cursor">>, Page)).

%% A limit smaller than the ring produces a cursor, and resuming from it
%% returns DIFFERENT events — the keyset walks downwards rather than repeating
%% the first page.
a_limit_smaller_than_the_ring_pages(_) ->
    _ = [
        raise(<<"relay is down ", (integer_to_binary(I))/binary>>)
     || I <- lists:seq(1, 4)
    ],
    Page1 = call_kw(?MASTER_REALM_URI, history, #{~"limit" => 2}),
    ?assertEqual(2, length(maps:get(<<"values">>, Page1))),
    ?assertEqual(true, maps:get(<<"has_more">>, Page1)),
    Cursor = maps:get(<<"cursor">>, Page1),
    ?assert(is_binary(Cursor)),

    Page2 = call_kw(
        ?MASTER_REALM_URI, history, #{~"limit" => 2, ~"cursor" => Cursor}
    ),
    Seqs1 = [maps:get(<<"seq">>, E) || E <- maps:get(<<"values">>, Page1)],
    Seqs2 = [maps:get(<<"seq">>, E) || E <- maps:get(<<"values">>, Page2)],
    ?assertEqual(
        [],
        ordsets:intersection(
            ordsets:from_list(Seqs1), ordsets:from_list(Seqs2)
        )
    ),
    %% Newest first across pages, not just within one.
    ?assert(lists:min(Seqs1) > lists:max(Seqs2)).

%% KWArgs reach a handler with BINARY keys from the wire and ATOM keys from an
%% internal caller, and the cases above use only the binary spelling. Without
%% this one the atom clause of `bondy_wamp_api_utils:kwarg/4` is dead code that
%% looks alive.
pagination_reads_both_kwarg_spellings(_) ->
    _ = [
        raise(<<"relay is down ", (integer_to_binary(I))/binary>>)
     || I <- lists:seq(1, 3)
    ],
    Atom = call_kw(?MASTER_REALM_URI, history, #{limit => 1}),
    Bin = call_kw(?MASTER_REALM_URI, history, #{~"limit" => 1}),
    ?assertEqual(1, length(maps:get(<<"values">>, Atom))),
    ?assertEqual(1, length(maps:get(<<"values">>, Bin))),
    %% Same page either way, so the two spellings cannot mean different things.
    ?assertEqual(
        maps:get(<<"values">>, Atom), maps:get(<<"values">>, Bin)
    ).

%% `not_reached` is on EVERY page, empty or not. A key that only appeared when
%% something had gone wrong would have to be known about in advance to be
%% missed, and the caller that most needs it is the one that has never seen it.
every_page_reports_the_nodes_it_did_not_reach(_) ->
    ok = raise(<<"relay is down">>),
    Page = call(?MASTER_REALM_URI, history),
    ?assertEqual([], maps:get(<<"not_reached">>, Page)).

%% A cursor names the nodes still to walk, and a node can LEAVE between pages.
%% It is walked past rather than contacted, and it is not reported: nothing
%% failed, and history is never replicated, so a departing node takes its ring
%% with it. Naming it would send an operator to look at a node that is gone.
%%
%% One node cannot make a member leave, so the walk is pointed at a node that
%% was never a member — which is the state a resumed cursor is in once one has
%% departed.
a_cursor_naming_a_node_that_left_walks_past_it(_) ->
    _ = [
        raise(<<"relay is down ", (integer_to_binary(I))/binary>>)
     || I <- lists:seq(1, 3)
    ],
    Page1 = call_kw(?MASTER_REALM_URI, history, #{~"limit" => 1}),
    Reroute = reroute(Page1, [partisan:node(), 'ghost@nowhere']),

    Page2 = call_kw(?MASTER_REALM_URI, history, #{~"cursor" => Reroute}),

    ?assert(length(maps:get(<<"values">>, Page2)) > 0),
    ?assertEqual([], maps:get(<<"not_reached">>, Page2)),
    %% Walked out, so the walk is over — the ghost is not left for a next page.
    ?assertEqual(false, maps:get(<<"has_more">>, Page2)).

%% The cursor's `after_seq` is a position in the HEAD node's ring. When the
%% head has left, that position dies with it: carrying it onto the next node
%% would filter THAT node's ring by a sequence number minted on another one,
%% and the transitions it skipped would never be reported missing.
%%
%% The falsifier is the newest event. Resuming a cursor whose head has left
%% must hand it back — the surviving node's walk starts at the top — where
%% keeping the stale position would silently begin below it.
a_cursor_whose_head_left_restarts_that_position(_) ->
    _ = [
        raise(<<"relay is down ", (integer_to_binary(I))/binary>>)
     || I <- lists:seq(1, 3)
    ],
    Page1 = call_kw(?MASTER_REALM_URI, history, #{~"limit" => 1}),
    Newest = maps:get(<<"values">>, Page1),

    %% `after_seq` in this cursor is the newest event's own seq, and the head
    %% it belongs to is about to be replaced.
    Reroute = reroute(Page1, ['ghost@nowhere', partisan:node()]),
    Page2 = call_kw(
        ?MASTER_REALM_URI, history, #{~"limit" => 1, ~"cursor" => Reroute}
    ),
    ?assertEqual(Newest, maps:get(<<"values">>, Page2)).

%% A cursor this procedure did not mint is refused rather than paged wrongly.
%% It cannot be guessed, so unlike `limit` it has no tolerant fallback.
a_junk_cursor_is_refused(_) ->
    E = call_error(?MASTER_REALM_URI, history, #{
        ~"cursor" => <<"not-a-cursor">>
    }),
    ?assertEqual(?WAMP_INVALID_ARGUMENT, E#error.error_uri).

%% A progressive stream is bounded by the caller's `_deadline`. That is what
%% the option is FOR: the WAMP call timeout is, for a progressive call, an
%% inactivity window that every chunk restarts, so without this a
%% slowly-dripping stream is unbounded.
%%
%% Driven through `stream_pages/3` with a SYNTHETIC pager rather than through
%% the alarm history, for the one reason a real one cannot serve: the property
%% is about ELAPSED TIME and a local ring answers in microseconds. A pager that
%% takes 50ms a page against a 100ms deadline makes the outcome a fact rather
%% than a race. `bondy.alarm.history` is that loop's only caller today, which
%% is why its suite is where the loop is tested.
a_stream_stops_at_the_deadline(_) ->
    {M, Ctxt} = stream_call(#{'_deadline' => 100}),
    ?assertEqual(
        {error, stream_deadline_exceeded},
        bondy_wamp_api_utils:stream_pages(M, Ctxt, endless_pager(50))
    ),
    %% It STOPPED rather than never starting: the first page always runs, so a
    %% spent deadline shortens a stream and cannot empty one.
    Results = drain_results(),
    ?assertMatch([_ | _], Results),
    _ = [
        ?assertMatch([_ | _], maps:get(<<"values">>, P))
     || #result{args = [P]} <- Results
    ],
    %% And every chunk it did send was progressive. The ERROR is what settles
    %% the call, so none of them may have claimed to be the last — a final
    %% chunk plus an error would settle it twice.
    ?assertEqual(
        [],
        [
            D
         || #result{details = D} <- Results,
            maps:get(progress, D, false) /= true
        ]
    ).

%% The falsifier for the case above: the same loop and the same kind of pager,
%% with a deadline it fits inside, runs to completion. Without this a
%% `stream_pages/3` that gave up unconditionally would pass.
a_stream_with_time_left_runs_to_the_end(_) ->
    {M, Ctxt} = stream_call(#{'_deadline' => 60000}),
    ?assertEqual(ok, bondy_wamp_api_utils:stream_pages(M, Ctxt, pager(3))),
    ?assertEqual(3, length(drain_results())).

%% The catalogue is served whole. An operator writing alert rules needs it
%% BEFORE an alarm has ever fired, which is the point of declaring it.
catalogue_lists_every_declared_entry(_) ->
    #{<<"entries">> := Entries} = call(?MASTER_REALM_URI, catalogue),
    ?assertEqual(length(bondy_alarm_catalogue:list()), length(Entries)),
    [Relay] = [
        E
     || #{<<"id_pattern">> := [<<"mail_relay_down">> | _]} = E <- Entries
    ],
    ?assertEqual(<<"integration">>, maps:get(<<"class">>, Relay)),
    ?assertMatch([_ | _], maps:get(<<"config_keys">>, Relay)).

%% The runbook join (design §9): the entry names what to look at and what may
%% be done. Asserted on the WIRE because the fields are only useful if they
%% survive rendering — `observe_with` is a list of maps mixing binary and atom refs,
%% which is exactly the shape a renderer flattens by accident.
catalogue_entries_carry_their_runbook(_) ->
    #{<<"entries">> := Entries} = call(?MASTER_REALM_URI, catalogue),
    [Relay] = [
        E
     || #{<<"id_pattern">> := [<<"mail_relay_down">> | _]} = E <- Entries
    ],
    ?assertEqual([<<"bondy.mail.test">>], maps:get(<<"tasks">>, Relay)),
    Signals = maps:get(<<"observe_with">>, Relay),
    ?assert(
        lists:member(
            #{
                <<"kind">> => <<"metric">>,
                <<"ref">> => <<"bondy_mail_relay_up">>
            },
            Signals
        )
    ),
    ?assert(
        lists:member(
            #{
                <<"kind">> => <<"procedure">>,
                <<"ref">> => <<"bondy.mail.status.get">>
            },
            Signals
        )
    ).

%% The join KEY. A raised alarm's id is concrete and its catalogue entry is a
%% pattern, so an agent holding an alarm needs something to look the entry up
%% by. Without this it would have to re-implement the catalogue's own matching,
%% which is what the runbook exists to spare it.
an_alarm_carries_its_catalogue_join_key(_) ->
    ok = raise(<<"relay is down">>),
    #{<<"alarms">> := [A]} = call(?MASTER_REALM_URI, get, [wire_id()]),
    Key = maps:get(<<"catalogue_id">>, A),
    #{<<"entries">> := Entries} = call(?MASTER_REALM_URI, catalogue),
    [Entry] = [E || #{<<"id_pattern">> := P} = E <- Entries, P == Key],
    %% End to end: alarm -> its entry -> the task -> that task's own record.
    [Task] = maps:get(<<"tasks">>, Entry),
    ?assertMatch({ok, #{}}, bondy_task_catalogue:lookup(Task)).

%% D4. Every one of the four, because an authority check that covers three
%% procedures and misses the fourth is the usual shape of this bug.
every_procedure_requires_the_master_realm(_) ->
    ok = raise(<<"relay is down">>),
    lists:foreach(
        fun({Proc, Args}) ->
            E = call_error(?REALM, Proc, Args),
            ?assertEqual(
                ?WAMP_NOT_AUTHORIZED, E#error.error_uri, {not_refused, Proc}
            )
        end,
        [
            {list, []},
            {get, [wire_id()]},
            {history, []},
            {catalogue, []}
        ]
    ).

%% The producers put arbitrary terms in a description. `{tcp, closed}` cannot
%% be encoded, and an encoder raising here would kill the session of whoever
%% asked what was wrong.
replies_encode_with_a_non_encodable_detail(_) ->
    ok = alarm_handler:set_alarm(
        {?ALARM_ID, #{relay => <<"ct_alarm_api">>, reason => {tcp, closed}}}
    ),
    Envelope = call(?MASTER_REALM_URI, list),
    [A] = [
        X
     || X <- maps:get(<<"alarms">>, Envelope),
        maps:get(<<"id">>, X) == wire_id()
    ],
    ?assertEqual(
        <<"{tcp,closed}">>,
        maps:get(<<"reason">>, maps:get(<<"description">>, A))
    ),
    ?assert(is_binary(iolist_to_binary(json:encode(Envelope)))).

%% The predicate the gate reads, in both directions. With nothing subscribed
%% an alarm transition costs one registry probe and stops.
%%
%% WHAT THIS DOES NOT COVER: that the publisher actually consults it. A gate
%% removed from `bondy_event_wamp_publisher` publishes into a realm where
%% nobody is listening, which no observer can distinguish from not publishing
%% — the gate buys cost, not behaviour, and cost is not assertable here.
no_subscriber_means_no_demand(_) ->
    Probe = fun(Topic) ->
        bondy_registry:has_matches(subscription, ?MASTER_REALM_URI, Topic)
    end,
    ?assertNot(Probe(?BONDY_ALARM_RAISED)),
    ?assertNot(Probe(?BONDY_ALARM_CLEARED)),

    {ok, SubId} = subscribe(?BONDY_ALARM_RAISED),
    ?assert(Probe(?BONDY_ALARM_RAISED)),
    %% Per topic, not per prefix: a subscriber to `raised` does not make
    %% `cleared` demanded.
    ?assertNot(Probe(?BONDY_ALARM_CLEARED)),

    ok = unsubscribe([SubId]),
    ?assertNot(Probe(?BONDY_ALARM_RAISED)).

%% The payload is the same map `bondy.alarm.get` returns — an agent that
%% reacts to the event acts on it without a second call.
raise_and_clear_reach_a_subscriber(_) ->
    {ok, Raised} = subscribe(?BONDY_ALARM_RAISED),
    {ok, Cleared} = subscribe(?BONDY_ALARM_CLEARED),

    ok = raise(<<"relay is down">>),
    [Alarm] = (await_event(Raised))#event.args,
    ?assertEqual(wire_id(), maps:get(<<"id">>, Alarm)),
    ?assertEqual(<<"relay is down">>, maps:get(<<"description">>, Alarm)),
    %% The catalogue join reaches the topic too, not just the read API.
    ?assertEqual(<<"integration">>, maps:get(<<"class">>, Alarm)),
    ?assertEqual(partisan:nodestring(), maps:get(<<"node">>, Alarm)),

    ok = alarm_handler:clear_alarm(?ALARM_ID),
    [Gone] = (await_event(Cleared))#event.args,
    ?assertEqual(wire_id(), maps:get(<<"id">>, Gone)),
    %% Carried, so a subscriber can tell a resolved page from a resolved
    %% in-hours warning.
    ?assertEqual(<<"major">>, maps:get(<<"severity">>, Gone)),

    ok = unsubscribe([Raised, Cleared]).

%% `bondy_oplog_responder` restates its alarm once per offending item. If a
%% restatement published, one bad sync would emit thousands of identical
%% events — so the topics fire on exactly the transitions the history ring
%% records, and this walks all three.
only_a_real_change_publishes_an_update(_) ->
    {ok, Raised} = subscribe(?BONDY_ALARM_RAISED),
    {ok, Updated} = subscribe(?BONDY_ALARM_UPDATED),

    ok = raise(<<"first">>),
    _ = await_event(Raised),

    ok = raise(<<"first">>),
    ok = raise(<<"first">>),
    ?assertEqual(timeout, next_event(1000)),

    ok = raise(<<"second">>),
    [Alarm] = (await_event(Updated))#event.args,
    ?assertEqual(<<"second">>, maps:get(<<"description">>, Alarm)),

    ok = unsubscribe([Raised, Updated]).

%% The other delivery of the same walk. A caller that announced
%% `progressive_call_results` gets every page as a RESULT of its own and never
%% handles a cursor — same pager, so the two modes cannot disagree about what
%% the history IS.
%%
%% Driven with a limit of 1 against a ring holding several transitions, so the
%% stream is genuinely multi-chunk rather than one result wearing a flag.
a_progressive_call_streams_every_page(_) ->
    _ = [
        raise(<<"down ", (integer_to_binary(I))/binary>>)
     || I <- lists:seq(1, 4)
    ],
    _ = bondy_alarm_handler:list(),

    ok = progressive_call(#{~"limit" => 1}),
    Results = drain_results(),

    %% Every chunk but the last carries `progress`, and the last does not —
    %% that is what settles the call exactly once.
    Progress = [
        maps:get(progress, D, false)
     || #result{details = D} <- Results
    ],
    ?assert(length(Results) >= 3),
    ?assertEqual(
        lists:duplicate(length(Results) - 1, true) ++ [false], Progress
    ),

    %% One shape in both modes: `values` and `has_more`, no cursor. And
    %% `not_reached` on EVERY chunk — a progressive caller never handles a
    %% cursor, so a chunk is the only place it can learn a node went unasked.
    _ = [
        begin
            ?assert(is_list(maps:get(<<"values">>, P))),
            ?assert(is_boolean(maps:get(<<"has_more">>, P))),
            ?assertEqual([], maps:get(<<"not_reached">>, P)),
            ?assertEqual(error, maps:find(<<"cursor">>, P))
        end
     || #result{args = [P]} <- Results
    ],

    %% And the stream carries the same events the paged mode would: the ids
    %% this case raised are all there, newest first.
    Seqs = [
        maps:get(<<"seq">>, E)
     || #result{args = [P]} <- Results, E <- maps:get(<<"values">>, P)
    ],
    ?assertEqual(lists:reverse(lists:sort(Seqs)), Seqs).

%% The falsifier for the flag above: with nothing to page, the single result
%% must be FINAL. A loop that always sent a progressive chunk before the final
%% one would leave the call settled correctly but the caller reading a chunk
%% that was the whole answer.
a_progressive_call_settles_exactly_once(_) ->
    ok = raise(<<"relay is down">>),
    _ = bondy_alarm_handler:list(),

    ok = progressive_call(#{~"limit" => 1000}),
    [#result{details = Details, args = [Page]}] = drain_results(),
    ?assertEqual(false, maps:get(progress, Details, false)),
    ?assertEqual(false, maps:get(<<"has_more">>, Page)).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% A CALL asking for progressive results, and a context whose ref is this
%% process, so `stream_pages/3` delivers its chunks here.
stream_call(Options) ->
    Ref = bondy_ref:new(internal, self(), bondy_session_id:new()),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, Ref),
    M = bondy_wamp_message:call(
        1, Options#{receive_progress => true}, uri(history), []
    ),
    {M, Ctxt}.

%% @private
%% A pager that takes `Millis` per page and NEVER finishes. Only a bound
%% outside it can end this stream, which is the point.
endless_pager(Millis) ->
    fun(_Cursor) ->
        timer:sleep(Millis),
        {ok,
            bondy_pagination:result(
                [#{~"n" => 1}], bondy_pagination:new_cursor(~"ct", next)
            )}
    end.

%% @private
%% A pager with exactly `N` pages, the last reporting `has_more => false`.
pager(N) ->
    fun
        (undefined) -> {ok, test_page(N - 1)};
        (Cursor) -> {ok, test_page(bondy_pagination:payload(Cursor))}
    end.

%% @private
test_page(0) ->
    bondy_pagination:result([#{~"n" => 0}], undefined);
test_page(Left) ->
    bondy_pagination:result(
        [#{~"n" => Left}], bondy_pagination:new_cursor(~"ct", Left - 1)
    ).

%% @private
%% A CALL carrying `receive_progress`, dispatched with this process as the
%% caller's ref so the RESULTs land in this mailbox. `bondy_wamp_api:handle_call/2`
%% is entered DIRECTLY, which is what makes this a test of the static-callback
%% streaming path: `bondy_dealer:do_forward/2` would have stripped
%% `receive_progress` unless a real session had announced the feature in HELLO.
progressive_call(KWArgs) ->
    progressive_call(KWArgs, #{}).

progressive_call(KWArgs, Options) ->
    Ref = bondy_ref:new(internal, self(), bondy_session_id:new()),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI, Ref),
    %% `receive_progress` stays a CALL OPTION — it IS a router-level
    %% instruction about how the reply is delivered, as `_deadline` is. `limit`
    %% is a KWArg, because it is an argument to the procedure. The two live in
    %% different places on purpose.
    M = bondy_wamp_message:call(
        1, Options#{receive_progress => true}, uri(history), [], KWArgs
    ),
    ok = bondy_wamp_api:handle_call(M, Ctxt),
    ok.

%% @private
%% Every RESULT already in the mailbox, in arrival order. The stream is sent
%% synchronously by `stream_pages/3` before `handle_call/2` returns, so nothing
%% is still in flight by the time this runs.
drain_results() ->
    drain_results([]).

%% @private
drain_results(Acc) ->
    receive
        {?BONDY_REQ, _, ?MASTER_REALM_URI, #result{} = R} ->
            drain_results([R | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

%% @private
%% An internal (pid) subscription in the master realm: events arrive as Bondy
%% requests in this process's mailbox.
subscribe(Topic) ->
    Ref = bondy_ref:new(internal, self(), bondy_session_id:new()),
    bondy_broker:subscribe(?MASTER_REALM_URI, #{}, Topic, Ref).

%% @private
unsubscribe(Ids) ->
    lists:foreach(
        fun(Id) -> ok = bondy_broker:unsubscribe(Id, ?MASTER_REALM_URI) end, Ids
    ),
    %% Drop anything still in flight, so the next case starts clean.
    _ = next_event(0),
    ok.

%% @private
%% The publish runs in a `bondy_jobs` worker, so it is asynchronous with
%% respect to the `set_alarm` cast that caused it.
await_event(SubId) ->
    case next_event(5000) of
        #event{subscription_id = SubId} = E -> E;
        Other -> ct:fail({unexpected_event, SubId, Other})
    end.

%% @private
next_event(Timeout) ->
    receive
        {?BONDY_REQ, _, ?MASTER_REALM_URI, #event{} = E} -> E
    after Timeout -> timeout
    end.

%% @private
%% `Page`'s cursor, re-minted to walk `Nodes` instead. One node cannot produce
%% an unreachable peer, and the node list lives IN THE CURSOR — which is also
%% the state a walk reaches when a member goes away mid-walk.
%%
%% The fingerprint and the rest of the payload come from a REAL cursor rather
%% than being restated, so this keeps working — and keeps meaning the same
%% thing — when `?HISTORY_FP` is bumped or the payload grows a field.
reroute(Page, Nodes) ->
    C = binary_to_term(base64:decode(maps:get(<<"cursor">>, Page)), [safe]),
    bondy_pagination:encode_cursor(
        bondy_pagination:new_cursor(
            bondy_pagination:fingerprint(C),
            (bondy_pagination:payload(C))#{nodes => Nodes}
        )
    ).

%% @private
%% `alarm_handler:set_alarm/1` is a cast, but `bondy_alarm_handler:list/0` is a
%% `gen_event:call` to the same manager from the same process, so the raise is
%% already applied when the API reads. No sleep, and nothing to flake on.
raise(Desc) ->
    alarm_handler:set_alarm({?ALARM_ID, Desc}).

%% @private
wire_id() ->
    bondy_alarm_api:wire_id(?ALARM_ID).

%% @private
uri(list) -> <<"bondy.alarm.list">>;
uri(get) -> <<"bondy.alarm.get">>;
uri(history) -> <<"bondy.alarm.history">>;
uri(catalogue) -> <<"bondy.alarm.catalogue">>.

%% @private
%% Through the dispatcher, so the `bondy.alarm.` clause in
%% `bondy_wamp_api:do_handle_call/3` is exercised by every call.
handle(RealmUri, Proc, Args) ->
    handle(RealmUri, Proc, Args, #{}).

%% @private
handle(RealmUri, Proc, Args, Options) ->
    handle(RealmUri, Proc, Args, Options, #{}).

%% @private
%% `KWArgs` carries the pagination knobs (`limit`, `cursor`). They are
%% ARGUMENTS to the procedure, not CALL options: Bondy is the callee for
%% `bondy.*`, and the option form never reached a callee at all.
handle(RealmUri, Proc, Args, Options, KWArgs) ->
    Ctxt = bondy_context:local_context(RealmUri),
    M = bondy_wamp_message:call(1, Options, uri(Proc), Args, KWArgs),
    bondy_wamp_api:handle_call(M, Ctxt).

%% @private
call(RealmUri, Proc) ->
    call(RealmUri, Proc, []).

%% @private
call(RealmUri, Proc, Args) ->
    case handle(RealmUri, Proc, Args) of
        {reply, #result{args = [Reply]}} -> Reply;
        Other -> ct:fail({expected_result, Proc, Other})
    end.

%% @private
call_kw(RealmUri, Proc, KWArgs) ->
    case handle(RealmUri, Proc, [], #{}, KWArgs) of
        {reply, #result{args = [Reply]}} -> Reply;
        Other -> ct:fail({expected_result, Proc, Other})
    end.

%% @private
%% The unauthorized path THROWS the error rather than returning it, which is
%% how `bondy_wamp_api_utils:admin_call_args/3` reports refusal.
call_error(RealmUri, Proc, Args) when is_list(Args) ->
    try handle(RealmUri, Proc, Args) of
        {reply, #error{} = E} -> E;
        Other -> ct:fail({expected_error, Proc, Other})
    catch
        error:#error{} = E -> E
    end;
call_error(RealmUri, Proc, KWArgs) when is_map(KWArgs) ->
    try handle(RealmUri, Proc, [], #{}, KWArgs) of
        {reply, #error{} = E} -> E;
        Other -> ct:fail({expected_error, Proc, Other})
    catch
        error:#error{} = E -> E
    end.
