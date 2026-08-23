#!/usr/bin/env escript
%% -*- erlang -*-
%%! -hidden
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% bondy.conf MIGRATION tool.
%%
%%     migrate_conf.escript check    <conf-file> [--schema-dir DIR]...
%%     migrate_conf.escript migrate  <conf-file> --out FILE [--schema-dir DIR]...
%%     migrate_conf.escript selftest [--schema-dir DIR]...
%%
%% `check' reports every key in a `bondy.conf' that this release no longer reads,
%% every key it reads but whose VALUE it cannot parse, every key it still reads
%% but reads DIFFERENTLY, which listeners the file will actually start, and any
%% inert `advanced.config' stanza beside it. Nothing is written. `migrate' writes
%% a converted file. `selftest' is the gate -- see the SELFTEST section.
%%
%% WHY THIS EXISTS: neither of the two ways a bondy.conf can be wrong announces
%% itself at boot, and in both cases that is structural rather than an oversight.
%%
%% An unknown KEY is dropped in silence. The generated pre-start hook runs
%% cuttlefish three times against the SAME etc/bondy.conf
%% (`bin/hooks/pre_start_cuttlefish', invocations at lines 10, 28 and 46), each
%% seeing only its own schema set, so every key owned by another set looks
%% unrecognised to the run currently executing. All three therefore pass
%% --allow_extra, and cuttlefish then does nothing at all for a key it cannot
%% find (`cuttlefish_generator.erl:406-411'; the fail-with-suggestion branch at
%% :412-422 is never taken by the release). A stale or renamed key is dropped in
%% silence and the subsystem runs on its default while the operator believes
%% their setting applies.
%%
%% A bad VALUE is worse, and silent for a different reason. Cuttlefish generates
%% all-or-nothing: one value that fails its datatype or a validator abandons the
%% whole run, so no app config is written for ANY key. The same hook passes
%% --silent and does not check the exit status, and `config/prod/sys.config' ends
%% with the include string "etc/generated/user_defined.config" -- so the failure
%% prints nothing and the node boots on the file the last SUCCESSFUL generation
%% left behind. Seen in the field 2026-08-22: a migrated file carrying
%% `wamp.websocket.max_frame_size = infinity' against a `{datatype, bytesize}'
%% mapping brought a node up on default listeners and an earlier run's values,
%% with no diagnostic anywhere. See the VALUES THE SCHEMA REJECTS section.
%%
%% WHAT IT CANNOT SEE: a value that is well-typed and wrong. The same field file
%% set `platform_tmp_dir = /bondy/tmpXX', which is a perfectly good directory
%% string, and no schema check can know it was meant to be `/bondy/tmp'.
%%
%% Note the three invocations use only TWO distinct --schema_dir values: the
%% second and third are identical (`releases/<vsn>/schema/'), because the release
%% copies riak_sysmon's schema in beside the application ones.
%%
%% This tool reuses cuttlefish's OWN parsers rather than reimplementing them, so
%% there is no second implementation to drift: `cuttlefish_conf:file/1' reads the
%% conf, `cuttlefish_schema:files/1' reads the schemas, and
%% `cuttlefish_variable:is_fuzzy_match/2' decides whether a key matches a
%% `$name'-style mapping.
%%
%% It takes the UNION of every mapping in every schema set rather than
%% intersecting per-set complaints as the pre-start hook's three invocations
%% force. Same verdict, reached directly: a key is unknown iff no mapping
%% anywhere matches it, which is what "Bondy does not read this" means.
%%
%% VERIFIED against two corpora, both with an answer established independently of
%% this script: the twelve shipped conf files at HEAD report zero unknown keys,
%% and the seven that existed at 8dd090bf^ report exactly 86 distinct unknown
%% keys across 258 occurrences -- 28 of them the original hand audit, the rest
%% keys the schemas have since dropped (see ?DIRTY_EXPECTED for why the number
%% moved). `selftest' re-runs both, plus the rule-table, no-op, round-trip,
%% listener, changed-meaning and value invariants. The value check is pinned
%% against cuttlefish's own generator rather than a table of expected answers.
%% =============================================================================

-mode(compile).

%% Exit codes. `check' distinguishes "your file has findings" from "this script
%% could not do its job", because a runbook must not read the second as the
%% first.
%% Where a legacy listener's bind port and address live, as mapping-target
%% suffixes tried in order. Re-derived from the schemas' own targets and matching
%% `bondy_listener_manager:legacy_bind/2' and `legacy_ip/2': `ip' has three shapes
%% because a listener's `ip' target and its `ip_version' target are not always the
%% same path.
-define(PORT_TARGETS, ["transport_opts.socket_opts.port", "port"]).
-define(IP_TARGETS, [
    "ip", "transport_opts.ip", "transport_opts.socket_opts.ip"
]).

-define(EXIT_CLEAN, 0).
-define(EXIT_FINDINGS, 1).
-define(EXIT_ERROR, 2).

main(Args) ->
    try
        run(Args)
    catch
        throw:{usage, Msg} ->
            err("~s~n~n~s", [Msg, usage()]),
            halt(?EXIT_ERROR);
        throw:{fail, Fmt, FArgs} ->
            err("error: " ++ Fmt, FArgs),
            halt(?EXIT_ERROR);
        %% A bug in this script must still exit 2, not the 127 an uncaught
        %% escript exception produces: the documented contract is that anything
        %% other than 0 or 1 means "the check did not run", and a caller keying
        %% on that must not have to know about 127. The stack trace is printed
        %% so the bug stays diagnosable.
        Class:Reason:Stack ->
            err("internal error: ~p:~p~n~p", [Class, Reason, Stack]),
            halt(?EXIT_ERROR)
    end.

run(["check", ConfFile | Rest]) ->
    SchemaDirs = parse_schema_dirs(Rest),
    ok = locate_cuttlefish(),
    {KeyFindings, ValueFindings, ListenerFindings} = check(ConfFile, SchemaDirs),
    halt(
        case KeyFindings ++ ValueFindings ++ ListenerFindings of
            [] -> ?EXIT_CLEAN;
            _ -> ?EXIT_FINDINGS
        end
    );
run(["migrate", ConfFile | Rest]) ->
    {Out, SchemaDirs} = parse_migrate_args(Rest),
    ok = locate_cuttlefish(),
    %% The findings are the OUTPUT's, so this answers "is the file I just wrote
    %% deployable" rather than "did the rewrite run". It halted ?EXIT_CLEAN
    %% unconditionally before, which made `migrate && deploy' green on a file
    %% that aborts the boot -- the same conflation the header warns about for
    %% `check', in the mode where it does more damage.
    {KeyFindings, ValueFindings, ListenerFindings} =
        migrate(ConfFile, Out, SchemaDirs),
    halt(
        case KeyFindings ++ ValueFindings ++ ListenerFindings of
            [] -> ?EXIT_CLEAN;
            _ -> ?EXIT_FINDINGS
        end
    );
run(["selftest" | Rest]) ->
    SchemaDirs = parse_schema_dirs(Rest),
    ok = locate_cuttlefish(),
    halt(selftest(SchemaDirs));
run(_) ->
    throw({usage, "unrecognised arguments"}).

usage() ->
    "Usage:\n"
    "  migrate_conf.escript check   <conf-file> [--schema-dir DIR]...\n"
    "  migrate_conf.escript migrate <conf-file> --out FILE [--schema-dir DIR]...\n"
    "  migrate_conf.escript selftest [--schema-dir DIR]...\n"
    "\n"
    "  --out FILE        where to write the converted file. Never written in\n"
    "                    place, and never over an existing file.\n"
    "  --schema-dir DIR  a directory of .schema files; repeatable. When none is\n"
    "                    given the layout is auto-detected (see schema_dirs/0).\n"
    "\n"
    "Exit: 0 clean, 1 findings, 2 the operation could not be performed.\n".

parse_schema_dirs(Args) ->
    parse_schema_dirs(Args, []).

parse_schema_dirs([], Acc) ->
    lists:reverse(Acc);
parse_schema_dirs(["--schema-dir", Dir | Rest], Acc) ->
    parse_schema_dirs(Rest, [Dir | Acc]);
parse_schema_dirs([Other | _], _) ->
    throw({usage, "unrecognised argument: " ++ Other}).

parse_migrate_args(Args) ->
    parse_migrate_args(Args, undefined, []).

parse_migrate_args([], undefined, _) ->
    throw({usage, "migrate needs --out FILE"});
parse_migrate_args([], Out, Dirs) ->
    {Out, lists:reverse(Dirs)};
parse_migrate_args(["--out", Out | Rest], undefined, Dirs) ->
    parse_migrate_args(Rest, Out, Dirs);
parse_migrate_args(["--out", _ | _], _, _) ->
    throw({usage, "--out given twice"});
parse_migrate_args(["--schema-dir", Dir | Rest], Out, Dirs) ->
    parse_migrate_args(Rest, Out, [Dir | Dirs]);
parse_migrate_args([Other | _], _, _) ->
    throw({usage, "unrecognised argument: " ++ Other}).

%% =============================================================================
%% CHECK
%% =============================================================================

%% Returns {KeyFindings, ValueFindings, ListenerFindings}. The three are separate
%% because they are different hazards: a key finding is a setting this release
%% does not read at all, a value finding is a key it DOES read whose value it
%% cannot parse -- which discards the whole file, not just that key -- and a
%% listener finding is a live key whose listener will not start.
check(ConfFile, SchemaDirs0) ->
    SchemaDirs = resolve_schema_dirs(SchemaDirs0),
    {Schema, Validators} = schema_and_validators(SchemaDirs),
    Conf = read_conf(ConfFile),
    Findings = classify(Conf, Schema),
    Values = value_faults(Conf, Schema, Validators),
    Changed = reinterpretations(Conf),
    Listeners = listener_analysis(Conf, Schema),
    out("~s", [ConfFile]),
    out("  ~p keys, schemas: ~s",
        [length(Conf), string:join(SchemaDirs, " ")]),
    report(length(Conf), Findings),
    ok = report_values(Values),
    ok = report_reinterpreted(Changed),
    ok = listener_report(Listeners),
    Advanced = advanced_check(sibling_advanced_config(ConfFile)),
    ListenerFindings = listener_findings(Listeners) ++ Advanced,
    %% The verdict goes LAST and covers every section. An earlier version printed
    %% `OK' as the first line whenever the KEYS section was clean, which read as
    %% a clean bill of health on files that were exiting 1 for a listener
    %% finding.
    ok = verdict_line(Findings, Values, ListenerFindings, Changed),
    {Findings, Values, ListenerFindings}.

%% Changed-meaning keys are named here but do not make the verdict a finding,
%% for the reason given at `reinterpreted/0': they are reported so `clean'
%% cannot be read as silence, and they leave the exit code alone.
verdict_line(Findings, Values, ListenerFindings, Changed) ->
    out("", []),
    out("RESULT  ~s~s", [
        keys_verdict(Findings, Values, ListenerFindings),
        changed_verdict(Changed)
    ]),
    ok.

keys_verdict([], [], []) ->
    "clean -- every key is read, every value parses, every listener is declared";
keys_verdict(Findings, Values, ListenerFindings) ->
    io_lib:format(
        "~p key~s not read, ~p invalid value~s, ~p listener finding~s"
        " -- see above",
        [length(Findings), plural(length(Findings)),
            length(Values), plural(length(Values)),
            length(ListenerFindings), plural(length(ListenerFindings))]).

changed_verdict([]) ->
    "";
changed_verdict(Changed) ->
    io_lib:format("; ~p key~s changed meaning in this release",
        [length(Changed), plural(length(Changed))]).

%% A release keeps bondy.conf and advanced.config side by side in `etc', so the
%% sibling is checked without the operator having to name it. Absence is normal
%% and silent: most deployments have no advanced.config at all.
sibling_advanced_config(ConfFile) ->
    Candidate = filename:join(filename:dirname(ConfFile), "advanced.config"),
    case filelib:is_regular(Candidate) of
        true -> Candidate;
        false -> undefined
    end.

%% A key is known iff SOME mapping matches it. `is_fuzzy_match/2' handles both
%% the exact case and the `$name' case, and requires equal segment counts, so
%% `["a","b"]' does not match `["a","$x","c"]' (probed).
is_known(Key, Schema) ->
    mapping_for(Key, Schema) =/= undefined.

mapping_for(Key, Schema) ->
    case lists:search(
        fun({Var, _}) -> cuttlefish_variable:is_fuzzy_match(Key, Var) end, Schema
    ) of
        {value, {_, M}} -> M;
        false -> undefined
    end.

%% Every key this release does not read, with what to do about it. Rules are
%% consulted ONLY for keys already proven unknown, which is what lets some of
%% them be broad: a suffix rule on `.ping.interval' cannot disturb a live key,
%% because a live key never reaches here.
%% "Unknown" is the wrong test on its own inside a legacy listener block, because
%% a FUZZY mapping from an unrelated family can match a dead key and make it look
%% live. `bridge.listener.tls.certfile' is the case that exists: the release this
%% file targets dropped its explicit mapping to
%% `bondy_router.bridge_relay_tls.transport_opts.socket_opts.certfile'
%% (`schema/bondy_bridge_relay.schema:1026' at `9b4f0a29^'), leaving only
%% `bridge.$name.tls.certfile', which matches it with `$name = "listener"'. So
%% cuttlefish does read the key -- as a bridge relay CLIENT named `listener',
%% which is not a thing the operator configured -- while the `bridge_relay_tls'
%% listener it was written for gets no TLS material at all.
%%
%% Filtering on `not is_known/2' alone therefore skipped the key before its rename
%% rule could fire, and `tls_tails()' lists those tails under the bridge block's
%% `tls' class precisely so they WOULD be renamed. A key inside a legacy block is
%% dead by construction on this release -- that is what makes the block legacy --
%% so the block membership is the authority there, not the mapping table.
%%
%% Scoped to `legacy_block_of/1' rather than applied generally: it answers with a
%% listener name only for a key under one of the eight prefixes in
%% `legacy_listeners/0', so a live key that merely shares a family head
%% (`api_gateway.config_file', `wamp.broker.*') is untouched.
classify(Conf, Schema) ->
    Candidates = [
        {K, V}
     || {K, V} <- Conf,
        not is_known(K, Schema) orelse legacy_block_of(K) =/= undefined
    ],
    [{K, V, verdict(K, V, Schema, Conf)} || {K, V} <- Candidates].

verdict(Key, Value, Schema, Conf) ->
    case match_rule(Key, rules()) of
        no_rule ->
            no_rule;
        {drop, Why} ->
            {drop, Why};
        {manual, Rewrites, Why} ->
            {manual, [candidate(Key, R, Value, Schema) || R <- Rewrites], Why};
        {rewrite, Rewrite} ->
            New = rewrite(Key, Rewrite),
            case is_known(New, Schema) of
                true -> collides_or_contested(Key, New, Value, Conf);
                %% The rule fired but its destination is not mapped by the
                %% schemas being checked. Two causes, and the operator can tell
                %% them apart: the schemas belong to a release OLDER than the
                %% one this rule table targets, or the table has a typo. The
                %% selftest's rule check rules out the second against the
                %% current schemas, so in the field this is nearly always the
                %% first. Either way the rename is withheld rather than sending
                %% the operator to a second key nothing reads.
                false -> {unmapped_target, New}
            end
    end.

%% A candidate for a key that needs a human. Annotated when the operator's value
%% equals the candidate's own default, which is the evidence that resolved
%% `bridge.edge.timeout' to `connect_timeout' rather than to its two siblings.
%% For a carrier key it decides something larger: a line that only restated the
%% default needs no fan-out at all, it needs deleting.
candidate(Key, Rewrite, Value, Schema) ->
    New = rewrite(Key, Rewrite),
    Known = is_known(New, Schema),
    {New, Known, Known andalso is_default(New, Value, Schema)}.

%% @private
%% Two ways a value can turn out to be its key's default, and a `listeners.$name'
%% key can only be the second: `cuttlefish_generator:add_fuzzy_default/4'
%% materialises a fuzzy default for every name under the `listeners' prefix, so
%% no mapping there may declare one and `default_of/2' always answers
%% `undefined'. Those defaults live in `bondy_listener_config:carrier_defaults/1'
%% instead.
is_default(New, Value, Schema) ->
    case default_of(New, Schema) of
        {ok, Value} -> true;
        {ok, _} -> false;
        undefined -> is_carrier_default(New, Value, Schema)
    end.

%% @private
%% Compares through the DATATYPE, not as text: the conf carries `8h', `4MB' and
%% `on' where the code table holds 28800000, 4194304 and `true'. The mapping's
%% own datatype is what converts them, so this asks the question cuttlefish
%% would -- `is this line's value what the key would have been anyway?'
%%
%% Answers `false' rather than raising when `bondy_listener_config' is not
%% loadable (`locate_bondy_router/0' reports that separately), so a checkout
%% without a built tree loses the annotation and nothing else.
is_carrier_default(["listeners", _Name, Carrier | Tail] = New, Value, Schema) ->
    case carrier_default(list_to_atom(Carrier), carrier_path(Tail)) of
        undefined ->
            false;
        {ok, Default} ->
            case mapping_for(New, Schema) of
                undefined ->
                    false;
                M ->
                    transform_value(cuttlefish_mapping:datatype(M), Value) ==
                        {ok, Default}
            end
    end;
is_carrier_default(_New, _Value, _Schema) ->
    false.

%% @private
%% Where a `listeners.$name.<carrier>.<tail>' key LANDS inside the carrier's
%% option block, which is what `bondy_listener_config:carrier_defaults/1' is
%% keyed on. Two tails do not render under their own name, and both are the
%% schema translation's doing rather than this tool's:
%% `websocket.compression_enabled' lands on `compress' and `websocket.deflate.*'
%% on `deflate_opts.*'.
%%
%% This is a second statement of a fact the schema owns, so it is CHECKED rather
%% than trusted: `selftest_carrier_paths/2' resolves every carrier key in the
%% schema through here and fails if one does not land on a real default.
carrier_path(["compression_enabled"]) ->
    [compress];
carrier_path(["deflate", Key]) ->
    [deflate_opts, list_to_atom(Key)];
carrier_path(Tail) ->
    [list_to_atom(Key) || Key <- Tail].

%% @private
%% `locate_bondy_router/0' rather than `function_exported/3' alone: the module is
%% not on the escript's path until something loads it, and that check answers
%% `false' for a module that merely has not been loaded yet -- which made every
%% carrier line look like a deviation. Idempotent, so calling it per candidate
%% costs one `code:ensure_loaded/1' after the first.
carrier_default(Carrier, Path) ->
    case locate_bondy_router() of
        unavailable ->
            undefined;
        ok ->
            walk(bondy_listener_config:carrier_defaults(Carrier), Path)
    end.

%% @private
walk(Value, []) ->
    {ok, Value};
walk(Map, [Key | Rest]) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Inner} -> walk(Inner, Rest);
        error -> undefined
    end;
walk(_, _) ->
    undefined.

%% =============================================================================
%% RULES
%% =============================================================================

%% Selector:
%%   {match,  Pattern}  whole key, `$x' segments matching any one segment
%%   {prefix, Segments} key starts with Segments
%%   {suffix, Segments} key ends with Segments
%%
%% Action:
%%   {rewrite, {head|tail|all, N, New}}  replace N segments, or the whole key
%%   {drop, Why}                         the setting has no equivalent
%%   {manual, [Rewrite], Why}            needs a human; candidates are advisory
%%
%% Order matters: the first selector that matches wins, so a specific rule must
%% precede the prefix rule that would otherwise swallow it.
rules() ->
    %% The legacy per-listener blocks come FIRST. Two of the generic suffix rules
    %% below (`dynamic_buffer.*' and `ping.interval') would otherwise match a key
    %% inside one of those blocks and rename only its tail, leaving the legacy
    %% family at the head and producing a destination nothing maps.
    legacy_listener_rules() ++
        [
        %% ---------------------------------------------------------------------
        %% Features that stopped being configurable
        %% ---------------------------------------------------------------------
        {{match, ["wamp", "dealer", "pattern_based_registration"]},
            {drop, "pattern-based registration is always on. The router itself"
                " registers a wildcard procedure to serve `wamp.session.get',"
                " so `off' refused that registration and took every session"
                " open down with it; the setting is gone rather than fixed,"
                " because there is no working node with it off. `on' needs no"
                " action -- it is what you now get."}},
        {{match, ["wamp", "broker", "pattern_based_subscription"]},
            {drop, "pattern-based subscription is always on, for the same"
                " reason as `wamp.dealer.pattern_based_registration' above."
                " `on' needs no action."}},

        %% Every WAMP broker/dealer feature. None of them is a setting any
        %% more: a feature tells a client which parts of the advanced profile
        %% this build implements, a client asks for a subset in HELLO, and
        %% `bondy_session:parse_roles/1' intersects the two. An operator was
        %% never in that chain, so the whole family left `bondy.conf' at once.
        %%
        %% A prefix rule on `wamp.broker'/`wamp.dealer' would be shorter and
        %% wrong: `wamp.dealer.*' is not exhausted by features, and a prefix
        %% would swallow whatever is added there next. `selftest_capabilities/1'
        %% joins these against `bondy_config:code_defined_features/0', so a
        %% feature that gains or loses a value fails there rather than drifting.
        {{match, ["wamp", "broker", "acknowledge_event_received"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "broker", "acknowledge_subscriber_received"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "broker", "event_history"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "broker", "payload_passthru_mode"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "broker", "publication_trustlevels"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "broker", "sharded_subscription"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "broker", "subscription_meta_api"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "broker", "subscription_revocation"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "dealer", "call_reroute"]},
            {drop, "call rerouting is not implemented, so it is no longer a"
                " setting -- see `wamp.broker.event_history' above for why the"
                " family stopped being configurable. This one is worth reading"
                " twice: its old default made the node ADVERTISE call_reroute"
                " in WELCOME while never performing it, and it now advertises"
                " false. A client that branched on the announced feature will"
                " see it disappear, which is the announcement being corrected"
                " rather than a capability being withdrawn."}},
        {{match, ["wamp", "dealer", "payload_passthru_mode"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "dealer", "reflection"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "dealer", "registration_revocation"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "dealer", "sharded_registration"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "dealer", "testament_meta_api"]},
            {drop, unimplemented_why()}},
        {{match, ["wamp", "broker", "event_retention"]},
            {drop, capability_why()}},
        {{match, ["wamp", "broker", "publisher_exclusion"]},
            {drop, capability_why()}},
        {{match, ["wamp", "broker", "publisher_identification"]},
            {drop, capability_why()}},
        {{match, ["wamp", "broker", "reflection"]},
            {drop, capability_why()}},
        {{match, ["wamp", "broker", "session_meta_api"]},
            {drop, capability_why()}},
        {{match, ["wamp", "broker", "subscriber_blackwhite_listing"]},
            {drop, capability_why()}},
        {{match, ["wamp", "dealer", "call_canceling"]},
            {drop, capability_why()}},
        {{match, ["wamp", "dealer", "call_timeout"]},
            {drop, capability_why()}},
        {{match, ["wamp", "dealer", "call_trustlevels"]},
            {drop, capability_why()}},
        {{match, ["wamp", "dealer", "caller_auth_claims"]},
            {drop, capability_why()}},
        {{match, ["wamp", "dealer", "caller_identification"]},
            {drop, capability_why()}},
        {{match, ["wamp", "dealer", "registration_meta_api"]},
            {drop, capability_why()}},
        {{match, ["wamp", "dealer", "session_meta_api"]},
            {drop, capability_why()}},
        {{match, ["wamp", "dealer", "shared_registration"]},
            {drop, capability_why()}},
        {{match, ["wamp", "dealer", "progressive_calls"]},
            {drop, progressive_why()}},
        {{match, ["wamp", "dealer", "progressive_call_results"]},
            {drop, progressive_why()}},

        %% ---------------------------------------------------------------------
        %% oplog.* -> db.* (the rename this release shipped)
        %% ---------------------------------------------------------------------
        {{match, ["oplog", "catalog"]},
            {drop, "never had a consumer"}},
        {{match, ["oplog", "core", "scan_max_concurrency"]},
            {drop, "never had a consumer"}},
        {{match, ["oplog", "core", "gc_interval"]},
            {rewrite, {all, 0, ["db", "gc_interval"]}}},
        {{match, ["oplog", "core", "gc_heap_delta"]},
            {rewrite, {all, 0, ["db", "gc_heap_delta"]}}},
        {{match, ["oplog", "core", "pack_auto_seal_bytes"]},
            {rewrite, {all, 0, ["db", "pack_auto_seal_bytes"]}}},
        {{match, ["oplog", "core", "pack_seal_mode"]},
            {rewrite, {all, 0, ["db", "pack_seal_mode"]}}},
        {{match, ["oplog", "core", "shard_count"]},
            {rewrite, {all, 0, ["db", "main", "shard_count"]}}},
        {{match, ["oplog", "core", "partition_strategy"]},
            {rewrite, {all, 0, ["db", "main", "partition_strategy"]}}},
        {{match, ["oplog", "core", "realm_prefix_depth"]},
            {rewrite, {all, 0, ["db", "main", "realm_prefix_depth"]}}},
        {{match, ["oplog", "core", "on_topology_mismatch"]},
            {rewrite, {all, 0, ["db", "main", "on_topology_mismatch"]}}},
        %% A prefix rule rather than the eleven rows the design enumerated: the
        %% tail is preserved verbatim and the result is checked against the
        %% schema, so a member with no `db.aae.' counterpart reports as a stale
        %% rule instead of being silently renamed onto nothing.
        {{prefix, ["oplog", "aae"]},
            {rewrite, {head, 2, ["db", "aae"]}}},

        %% ---------------------------------------------------------------------
        %% rpc_gateway.* -> http_connector.*
        %% ---------------------------------------------------------------------
        %% A prefix rule is required, not a convenience: the tail carries the
        %% `$service' and `$proc' wildcard segments, which no lookup table can
        %% enumerate.
        {{prefix, ["rpc_gateway"]},
            {rewrite, {head, 1, ["http_connector"]}}},

        %% ---------------------------------------------------------------------
        %% Removed surfaces
        %% ---------------------------------------------------------------------
        {{prefix, ["store"]},
            {drop, "the RocksDB tuning surface; this release has no equivalent"}},
        {{match, ["leveldb", "maximum_memory", "percent"]},
            {drop, "predates even the RocksDB surface"}},
        {{match, ["platform_etc_dir"]},
            {drop, "never had a mapping; only platform_{data,lib,log,tmp}_dir do"}},
        %% Established by probe on erts 16.4, not from documentation: `+K' is
        %% absent from the emulator's usage output and both `+K true' and
        %% `+K false' leave erlang:system_info(kernel_poll) at true.
        {{match, ["erlang", "kernel_polling"]},
            {drop, "+K is inert in erts 16.4; kernel polling is unconditional"}},

        %% ---------------------------------------------------------------------
        %% erlang.* -> vm.*
        %% ---------------------------------------------------------------------
        {{match, ["erlang", "async_threads"]},
            {rewrite, {all, 0, ["vm", "async_thread", "number"]}}},
        {{match, ["erlang", "process_limit"]},
            {rewrite, {all, 0, ["vm", "process", "limit"]}}},
        {{match, ["erlang", "max_ports"]},
            {rewrite, {all, 0, ["vm", "port", "limit"]}}},
        {{match, ["erlang", "distribution_buffer_size"]},
            {rewrite, {all, 0, ["vm", "distribution", "buffer_size"]}}},
        {{match, ["erlang", "dirty_io_schedulers", "number"]},
            {rewrite, {all, 0, ["vm", "io", "dirty_scheduler", "number"]}}},
        {{match, ["erlang", "time_correction"]},
            {rewrite, {all, 0, ["vm", "time_correction"]}}},
        {{match, ["erlang", "time_correction", "warp_mode"]},
            {rewrite, {all, 0, ["vm", "time_correction", "warp_mode"]}}},
        {{match, ["erlang", "sbwt"]},
            {rewrite, {all, 0, ["vm", "cpu", "scheduler", "busy_wait_threshold"]}}},
        %% Not an old key: a misspelling of a live one.
        {{match, ["vm", "io", "dirty_schedulers"]},
            {rewrite, {all, 0, ["vm", "io", "dirty_scheduler", "number"]}}},

        %% ---------------------------------------------------------------------
        %% Node identity: never cuttlefish keys on this release
        %% ---------------------------------------------------------------------
        %% Env-var interpolation is not available to a bondy.conf value feeding
        %% an -args_file, and `-name' resolves FIRST-wins, so a restored key
        %% would be shadowed by vm.args even if one existed.
        {{match, ["nodename"]},
            {manual, [], "set -name in vm.args; the shipped prod and docker"
                " releases read $BONDY_ERL_NODENAME"}},
        {{match, ["distributed_cookie"]},
            {manual, [], "set -setcookie in vm.args; the shipped prod and"
                " docker releases read $BONDY_ERL_DISTRIBUTED_COOKIE"}},

        %% ---------------------------------------------------------------------
        %% Logging: a different surface, not a rename
        %% ---------------------------------------------------------------------
        {{prefix, ["log", "console"]},
            {manual, [], "handlers are configured per id: log.handlers.$id.level"
                " and log.handlers.$id.backend. Note log.level gates before any"
                " handler does, so both must allow a level for it to appear"}},
        {{match, ["log", "syslog"]},
            {manual, [], "no syslog backend; use log.handlers.$id.backend"}},
        {{match, ["log", "error", "redirect"]},
            {manual, [], "no equivalent; logger routes by level and filter"}},
        {{prefix, ["log", "async_threshold"]},
            {manual, [], "logger expresses this as overload protection:"
                " log.handlers.$id.config.{sync_mode_qlen,drop_mode_qlen,"
                "flush_qlen} and the burst_limit_* family"}},

        %% ---------------------------------------------------------------------
        %% Spelling changes that a key-name search cannot find
        %% ---------------------------------------------------------------------
        %% `dynamic_buffer' is the mapping TARGET, never a key. Matching on
        %% target paths finds this; grepping for the key name does not.
        {{suffix, ["dynamic_buffer", "min"]},
            {rewrite, {tail, 2, ["buffer", "min"]}}},
        {{suffix, ["dynamic_buffer", "max"]},
            {rewrite, {tail, 2, ["buffer", "max"]}}},
        %% ---------------------------------------------------------------------
        %% The global carrier blocks. A WebSocket, SSE or long-poll setting is
        %% now written on the LISTENER that serves it, and one global key used
        %% to cover every listener at once -- so this is a fan-out, not a
        %% rename, and only the operator knows which listeners they meant. The
        %% candidate names the shape; the LISTENERS section of the same report
        %% names the listeners this file declares.
        %%
        %% Ahead of the generic `ping.interval' and `ping.max_retries' renames
        %% below, which would otherwise rewrite the tail and leave `wamp.' at
        %% the head, producing a destination nothing maps.
        %% ---------------------------------------------------------------------

        %% Two knobs that never did anything, so there is nothing to fan out.
        {{match, ["wamp", "websocket", "buffer", "min"]},
            {drop, websocket_buffer_why()}},
        {{match, ["wamp", "websocket", "buffer", "max"]},
            {drop, websocket_buffer_why()}},

        %% The two legacy spellings, which move AND get renamed.
        {{match, ["wamp", "websocket", "ping", "interval"]},
            {manual,
                [{all, 0, ["listeners", "$name", "websocket", "ping",
                    "idle_timeout"]}],
                carrier_why("websocket") ++
                " The key is also renamed: `interval' became `idle_timeout'."}},
        {{match, ["wamp", "websocket", "ping", "max_retries"]},
            {manual,
                [{all, 0, ["listeners", "$name", "websocket", "ping",
                    "max_attempts"]}],
                carrier_why("websocket") ++
                " The key is also renamed: `max_retries' became"
                " `max_attempts'."}},

        {{prefix, ["wamp", "websocket"]},
            {manual, [{head, 2, ["listeners", "$name", "websocket"]}],
                carrier_why("websocket")}},
        {{prefix, ["wamp", "sse"]},
            {manual, [{head, 2, ["listeners", "$name", "sse"]}],
                carrier_why("sse")}},
        {{prefix, ["wamp", "longpoll"]},
            {manual, [{head, 2, ["listeners", "$name", "longpoll"]}],
                carrier_why("longpoll")}},

        %% ---------------------------------------------------------------------
        %% The HTTP long-poll / SSE transport block, renamed to say what it
        %% covers. `wamp.transport_queue.*' read as a queue for every transport
        %% and was never that: a WebSocket or raw-socket session reaches none of
        %% it. Straight renames -- the settings, their units and their defaults
        %% are unchanged.
        %% ---------------------------------------------------------------------

        %% Never a queue setting. It is the SESSION's inactivity deadline, read
        %% once by `bondy_http_transport_session:init/1', and it was filed under
        %% the queue only because it shared the block.
        {{match, ["wamp", "transport_queue", "transport_ttl"]},
            {rewrite, {all, 0, ["wamp", "http_transport", "idle_timeout"]}}},

        {{match, ["wamp", "transport_queue", "overflow_strategy"]},
            {drop, "it was seeded and never read: the eviction it named is"
                " unconditional in bondy_http_transport_queue:do_enqueue/3, and"
                " the enum admitted one value. Evicting the oldest entry is the"
                " only policy that makes sense for a stream a client reads in"
                " order, so there is nothing to choose"}},

        {{prefix, ["wamp", "transport_queue"]},
            {rewrite, {head, 2, ["wamp", "http_transport", "queue"]}}},

        {{suffix, ["ping", "interval"]},
            {rewrite, {tail, 2, ["ping", "idle_timeout"]}}},
        {{suffix, ["ping", "max_retries"]},
            {rewrite, {tail, 2, ["ping", "max_attempts"]}}},

        %% ---------------------------------------------------------------------
        %% Needs a human: several live keys are plausible and the name does not
        %% decide between them
        %% ---------------------------------------------------------------------
        {{match, ["bridge", "$name", "timeout"]},
            {manual,
                [
                    {tail, 1, ["connect_timeout"]},
                    {tail, 1, ["idle_timeout"]},
                    {tail, 1, ["network_timeout"]}
                ],
                "there is no bridge.$name.timeout; pick the phase you meant"}},
        {{match, ["cluster", "peer_discovery", "automatic_join"]},
            {manual, [{tail, 1, ["enabled"]}],
                "the live surface is cluster.peer_discovery.{enabled,type,"
                "initial_delay,polling_interval,timeout} plus config.$name"}},
        {{match, ["cluster", "peer_discovery", "join_retry_interval"]},
            {manual, [{tail, 1, ["polling_interval"]}, {tail, 1, ["initial_delay"]}],
                "the live surface has no retry interval; polling_interval is"
                " the closest, initial_delay the first-attempt delay"}}
        ].

%% Every legacy per-listener block, and the listener name its settings move to.
%% Only `admin_api.http' changes name: `admin' is the reserved name for the
%% administrable listener, and a listener's options are read under its CURRENT
%% name, so this rename is what keeps them read at all.
%%
%% The third element says which extra tail classes the block has. It is not
%% cosmetic: the SAME tail moves to different places depending on the block.
%% `idle_timeout' and `linger.timeout' are Cowboy protocol options under an HTTP
%% block, so they move under `http.'; under a raw-socket or bridge block they are
%% the listener's own and stay put. A rule table keyed only on the tail would get
%% one of the two wrong.
%% Shared by the fourteen feature rules above. Written once because the answer is
%% @private
%% Shared by the three carrier-block rules. One sentence per fact: what moved,
%% why it cannot be rewritten mechanically, and what happens if the line is just
%% deleted.
carrier_why(Carrier) ->
    "wamp." ++ Carrier ++ ".* was the value a listener fell back to when it set"
    " nothing, so one key covered every listener at once. Restate it as"
    " listeners.<name>." ++ Carrier ++ ".<tail> on each listener that serves"
    " the carrier. The defaults did not change, so a line that only restated"
    " one can be deleted instead.".

%% @private
websocket_buffer_why() ->
    "since Cowboy 2.13 a WebSocket connection inherits its listener's dynamic"
    " buffer and cowboy_websocket overrides any handler-supplied value, so"
    " neither key could ever take effect; listeners.$name.http.buffer.min/.max"
    " are the ones that do".

%% the same for all of them and a per-key paraphrase would drift.
capability_why() ->
    "a WAMP feature is a capability, not a setting: it states which parts of"
    " the advanced profile this build implements. A client asks for a subset in"
    " HELLO and the session gets the intersection, so an operator was never in"
    " that chain -- the key only ever let a deployment lie about the build."
    " Bondy implements this one and still announces it; nothing to do.".

progressive_why() ->
    "progressive calls are a capability now, not a rollout switch. The key is"
    " gone and the feature is announced, but a peer still has to ask for it"
    " EXPLICITLY -- `bondy_session:?STRICT_OPTIN_FEATURES' refuses to infer it"
    " from the router's advertised set, so a client that never announced it is"
    " not treated as supporting it. If you were holding this `off' to stage a"
    " mixed-version upgrade, that is no longer what it did.".

unimplemented_why() ->
    "this WAMP feature has no implementation in Bondy, so it is a build"
    " capability rather than a setting and the key is gone. Nothing to do:"
    " the node already behaved this way. It was never usable as a switch"
    " either -- the mapping accepted only the word `off', which cuttlefish"
    " resolved to TRUE, while `on' failed config generation silently and left"
    " the node running on a previous generation's file.".

legacy_listeners() ->
    [
        {["admin_api", "http"], "admin", [http]},
        {["admin_api", "https"], "admin_api_https", [http, tls]},
        {["api_gateway", "http"], "api_gateway_http", [http]},
        {["api_gateway", "https"], "api_gateway_https", [http, tls]},
        {["wamp", "tcp"], "wamp_tcp", []},
        {["wamp", "tls"], "wamp_tls", [tls, ping_interval]},
        {["bridge", "listener", "tcp"], "bridge_relay_tcp", [bridge]},
        {["bridge", "listener", "tls"], "bridge_relay_tls", [bridge, tls]}
    ].

%% The identity a legacy block's listener needs on THIS release, keyed by the
%% name `legacy_listeners/0' renames it to. `undefined' for any other name.
%%
%% Renaming keys moves a listener's SETTINGS; it does not declare the listener.
%% `bondy_listener_config:resolve_one/3' takes `transport' and `protocol' from
%% every inventory entry through `required/3', and `resolve_services/3' also
%% requires a non-empty `services' when `protocol = http'. A file whose keys are
%% all renamed and whose listeners are all undeclared therefore aborts the boot
%% with `{invalid_listener, <name>, {missing, transport}}' -- MEASURED, by
%% rendering a fully migrated file with `cuttlefish_generator:map/2' and calling
%% `bondy_listener_config:resolve/2' on the inventory. Emitting identity is part
%% of the migration for that reason, not a convenience on top of it.
%%
%% Every row is READ OFF the release these blocks belonged to, at `9b4f0a29^',
%% rather than inferred from the block's name or its tail classes:
%%
%%   - `bondy_http_gateway.erl:102-105' defines the four HTTP listeners
%%     (`api_gateway_http', `api_gateway_https', `admin_api_http',
%%     `admin_api_https'), which is where the `https' rows' `tls' comes from.
%%   - `:945-946' hands `base_routes()' to BOTH the `http' and the `https'
%%     listener, and `:554' hands `admin_base_routes()' to both admin listeners,
%%     so each twin pair served an IDENTICAL route set and so takes an identical
%%     `services' list. That is the fact that makes the `https' rows derivable
%%     at all.
%%   - `base_routes/0:995' mounts `/ws', `/wamp/sse/*' and `/wamp/longpoll/*' --
%%     `wamp_ws', `wamp_sse', `wamp_longpoll' -- beside the API Gateway
%%     specifications themselves, which is `api_gateway'.
%%   - `admin_base_routes/0:1023' mounts `/ws', `/ping', `/ready',
%%     `/cluster/topology' and `/metrics/[:registry]' -- `wamp_ws', `admin' and
%%     `metrics' -- beside the built-in Admin API specification, which is
%%     `admin_api'.
%%
%% The two `services' lists come out equal to `default_inventory/0''s `admin' and
%% `api_gateway_http' entries. That agreement is a CHECK on the reading above,
%% not its source: the default inventory describes a fresh node, and a migrated
%% file must reproduce what the operator's own listeners served.
%%
%% A raw-socket or bridge-relay listener takes no `services' at all:
%% `resolve_services/3' rejects the key outright for a non-HTTP protocol, so
%% emitting one would turn a bootable file into `{services_not_supported, _}'.
legacy_identity("admin") ->
    %% `start_phase' is emitted only for `admin', and only because declaring it
    %% LOSES it otherwise. `bondy_listener_manager:with_reserved/1' injects the
    %% reserved spec -- which carries `start_phase => early' -- only for a name
    %% the operator did not write, and `resolve_one/3' defaults an operator's own
    %% entry to `normal'. Renaming `admin_api.http.*' onto `listeners.admin.*'
    %% makes `admin' operator-written, so without this line a migrated node stops
    %% answering `/ping' and `/ready' until every other listener is up.
    [
        {"transport", "tcp"},
        {"protocol", "http"},
        {"services", "admin_api, wamp_ws, admin, metrics"},
        {"start_phase", "early"}
    ];
legacy_identity("admin_api_https") ->
    [
        {"transport", "tls"},
        {"protocol", "http"},
        {"services", "admin_api, wamp_ws, admin, metrics"}
    ];
legacy_identity("api_gateway_http") ->
    [
        {"transport", "tcp"},
        {"protocol", "http"},
        {"services", "api_gateway, wamp_ws, wamp_sse, wamp_longpoll"}
    ];
legacy_identity("api_gateway_https") ->
    [
        {"transport", "tls"},
        {"protocol", "http"},
        {"services", "api_gateway, wamp_ws, wamp_sse, wamp_longpoll"}
    ];
legacy_identity("wamp_tcp") ->
    [{"transport", "tcp"}, {"protocol", "wamp_rawsocket"}];
legacy_identity("wamp_tls") ->
    [{"transport", "tls"}, {"protocol", "wamp_rawsocket"}];
legacy_identity("bridge_relay_tcp") ->
    [{"transport", "tcp"}, {"protocol", "bridge_relay"}];
legacy_identity("bridge_relay_tls") ->
    [{"transport", "tls"}, {"protocol", "bridge_relay"}];
legacy_identity(_) ->
    undefined.

%% Cowboy protocol options. Under an HTTP block these move to
%% `listeners.<name>.http.<tail>', which is where the schema routes
%% `protocol_opts'.
http_tails() ->
    [
        ["active_n"],
        ["buffer", "max"],
        ["buffer", "min"],
        ["idle_timeout"],
        ["inactivity_timeout"],
        ["initial_stream_flow_size"],
        ["invalid_response_headers"],
        ["linger", "timeout"],
        ["max_authority_length"],
        ["max_authorization_header_value_length"],
        ["max_concurrent_streams"],
        ["max_cookie_header_value_length"],
        ["max_empty_lines"],
        ["max_header_name_length"],
        ["max_header_value_length"],
        ["max_headers"],
        ["max_keepalive"],
        ["max_method_length"],
        ["max_request_line_length"],
        ["max_skip_body_length"],
        ["request_timeout"],
        ["reset_idle_timeout_on_send"],
        ["sendfile"]
    ].

%% TLS material moves to `listeners.<name>.tls.<tail>', which is the only place
%% `bondy_listener_config:tls_material/3' reads it from.
tls_tails() ->
    [
        ["cacertfile"],
        ["certfile"],
        ["fail_if_no_peer_cert"],
        ["keyfile"],
        ["verify"],
        ["versions"]
    ].

%% Derived from each block's own shape rather than written out as 331 rows: the
%% destination is computed from the block's prefix length, so a rule cannot name
%% a listener the table above does not list. Each rule's destination is still
%% checked against the schema before it is offered, and the selftest's rule check
%% fails on any that is not mapped.
legacy_listener_rules() ->
    lists:append([
        listener_rules(Prefix, Name, Classes)
     || {Prefix, Name, Classes} <- legacy_listeners()
    ]).

listener_rules(Prefix, Name, Classes) ->
    N = length(Prefix),
    Into = fun(Block) ->
        {rewrite, {head, N, ["listeners", Name] ++ Block}}
    end,
    Renamed = fun(Tail) -> {rewrite, {all, 0, ["listeners", Name] ++ Tail}} end,

    Http =
        case lists:member(http, Classes) of
            false ->
                [];
            true ->
                [
                    {{match, Prefix ++ Tail}, Into(["http"])}
                 || Tail <- http_tails()
                ] ++
                    %% `dynamic_buffer' is the mapping TARGET of `buffer.min' and
                    %% `buffer.max', never a key an operator wrote -- but files
                    %% carrying it exist, so both spellings are handled.
                    [
                        {{match, Prefix ++ ["dynamic_buffer", "min"]},
                            Renamed(["http", "buffer", "min"])},
                        {{match, Prefix ++ ["dynamic_buffer", "max"]},
                            Renamed(["http", "buffer", "max"])}
                    ]
        end,

    Tls =
        case lists:member(tls, Classes) of
            false -> [];
            true -> [{{match, Prefix ++ Tail}, Into(["tls"])} || Tail <- tls_tails()]
        end,

    %% The bridge blocks spell two keys differently from every other block: the
    %% block name ALONE is its `enabled' flag, and `ping' alone is
    %% `ping.enabled'.
    Bridge =
        case lists:member(bridge, Classes) of
            false ->
                [];
            true ->
                [
                    {{match, Prefix}, Renamed(["enabled"])},
                    {{match, Prefix ++ ["ping"]}, Renamed(["ping", "enabled"])},
                    {{match, Prefix ++ ["ping", "interval"]},
                        Renamed(["ping", "idle_timeout"])},
                    {{match, Prefix ++ ["ping", "max_retries"]},
                        Renamed(["ping", "max_attempts"])},
                    %% Nothing has ever read `<name>.max_frame_size' for a
                    %% bridge-relay listener: `bondy_bridge_relay_server' reads
                    %% `auth_timeout', `idle_timeout', `hibernate' and `ping', and
                    %% no other module reads the key. It was dead before this
                    %% release removed the mapping.
                    {{match, Prefix ++ ["max_frame_size"]},
                        {drop, "no consumer has ever read it for a bridge relay"}}
                ]
        end,

    PingInterval =
        case lists:member(ping_interval, Classes) of
            false ->
                [];
            true ->
                [
                    {{match, Prefix ++ ["ping", "interval"]},
                        Renamed(["ping", "idle_timeout"])}
                ]
        end,

    %% Last for this block: every remaining tail keeps its spelling and only the
    %% block prefix changes. Checked against the schema like any other rewrite,
    %% so a tail with no counterpart reports as an unmapped destination rather
    %% than being renamed onto nothing.
    Http ++ Tls ++ Bridge ++ PingInterval ++
        [{{prefix, Prefix}, Into([])}].

match_rule(_Key, []) ->
    no_rule;
match_rule(Key, [{Selector, Action} | Rest]) ->
    case selects(Key, Selector) of
        true -> Action;
        false -> match_rule(Key, Rest)
    end.

selects(Key, {match, Pattern}) ->
    cuttlefish_variable:is_fuzzy_match(Key, Pattern);
selects(Key, {prefix, Segments}) ->
    lists:prefix(Segments, Key);
selects(Key, {suffix, Segments}) ->
    lists:suffix(Segments, Key).

rewrite(_Key, {all, _, New}) ->
    New;
rewrite(Key, {head, N, New}) ->
    New ++ lists:nthtail(N, Key);
rewrite(Key, {tail, N, New}) ->
    lists:sublist(Key, length(Key) - N) ++ New.

%% The schema's own default for a key, used only as evidence in a candidate
%% annotation. `commented' counts: it is the value the shipped conf shows, which
%% is what an operator's file was most likely copied from.
default_of(Key, Schema) ->
    case mapping_for(Key, Schema) of
        undefined ->
            undefined;
        M ->
            case cuttlefish_mapping:has_default(M) of
                true -> {ok, to_str(cuttlefish_mapping:default(M))};
                false ->
                    case cuttlefish_mapping:commented(M) of
                        undefined -> undefined;
                        C -> {ok, to_str(C)}
                    end
            end
    end.

to_str(V) when is_list(V) -> V;
to_str(V) when is_atom(V) -> atom_to_list(V);
to_str(V) when is_integer(V) -> integer_to_list(V);
to_str(V) -> lists:flatten(io_lib:format("~p", [V])).

%% =============================================================================
%% CONTESTED AND COLLIDING RENAMES
%% =============================================================================

%% A rename whose destination the file ALREADY sets. Renaming would leave two
%% lines for the same key, and cuttlefish keeps the LAST one:
%% `cuttlefish_conf:remove_duplicates/1' folds left with
%% `cuttlefish_util:replace_proplist_value/3', so a later occurrence replaces an
%% earlier one. Whichever way round they fall, one of the two values is silently
%% discarded -- and if the legacy line happens to sit lower in the file, the
%% rename would override the new-style value the operator wrote deliberately.
%%
%% So the rename is withheld and both values are shown. Migrate comments the
%% legacy line out, which keeps the explicit new-style setting in force and
%% changes nothing.
collides_or_contested(Key, New, Value, Conf) ->
    case lists:keyfind(New, 1, Conf) of
        {_, Existing} -> {collides, New, Value, Existing};
        false -> contested(Key, New, Value, Conf)
    end.

%% A rename whose target is live but whose VALUE contradicts the rest of the
%% file. Activating a previously-inert key is not automatically the right
%% migration: `erlang.max_ports = 65536' never reached the VM, and renaming it to
%% the live `vm.port.limit' would cap total ports below the max_connections
%% declared in the same file. Reported, never performed silently.
contested(_Key, ["vm", "port", "limit"] = New, Value, Conf) ->
    case int_value(Value) of
        {ok, Limit} ->
            Over = [{K, V} || {K, V} <- Conf, lists:suffix(["max_connections"], K),
                exceeds(V, Limit)],
            case Over of
                [] -> {rename, New};
                _ -> {contested, New, port_limit_why(Limit, Over)}
            end;
        error ->
            {rename, New}
    end;
contested(_Key, New, _Value, _Conf) ->
    {rename, New}.

port_limit_why(Limit, Over) ->
    lists:flatten(io_lib:format(
        "this key never reached the VM, so renaming it ACTIVATES it. ~p would"
        " cap total ports below the connection limits set in this same file"
        " (~s). Drop the key to keep the erts default, or raise it above the"
        " largest of them.",
        [Limit, string:join([key_str(K) ++ " = " ++ V || {K, V} <- Over], ", ")]
    )).

exceeds("infinity", _Limit) ->
    true;
exceeds(V, Limit) ->
    case int_value(V) of
        {ok, N} -> N > Limit;
        error -> false
    end.

int_value(V) ->
    try
        {ok, list_to_integer(string:trim(V))}
    catch
        error:badarg -> error
    end.

%% =============================================================================
%% VALUES THE SCHEMA REJECTS
%% =============================================================================

%% The third hazard, and the worst of the three, because it is not confined to
%% the key it appears on.
%%
%% `classify/2' asks whether a key is READ. This asks whether its value can be
%% USED, which is a separate question with a much larger blast radius: cuttlefish
%% generates all-or-nothing. `cuttlefish_generator:map_transform_datatypes/3'
%% returns `{error, transform_datatypes, _}' if ANY value fails its datatype, and
%% `map_validate/2' returns `{error, validation, _}' if any passes its datatype
%% but fails a validator. Either one abandons the whole run, so no app config is
%% written at all and every other setting in the file is lost with it.
%%
%% The operator sees none of that. `rebar3_scuttler/priv/pre_start_cuttlefish.tpl'
%% runs cuttlefish with `--silent' and does not check its exit status, and
%% `config/prod/sys.config' ends with the include string
%% `"etc/generated/user_defined.config"' -- so a failed generation prints nothing
%% and leaves the file the last SUCCESSFUL run wrote. The node boots on stale
%% config with no diagnostic anywhere. Found in the field 2026-08-22 on a
%% migrated file carrying `wamp.websocket.max_frame_size = infinity' against a
%% `{datatype, bytesize}' mapping: the node came up on default listeners and an
%% earlier run's `platform_tmp_dir', and the boot log's only trace was the values
%% themselves being wrong.
%%
%% Only keys the file SETS are checked. A schema default that cannot parse is a
%% schema bug and would break every deployment equally; it is not something an
%% operator can act on from their own file.
value_faults(Conf, Schema, Validators) ->
    [
        {Key, Value, Fault}
     || {Key, Value} <- Conf,
        Fault <- [value_fault(Key, Value, Schema, Validators)],
        Fault =/= ok
    ].

value_fault(Key, Value, Schema, Validators) ->
    case mapping_for(Key, Schema) of
        undefined ->
            %% Nothing reads it, so nothing parses it either. The KEYS section
            %% owns this key; reporting it twice under two headings would read
            %% as two problems.
            ok;
        M ->
            case has_placeholder(Value) of
                true -> ok;
                false -> datatype_fault(Value, M, Validators)
            end
    end.

%% A value that is not yet the value cuttlefish will see. Two forms, substituted
%% by two different things, and neither is this tool's to resolve:
%%
%%   `${VAR}'    the release's own `bin/replace-env-vars', which rewrites
%%               `etc/bondy.conf.template' into `etc/bondy.conf' in the pre-start
%%               hook, before cuttlefish runs (`priv/tools/replace-env-vars:171',
%%               `${name}' only -- not `$name', not nested).
%%   `$(a.b.c)'  `cuttlefish_generator:value_sub/1', which splices another key's
%%               value in before any datatype is applied.
%%
%% Skipped rather than resolved. The first cannot be resolved at all -- the
%% environment that will hold `FLY_PRIVATE_IP' does not exist on the machine
%% running this check -- and resolving the second means a second implementation
%% of a resolver with its own circular-reference detection. Both would otherwise
%% be false positives on files that are correct: four shipped templates set
%% `cluster.peer_ip = ${FLY_PRIVATE_IP}', which no `ip' datatype can parse and
%% which is nonetheless exactly right. The cost is a false negative on the
%% substituted value; check the rendered `bondy.conf' to cover it.
has_placeholder(Value) ->
    string:find(Value, "${") =/= nomatch orelse
        string:find(Value, "$(") =/= nomatch.

datatype_fault(Value, M, Validators) ->
    DTs = cuttlefish_mapping:datatype(M),
    case transform_value(DTs, Value) of
        error -> {datatype, DTs};
        {ok, Typed} -> validator_fault(Typed, M, Validators)
    end.

%% A validator runs on the TYPED value, and only for a concrete mapping.
%%
%% `cuttlefish_generator:run_validations/2' looks a mapping's value up with
%% `proplists:get_value(cuttlefish_mapping:variable(M), Conf)', and a fuzzy
%% mapping's variable is the literal `["mail","relay","$name","port"]', which no
%% conf ever contains -- so the lookup yields `undefined' and the clause
%% `{undefined, _} -> true' skips it. Every validator on a `$name' mapping is
%% therefore dead, and there are 18 of them in these schemas.
%%
%% PROBED, not inferred: a two-mapping schema differing only in fuzziness, both
%% carrying the same validator, fed the same violating value -- `a.b.n = 0'
%% mapped clean while `c.n = 0' returned `{error, validation, _}'. Enforcing them
%% here would report a file that boots as one that does not.
validator_fault(Typed, M, Validators) ->
    case cuttlefish_mapping:is_fuzzy_variable(M) of
        true ->
            ok;
        false ->
            case [V || V <- cuttlefish_mapping:validators(M, Validators),
                not passes(V, Typed)]
            of
                [] -> ok;
                [V | _] -> {validator, cuttlefish_validator:description(V)}
            end
    end.

%% `run_validations/2' matches on `{_, true}', so anything other than `true' is a
%% failure. A validator that RAISES is the one divergence: cuttlefish does not
%% catch it, so the generator dies where this reports a finding. Both mean the
%% file does not boot, and a finding an operator can read beats a stack trace.
passes(V, Typed) ->
    Fun = cuttlefish_validator:func(V),
    try Fun(Typed) =:= true catch _:_ -> false end.

%% `cuttlefish_generator:transform_type/2' is not exported, so its dispatch is
%% restated here: try each datatype in the mapping's list and take the first that
%% parses, preferring `is_supported/1' over `is_extended/1' in that order. Every
%% branch calls cuttlefish's own `from_string/2', so the accept/reject decision
%% is still cuttlefish's; only the dispatch is local. `selftest_values/2' pins
%% the two apart by asserting this agrees with `cuttlefish_generator:map/2' on
%% the same input.
transform_value([], _Value) ->
    error;
transform_value([DT | Rest], Value) ->
    case transform_one(DT, Value) of
        {ok, _} = Ok -> Ok;
        error -> transform_value(Rest, Value)
    end.

transform_one(DT, Value) ->
    Supported = cuttlefish_datatypes:is_supported(DT),
    Extended = cuttlefish_datatypes:is_extended(DT),
    if
        Supported -> from_string(DT, Value);
        Extended -> extended(DT, Value);
        %% A datatype cuttlefish itself does not recognise. That is a schema
        %% fault, not the operator's, so it is not reported as a bad value.
        true -> {ok, Value}
    end.

from_string(DT, Value) ->
    try cuttlefish_datatypes:from_string(Value, DT) of
        {error, _} -> error;
        New -> {ok, New}
    catch
        _:_ -> error
    end.

%% An extended datatype names the ONE value it accepts, so parsing is not enough:
%% `transform_extended_type/2' requires the parsed value to equal it.
extended({DT, Acceptable}, Value) ->
    case from_string(DT, Value) of
        {ok, Acceptable} -> {ok, Acceptable};
        _ -> error
    end.

%% =============================================================================
%% KEYS WHOSE MEANING CHANGED
%% =============================================================================

%% Keys this release still reads, but reads DIFFERENTLY. Neither of the other
%% two sections can carry one: `classify/2' only ever examines keys that NO
%% mapping matches, and a listener finding is a listener that will not start. A
%% file whose every key is live and whose every listener boots is therefore
%% reported clean -- correctly -- while one of its settings quietly means
%% something other than what it did.
%%
%% Entries are ADVISORY and do not set the exit code. The line is spelled
%% correctly and may well need no edit, only a human deciding whether the new
%% meaning is still the one they wanted; exit 1 stays reserved for "this file
%% needs changing", which keeps a clean exit reachable for a file that
%% legitimately sets the key. The verdict line names the count, so `clean'
%% cannot be read as silence.
%%
%% A pattern is a WHOLE key, with `$name' matching any one segment, so it cannot
%% reach a longer or shorter path: `cuttlefish_variable:is_fuzzy_match/2'
%% compares segment counts before it compares anything else
%% (`cuttlefish_variable.erl:148'). That is what keeps the four-segment socket
%% key below apart from Cowboy's five-segment
%% `listeners.<name>.http.linger.timeout', a different setting in different
%% units, which the test templates set on the same listeners.
reinterpreted() ->
    [
        {["listeners", "$name", "linger", "timeout"],
            "was milliseconds, is now seconds",
            "The value is handed to the socket as the N in"
            " `{linger, {true, N}}', which inet documents in SECONDS"
            " (`kernel/src/inet.erl:1124', OTP 28.5), so a duration now renders"
            " as the number it reads as: `1s' is 1 where it used to be 1000,"
            " and asked for a 1000-SECOND blocking close. Confirm the value is"
            " the number of seconds you intend. A bare integer was already"
            " taken unconverted and is unaffected, as is the `-1' sentinel; a"
            " sub-second value rounds UP to 1, because `{linger, {true, 0}}'"
            " means abort the connection and discard unsent data. Two related"
            " changes: the `1s' default is restored on top of the corrected"
            " unit, so a raw-socket or bridge-relay listener that sets nothing"
            " now lingers for one second; and Cowboy's"
            " `listeners.<name>.http.linger.timeout' is a different key, still"
            " in milliseconds, and is not affected."}
    ].

%% The entries covering a file's keys, in file order, each paired with the entry
%% that matched it. Matching is cuttlefish's own, so this section and
%% `is_known/2' cannot disagree about which mapping a key belongs to.
reinterpretations(Conf) ->
    [
        {Key, Value, Entry}
     || {Key, Value} <- Conf,
        {Pattern, _, _} = Entry <- reinterpreted(),
        cuttlefish_variable:is_fuzzy_match(Key, Pattern)
    ].

%% =============================================================================
%% REPORT
%% =============================================================================

report(_Total, []) ->
    out("  KEYS: all recognised", []);
report(Total, Findings) ->
    out("", []),
    out("  KEYS: ~p of ~p are set but this release maps none of them, so each",
        [length(Findings), Total]),
    out("  is dropped in silence at boot and the setting does not apply.", []),
    lists:foreach(fun(G) -> report_group(G, Findings) end, groups()).

%% Deliberately louder than the other sections, and the reason is in the second
%% sentence: this is the only finding whose consequence is not confined to the
%% key it names.
report_values([]) ->
    ok;
report_values(Faults) ->
    out("", []),
    out("  INVALID VALUE (~p) -- this release reads ~s, but cannot parse the"
        " value.",
        [length(Faults), case length(Faults) of
            1 -> "this key";
            _ -> "these keys"
        end]),
    wrap("  ", "cuttlefish generates all or nothing: one value it cannot use"
        " abandons the whole run, so NO setting in this file applies -- not just"
        " the one below. The pre-start hook runs cuttlefish with --silent and"
        " does not check its exit status, and sys.config includes the file it"
        " would have written, so the node boots in silence on whatever the last"
        " successful generation left in etc/generated/. Nothing appears in the"
        " boot log. Fix these before deploying."),
    lists:foreach(
        fun({K, V, Fault}) ->
            out("    ~s = ~s", [pad(key_str(K), 46), V]),
            wrap("        ", value_fault_why(Fault))
        end,
        Faults
    ),
    ok.

value_fault_why({datatype, DTs}) ->
    "not a valid " ++ datatype_str(DTs) ++
        ". Generation stops at phase transform_datatypes.";
value_fault_why({validator, Description}) ->
    "the value parses but the schema refuses it: " ++ Description ++
        ". Generation stops at phase validation.".

%% A mapping's datatype is a LIST, and most carry exactly one. Naming a
%% single-element list as a list ("not a valid [bytesize]") reads as a typo, so
%% the common case is unwrapped and the rare alternation is spelled out.
datatype_str([DT]) ->
    datatype_name(DT);
datatype_str(DTs) ->
    string:join([datatype_name(DT) || DT <- DTs], " or ").

datatype_name({enum, Values}) ->
    "one of " ++ string:join([to_str(V) || V <- Values], ", ");
datatype_name({duration, _}) ->
    "duration";
%% A flag whose two names are the SAME accepts exactly one word. Rendering that
%% as "off or off" reads as a bug in this formatter rather than what it is -- a
%% mapping declared with one usable value.
datatype_name({flag, Name, Name}) when is_atom(Name) ->
    "value here: the only word this key accepts is " ++ to_str(Name);
datatype_name({flag, On, Off}) when is_atom(On), is_atom(Off) ->
    to_str(On) ++ " or " ++ to_str(Off);
datatype_name(flag) ->
    "on or off";
datatype_name(DT) when is_atom(DT) ->
    atom_to_list(DT);
datatype_name(DT) ->
    lists:flatten(io_lib:format("~p", [DT])).

report_reinterpreted([]) ->
    ok;
report_reinterpreted(Items) ->
    out("", []),
    out("  CHANGED MEANING (~p)", [length(Items)]),
    wrap("  ", "These keys are still read, but not as they were. There is"
        " nothing to rename, so migrate copies them through untouched: check"
        " that each value still says what you meant by it."),
    lists:foreach(
        fun({K, V, {_, What, Advice}}) ->
            out("    ~s = ~s", [pad(key_str(K), 46), V]),
            out("        ~s", [What]),
            wrap("        ", Advice)
        end,
        Items
    ),
    ok.

groups() ->
    [
        {rename, "RENAME -- same setting, new key"},
        {contested, "CONTESTED -- the rename would change behaviour; read this"},
        {collides,
            "ALREADY SET -- the new key is in this file too, with another value"},
        {drop, "DROP -- no equivalent on this release"},
        {manual, "BY HAND -- no mechanical equivalent"},
        {unmapped_target,
            "NOT ON THIS RELEASE -- the new key exists in a later version"},
        {no_rule, "NO RULE -- this tool has nothing for these"}
    ].

report_group({Tag, Title}, Findings) ->
    case [F || F <- Findings, tag_of(F) == Tag] of
        [] ->
            ok;
        Group ->
            out("", []),
            out("  ~s (~p)", [Title, length(Group)]),
            lists:foreach(fun report_finding/1, Group)
    end.

tag_of({_, _, no_rule}) -> no_rule;
tag_of({_, _, Verdict}) -> element(1, Verdict).

report_finding({K, V, {rename, New}}) ->
    out("    ~s = ~s ->  ~s", [pad(key_str(K), 46), pad(V, 14), key_str(New)]);
report_finding({K, V, {contested, New, Why}}) ->
    out("    ~s = ~s", [pad(key_str(K), 46), V]),
    out("        would become ~s", [key_str(New)]),
    wrap("        ", Why);
report_finding({K, V, {collides, New, _Old, Existing}}) ->
    out("    ~s = ~s", [pad(key_str(K), 46), V]),
    out("        ~s is already set to ~s in this file.", [key_str(New), Existing]),
    out("        Not renamed: two lines for one key means the LAST wins, so one", []),
    out("        of the two values would be discarded without a word.", []);
report_finding({K, V, {drop, Why}}) ->
    out("    ~s = ~s", [pad(key_str(K), 46), V]),
    wrap("        ", Why);
report_finding({K, V, {unmapped_target, New}}) ->
    out("    ~s = ~s", [pad(key_str(K), 46), V]),
    out("        becomes ~s, which the schemas being checked do not map.",
        [key_str(New)]),
    out("        Point --schema-dir at the release you are upgrading TO.", []);
report_finding({K, V, {manual, Candidates, Why}}) ->
    out("    ~s = ~s", [pad(key_str(K), 46), V]),
    wrap("        ", Why),
    lists:foreach(
        fun
            ({New, true, true}) ->
                out("        candidate ~s", [key_str(New)]),
                out("        this line restates the default, so deleting it"
                    " changes nothing", []);
            ({New, true, false}) ->
                out("        candidate ~s", [key_str(New)]);
            ({New, false, _}) ->
                out("        candidate ~s (NOT mapped -- tool bug)", [key_str(New)])
        end,
        Candidates
    );
report_finding({K, V, no_rule}) ->
    out("    ~s = ~s", [pad(key_str(K), 46), V]).

%% Prose in the report is written as one string and wrapped here, so a rule's
%% explanation does not have to be hand-split at the column width.
wrap(Indent, Text) ->
    lists:foreach(
        fun(Line) -> out("~s~s", [Indent, Line]) end,
        wrapped(Text, 78 - length(Indent))
    ).

wrapped(Text, Width) ->
    wrap_lines(string:lexemes(Text, " \n"), Width, [], []).

wrap_lines([], _Width, [], Acc) ->
    lists:reverse(Acc);
wrap_lines([], _Width, Cur, Acc) ->
    lists:reverse([string:join(lists:reverse(Cur), " ") | Acc]);
wrap_lines([W | Rest], Width, Cur, Acc) ->
    Candidate = string:join(lists:reverse([W | Cur]), " "),
    case Cur =/= [] andalso length(Candidate) > Width of
        true ->
            wrap_lines([W | Rest], Width, [],
                [string:join(lists:reverse(Cur), " ") | Acc]);
        false ->
            wrap_lines(Rest, Width, [W | Cur], Acc)
    end.

%% =============================================================================
%% ADVANCED.CONFIG
%% =============================================================================

%% `etc/advanced.config' is overlaid onto the generated sys.config
%% (`cuttlefish_escript.erl:390-397'), and a stanza for an application that does
%% not exist is inert -- no error, no log line. Two such stanzas survive from
%% older deployments: `{bondy, ...}', whose application was renamed
%% `bondy_router', and `{plum_db, ...}', whose application is gone.
%%
%% Rather than a two-row table this asks whether the application EXISTS, so a
%% stanza for any other departed or misspelled application is reported too, and
%% the check does not need editing when an application is next renamed.
%%
%% CHECK ONLY: `advanced.config' is a term file, so rewriting it means consulting
%% and re-printing, which discards every comment. It is reported, never rewritten.
advanced_check(undefined) ->
    [];
advanced_check(File) ->
    case file:consult(File) of
        {ok, [Stanzas]} when is_list(Stanzas) ->
            Known = known_apps(),
            Unknown = [App || {App, _} <- Stanzas, not lists:member(App, Known)],
            advanced_report(File, length(Stanzas), Unknown);
        {ok, Other} ->
            out("", []),
            out("  ADVANCED.CONFIG ~s: expected one list of {App, Opts} pairs,", [File]),
            out("  got ~p terms; not checked.", [length(Other)]),
            ok;
        {error, Reason} ->
            out("", []),
            out("  ADVANCED.CONFIG ~s: cannot read (~p); not checked.",
                [File, Reason]),
            []
    end.

advanced_report(File, Total, []) ->
    out("", []),
    out("  ADVANCED.CONFIG ~s: ~p stanzas, every application exists  OK",
        [File, Total]),
    [];
advanced_report(File, Total, Unknown) ->
    out("", []),
    out("  ADVANCED.CONFIG ~s (~p stanzas)", [File, Total]),
    out("  These name applications this release does not have, so the whole", []),
    out("  stanza is overlaid onto nothing and silently ignored:", []),
    lists:foreach(
        fun(App) ->
            out("", []),
            out("    {~s, ...}", [atom_to_list(App)]),
            wrap("        ", advanced_advice(App))
        end,
        Unknown
    ),
    [{inert_stanza, App} || App <- Unknown].

advanced_advice(bondy) ->
    "the OTP application was renamed bondy_router; rename the stanza. The"
    " release, node name, conf file and WAMP URIs all stay `bondy', which is"
    " why this one is easy to miss.";
advanced_advice(plum_db) ->
    "plum_db was removed; storage is bondy_db. There is no equivalent stanza --"
    " delete this one and set what you need under db.* in bondy.conf.";
advanced_advice(_) ->
    "no application of this name is present. Either it was renamed or removed,"
    " or the stanza is misspelled.".

%% An application is present if OTP resolves it, or the repository builds it, or
%% a release ships it. Checked across all four layouts so the answer does not
%% depend on where this script was run from.
known_apps() ->
    FromDirs = [
        app_name(D)
        || D <- filelib:wildcard("apps/*") ++
            filelib:wildcard("_build/default/lib/*") ++
            filelib:wildcard("lib/*"),
            filelib:is_dir(D)
    ],
    lists:usort([A || A <- FromDirs, A =/= undefined] ++ otp_apps()).

%% `lib/' entries in a release carry a version suffix (`bondy_router-1.2.3');
%% repository and _build entries do not.
app_name(Dir) ->
    Base = filename:basename(Dir),
    case string:split(Base, "-") of
        [Name, _Vsn] -> list_to_atom(Name);
        [Name] -> list_to_atom(Name)
    end.

otp_apps() ->
    [
        app_name(D)
        || D <- filelib:wildcard(filename:join(code:lib_dir(), "*")),
            filelib:is_dir(D)
    ].

%% =============================================================================
%% LISTENER PROVENANCE
%% =============================================================================

%% The second hazard, and the one that is invisible from the symptom.
%%
%% `bondy_listener_manager:init/0' reads `bondy_config:get(listeners, undefined)'.
%% `undefined' means no `listeners.*' key was written -- every
%% `listeners.$name.*' mapping is default-free, so cuttlefish drops the inventory
%% translation entirely -- and the node starts
%% `bondy_listener_config:default_inventory/0', which is THREE plaintext
%% listeners. It is not the historical set: this release deleted the legacy
%% per-listener blocks, so there is no longer any path on which a legacy key
%% starts a listener.
%%
%% That makes a legacy file dangerous in a way it never used to be. Renaming its
%% option keys is not enough on its own either: a `listeners.<name>.*' block with
%% options but no `transport'/`protocol'/bind target is refused at boot with
%% `{invalid_listener, <name>, {missing, transport}}'.
%%
%% The default inventory and the reserved names are read from
%% `bondy_listener_config' itself rather than copied here, so this cannot drift
%% from what the node does.
listener_analysis(Conf, _Schema) ->
    case locate_bondy_router() of
        unavailable ->
            unavailable;
        ok ->
            Declared = declared_listeners(Conf),
            Default = [
                atom_to_list(N)
             || {N, _} <- bondy_listener_config:default_inventory()
            ],
            Reserved = [
                atom_to_list(N) || N <- bondy_listener_config:reserved_names()
            ],
            %% What this file will actually start. On the configured path the
            %% manager injects every reserved name that is absent, so they are
            %% part of the answer whether or not the operator wrote them.
            Effective =
                case Declared of
                    [] -> Default;
                    _ -> lists:usort(Declared ++ Reserved)
                end,
            Legacy = legacy_blocks(Conf),
            Lost = [
                {Name, Keys}
             || {Name, Keys} <- Legacy, not lists:member(Name, Effective)
            ],
            %% A declared listener that carries options but not its identity is
            %% the other half of the same hazard, and the one a key-by-key rename
            %% produces on its own: the file looks migrated and the node refuses
            %% to boot.
            %%
            %% Only the INTERNAL reserved names are exempt, not every reserved
            %% name. `bondy_listener_manager:with_reserved/1' injects a reserved
            %% spec only for a name the operator did NOT write -- it guards on
            %% `lists:keymember/3' -- so a file declaring any `listeners.admin.*'
            %% option puts `admin' into the inventory as an operator entry, and
            %% `resolve_one/3' then requires its identity like any other entry.
            %% Exempting every reserved name reported 7 incomplete listeners for
            %% a migrated file whose actual first boot failure was
            %% `{invalid_listener,admin,{missing,transport}}': MEASURED by
            %% rendering the inventory with `cuttlefish_generator:map/2' and
            %% calling `bondy_listener_config:resolve/2' on the result.
            %%
            %% `admin_local' stays exempt for a different reason: an operator may
            %% not declare it at all, so `assert_reserved/2' refuses the name
            %% outright and "missing identity" would be the wrong diagnosis.
            %% Derived as the reserved names the default inventory does not name,
            %% rather than restated here, because `?RESERVED_INTERNAL' is not
            %% exported.
            Internal = Reserved -- Default,
            Incomplete = [
                {Name, Missing}
             || Name <- Declared,
                not lists:member(Name, Internal),
                Missing <- [missing_identity(Name, Conf)],
                Missing =/= []
            ],
            {listeners, Declared, Effective, Legacy, Lost, Incomplete}
    end.

%% The identity keys `bondy_listener_config:resolve_one/3' reads directly from a
%% spec and raises `{missing, K}' for. Only those: an absent option block is
%% legal and means the driver's own defaults apply.
missing_identity(Name, Conf) ->
    Get = fun(K) -> conf_has(Name, K, Conf) end,
    Transport = [transport || not Get("transport")],
    Protocol = [protocol || not Get("protocol")],
    %% `resolve_bind/3' takes `path' for a uds listener and `port' otherwise, so
    %% either one satisfies this; which of the two is right depends on a
    %% `transport' that may itself be missing.
    Bind = [bind || not Get("port"), not Get("path")],
    %% `resolve_services/3' requires the key for an HTTP listener only.
    Services =
        case conf_value_of(Name, "protocol", Conf) of
            "http" -> [services || not Get("services")];
            _ -> []
        end,
    Transport ++ Protocol ++ Bind ++ Services.

conf_has(Name, Key, Conf) ->
    conf_value_of(Name, Key, Conf) =/= undefined.

conf_value_of(Name, Key, Conf) ->
    case lists:keyfind(["listeners", Name, Key], 1, Conf) of
        {_, Value} -> Value;
        false -> undefined
    end.

%% The legacy per-listener blocks this file writes, grouped by the listener name
%% each block's settings belong to now. Derived from the same table the rename
%% rules use, so the report and the rewrites cannot disagree about which listener
%% a key belongs to.
legacy_blocks(Conf) ->
    Grouped = lists:foldl(
        fun({Key, _}, Acc) ->
            case legacy_block_of(Key) of
                undefined -> Acc;
                Name -> maps:update_with(Name, fun(Ks) -> [Key | Ks] end, [Key], Acc)
            end
        end,
        #{},
        Conf
    ),
    [{Name, lists:sort(Keys)} || {Name, Keys} <- lists:sort(maps:to_list(Grouped))].

legacy_block_of(Key) ->
    case
        lists:search(
            fun({Prefix, _, _}) -> lists:prefix(Prefix, Key) end,
            legacy_listeners()
        )
    of
        {value, {_, Name, _}} -> Name;
        false -> undefined
    end.

%% Two findings, and both are fatal to what the operator asked for. `dropped' is
%% a listener the file configures through a legacy block and the node will not
%% start -- the shape of the failure that presented only as `econnrefused'.
%% `incomplete' is a listener declared with options but no identity, which does
%% not start either: it aborts the whole boot.
listener_findings(unavailable) -> [];
listener_findings({listeners, _Declared, _Effective, _Legacy, Lost, Incomplete}) ->
    [{dropped, N} || {N, _} <- Lost] ++
        [{incomplete, N, K} || {N, Ks} <- Incomplete, K <- Ks].

%% Names mentioned under `listeners.', whatever the tail. One key is enough to
%% flip the provenance gate, which is exactly why this counts mentions rather
%% than complete blocks.
declared_listeners(Conf) ->
    lists:usort([Name || {["listeners", Name | _], _} <- Conf]).
%% bondy_listener_config lives in the bondy_router application. Both layouts are
%% supported for the same reason the cuttlefish lookup supports both.
locate_bondy_router() ->
    case code:ensure_loaded(bondy_listener_config) of
        {module, _} ->
            ok;
        _ ->
            Dirs = ["_build/default/lib/bondy_router/ebin"] ++
                filelib:wildcard("lib/bondy_router-*/ebin"),
            case lists:search(fun filelib:is_dir/1, Dirs) of
                {value, Dir} ->
                    true = code:add_pathz(Dir),
                    case code:ensure_loaded(bondy_listener_config) of
                        {module, _} -> ok;
                        _ -> unavailable
                    end;
                false ->
                    unavailable
            end
    end.

%% -----------------------------------------------------------------------------
%% Listener report
%% -----------------------------------------------------------------------------

listener_report(unavailable) ->
    out("", []),
    out("  LISTENERS: not checked -- bondy_listener_config could not be loaded.", []),
    out("  Either this is not a built checkout or unpacked release, or the", []),
    out("  release predates listeners.* and so has no such module. Reported", []),
    out("  rather than skipped: without that table this check proves nothing.", []),
    ok;
listener_report({listeners, Declared, Effective, Legacy, Lost, Incomplete}) ->
    out("", []),
    case Declared of
        [] ->
            out("  LISTENERS: this file writes no listeners.* key, so the node", []),
            out("  starts the built-in default inventory and nothing else:", []);
        _ ->
            out("  LISTENERS: this file declares listeners.* keys, so the node", []),
            out("  starts exactly what it declares, plus any reserved name:", [])
    end,
    [out("    ~s", [N]) || N <- Effective],
    report_incomplete(Incomplete),
    report_lost(Lost),
    case Legacy of
        [] ->
            ok;
        _ ->
            out("", []),
            out("  This file still writes ~p legacy per-listener block~s. Renaming"
                " their keys",
                [length(Legacy), plural(length(Legacy))]),
            out("  (above) moves the SETTINGS. It does not declare the listener:"
                " a block with", []),
            out("  options but no transport, protocol and bind target is refused"
                " at boot with", []),
            out("  {invalid_listener, <name>, {missing, transport}}.", [])
    end,
    case {Lost, Legacy, Incomplete} of
        {[], [], []} ->
            out("", []),
            out("  No legacy listener block in this file, and every declared"
                " listener has an identity.", []);
        _ ->
            ok
    end,
    ok.

report_incomplete([]) ->
    ok;
report_incomplete(Incomplete) ->
    out("", []),
    out("  WILL NOT BOOT (~p) -- declared with options but not with an identity."
        " Each is",
        [length(Incomplete)]),
    out("  refused by bondy_listener_config:resolve_one/3, which aborts the whole"
        " boot:", []),
    lists:foreach(
        fun({Name, Missing}) ->
            out("", []),
            out("    ~s missing ~s", [pad(Name, 24),
                string:join([atom_to_list(K) || K <- Missing], ", ")]),
            [
                out("        listeners.~s.~s = ...", [Name, key_hint(K)])
             || K <- Missing
            ]
        end,
        Incomplete
    ).

%% `bind' is not a key: it is the port-or-path requirement, and the report has to
%% name something an operator can write.
key_hint(bind) -> "port";
key_hint(K) -> atom_to_list(K).

report_lost([]) ->
    ok;
report_lost(Lost) ->
    out("", []),
    out("  GONE (~p) -- this file configures ~s through a legacy block, and the"
        " node will",
        [length(Lost), case length(Lost) of 1 -> "a listener"; _ -> "listeners" end]),
    out("  not start ~s at all. Every setting below is dead, and so is the"
        " listener:",
        [case length(Lost) of 1 -> "it"; _ -> "them" end]),
    lists:foreach(
        fun({Name, Keys}) ->
            out("", []),
            out("    ~s ~p setting~s", [pad(Name, 24), length(Keys),
                plural(length(Keys))]),
            out("        declare it: listeners.~s.transport, .protocol and"
                " .port (or .path),", [Name]),
            out("        then move the settings onto listeners.~s.*", [Name])
        end,
        Lost
    ).
%% =============================================================================
%% MIGRATE
%% =============================================================================

%% Rewrites a conf file line by line, so comments, blank lines, ordering and the
%% column the `=' sits in all survive. Parsing with cuttlefish_conf and
%% re-emitting would lose every comment in the file, which for a hand-maintained
%% bondy.conf is most of its value.
%%
%% Line-oriented rewriting is sound here rather than merely convenient: the
%% grammar's `setting <- ws* key ws* "=" ws* value ws* comment?'
%% (`conf_parse.peg') is single-line with no continuation, so a setting cannot
%% straddle two lines.
%%
%% WHAT IT DOES NOT DO: it never activates a key that was inert. A renamed key
%% starts applying -- that is the point -- but every other verdict is commented
%% out with its reason inline. Commenting out an unknown key changes nothing at
%% runtime, because cuttlefish was already discarding it; it only makes the
%% discard visible.
%%
%% WHAT IT DOES DO BEYOND RENAMING: it declares each listener whose legacy block
%% it renamed, by emitting the `transport', `protocol' and (for HTTP) `services'
%% keys from `legacy_identity/1'. This is not an exception to the paragraph above
%% -- those listeners were RUNNING on the release the file came from, and a
%% rename alone would leave them declared-but-unbootable, which is a state the
%% input was never in. Without it the output aborts the boot; with it the two
%% together give the round-trip property: check mode reports the output clean,
%% for keys AND for listeners.
migrate(ConfFile, Out, SchemaDirs0) ->
    Out =/= ConfFile orelse throw({fail,
        "--out must differ from the input; this tool never rewrites in place",
        []}),
    not filelib:is_file(Out) orelse throw({fail,
        "~s already exists; refusing to overwrite it", [Out]}),
    SchemaDirs = resolve_schema_dirs(SchemaDirs0),
    {Schema, Validators} = schema_and_validators(SchemaDirs),
    Conf = read_conf(ConfFile),
    Findings = classify(Conf, Schema),
    Verdicts = maps:from_list([{K, Verdict} || {K, _, Verdict} <- Findings]),

    {ok, Bin} = file:read_file(ConfFile),
    {Lines, Eol} = split_lines(binary_to_list(Bin)),
    {NewLines0, {Actions, Undeclared}} = lists:mapfoldl(
        fun(Line, {Acc, Todo}) ->
            case migrate_line(Line, Verdicts) of
                unchanged ->
                    %% An anchor even though the line itself does not change: a
                    %% file already written against `listeners.*' but missing an
                    %% identity needs the block too, and its lines are all
                    %% `unchanged'.
                    {Emitted, Todo1} = identity_before(Line, Verdicts, Todo),
                    {Emitted ++ [Line], {acted(Emitted, Acc), Todo1}};
                {changed, New, Action} ->
                    {Emitted, Todo1} = identity_before(Line, Verdicts, Todo),
                    {Emitted ++ New,
                        {[Action | acted(Emitted, Acc)], Todo1}}
            end
        end,
        {[], pending_identity(Conf)},
        Lines
    ),
    %% Anchored emission covers every listener the file mentions, so anything
    %% left here would be a listener with an identity to write and no line to
    %% write it against -- which `pending_identity/1' cannot produce, since it
    %% only names listeners derived from keys the file contains. Asserted rather
    %% than assumed: silently dropping an identity is the exact failure this
    %% change exists to remove.
    #{} = Undeclared,
    map_size(Undeclared) == 0 orelse
        throw({fail, "internal: no anchor for listener identity: ~s",
            [string:join(maps:keys(Undeclared), ", ")]}),
    ok = file:write_file(Out, string:join(lists:append(NewLines0), Eol)),
    migrate_report(ConfFile, Out, length(Conf), lists:reverse(Actions)),
    %% Reported here too, and not only by check mode: an operator who only ever
    %% runs migrate would otherwise see a clean summary and never learn that an
    %% advanced.config stanza is inert, that a key copied through unchanged now
    %% means something else, or that a listener still will not start.
    ok = report_reinterpreted(reinterpretations(Conf)),

    %% Everything below describes the OUTPUT, not the input. Reporting the
    %% input's listeners was actively misleading once migrate began declaring
    %% them: it printed "this file writes no listeners.* key" and named five
    %% GONE listeners for a run that had just declared all eight. What an
    %% operator needs from `migrate' is what the file they are about to deploy
    %% will do, and the only way to answer that without a second implementation
    %% is to read the file back.
    OutConf = read_conf(Out),
    Listeners = listener_analysis(OutConf, Schema),
    ok = listener_report(Listeners),
    Advanced = advanced_check(sibling_advanced_config(ConfFile)),
    KeyFindings = classify(OutConf, Schema),
    %% Reported, never repaired. Every other verdict this tool acts on is a
    %% mechanical fact about a KEY -- a rename has one destination, an unknown
    %% key can only be commented out. A value the schema refuses has no such
    %% answer: only the operator knows what they meant by it, and writing a guess
    %% into their file would be the one edit here that changes behaviour without
    %% being able to justify itself. So the bad value is copied through and shows
    %% up in the output's own verdict, which is what makes `migrate && deploy'
    %% exit non-zero on a file that cannot generate.
    ValueFindings = value_faults(OutConf, Schema, Validators),
    ok = report_values(ValueFindings),
    ListenerFindings = listener_findings(Listeners) ++ Advanced,
    ok = verdict_line(
        KeyFindings, ValueFindings, ListenerFindings, reinterpretations(OutConf)
    ),
    {KeyFindings, ValueFindings, ListenerFindings}.

%% Keeps the file's own line ending and whether it ended with a newline, so a
%% migration of an unchanged region is byte-identical.
split_lines(Text) ->
    Eol = case string:find(Text, "\r\n") of
        nomatch -> "\n";
        _ -> "\r\n"
    end,
    {string:split(Text, Eol, all), Eol}.

migrate_line(Line, Verdicts) ->
    case split_setting(Line) of
        not_a_setting ->
            unchanged;
        {Indent, Key, Tail} ->
            case maps:find(Key, Verdicts) of
                error ->
                    unchanged;
                {ok, {rename, New}} ->
                    {changed, [Indent ++ key_text(New) ++ Tail],
                        {renamed, Key, New}};
                {ok, Verdict} ->
                    {changed, comment_out(Line, Verdict),
                        {disabled, Key, Verdict}}
            end
    end.

%% The identity each listener still needs, keyed by name. A listener is in here
%% only if this file will end up declaring it AND `legacy_identity/1' knows what
%% it is AND the file does not already say so itself.
%%
%% Both sources are consulted. `legacy_blocks/1' names the listeners this
%% migration is about to create by renaming; `declared_listeners/1' names those a
%% file already written against `listeners.*' declares, which catches a file
%% migrated by hand or by an older run of this tool. A name in neither table --
%% an operator's own listener under a name of their choosing -- is deliberately
%% absent: nothing here knows what it carries, so `check' reports it and the
%% caller sees a non-zero exit rather than a guess written into their file.
%%
%% Per-KEY rather than per-listener, so a half-declared block is completed
%% instead of duplicated: an operator who wrote `transport' by hand but no
%% `protocol' gets only the `protocol' line.
pending_identity(Conf) ->
    Names = lists:usort(
        [N || {N, _} <- legacy_blocks(Conf)] ++ declared_listeners(Conf)
    ),
    maps:from_list([
        {Name, Missing}
     || Name <- Names,
        Identity <- [legacy_identity(Name)],
        Identity =/= undefined,
        Missing <- [[KV || {K, _} = KV <- Identity, not conf_has(Name, K, Conf)]],
        Missing =/= []
    ]).

%% The identity lines to emit immediately above `Line', if this is the first line
%% belonging to a listener that still needs one.
%%
%% "Belonging to" is decided the same way for both anchor shapes: the key's
%% destination after `Verdicts' is applied. A legacy key that renames into
%% `listeners.<name>.*' and a key already written as `listeners.<name>.*' both
%% resolve to the same name, so one clause handles both and neither can emit
%% twice -- the name is removed from `Todo' on the first hit.
identity_before(Line, Verdicts, Todo) when map_size(Todo) > 0 ->
    case destination_listener(Line, Verdicts) of
        undefined ->
            {[], Todo};
        Name ->
            case maps:take(Name, Todo) of
                error ->
                    {[], Todo};
                {Identity, Todo1} ->
                    {identity_lines(Name, Identity), Todo1}
            end
    end;
identity_before(_Line, _Verdicts, Todo) ->
    {[], Todo}.

%% @private
%% Which listener a line's setting ends up under, or `undefined' for a line that
%% is not a setting, is not renamed into a listener block and is not already in
%% one. A commented-out verdict returns `undefined' deliberately: a dropped key
%% is not a reason to declare anything.
destination_listener(Line, Verdicts) ->
    case split_setting(Line) of
        not_a_setting ->
            undefined;
        {_Indent, Key, _Tail} ->
            case maps:find(Key, Verdicts) of
                {ok, {rename, ["listeners", Name | _]}} -> Name;
                {ok, _} -> undefined;
                error ->
                    case Key of
                        ["listeners", Name | _] -> Name;
                        _ -> undefined
                    end
            end
    end.

%% @private
%% Written with the reason inline, because an operator reading the migrated file
%% finds keys here that they never wrote and the diff does not say why.
identity_lines(Name, Identity) ->
    [
        "## migrate_conf: " ++ L
     || L <-
            wrapped(
                "declares the `" ++ Name ++ "' listener. Renaming its keys moves"
                " the settings; `bondy_listener_config:resolve_one/3' also needs"
                " the listener's identity, and aborts the boot without it.",
                74
            )
    ] ++ [key_text(["listeners", Name, K]) ++ " = " ++ V || {K, V} <- Identity].

%% @private
%% One `declared' action per emitted block, so `migrate_report/4' can name what it
%% wrote. Takes the emitted lines rather than the name so the caller cannot record
%% a block it did not emit.
acted([], Acc) ->
    Acc;
acted(Lines, Acc) ->
    [{declared, declared_name_of(Lines)} | Acc].

%% @private
declared_name_of(Lines) ->
    %% The first non-comment line is `listeners.<name>.<key> = <value>'.
    [Setting | _] = [L || L <- Lines, not lists:prefix("##", L)],
    {_Indent, ["listeners", Name | _], _Tail} = split_setting(Setting),
    Name.

%% A key that cannot be renamed is commented out, with the reason wrapped into
%% comment lines directly above it, so the operator can see what was set, what
%% happened to it and why without a second file to cross-reference.
comment_out(Line, Verdict) ->
    [
        "## migrate_conf: " ++ L
        || L <- wrapped(one_line(reason(Verdict)), 74)
    ] ++ ["## " ++ Line].

reason({drop, Why}) ->
    "dropped -- " ++ Why;
reason({contested, New, Why}) ->
    "NOT renamed to " ++ key_str(New) ++ " -- " ++ Why;
reason({manual, Candidates, Why}) ->
    Cs = [key_str(K) || {K, true, _} <- Candidates],
    "needs a decision -- " ++ Why ++
        case Cs of
            [] -> "";
            _ -> " (candidates: " ++ string:join(Cs, ", ") ++ ")"
        end ++
        %% The same note the check report carries. It belongs here too: the
        %% migrated file is what the operator edits, and a commented-out line
        %% that only restated the default needs no decision at all.
        case [K || {K, true, true} <- Candidates] of
            [] -> "";
            _ -> " This line restates the default, so deleting it changes"
                " nothing."
        end;
reason({collides, New, _Value, Existing}) ->
    "not renamed -- " ++ key_str(New) ++ " is already set to " ++ Existing ++
        " in this file, and two lines for one key means the last one wins;"
        " commenting this out keeps the explicit setting in force";
reason({unmapped_target, New}) ->
    "renamed to " ++ key_str(New) ++ " in a later release than the schemas"
        " being checked; not rewritten here";
reason(no_rule) ->
    "no rule for this key; it is not read by this release".

one_line(Text) ->
    string:join(string:lexemes(Text, "\n"), " ").

dedup_actions(Actions) ->
    lists:foldr(
        fun(A, Acc) ->
            case lists:any(fun(B) -> element(2, B) == element(2, A) end, Acc) of
                true -> Acc;
                false -> [A | Acc]
            end
        end,
        [],
        Actions
    ).

plural(1) -> "";
plural(_) -> "s".

%% Splits a line into {Indent, KeySegments, Tail} where Tail runs from the
%% whitespace before `=' to the end of the line, so reassembly preserves the
%% value, any trailing comment, and the column the `=' was in.
%%
%% Deliberately conservative: anything that is not unmistakably a setting is left
%% alone. A false negative leaves a line untouched and check mode still reports
%% the key; a false positive would corrupt an operator's file.
split_setting(Line) ->
    Indent = lists:takewhile(fun(C) -> C == $\s orelse C == $\t end, Line),
    Rest = lists:nthtail(length(Indent), Line),
    case Rest of
        [$# | _] ->
            not_a_setting;
        "" ->
            not_a_setting;
        _ ->
            case string:split(Rest, "=") of
                [_] ->
                    not_a_setting;
                [KeyRaw, Value] ->
                    KeyText = string:trim(KeyRaw, trailing),
                    WsBeforeEq = lists:nthtail(length(KeyText), KeyRaw),
                    case is_key_text(KeyText) of
                        true ->
                            {Indent, key_segments(KeyText),
                                WsBeforeEq ++ "=" ++ Value};
                        false ->
                            not_a_setting
                    end
            end
    end.

%% The grammar's `word <- ("\\." / [A-Za-z0-9_-])+', dot-separated. `include'
%% lines have no `=' and so never reach here, and a `$' cannot appear in a conf
%% key at all -- `$name' exists only in schemas.
is_key_text("") ->
    false;
is_key_text(Text) ->
    lists:all(
        fun(C) ->
            (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
                (C >= $0 andalso C =< $9) orelse C == $_ orelse C == $- orelse
                C == $. orelse C == $\\
        end,
        Text
    ).

%% Split on unescaped dots, then unescape, matching the grammar's
%% `unescape_dots'.
key_segments(Text) ->
    key_segments(Text, [], []).

key_segments([], Cur, Acc) ->
    lists:reverse([lists:reverse(Cur) | Acc]);
key_segments([$\\, $. | Rest], Cur, Acc) ->
    key_segments(Rest, [$. | Cur], Acc);
key_segments([$. | Rest], Cur, Acc) ->
    key_segments(Rest, [], [lists:reverse(Cur) | Acc]);
key_segments([C | Rest], Cur, Acc) ->
    key_segments(Rest, [C | Cur], Acc).

%% The inverse: a literal dot inside a segment must go back out escaped, or the
%% rewritten key would parse as two segments.
key_text(Segments) ->
    string:join([escape_dots(S) || S <- Segments], ".").

escape_dots(Segment) ->
    lists:append([case C of $. -> "\\."; _ -> [C] end || C <- Segment]).

migrate_report(ConfFile, Out, Total, Actions) ->
    %% Counted per KEY, not per action: a key set on two lines is rewritten
    %% twice, and mixing the two units gave a "left as they were" figure that
    %% did not add up.
    Renamed = dedup_actions([A || {renamed, _, _} = A <- Actions]),
    Disabled = dedup_actions([A || {disabled, _, _} = A <- Actions]),
    Declared = [N || {declared, N} <- Actions],
    %% `declared' actions are excluded from the line arithmetic: they ADD lines
    %% rather than rewriting one, so counting them made "lines rewritten" exceed
    %% the number of lines that changed and reported phantom duplicate keys.
    Lines = length(Actions) - length(Declared),
    Keys = length(Renamed) + length(Disabled),
    out("migrated ~s -> ~s", [ConfFile, Out]),
    out("  ~p keys read, ~p renamed, ~p commented out, ~p left as they were",
        [Total, length(Renamed), length(Disabled), Total - Keys]),
    Lines > Keys andalso
        out("  (~p lines rewritten: ~p key~s set more than once)",
            [Lines, Lines - Keys, plural(Lines - Keys)]),
    case Renamed of
        [] -> ok;
        _ ->
            out("", []),
            out("  RENAMED -- these settings now take effect. Check that each", []),
            out("  value is still what you want, since it was being ignored:", []),
            [out("    ~s ->  ~s", [pad(key_str(K), 46), key_str(New)])
                || {renamed, K, New} <- Renamed]
    end,
    case Disabled of
        [] -> ok;
        _ ->
            out("", []),
            out("  COMMENTED OUT -- already inert before this migration, now", []),
            out("  visibly so. Each carries its reason inline in the file:", []),
            [begin
                out("    ~s", [key_str(K)]),
                wrap("        ", reason(V))
             end || {disabled, K, V} <- Disabled]
    end,
    case Declared of
        [] -> ok;
        _ ->
            out("", []),
            out("  DECLARED -- keys ADDED, which no other verdict does. Each of", []),
            out("  these listeners ran on the release this file came from, and", []),
            out("  a rename alone would leave it declared but unbootable:", []),
            [out("    ~s ~s", [pad(N, 24),
                string:join([K ++ " = " ++ V || {K, V} <- legacy_identity(N)],
                    ", ")])
             || N <- Declared]
    end.

%% =============================================================================
%% SCHEMA AND CONF LOADING
%% =============================================================================

%% The UNION of every mapping in every schema set, as {Variable, Mapping} pairs.
%%
%% The union, rather than the per-set intersection of complaints the pre-start
%% hook's three invocations force: a key is unknown iff nothing anywhere maps it,
%% and computing that directly removes the per-set false positives the hook's
%% --allow_extra exists to tolerate. Duplicates across files are harmless -- this
%% answers "does anything map this key", and for a default only the shape of the
%% value matters.
%% The mappings AND the validator table, from one parse. `value_faults/3' needs
%% both: a mapping names its validators only by name, and
%% `cuttlefish_mapping:validators/2' resolves them against this table -- the same
%% call `cuttlefish_generator:run_validations/2' makes, so the two cannot disagree
%% about which validator guards a key.
schema_and_validators(SchemaDirs) ->
    Files = lists:append([filelib:wildcard(filename:join(D, "*.schema"))
        || D <- SchemaDirs]),
    Files == [] andalso throw({fail,
        "no .schema files under: ~s", [string:join(SchemaDirs, " ")]}),
    case cuttlefish_schema:files(Files) of
        {_Translations, Mappings, Validators} when is_list(Mappings) ->
            Mappings == [] andalso throw({fail,
                "~p schema files yielded no mappings", [length(Files)]}),
            {[{cuttlefish_mapping:variable(M), M} || M <- Mappings], Validators};
        Other ->
            throw({fail, "cannot load schemas: ~p", [Other]})
    end.

read_conf(ConfFile) ->
    filelib:is_regular(ConfFile) orelse
        throw({fail, "no such conf file: ~s", [ConfFile]}),
    case cuttlefish_conf:file(ConfFile) of
        Conf when is_list(Conf) ->
            Conf;
        {errorlist, Errors} ->
            throw({fail, "cannot parse ~s:~n~s", [ConfFile,
                string:join([lists:flatten(io_lib:format("        ~p", [E]))
                    || E <- Errors], "\n")]})
    end.

%% Where the .schema files live, in the two layouts that exist. Auto-detection
%% mirrors `rebar.config''s {scuttler, [{schemas, ...}]} block (:1030-1053) for
%% the repository, and the generated hook's --schema_dir values for a release.
resolve_schema_dirs([]) ->
    Detected = [D || D <- schema_dirs(), filelib:wildcard(
        filename:join(D, "*.schema")) =/= []],
    Detected == [] andalso throw({fail,
        "cannot find any .schema directory from ~s; pass --schema-dir",
        [element(2, file:get_cwd())]}),
    Detected;
resolve_schema_dirs(Dirs) ->
    Dirs.

schema_dirs() ->
    %% Repository layout: the three sets the scuttler block declares. Release
    %% layout: `releases/<vsn>' holds vm_args.schema and `releases/<vsn>/schema'
    %% holds the application schemas -- which is where the release ALSO puts
    %% riak_sysmon's, so a release has two directories where the repository has
    %% three.
    ["schema", "schema/hidden", "_build/default/lib/riak_sysmon/priv"] ++
        lists:append([[D, filename:join(D, "schema")]
            || D <- filelib:wildcard("releases/*")]).

%% =============================================================================
%% CUTTLEFISH
%% =============================================================================

%% Load cuttlefish from wherever this invocation can reach it. Both branches are
%% probe-verified. A release does not carry cuttlefish's beams loose -- they are
%% inside the `bin/cuttlefish' escript's archive section -- so they are extracted
%% to a .ez and put on the path.
locate_cuttlefish() ->
    case code:ensure_loaded(cuttlefish_conf) of
        {module, cuttlefish_conf} ->
            ok;
        _ ->
            try_cuttlefish_sources(cuttlefish_sources())
    end.

cuttlefish_sources() ->
    [
        {ebin, "_build/default/plugins/cuttlefish/ebin"},
        {escript, "bin/cuttlefish"},
        {escript, "_build/default/rel/bondy/bin/cuttlefish"}
    ].

try_cuttlefish_sources([]) ->
    throw({fail,
        "cannot find cuttlefish. Run this from a built checkout (it needs~n"
        "       _build/default/plugins/cuttlefish/ebin, so `rebar3 compile'~n"
        "       first) or from the root of an unpacked release (which carries~n"
        "       bin/cuttlefish).", []});
try_cuttlefish_sources([Source | Rest]) ->
    case add_cuttlefish(Source) of
        ok ->
            case code:ensure_loaded(cuttlefish_conf) of
                {module, cuttlefish_conf} -> ok;
                _ -> try_cuttlefish_sources(Rest)
            end;
        error ->
            try_cuttlefish_sources(Rest)
    end.

add_cuttlefish({ebin, Dir}) ->
    case filelib:is_dir(Dir) of
        true ->
            true = code:add_pathz(Dir),
            ok;
        false ->
            error
    end;
add_cuttlefish({escript, Path}) ->
    case filelib:is_regular(Path) of
        false ->
            error;
        true ->
            case escript:extract(Path, []) of
                {ok, Sections} ->
                    case lists:keyfind(archive, 1, Sections) of
                        {archive, Bin} -> add_cuttlefish_archive(Bin);
                        false -> error
                    end;
                {error, _} ->
                    error
            end
    end.

add_cuttlefish_archive(Bin) ->
    %% The .ez name carries the OS pid so two concurrent runs cannot read each
    %% other's half-written file.
    Ez = filename:join(tmp_dir(), "cuttlefish_" ++ os:getpid() ++ ".ez"),
    case file:write_file(Ez, Bin) of
        ok ->
            true = code:add_pathz(filename:join([Ez, "cuttlefish", "ebin"])),
            ok;
        {error, _} ->
            error
    end.

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        Dir -> Dir
    end.

%% =============================================================================
%% SELFTEST
%% =============================================================================

%% Guards this script against passing vacuously, in the spirit of
%% check_layering.escript's canaries. Two corpora with independently established
%% answers: the shipped files must be clean, and their pre-cleanup versions must
%% yield exactly the dead keys that were found by hand.
%%
%% The count is 86, not the 28 of the first audit, because keys the corpus sets
%% have since stopped being read: 56 of them when the eight legacy per-listener
%% blocks were deleted from the schemas, and 2 more when
%% `wamp.dealer.pattern_based_registration' and
%% `wamp.broker.pattern_based_subscription' stopped being configurable. Every one
%% was LIVE when the first audit ran, so it was correctly not counted then. This
%% number rises as mappings are retired and falls only if one comes back -- the
%% corpus is read from a fixed git ref and cannot drift.
%%
%% 91, not 86, since `classify/2' stopped treating a legacy-block key as live
%% merely because a fuzzy mapping from another family matches it. The five are
%% `bridge.listener.tls.' + `cacertfile', `certfile', `keyfile', `verify' and
%% `versions': each has a `bridge.$name.tls.<same>' counterpart that matches with
%% `$name = "listener"', so each looked live while naming a bridge relay CLIENT
%% the operator never configured. They are the whole of the difference --
%% MEASURED by running both filters over a file holding all eight
%% `bridge.listener.tls.*' spellings, where the other three (`idle_timeout',
%% `ping', `max_frame_size') have no `bridge.$name.' counterpart at that depth
%% and were already classified.
%%
%% 103, not 91, since the twelve `wamp.websocket.*' spellings the corpus sets
%% stopped being read with the global carrier blocks. The corpus holds no
%% `wamp.sse.*' or `wamp.longpoll.*' key, so those blocks' removal moves this
%% number not at all -- their rules are covered by the rule table check instead.
-define(DIRTY_REF, "8dd090bf^").
-define(DIRTY_EXPECTED, 103).

selftest(SchemaDirs0) ->
    SchemaDirs = resolve_schema_dirs(SchemaDirs0),
    {Schema, Validators} = schema_and_validators(SchemaDirs),
    out("selftest: ~p mappings from ~s", [length(Schema),
        string:join(SchemaDirs, " ")]),
    Results = [
        selftest_rules(Schema),
        selftest_clean(Schema),
        selftest_dirty(Schema),
        selftest_noop(SchemaDirs),
        selftest_roundtrip(SchemaDirs),
        selftest_synthesis(SchemaDirs),
        selftest_listeners(Schema),
        selftest_reinterpreted(Schema),
        selftest_values(SchemaDirs, {Schema, Validators}),
        selftest_capabilities(Schema),
        selftest_carrier_paths(Schema)
    ],
    case [R || R <- Results, R =/= ok] of
        [] ->
            out("~nselftest OK", []),
            ?EXIT_CLEAN;
        Failures ->
            err("~nselftest FAILED (~p of ~p)", [length(Failures),
                length(Results)]),
            ?EXIT_FINDINGS
    end.

%% `carrier_path/1' is this tool's copy of where a `listeners.$name.<carrier>.*'
%% key lands inside the carrier's option block, and the schema translation is
%% what actually decides that. A copy nothing checks is how the two drift, so
%% every carrier key in the schema is resolved through it here and must land on
%% a real entry of `bondy_listener_config:carrier_defaults/1'.
%%
%% Two ways this fails, and both are the point: a carrier key added to the
%% schema with no default behind it, and a key whose rendered name differs from
%% its conf name without `carrier_path/1' being told. Either would silently stop
%% the "this line restates the default" annotation firing for that key -- the
%% annotation would just never appear, which is the failure mode a report cannot
%% show you.
%%
%% Vacuous if it ever matched nothing, so the count is asserted too.
selftest_carrier_paths(Schema) ->
    Keys = [
        {Carrier, Tail}
     || {["listeners", "$name", Carrier | Tail], _} <- Schema,
        Tail =/= [],
        lists:member(Carrier, ["websocket", "sse", "longpoll"])
    ],
    Bad = [
        key_str(["listeners", "$name", C | T])
     || {C, T} <- Keys,
        carrier_default(list_to_atom(C), carrier_path(T)) == undefined
    ],
    case {Keys, Bad} of
        {[], _} ->
            err("  carrier paths: no carrier key found in the schema -- this"
                " check has gone vacuous", []),
            failed;
        {_, []} ->
            out("  carrier paths: ~p carrier keys, every one lands on a"
                " default  OK", [length(Keys)]),
            ok;
        _ ->
            err("  carrier paths: ~p of ~p land on no default:",
                [length(Bad), length(Keys)]),
            [err("      ~s", [B]) || B <- Bad],
            failed
    end.

%% Every rule must name a live destination. A `{rewrite, {all, ...}}' names a
%% whole key, so it is checked outright; a head or tail rewrite names a fragment,
%% so it is checked by requiring that some mapping starts, or ends, with it. This
%% is what makes the rule table safe to extend: a typo fails here rather than
%% sending an operator to a second key this release does not read.
selftest_rules(Schema) ->
    Vars = [Var || {Var, _} <- Schema],
    Bad = lists:append([rule_faults(R, Vars) || R <- rules()]),
    case Bad of
        [] ->
            out("  rule table: ~p rules, every destination is mapped  OK",
                [length(rules())]),
            ok;
        _ ->
            err("  rule table: ~p destinations are not mapped:", [length(Bad)]),
            [err("      ~s", [B]) || B <- Bad],
            failed
    end.

rule_faults({Selector, {rewrite, Rewrite}}, Vars) ->
    rewrite_faults(Selector, Rewrite, Vars);
rule_faults({Selector, {manual, Rewrites, _}}, Vars) ->
    lists:append([rewrite_faults(Selector, R, Vars) || R <- Rewrites]);
rule_faults({_Selector, {drop, _}}, _Vars) ->
    [].

rewrite_faults(Selector, {all, _, New}, Vars) ->
    case lists:any(fun(V) -> cuttlefish_variable:is_fuzzy_match(New, V) end, Vars) of
        true -> [];
        false -> [fault(Selector, New, "no mapping matches it")]
    end;
rewrite_faults(Selector, {head, _, New}, Vars) ->
    case lists:any(fun(V) -> fuzzy_prefix(New, V) end, Vars) of
        true -> [];
        false -> [fault(Selector, New, "no mapping starts with it")]
    end;
rewrite_faults(Selector, {tail, _, New}, Vars) ->
    case lists:any(fun(V) -> lists:suffix(New, V) end, Vars) of
        true -> [];
        false -> [fault(Selector, New, "no mapping ends with it")]
    end.

%% `lists:prefix/2' with cuttlefish's `$name' semantics: a `$'-prefixed segment
%% of the MAPPING matches any one segment of the destination fragment. A plain
%% prefix test is wrong here because a head rewrite that targets a per-listener
%% key names a concrete listener (`listeners.admin.http'), while the only mapping
%% that reads it is fuzzy (`listeners.$name.http.active_n') -- so every one of
%% those rules would report as unmapped.
fuzzy_prefix([], _) ->
    true;
fuzzy_prefix(_, []) ->
    false;
fuzzy_prefix([S | Ss], [V | Vs]) ->
    case V of
        [$$ | _] -> fuzzy_prefix(Ss, Vs);
        S -> fuzzy_prefix(Ss, Vs);
        _ -> false
    end.

fault(Selector, New, Why) ->
    lists:flatten(io_lib:format("~p -> ~s: ~s",
        [Selector, key_str(New), Why])).

selftest_clean(Schema) ->
    Files = shipped_conf_files(),
    Files == [] andalso throw({fail, "selftest: no shipped conf files found", []}),
    Unknown = lists:append([
        [{F, K} || {K, _} <- read_conf(F), not is_known(K, Schema)]
        || F <- Files
    ]),
    case Unknown of
        [] ->
            out("  clean corpus: ~p files, 0 unknown keys  OK", [length(Files)]),
            ok;
        _ ->
            err("  clean corpus: ~p files, expected 0 unknown, got ~p:",
                [length(Files), length(Unknown)]),
            [err("      ~s: ~s", [F, key_str(K)]) || {F, K} <- Unknown],
            failed
    end.

selftest_dirty(Schema) ->
    case dirty_corpus() of
        {error, Reason} ->
            %% Not a pass. A corpus that cannot be read proves nothing, and
            %% silently skipping it is how a check starts passing vacuously.
            err("  dirty corpus: UNAVAILABLE (~s) -- cannot confirm this script"
                " detects anything", [Reason]),
            failed;
        {ok, Contents} ->
            Findings = lists:append([
                begin
                    Conf = conf_from_string(Name, Body),
                    classify(Conf, Schema)
                end
                || {Name, Body} <- Contents
            ]),
            Distinct = lists:usort([K || {K, _, _} <- Findings]),
            Counted = selftest_dirty_count(Contents, Distinct, Findings),
            Covered = selftest_dirty_coverage(Findings),
            case [R || R <- [Counted, Covered], R =/= ok] of
                [] -> ok;
                _ -> failed
            end
    end.

selftest_dirty_count(Contents, Distinct, Findings) ->
    case length(Distinct) of
        ?DIRTY_EXPECTED ->
            out("  dirty corpus: ~p files, ~p distinct unknown keys"
                " (~p occurrences)  OK",
                [length(Contents), length(Distinct), length(Findings)]),
            ok;
        N ->
            err("  dirty corpus: expected ~p distinct unknown keys, got ~p:",
                [?DIRTY_EXPECTED, N]),
            [err("      ~s", [key_str(K)]) || K <- Distinct],
            failed
    end.

%% Every key in the dirty corpus was resolved by hand, so the rule table must
%% have something to say about each. A key falling through to `no_rule' is a gap
%% in the table; `unmapped_target' against the CURRENT schemas would be a fault
%% in it.
selftest_dirty_coverage(Findings) ->
    Gaps = lists:usort([{tag_of(F), element(1, F)}
        || F <- Findings, lists:member(tag_of(F), [no_rule, unmapped_target])]),
    case Gaps of
        [] ->
            Tags = [tag_of(F) || F <- Findings],
            out("  rule coverage: all ~p findings classified (~s)  OK",
                [length(Findings), tally(Tags)]),
            ok;
        _ ->
            err("  rule coverage: ~p unclassified:", [length(Gaps)]),
            [err("      ~s ~s", [atom_to_list(T), key_str(K)]) || {T, K} <- Gaps],
            failed
    end.

tally(Tags) ->
    Counts = [{T, length([X || X <- Tags, X == T])} || T <- lists:usort(Tags)],
    string:join([atom_to_list(T) ++ "=" ++ integer_to_list(N)
        || {T, N} <- Counts], " ").

%% Three invariants over the shipped files.
%%
%% 1. No shipped file may write a legacy per-listener block at all. This is the
%%    strict form: the weaker "loses no listener" passed a file that kept 26
%%    `admin_api.http.*' options nothing read, which is the regression that
%%    prompted it.
%% 2. No shipped file may lose a listener it configures.
%% 3. Every listener a shipped file declares must carry its identity, or that
%%    file cannot boot at all. A key-by-key rename satisfies 1 and 2 while
%%    violating this one, so it is checked separately.
%%
%% All three are falsifiable and were falsified: injecting `wamp.tls.backlog'
%% into a shipped template fails 1, and deleting a `listeners.<name>.transport'
%% line fails 3.
selftest_listeners(Schema) ->
    Results = [
        {F, listener_analysis(read_conf(F), Schema)}
        || F <- shipped_conf_files()
    ],
    case [F || {F, unavailable} <- Results] of
        [] ->
            %% Every shipped file must be fully migrated: no legacy
            %% per-listener block at all, which subsumes the weaker "loses no
            %% listener". Matching on `{listeners, ...}` rather than a wildcard
            %% is deliberate -- a shape change here must fail this check, not
            %% pass it vacuously by matching nothing.
            Analyses = [A || {_, A} <- Results],
            length(Analyses) ==
                length([A || {listeners, _, _, _, _, _} = A <- Analyses])
                orelse
                throw({fail,
                    "selftest: listener_analysis returned an unexpected shape",
                    []}),
            Lost = [{F, N}
                || {F, {listeners, _, _, _, L, _}} <- Results, {N, _} <- L],
            Legacy = [{F, N}
                || {F, {listeners, _, _, Ls, _, _}} <- Results, {N, _} <- Ls],
            Incomplete = [{F, N}
                || {F, {listeners, _, _, _, _, I}} <- Results, {N, _} <- I],
            case {Lost, Legacy, Incomplete} of
                {[], [], []} ->
                    out("  listeners: ~p files, none writes a legacy per-listener"
                        " block and every declared listener has an identity  OK",
                        [length(Results)]),
                    ok;
                _ ->
                    [err("  listeners: ~s loses ~s -- configured through a legacy"
                        " block and not declared", [F, N]) || {F, N} <- Lost],
                    [err("  listeners: ~s still writes the legacy block for ~s",
                        [F, N]) || {F, N} <- Legacy],
                    [err("  listeners: ~s declares ~s without an identity -- that"
                        " file cannot boot", [F, N]) || {F, N} <- Incomplete],
                    failed
            end;
        Missing ->
            err("  listeners: UNAVAILABLE for ~p files -- bondy_listener_config"
                " could not be loaded, so this check proves nothing",
                [length(Missing)]),
            failed
    end.

%% Two invariants over the changed-meaning table.
%%
%% 1. Every entry must name a key this release still READS. That is what
%%    distinguishes this section from `classify/2': an entry left behind for a
%%    deleted key would sit here firing on nothing, while the key itself was
%%    reported as unknown two sections higher.
%% 2. Over the shipped corpus the table must flag at least one key, or nothing
%%    here proves the matching works at all.
%%
%% One mutation falsifies both, which is why they are checked together: changing
%% a segment of the entry's pattern makes it name a key no mapping reads AND
%% takes the corpus count to zero. Run, and it does.
%%
%% What is NOT checked is that an entry flags only the key it means to, because
%% nothing mechanical can be: this script cannot know which key's meaning
%% changed. Depth confusion in particular -- Cowboy's five-segment
%% `listeners.<name>.http.linger.timeout' against the four-segment socket key,
%% both of which the test templates set -- is excluded by construction and not
%% by a check, since `cuttlefish_variable:is_fuzzy_match/2' compares segment
%% counts before anything else (`cuttlefish_variable.erl:148'). A depth
%% assertion was written here and deleted: it could not be made to fail, because
%% the matcher had already made the flagged key and its pattern the same length.
selftest_reinterpreted(Schema) ->
    Dead = [P || {P, _, _} <- reinterpreted(), not is_known(P, Schema)],
    Flagged = [
        Key
     || F <- shipped_conf_files(),
        {Key, _, _} <- reinterpretations(read_conf(F))
    ],
    case {Dead, Flagged} of
        {[], [_ | _]} ->
            out("  changed meaning: ~p key~s in the table, all live, flagged on"
                " ~p line~s of the shipped corpus  OK",
                [length(reinterpreted()), plural(length(reinterpreted())),
                    length(Flagged), plural(length(Flagged))]),
            ok;
        _ ->
            [err("  changed meaning: ~s is not read by this release -- that"
                " entry is dead", [key_str(P)]) || P <- Dead],
            Flagged == [] andalso
                err("  changed meaning: the shipped corpus flags nothing, so"
                    " this check proves nothing", []),
            failed
    end.

%% The value check, against an INDEPENDENT oracle: cuttlefish's own generator.
%%
%% `value_faults/3' restates a dispatch cuttlefish does not export, so asserting
%% it against a table of expected answers would only be asserting that this file
%% agrees with itself. Instead each case is fed to `cuttlefish_generator:map/2'
%% over the real schemas and the PHASE it stops at is compared with the verdict
%% here. Agreement across the three cases is the claim; the table below records
%% which phase each one covers, because a check that only ever sees one is
%% asserting far less than it looks.
%%
%% The third case is the one that fails a plausible wrong implementation. A fuzzy
%% mapping's validators never run (see `validator_fault/3'), so enforcing them
%% would flag a file that boots. `mail.relay.x.pool.size = 0' violates
%% `positive_integer' and must NOT be reported -- and cuttlefish confirms it by
%% getting as far as `apply_translations', a phase AFTER validation, which it
%% could not reach if the validator had fired. It stops there for an unrelated
%% reason: one key is not a whole relay definition. That is why the assertion is
%% "reached a phase past validation" rather than "no error".
%%
%% The corpus is the liveness half, and it is PINNED rather than merely expected
%% to be empty, because on its first run it found a real defect in a shipped file
%% and suppressing that would be the vacuous outcome this file keeps warning
%% about.
%%
%% The corpus is the liveness half: if a shipped file ever starts reporting a
%% value fault, this check has become over-strict rather than the file having
%% become wrong -- and it is the corpus that found the two defects this section
%% exists because of.
%%
%% Both are now fixed at source, and the exception that held them is deleted
%% rather than left as a permanently-satisfied assertion. For the record:
%% `config/bondy.conf.defaults' is `cuttlefish effective -s schema/', and
%% `cuttlefish_effective:build/3' prints each default with `~s' straight off
%% `add_defaults/2' -- no `to_string/2' anywhere -- so sixteen `flag' defaults
%% written as the Erlang term `true' were published as a word `flag' cannot read.
%% Fourteen more were declared `{flag, off, off}', which cuttlefish turns into
%% `{enum, [{off,true},{off,false}]}' and matches by name before value, so `off'
%% resolved to `true' and `on' failed the whole generation; those are no longer
%% settings at all (`bondy_config:unadvertised_features/0').

selftest_values(SchemaDirs, {Schema, Validators}) ->
    Cases = [
        {"listeners.pub.websocket.max_frame_size = infinity", datatype,
            transform_datatypes},
        {"load_regulation.router.pool.size = 0", validator, validation},
        {"mail.relay.x.pool.size = 0", none, past_validation}
    ],
    Disagreed = [
        {Line, Expected, Mine, Phase}
     || {Line, Expected, ExpectedPhase} <- Cases,
        Mine <- [value_verdict(Line, Schema, Validators)],
        Phase <- [cuttlefish_phase(Line, SchemaDirs)],
        Mine =/= Expected orelse not phase_agrees(ExpectedPhase, Phase)
    ],
    Files = shipped_conf_files(),
    Corpus = [
        {F, value_faults(read_conf(F), Schema, Validators)} || F <- Files
    ],
    Unexpected = lists:append([corpus_faults(F, Faults) || {F, Faults} <- Corpus]),
    case {Disagreed, Unexpected} of
        {[], []} ->
            out("  values: ~p cases agree with cuttlefish_generator:map/2"
                " (datatype, validation, fuzzy-validator-is-dead); ~p corpus"
                " files report none  OK",
                [length(Cases), length(Files)]),
            ok;
        _ ->
            [err("  values: ~s -- expected ~p, got ~p; cuttlefish stopped at ~p",
                [L, E, M, P]) || {L, E, M, P} <- Disagreed],
            [err("  values: ~s", [W]) || W <- Unexpected],
            failed
    end.

%% What a corpus file is allowed to report: nothing at all. There is no longer an
%% exception, and re-introducing one should mean fixing the file instead.
corpus_faults(File, Faults) ->
    [
        lists:flatten(io_lib:format("corpus file ~s reports ~s = ~s: ~s",
            [File, key_str(K), V, value_fault_why(F)]))
     || {K, V, F} <- Faults
    ].


%% What `value_faults/3' makes of a single setting, reduced to the kind of fault
%% so a case can name an expectation without quoting a message.
value_verdict(Line, Schema, Validators) ->
    case value_faults(
        conf_from_string("selftest", Line ++ "\n"), Schema, Validators
    ) of
        [] -> none;
        [{_, _, {Kind, _}} | _] -> Kind
    end.

%% The phase cuttlefish itself stops at for the same setting. `map/2' fills in
%% every default first, so a one-line conf is a complete configuration.
cuttlefish_phase(Line, SchemaDirs) ->
    Files = lists:append([filelib:wildcard(filename:join(D, "*.schema"))
        || D <- SchemaDirs]),
    Full = cuttlefish_schema:files(Files),
    Conf = conf_from_string("selftest", Line ++ "\n"),
    case unlogged(fun() -> cuttlefish_generator:map(Full, Conf) end) of
        {error, Phase, _} -> Phase;
        L when is_list(L) -> ok
    end.

%% `quietly/1' swaps the group leader, which covers `io:format' but not `logger'
%% -- and cuttlefish reports a rejected value through `?LOG_ERROR', whose handler
%% writes to its own device. Two of the three cases here are SUPPOSED to be
%% rejected, so without this the selftest prints cuttlefish's error reports in
%% the middle of its own passing output.
unlogged(Fun) ->
    #{level := Level} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, none),
    try
        quietly(Fun)
    after
        logger:set_primary_config(level, Level)
    end.

%% Phases run add_defaults -> substitutions -> transform_datatypes -> validation
%% -> apply_translations, so anything at or past apply_translations proves
%% validation was reached and passed.
phase_agrees(past_validation, Phase) ->
    lists:member(Phase, [apply_translations, ok]);
phase_agrees(Expected, Phase) ->
    Expected =:= Phase.

%% The WAMP features that stopped being options are described in three places
%% that can drift apart: `bondy_config:unadvertised_features/0' seats the value,
%% `schema/bondy.schema' no longer maps the key, and `rules()' explains its
%% disappearance. This joins them, in the direction where drift does damage.
%%
%% For every capability the node seats: the key must be mapped by NO schema --
%% otherwise it is still an operator setting and the seated value silently
%% overrides whatever they wrote -- and `match_rule/2' must answer `{drop, _}',
%% otherwise an operator upgrading gets `NO RULE' for a key this release
%% deliberately removed.
%%
%% Read from the loaded beam rather than restated, like `default_inventory/0'
%% above, so the list cannot be copied wrong. An empty list is a FAILURE, not a
%% pass: it is how this check would go vacuous.
selftest_capabilities(Schema) ->
    case locate_bondy_router() of
        unavailable ->
            err("  capabilities: NOT CHECKED -- bondy_config could not be"
                " loaded, so the drop rules cannot be joined against the"
                " features the node seats", []),
            failed;
        ok ->
            Caps = [
                {["wamp", atom_to_list(Role), atom_to_list(Feature)],
                    {Role, Feature}}
             || {Role, Feature} <- bondy_config:code_defined_features()
            ],
            StillMapped = [K || {K, _} <- Caps, is_known(K, Schema)],
            Unexplained = [
                K
             || {K, _} <- Caps,
                case match_rule(K, rules()) of
                    {drop, _} -> false;
                    _ -> true
                end
            ],
            case {Caps, StillMapped, Unexplained} of
                {[_ | _], [], []} ->
                    out("  capabilities: ~p features seated in bondy_config,"
                        " none still mapped by a schema, all explained by a"
                        " drop rule  OK", [length(Caps)]),
                    ok;
                _ ->
                    Caps == [] andalso
                        err("  capabilities: bondy_config seats none, so this"
                            " check proves nothing", []),
                    [err("  capabilities: ~s is seated in code AND still mapped"
                        " by a schema -- the operator's value is silently"
                        " overridden", [key_str(K)]) || K <- StillMapped],
                    [err("  capabilities: ~s has no drop rule -- an operator"
                        " who sets it gets `NO RULE'", [key_str(K)])
                     || K <- Unexplained],
                    failed
            end
    end.

%% Migrating a file that has nothing to migrate must return it byte for byte.
%% This is the check that the line rewriter cannot quietly reflow, reorder, drop
%% a comment, or move the trailing newline.
selftest_noop(SchemaDirs) ->
    Files = shipped_conf_files(),
    Differing = [F || F <- Files, migrate_to_temp(F, SchemaDirs) =/= same],
    case Differing of
        [] ->
            out("  migrate no-op: ~p clean files, output byte-identical  OK",
                [length(Files)]),
            ok;
        _ ->
            err("  migrate no-op: ~p files changed when they should not have:",
                [length(Differing)]),
            [err("      ~s", [F]) || F <- Differing],
            failed
    end.

migrate_to_temp(File, SchemaDirs) ->
    Out = filename:join(tmp_dir(),
        "migrate_conf_noop_" ++ os:getpid() ++ "_" ++ safe_name(File)),
    file:delete(Out),
    try
        _ = quietly(fun() -> migrate(File, Out, SchemaDirs) end),
        {ok, A} = file:read_file(File),
        {ok, B} = file:read_file(Out),
        case A == B of
            true -> same;
            false -> different
        end
    after
        file:delete(Out)
    end.

%% The round trip the design asks for: a migrated file, fed back to check mode,
%% reports clean. Run over the dirty corpus, which is the only input where
%% migrate has work to do.
selftest_roundtrip(SchemaDirs) ->
    case dirty_corpus() of
        {error, Reason} ->
            err("  round trip: UNAVAILABLE (~s)", [Reason]),
            failed;
        {ok, Contents} ->
            Bad = lists:filtermap(
                fun({Name, Body}) ->
                    case roundtrip(Name, Body, SchemaDirs) of
                        clean -> false;
                        {dirty, Keys} -> {true, {Name, Keys}}
                    end
                end,
                Contents
            ),
            case Bad of
                [] ->
                    out("  round trip: ~p migrated files re-check clean  OK",
                        [length(Contents)]),
                    ok;
                _ ->
                    err("  round trip: ~p files still have findings after"
                        " migration:", [length(Bad)]),
                    [begin
                        err("      ~s", [N]),
                        [err("          ~s", [key_str(K)]) || K <- Ks]
                     end || {N, Ks} <- Bad],
                    failed
            end
    end.

%% The round trip above is NECESSARY but not SUFFICIENT, and this covers the
%% difference. Every file in both corpora already writes its own
%% `listeners.<name>.transport' -- they were converted when the listener rework
%% landed -- so not one of them needs `migrate' to synthesise anything. MEASURED:
%% with `pending_identity/1' stubbed to `#{}', disabling synthesis outright, the
%% whole selftest still passed. A gate that a total removal of the mechanism does
%% not trip is not guarding it.
%%
%% So the input here is built rather than read: one legacy block per row of
%% `legacy_listeners/0', a port apiece, and NO `listeners.*' key anywhere -- the
%% shape a file has when it is migrated from a release older than the rework,
%% which is the only shape that needs synthesis and the one no corpus file has.
%%
%% Asserting `clean' alone would still pass if migrate declared the listeners
%% with the wrong identity, so the emitted keys are compared against
%% `legacy_identity/1' as well.
selftest_synthesis(SchemaDirs) ->
    Base = filename:join(tmp_dir(), "migrate_conf_syn_" ++ os:getpid()),
    In = Base ++ ".in",
    Out = Base ++ ".out",
    Blocks = legacy_listeners(),
    Body = string:join(
        lists:append([
            [key_str(Prefix ++ ["port"]) ++ " = " ++ integer_to_list(P)]
         || {{Prefix, _, _}, P} <- lists:zip(
                Blocks, lists:seq(19001, 19000 + length(Blocks)))
        ]),
        "\n"
    ) ++ "\n",
    ok = file:write_file(In, Body),
    file:delete(Out),
    try
        _ = quietly(fun() -> migrate(In, Out, SchemaDirs) end),
        OutConf = read_conf(Out),
        Verdict = quietly(fun() -> check(Out, SchemaDirs) end),
        Wrong = lists:append([
            [
                {Name, K, V}
             || {K, V} <- Expected,
                conf_value_of(Name, K, OutConf) =/= V
            ]
         || {Name, Expected} <- identity_oracle()
        ]),
        case {Verdict, Wrong} of
            {{[], [], []}, []} ->
                out("  synthesis: ~p legacy blocks with no listeners.* key,"
                    " all declared and re-check clean  OK", [length(Blocks)]),
                ok;
            {{K, V, L}, _} when K =/= []; V =/= []; L =/= [] ->
                err("  synthesis: migrated output is not clean:", []),
                [err("      ~s", [key_str(Key)]) || {Key, _, _} <- K],
                [err("      ~s (invalid value)", [key_str(Key)])
                 || {Key, _, _} <- V],
                [err("      ~s", [key_str(listener_finding_key(F))]) || F <- L],
                failed;
            _ ->
                err("  synthesis: identity emitted does not match"
                    " default_inventory/0:", []),
                [err("      listeners.~s.~s: expected ~s, got ~p",
                    [N, K, V, conf_value_of(N, K, OutConf)])
                 || {N, K, V} <- Wrong],
                failed
        end
    after
        file:delete(In),
        file:delete(Out)
    end.

%% @private
%% What the emitted identity must equal, derived from a source OTHER than
%% `legacy_identity/1'. Comparing the output against that table is a tautology --
%% it is the table that produced the output -- and measurably so: a mutant that
%% declared `admin' as `tls' passed a check written that way.
%%
%% `bondy_listener_config:default_inventory/0' is the independent source for
%% three rows, being the product's own statement of what those listeners are. The
%% other rows follow from ONE stated fact about the release the blocks come from:
%% a `https'/`tls' block was the same listener as its plaintext twin on a TLS
%% socket -- `bondy_http_gateway.erl:945-946' hands both the same routes -- so a
%% twin differs from its counterpart in `transport' and in nothing else.
%%
%% WHAT THIS DOES NOT COVER: `bridge_relay_tcp' and `bridge_relay_tls'. Neither
%% appears in the default inventory and neither has a plaintext twin there, so
%% there is no second source to check them against and they are absent here
%% rather than checked against themselves. Their `protocol' is still exercised by
%% the clean re-check beside this one -- `bridge_relay' is what makes
%% `resolve_one/3' accept a bridge block at all -- but their values are not
%% independently confirmed.
identity_oracle() ->
    case locate_bondy_router() of
        unavailable ->
            [];
        ok ->
            Inv = bondy_listener_config:default_inventory(),
            Of = fun(Name) ->
                {_, Spec} = lists:keyfind(list_to_atom(Name), 1, Inv),
                Spec
            end,
            Plain = fun(Name) ->
                Spec = Of(Name),
                [
                    {"transport", atom_to_list(maps:get(transport, Spec))},
                    {"protocol", atom_to_list(maps:get(protocol, Spec))}
                ] ++ services_of(Spec)
            end,
            %% A twin is its counterpart with `transport' replaced.
            Twin = fun(Name) ->
                lists:keyreplace("transport", 1, Plain(Name),
                    {"transport", "tls"})
            end,
            [
                {"admin", Plain("admin")},
                {"api_gateway_http", Plain("api_gateway_http")},
                {"wamp_tcp", Plain("wamp_tcp")},
                {"admin_api_https", Twin("admin")},
                {"api_gateway_https", Twin("api_gateway_http")},
                {"wamp_tls", Twin("wamp_tcp")}
            ]
    end.

%% @private
%% Rendered the way an operator writes it, which is how it comes back out of
%% `read_conf/1': `Split' in the translation tokenises on "," and trims.
services_of(Spec) ->
    case maps:get(services, Spec, []) of
        [] -> [];
        Ss -> [{"services", string:join([atom_to_list(S) || S <- Ss], ", ")}]
    end.

%% @private
%% A listener finding rendered as a key path, so the round-trip failure report
%% prints it with `key_str/1' beside the key findings instead of needing a second
%% formatter. The three shapes are the three `listener_findings/1' and
%% `advanced_report/3' produce.
listener_finding_key({dropped, Name}) ->
    ["listeners", Name, "<undeclared>"];
listener_finding_key({incomplete, Name, Key}) ->
    ["listeners", Name, atom_to_list(Key)];
listener_finding_key({inert_stanza, App}) ->
    ["advanced.config", atom_to_list(App)].

roundtrip(Name, Body, SchemaDirs) ->
    Base = filename:join(tmp_dir(),
        "migrate_conf_rt_" ++ os:getpid() ++ "_" ++ safe_name(Name)),
    In = Base ++ ".in",
    Out = Base ++ ".out",
    ok = file:write_file(In, Body),
    file:delete(Out),
    try
        _ = quietly(fun() -> migrate(In, Out, SchemaDirs) end),
        %% BOTH halves of the verdict. This took `element(1, ...)' -- key
        %% findings only -- on the premise that migrate does not synthesise
        %% listener blocks, so listener findings after a migration were "the
        %% intended outcome". That premise made the gate vacuous for exactly the
        %% defect it should have caught: a migrated file that renames every key
        %% and boots on none of its listeners passed, because the only evidence
        %% of it was in the half being discarded. migrate now declares what it
        %% renames, so the honest gate is the whole verdict -- and if a future
        %% change stops it declaring, this fails instead of shrugging.
        case quietly(fun() -> check(Out, SchemaDirs) end) of
            {[], [], []} ->
                clean;
            {KeyFindings, ValueFindings, ListenerFindings} ->
                {dirty,
                    [K || {K, _, _} <- KeyFindings] ++
                        [K || {K, _, _} <- ValueFindings] ++
                        [listener_finding_key(F) || F <- ListenerFindings]}
        end
    after
        file:delete(In),
        file:delete(Out)
    end.

%% check/2 and migrate/3 report to stdout by contract -- that IS their product.
%% The selftest calls them for their return value, so their output is captured
%% and discarded rather than interleaved into the selftest's own report.
quietly(Fun) ->
    Group = group_leader(),
    {ok, Sink} = file:open("/dev/null", [write]),
    group_leader(Sink, self()),
    try
        Fun()
    after
        group_leader(Group, self()),
        file:close(Sink)
    end.

%% Every conf file the repository ships, not just those under `config/'. The
%% deployment and harness templates are real operator-facing files and were the
%% last ones still on legacy listener keys, so leaving them out of the corpus is
%% what let that go unnoticed.
%% `examples/*/etc/bondy.conf' matched the file the example GENERATES, which is
%% untracked, while `examples/*/etc/bondy.conf.template' -- the tracked file a
%% change would actually be made to -- was checked by nothing. Both are globbed
%% now: the template because it is the source, the generated file because
%% checking it costs nothing when it is present and says the rendering still
%% agrees.
%%
%% `config/test/bondy.conf' is here for a plainer reason: the dirty corpus reads
%% it at `?DIRTY_REF' -- it is one of that ref's seven -- so the clean corpus not
%% reading it at HEAD meant one file was asserted to be dirty before the cleanup
%% and nothing at all after it.
shipped_conf_files() ->
    lists:usort(
        filelib:wildcard("config/*/bondy.conf.template") ++
        filelib:wildcard("config/test/*_bondy.conf.template") ++
        filelib:wildcard("config/test/bondy.conf") ++
        filelib:wildcard("config/bondy.conf.defaults") ++
        filelib:wildcard("deployment/*/config/bondy.conf.template") ++
        filelib:wildcard("harness/*/config/bondy.conf.template") ++
        filelib:wildcard("examples/*/etc/bondy.conf") ++
        filelib:wildcard("examples/*/etc/bondy.conf.template")
    ).

%% The pre-cleanup versions of the shipped files, read out of git rather than
%% checked in as fixtures, so the corpus cannot drift from what was audited.
dirty_corpus() ->
    Files = shipped_conf_files_at(?DIRTY_REF),
    case Files of
        [] ->
            {error, "no files at " ++ ?DIRTY_REF};
        _ ->
            Read = [{F, git_show(?DIRTY_REF, F)} || F <- Files],
            case [F || {F, error} <- Read] of
                [] -> {ok, [{F, B} || {F, {ok, B}} <- Read]};
                Missing -> {error, "cannot read " ++ string:join(Missing, ", ")}
            end
    end.

%% The file list comes from the ref itself: at HEAD the cleanup may have renamed
%% or dropped files, so globbing the working tree would ask git for paths that
%% did not exist then.
shipped_conf_files_at(Ref) ->
    case sh("git ls-tree -r --name-only " ++ Ref ++ " -- config/") of
        {0, Out} ->
            [L || L <- string:lexemes(Out, "\n"),
                filename:basename(L) == "bondy.conf" orelse
                    lists:suffix("bondy.conf.template", L)];
        {_, _} ->
            []
    end.

git_show(Ref, File) ->
    case sh("git show " ++ Ref ++ ":" ++ File) of
        {0, Out} -> {ok, Out};
        {_, _} -> error
    end.

%% cuttlefish_conf has no string entry point, so a corpus held in memory is
%% written to a temp file and parsed by the same path as any other conf file.
conf_from_string(Name, Body) ->
    Path = filename:join(tmp_dir(),
        "migrate_conf_" ++ os:getpid() ++ "_" ++ safe_name(Name)),
    ok = file:write_file(Path, Body),
    try
        read_conf(Path)
    after
        file:delete(Path)
    end.

safe_name(Name) ->
    [case lists:member(C, "/ \t") of true -> $_; false -> C end || C <- Name].

%% =============================================================================
%% UTIL
%% =============================================================================

key_str(Key) ->
    string:join(Key, ".").

%% Pad to at least Width. NOT `~-Ns', which TRUNCATES in Erlang: that turned
%% `multi_time_warp' into `multi_time_war' in an earlier version of this report,
%% i.e. it altered the operator's own value while showing it back to them.
pad(Str, Width) when length(Str) >= Width ->
    Str;
pad(Str, Width) ->
    Str ++ lists:duplicate(Width - length(Str), $\s).

out(Fmt, Args) ->
    io:format(Fmt ++ "~n", Args).

err(Fmt, Args) ->
    io:format(standard_error, Fmt ++ "~n", Args).

sh(Cmd) ->
    Port = open_port({spawn, "sh -c " ++ quote(Cmd) ++ " 2>/dev/null"},
        [exit_status, stderr_to_stdout, binary, in]),
    collect(Port, []).

quote(S) ->
    "'" ++ lists:flatten([case C of $' -> "'\\''"; _ -> C end || C <- S]) ++ "'".

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, binary_to_list(iolist_to_binary(lists:reverse(Acc)))}
    end.
