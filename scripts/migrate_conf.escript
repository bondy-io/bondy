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
%% every key it still reads but reads DIFFERENTLY, which listeners the file will
%% actually start, and any inert `advanced.config' stanza beside it. Nothing is
%% written. `migrate' writes a converted file. `selftest' is the gate -- see the
%% SELFTEST section.
%%
%% WHY THIS EXISTS: Bondy cannot fail the boot on an unknown key, and that is
%% structural rather than an oversight. The generated pre-start hook runs
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
%% listener and changed-meaning invariants.
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
    {KeyFindings, ListenerFindings} = check(ConfFile, SchemaDirs),
    halt(
        case KeyFindings ++ ListenerFindings of
            [] -> ?EXIT_CLEAN;
            _ -> ?EXIT_FINDINGS
        end
    );
run(["migrate", ConfFile | Rest]) ->
    {Out, SchemaDirs} = parse_migrate_args(Rest),
    ok = locate_cuttlefish(),
    ok = migrate(ConfFile, Out, SchemaDirs),
    halt(?EXIT_CLEAN);
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

%% Returns {KeyFindings, ListenerFindings}. The two are separate because they are
%% different hazards: a key finding is a setting this release does not read at
%% all, while a listener finding is a live key that IS read but whose listener
%% will not start.
check(ConfFile, SchemaDirs0) ->
    SchemaDirs = resolve_schema_dirs(SchemaDirs0),
    Schema = schema(SchemaDirs),
    Conf = read_conf(ConfFile),
    Findings = classify(Conf, Schema),
    Changed = reinterpretations(Conf),
    Listeners = listener_analysis(Conf, Schema),
    out("~s", [ConfFile]),
    out("  ~p keys, schemas: ~s",
        [length(Conf), string:join(SchemaDirs, " ")]),
    report(length(Conf), Findings),
    ok = report_reinterpreted(Changed),
    ok = listener_report(Listeners),
    Advanced = advanced_check(sibling_advanced_config(ConfFile)),
    ListenerFindings = listener_findings(Listeners) ++ Advanced,
    %% The verdict goes LAST and covers every section. An earlier version printed
    %% `OK' as the first line whenever the KEYS section was clean, which read as
    %% a clean bill of health on files that were exiting 1 for a listener
    %% finding.
    ok = verdict_line(Findings, ListenerFindings, Changed),
    {Findings, ListenerFindings}.

%% Changed-meaning keys are named here but do not make the verdict a finding,
%% for the reason given at `reinterpreted/0': they are reported so `clean'
%% cannot be read as silence, and they leave the exit code alone.
verdict_line(Findings, ListenerFindings, Changed) ->
    out("", []),
    out("RESULT  ~s~s", [
        keys_verdict(Findings, ListenerFindings), changed_verdict(Changed)
    ]),
    ok.

keys_verdict([], []) ->
    "clean -- every key is read and every listener is declared";
keys_verdict(Findings, ListenerFindings) ->
    io_lib:format("~p key~s not read, ~p listener finding~s -- see above",
        [length(Findings), plural(length(Findings)),
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
classify(Conf, Schema) ->
    Unknown = [{K, V} || {K, V} <- Conf, not is_known(K, Schema)],
    [{K, V, verdict(K, V, Schema, Conf)} || {K, V} <- Unknown].

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
%% equals the candidate's own schema default, which is the evidence that resolved
%% `bridge.edge.timeout' to `connect_timeout' rather than to its two siblings.
candidate(Key, Rewrite, Value, Schema) ->
    New = rewrite(Key, Rewrite),
    Known = is_known(New, Schema),
    {New, Known, Known andalso default_of(New, Schema) == {ok, Value}}.

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
                out("        candidate ~s  <- its schema default is this value",
                    [key_str(New)]);
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
            %% to boot. Reserved names are exempt -- the manager supplies the
            %% whole spec for those, so an operator need not write any of it.
            Incomplete = [
                {Name, Missing}
             || Name <- Declared,
                not lists:member(Name, Reserved),
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
%% discard visible. That also gives the round-trip property: check mode reports
%% the output clean.
migrate(ConfFile, Out, SchemaDirs0) ->
    Out =/= ConfFile orelse throw({fail,
        "--out must differ from the input; this tool never rewrites in place",
        []}),
    not filelib:is_file(Out) orelse throw({fail,
        "~s already exists; refusing to overwrite it", [Out]}),
    SchemaDirs = resolve_schema_dirs(SchemaDirs0),
    Schema = schema(SchemaDirs),
    Conf = read_conf(ConfFile),
    Findings = classify(Conf, Schema),
    Verdicts = maps:from_list([{K, Verdict} || {K, _, Verdict} <- Findings]),

    {ok, Bin} = file:read_file(ConfFile),
    {Lines, Eol} = split_lines(binary_to_list(Bin)),
    {NewLines0, Actions} = lists:mapfoldl(
        fun(Line, Acc) ->
            case migrate_line(Line, Verdicts) of
                unchanged -> {[Line], Acc};
                {changed, New, Action} -> {New, [Action | Acc]}
            end
        end,
        [],
        Lines
    ),
    ok = file:write_file(Out, string:join(lists:append(NewLines0), Eol)),
    migrate_report(ConfFile, Out, length(Conf), lists:reverse(Actions)),
    %% Reported here too, and not only by check mode: migrate deliberately
    %% touches none of the three, so an operator who only ever runs migrate
    %% would otherwise see a clean summary and never learn that listeners are
    %% being dropped, that an advanced.config stanza is inert, or that a key it
    %% copied through unchanged now means something else.
    ok = report_reinterpreted(reinterpretations(Conf)),
    ok = listener_report(listener_analysis(Conf, Schema)),
    _ = advanced_check(sibling_advanced_config(ConfFile)),
    ok.

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
    Lines = length(Actions),
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
schema(SchemaDirs) ->
    Files = lists:append([filelib:wildcard(filename:join(D, "*.schema"))
        || D <- SchemaDirs]),
    Files == [] andalso throw({fail,
        "no .schema files under: ~s", [string:join(SchemaDirs, " ")]}),
    case cuttlefish_schema:files(Files) of
        {_Translations, Mappings, _Validators} when is_list(Mappings) ->
            Mappings == [] andalso throw({fail,
                "~p schema files yielded no mappings", [length(Files)]}),
            [{cuttlefish_mapping:variable(M), M} || M <- Mappings];
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
-define(DIRTY_REF, "8dd090bf^").
-define(DIRTY_EXPECTED, 86).

selftest(SchemaDirs0) ->
    SchemaDirs = resolve_schema_dirs(SchemaDirs0),
    Schema = schema(SchemaDirs),
    out("selftest: ~p mappings from ~s", [length(Schema),
        string:join(SchemaDirs, " ")]),
    Results = [
        selftest_rules(Schema),
        selftest_clean(Schema),
        selftest_dirty(Schema),
        selftest_noop(SchemaDirs),
        selftest_roundtrip(SchemaDirs),
        selftest_listeners(Schema),
        selftest_reinterpreted(Schema)
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
        ok = quietly(fun() -> migrate(File, Out, SchemaDirs) end),
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

roundtrip(Name, Body, SchemaDirs) ->
    Base = filename:join(tmp_dir(),
        "migrate_conf_rt_" ++ os:getpid() ++ "_" ++ safe_name(Name)),
    In = Base ++ ".in",
    Out = Base ++ ".out",
    ok = file:write_file(In, Body),
    file:delete(Out),
    try
        ok = quietly(fun() -> migrate(In, Out, SchemaDirs) end),
        %% Only the KEY findings: migrate deliberately does not synthesise
        %% listener blocks (see migrate/3), so a half-migrated input still has
        %% listener findings afterwards and that is the intended outcome.
        case quietly(fun() -> element(1, check(Out, SchemaDirs)) end) of
            [] -> clean;
            Findings -> {dirty, [K || {K, _, _} <- Findings]}
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
shipped_conf_files() ->
    lists:usort(
        filelib:wildcard("config/*/bondy.conf.template") ++
        filelib:wildcard("config/test/*_bondy.conf.template") ++
        filelib:wildcard("config/bondy.conf.defaults") ++
        filelib:wildcard("deployment/*/config/bondy.conf.template") ++
        filelib:wildcard("harness/*/config/bondy.conf.template") ++
        filelib:wildcard("examples/*/etc/bondy.conf")
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
