%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Renders `bondy.conf' fragments through cuttlefish exactly as the release's
%% pre-start hook does, and asserts on the resulting application environment.
%%
%% This is the only place the schema's behaviour can be checked: cuttlefish runs
%% as a standalone escript BEFORE the VM boots the release, so no runtime code
%% path exercises a translation.
%%
%% Every assertion below is on `bondy_router.listeners'. That is the ONLY key
%% the `listeners.$name.*' block renders. A cuttlefish mapping's target is
%% tokenised literally and each token is passed through `list_to_atom/1'
%% (cuttlefish_generator.erl:153 and :257-267), so a target cannot name a
%% listener whose name is only known at render time; `$name' in a target
%% produces the atom `'$name''. Each listener's option block therefore travels
%% nested inside its inventory entry. Nothing in this suite asserts on
%% `bondy_router.<name>.*', because this schema does not write it.
%% =============================================================================
-module(bondy_listener_schema_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).

-export([new_style_block_produces_inventory/1]).
-export([omitted_carrier_key_is_absent/1]).
-export([port_has_no_default/1]).
-export([unset_option_block_is_absent/1]).
-export([ip_is_parsed_at_spec_top_level/1]).
-export([http_and_stream_idle_timeout_are_distinct/1]).
-export([widened_datatypes_accept_raw_socket_values/1]).
-export([partial_cors_and_security_header_blocks_are_not_completed/1]).
-export([a_rendered_partial_block_does_not_defeat_the_hsts_default/1]).
-export([an_empty_security_header_value_is_a_syntax_error/1]).
-export([carrier_and_deflate_keys_reach_their_legacy_paths/1]).
-export([listeners_do_not_share_option_values/1]).
-export([malformed_ip_is_refused/1]).
-export([deflate_level_out_of_range_is_refused/1]).
-export([no_listener_configured_renders_no_inventory_key/1]).
-export([enabled_off_reaches_the_spec/1]).
-export([port_out_of_range_is_refused/1]).
-export([stream_and_http_integer_options_reject_non_positive_values/1]).
-export([cors_max_age_rejects_negative/1]).
-export([linger_timeout_rejects_below_minus_one/1]).
-export([linger_timeout_is_in_seconds/1]).
-export([a_security_header_can_be_switched_off_on_its_own/1]).
-export([all_116_keys_reach_their_documented_paths/1]).

all() ->
    [
        new_style_block_produces_inventory,
        omitted_carrier_key_is_absent,
        port_has_no_default,
        unset_option_block_is_absent,
        ip_is_parsed_at_spec_top_level,
        http_and_stream_idle_timeout_are_distinct,
        widened_datatypes_accept_raw_socket_values,
        partial_cors_and_security_header_blocks_are_not_completed,
        a_rendered_partial_block_does_not_defeat_the_hsts_default,
        an_empty_security_header_value_is_a_syntax_error,
        carrier_and_deflate_keys_reach_their_legacy_paths,
        listeners_do_not_share_option_values,
        malformed_ip_is_refused,
        deflate_level_out_of_range_is_refused,
        no_listener_configured_renders_no_inventory_key,
        enabled_off_reaches_the_spec,
        port_out_of_range_is_refused,
        stream_and_http_integer_options_reject_non_positive_values,
        cors_max_age_rejects_negative,
        linger_timeout_rejects_below_minus_one,
        linger_timeout_is_in_seconds,
        a_security_header_can_be_switched_off_on_its_own,
        all_116_keys_reach_their_documented_paths
    ].

init_per_suite(Config) ->
    %% cuttlefish is a rebar3 PLUGIN, not a dependency of this application, so
    %% its modules are not on the test code path by default. The plugin's ebin
    %% is the same code the release's pre-start hook runs, which is what this
    %% suite is meant to exercise, so it is added rather than a second copy
    %% being declared as a test-profile dependency.
    Root = repo_root(),
    Ebin = filename:join([
        Root, "_build", "default", "plugins", "cuttlefish", "ebin"
    ]),
    true = filelib:is_dir(Ebin),
    true = code:add_pathz(Ebin),
    %% No application needs starting: every function used here is pure.
    {module, cuttlefish_generator} = code:ensure_loaded(cuttlefish_generator),
    [{schema_dir, filename:join(Root, "schema")} | Config].

end_per_suite(Config) ->
    Config.

%% =============================================================================
%% CASES
%% =============================================================================

new_style_block_produces_inventory(Config) ->
    Inventory = inventory(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18080\n",
        "listeners.pub.services = api_gateway, wamp_ws\n",
        "listeners.pub.backlog = 512\n",
        "listeners.pub.acceptors_pool_size = 8\n",
        "listeners.pub.max_connections = 4096\n"
    ]),
    ?assertMatch([{pub, #{transport := tcp, protocol := http}}], Inventory),
    [{pub, Spec}] = Inventory,
    ?assertEqual(18080, maps:get(port, Spec)),
    ?assertEqual([api_gateway, wamp_ws], maps:get(services, Spec)),
    %% The option block travels nested inside the spec, at the path the legacy
    %% app-env layout uses, so that a later step can place it at
    %% `bondy_router.<name>.*' unchanged.
    ?assertEqual(
        512,
        key_value:get(
            [transport_opts, socket_opts, backlog], Spec, undefined
        )
    ),
    ?assertEqual(
        8, key_value:get([transport_opts, num_acceptors], Spec, undefined)
    ),
    ?assertEqual(
        4096,
        key_value:get([transport_opts, max_connections], Spec, undefined)
    ).

omitted_carrier_key_is_absent(Config) ->
    %% The regression guard for the default-free rule. If any
    %% `listeners.$name.*' mapping gains a `{default, ...}',
    %% `cuttlefish_generator:add_fuzzy_default/4' materialises it for EVERY
    %% listener name mentioned under the prefix, the key becomes
    %% always-present, and the global `wamp.websocket.*' fallback that
    %% `bondy_listener_config:resolve_carrier_key/5' relies on silently dies.
    [{pub, Spec}] = inventory(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18080\n",
        "listeners.pub.services = wamp_ws\n"
    ]),
    ?assertEqual(
        undefined, key_value:get([websocket, idle_timeout], Spec, undefined)
    ),
    ?assertNot(maps:is_key(websocket, Spec)).

port_has_no_default(Config) ->
    %% A default port would silently collide across listeners, so `port' must be
    %% absent when unset and rejected by the resolver rather than guessed.
    [{pub, Spec}] = inventory(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.services = wamp_ws\n"
    ]),
    ?assertNot(maps:is_key(port, Spec)).

unset_option_block_is_absent(Config) ->
    %% Whole-block form of the default-free rule, asserted on the WHOLE spec
    %% rather than key by key: a listener that declared only its identity and
    %% bind target must carry nothing else at all. Any `{default, ...}' added to
    %% a `listeners.$name.*' mapping materialises for every listener name
    %% mentioned under the prefix
    %% (`cuttlefish_generator:add_fuzzy_default/4'), which would both show up
    %% here and silently kill the global `wamp.<carrier>.*' fallback.
    [{q, Spec}] = inventory(Config, [
        "listeners.q.transport = tcp\n",
        "listeners.q.protocol = http\n",
        "listeners.q.port = 18086\n",
        "listeners.q.services = api_gateway\n"
    ]),
    %% `enabled' is absent too, for the same reason: it carries no default, so
    %% `bondy_listener_config:resolve_one/3' applies its own `true'.
    ?assertEqual(
        [port, protocol, services, transport], lists:sort(maps:keys(Spec))
    ).

ip_is_parsed_at_spec_top_level(Config) ->
    %% `bondy_listener_config:resolve_ip/3' reads `ip' from the spec and its own
    %% fallback is a tuple, and the value reaches ranch's `socket_opts' through
    %% `bondy_config:listener_transport_opts/2', so no later step converts a
    %% string.
    %%
    %% The address and `ip_version' AGREE here on purpose. They land at
    %% different paths, which is what this case pins, but they are not
    %% independent settings: `bondy_config:normalise_socket_opts/1' derives one
    %% socket family from the pair and an address decides its own family, so a
    %% v4 address under `ip_version = 6' would render cleanly and then bind as
    %% inet, silently ignoring the version an operator wrote.
    %% `explicit_ipv6_binds_without_an_ip_version' in `bondy_listener_SUITE'
    %% binds that precedence over a real socket.
    [{pub, Spec}] = inventory(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = wamp_rawsocket\n",
        "listeners.pub.port = 18082\n",
        "listeners.pub.ip = ::1\n",
        "listeners.pub.ip_version = 6\n"
    ]),
    ?assertEqual({0, 0, 0, 0, 0, 0, 0, 1}, maps:get(ip, Spec)),
    ?assertEqual(
        undefined,
        key_value:get([transport_opts, socket_opts, ip], Spec, undefined)
    ),
    %% ip_version keeps its legacy translation, at its legacy path.
    ?assertEqual(
        inet6,
        key_value:get(
            [transport_opts, socket_opts, ip_version], Spec, undefined
        )
    ).

http_and_stream_idle_timeout_are_distinct(Config) ->
    %% The reason the 23 HTTP protocol-level keys carry an `http.' prefix: one
    %% conf key has one meaning. `idle_timeout' and `http.idle_timeout' reach
    %% different paths, and neither depends on what else the listener sets.
    [{pub, Spec}] = inventory(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18080\n",
        "listeners.pub.services = api_gateway\n",
        "listeners.pub.idle_timeout = 3s\n",
        "listeners.pub.http.idle_timeout = 45s\n",
        "listeners.pub.linger.timeout = 2s\n",
        "listeners.pub.http.linger.timeout = 4s\n"
    ]),
    ?assertEqual(3000, maps:get(idle_timeout, Spec)),
    ?assertEqual(
        45000, key_value:get([protocol_opts, idle_timeout], Spec, undefined)
    ),
    %% The linger pair makes the point more sharply than the idle_timeout pair
    %% does, because the two are in different UNITS as well as at different
    %% paths. The flat key becomes an OS `{linger, {true, N}}' whose component
    %% `inet' documents in seconds, so `2s' is 2; the `http.' one becomes
    %% Cowboy's own `linger_timeout', which is milliseconds, so `4s' is 4000.
    %% Same spelling, same suffix, two correct answers — which is exactly why
    %% one conf key may only have one meaning.
    ?assertEqual(
        2,
        key_value:get(
            [transport_opts, socket_opts, linger_timeout], Spec, undefined
        )
    ),
    ?assertEqual(
        4000, key_value:get([protocol_opts, linger_timeout], Spec, undefined)
    ).

widened_datatypes_accept_raw_socket_values(Config) ->
    %% `wamp.tcp.idle_timeout' accepts `infinity' and `wamp.tcp.linger.timeout'
    %% accepts a bare integer, where the api_gateway.http namesakes do not. The
    %% merged mapping has to take the wider of the two, or a configuration that
    %% is valid today becomes a render error.
    [{raw, Spec}] = inventory(Config, [
        "listeners.raw.transport = tcp\n",
        "listeners.raw.protocol = wamp_rawsocket\n",
        "listeners.raw.port = 18082\n",
        "listeners.raw.idle_timeout = infinity\n",
        "listeners.raw.linger.timeout = -1\n"
    ]),
    ?assertEqual(infinity, maps:get(idle_timeout, Spec)),
    ?assertEqual(
        -1,
        key_value:get(
            [transport_opts, socket_opts, linger_timeout], Spec, undefined
        )
    ).

partial_cors_and_security_header_blocks_are_not_completed(Config) ->
    %% This section used to hand the consumers a TOTAL `cors' and
    %% `security_headers' map, restating all ten of their default values,
    %% because `bondy_http_cors:build_headers/2' reads its members with
    %% `maps:get/2' and a partial map raised `badkey' on the request path.
    %%
    %% Both consumers now merge their own `default_config/0' UNDER whatever
    %% arrives (`bondy_http_cors:config_from_req/1',
    %% `bondy_http_security_headers:init/1'), so restating the values here is a
    %% second copy of a security-relevant policy — two places that must agree
    %% about what a header defaults to, with nothing keeping them in step.
    %%
    %% What a set member renders as is still this section's job: the conversions
    %% below are render-time, and only the COMPLETION is gone.
    [{pub, Spec}] = inventory(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18080\n",
        "listeners.pub.services = api_gateway\n",
        "listeners.pub.cors.allowed_origins = https://a.example.com, *.b.io\n",
        "listeners.pub.cors.max_age = 60\n",
        "listeners.pub.security_headers.hsts = max-age=31536000\n"
    ]),
    %% ONLY the members the operator set.
    ?assertEqual(
        [allowed_origins, max_age], lists:sort(maps:keys(maps:get(cors, Spec)))
    ),
    ?assertEqual([hsts], maps:keys(maps:get(security_headers, Spec))),
    %% Each still converted: a comma list to binaries, an integer to a binary
    %% (`build_headers/2` puts `max_age` straight into a header value), a
    %% string to a binary.
    ?assertEqual(
        [<<"https://a.example.com">>, <<"*.b.io">>],
        key_value:get([cors, allowed_origins], Spec)
    ),
    ?assertEqual(<<"60">>, key_value:get([cors, max_age], Spec)),
    ?assertEqual(
        <<"max-age=31536000">>, key_value:get([security_headers, hsts], Spec)
    ),
    %% `*' and `auto' keep the atom form the consumer pattern-matches on.
    [{w, WSpec}] = inventory(Config, [
        "listeners.w.transport = tcp\n",
        "listeners.w.protocol = http\n",
        "listeners.w.port = 18080\n",
        "listeners.w.services = api_gateway\n",
        "listeners.w.cors.allowed_origins = auto\n"
    ]),
    ?assertEqual(auto, key_value:get([cors, allowed_origins], WSpec)),
    %% A listener that sets neither gets neither, so the consumers'
    %% `default_config/0' applies rather than a value invented here.
    [{n, NSpec}] = inventory(Config, [
        "listeners.n.transport = tcp\n",
        "listeners.n.protocol = http\n",
        "listeners.n.port = 18080\n",
        "listeners.n.services = api_gateway\n"
    ]),
    ?assertNot(maps:is_key(cors, NSpec)),
    ?assertNot(maps:is_key(security_headers, NSpec)).

a_rendered_partial_block_does_not_defeat_the_hsts_default(Config) ->
    %% Spans the render and the transport/protocol defaults, because that is
    %% where the completion did its damage and neither half shows it alone.
    %%
    %% `bondy_listener_config:option_defaults(tls, http)` supplies HSTS, and
    %% `with_option_defaults/1` merges it UNDER the operator's block. While the
    %% translation completed that block, a TLS listener stating one unrelated
    %% header also arrived carrying `hsts => undefined` — an operator value,
    %% which wins — so stating `frame_options` silently switched HSTS off on
    %% exactly the listeners it exists for.
    [{pub, Spec}] = inventory(Config, [
        "listeners.pub.transport = tls\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18083\n",
        "listeners.pub.services = api_gateway\n",
        "listeners.pub.tls.certfile = ./etc/ssl/server/keycert.pem\n",
        "listeners.pub.tls.keyfile = ./etc/ssl/server/key.pem\n",
        "listeners.pub.security_headers.frame_options = DENY\n"
    ]),
    #{security_headers := Headers} =
        bondy_listener_config:with_option_defaults(Spec),
    ?assertEqual(<<"DENY">>, maps:get(frame_options, Headers)),
    ?assertEqual(
        <<"max-age=31536000; includeSubDomains">>,
        maps:get(hsts, Headers, undefined)
    ).

an_empty_security_header_value_is_a_syntax_error(Config) ->
    %% Pins a fact about the operator surface, so that the empty-string clause
    %% the deleted completion carried is not "restored" later as if an operator
    %% could reach it.
    %%
    %% `bondy_http_security_headers:build_headers/1' drops an `undefined' member,
    %% which is how a header is suppressed, and the completion turned its own
    %% default of `""' into that `undefined'. An operator has no spelling for it.
    %%
    %% Asserted against `cuttlefish_conf:file/1' rather than through `render/2':
    %% the parser answers `{errorlist, _}' and `cuttlefish_generator:map/2' has no
    %% clause for that, so a render of this file crashes with `case_clause`
    %% instead of returning a `{error, Phase, _}' tuple.
    Dir = ?config(priv_dir, Config),
    File = filename:join(Dir, "empty_" ++ os:getpid() ++ ".conf"),
    ok = file:write_file(
        File, <<"listeners.e.security_headers.frame_options = \n">>
    ),
    ?assertMatch(
        {errorlist, [{error, {conf_syntax, _}} | _]}, cuttlefish_conf:file(File)
    ),

    %% And the nearest spelling an operator might reach for renders the two
    %% quote marks literally — a header containing `""', not an absent header.
    [{q, QSpec}] = inventory(Config, [
        "listeners.q.transport = tcp\n",
        "listeners.q.protocol = http\n",
        "listeners.q.port = 18080\n",
        "listeners.q.services = api_gateway\n",
        "listeners.q.security_headers.frame_options = \"\"\n"
    ]),
    ?assertEqual(
        <<"\"\"">>, key_value:get([security_headers, frame_options], QSpec)
    ).

carrier_and_deflate_keys_reach_their_legacy_paths(Config) ->
    %% The carrier paths are the ones `bondy_listener_config:?CARRIER_DEFAULTS'
    %% enumerates, and two of them are NOT the conf key's own name:
    %% `compression_enabled' targets `compress', and `deflate.level' targets
    %% `deflate_opts.level'.
    [{pub, Spec}] = inventory(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18080\n",
        "listeners.pub.services = wamp_ws, wamp_sse, wamp_longpoll\n",
        "listeners.pub.websocket.compression_enabled = on\n",
        "listeners.pub.websocket.deflate.level = 9\n",
        "listeners.pub.websocket.max_frame_size = 8MB\n",
        "listeners.pub.websocket.ping.max_attempts = 4\n",
        "listeners.pub.sse.ping.interval = 25s\n",
        "listeners.pub.longpoll.poll_timeout = 40s\n"
    ]),
    ?assertEqual(true, key_value:get([websocket, compress], Spec)),
    ?assertEqual(9, key_value:get([websocket, deflate_opts, level], Spec)),
    %% `bytesize', copied verbatim from `wamp.websocket.max_frame_size'. That
    %% mapping does not accept `infinity' either, and widening it here was not
    %% part of this change.
    ?assertEqual(
        8388608, key_value:get([websocket, max_frame_size], Spec)
    ),
    ?assertEqual(4, key_value:get([websocket, ping, max_attempts], Spec)),
    ?assertEqual(25000, key_value:get([sse, ping, interval], Spec)),
    ?assertEqual(40000, key_value:get([longpoll, poll_timeout], Spec)).

listeners_do_not_share_option_values(Config) ->
    %% Two listeners each setting the same key must keep their own value. A
    %% target that named the fuzzy variable instead of collecting per name
    %% collapsed both into one entry, which is the failure this guards.
    Inventory = inventory(Config, [
        "listeners.a.transport = tcp\n",
        "listeners.a.protocol = wamp_rawsocket\n",
        "listeners.a.port = 18082\n",
        "listeners.a.backlog = 512\n",
        "listeners.b.transport = tcp\n",
        "listeners.b.protocol = wamp_rawsocket\n",
        "listeners.b.port = 18083\n",
        "listeners.b.backlog = 256\n"
    ]),
    ?assertEqual([a, b], lists:sort([N || {N, _} <- Inventory])),
    {a, A} = lists:keyfind(a, 1, Inventory),
    {b, B} = lists:keyfind(b, 1, Inventory),
    ?assertEqual(512, key_value:get([transport_opts, socket_opts, backlog], A)),
    ?assertEqual(256, key_value:get([transport_opts, socket_opts, backlog], B)),
    ?assertEqual(18082, maps:get(port, A)),
    ?assertEqual(18083, maps:get(port, B)).

malformed_ip_is_refused(Config) ->
    %% An unparseable address must fail the render. Passing the string through
    %% would put a value ranch rejects into `socket_opts' with nothing left to
    %% catch it.
    Result = render(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = wamp_rawsocket\n",
        "listeners.pub.port = 18082\n",
        "listeners.pub.ip = not.an.address\n"
    ]),
    ?assertMatch({error, apply_translations, _}, Result).

deflate_level_out_of_range_is_refused(Config) ->
    %% The legacy `{mapping, "wamp.websocket.deflate.level"}' translation
    %% range-checks 0..9. Folding it into the single listeners translation
    %% must keep the check.
    Result = render(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18080\n",
        "listeners.pub.services = wamp_ws\n",
        "listeners.pub.websocket.deflate.level = 12\n"
    ]),
    ?assertMatch({error, apply_translations, _}, Result).

no_listener_configured_renders_no_inventory_key(Config) ->
    %% A `bondy.conf' that names no listener must leave `bondy_router.listeners'
    %% ABSENT, not render an empty list: `bondy_listener_manager:init/0'
    %% distinguishes the two, and `[]' would start no listeners at all.
    %%
    %% This holds because the section is default-free.
    %% `cuttlefish_generator:apply_mappings/2' keeps a translation only when at
    %% least one of its mappings has a default or appears in the conf
    %% (:144-167), so with neither, `bondy_router.listeners' lands in
    %% `TranslationsToDrop'.
    AppEnv = render(Config, ["registry.rib.damping = 0\n"]),
    ?assertMatch(L when is_list(L), AppEnv),
    Router = proplists:get_value(bondy_router, AppEnv, []),
    ?assertNot(proplists:is_defined(listeners, Router)),
    %% The literal `'$name'' key is the failure a per-listener target produces.
    %% Nothing in this schema writes it.
    ?assertNot(proplists:is_defined('$name', Router)).

enabled_off_reaches_the_spec(Config) ->
    [{pub, Spec}] = inventory(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = wamp_rawsocket\n",
        "listeners.pub.port = 18082\n",
        "listeners.pub.enabled = off\n"
    ]),
    ?assertEqual(false, maps:get(enabled, Spec)).

port_out_of_range_is_refused(Config) ->
    %% The legacy `port_number' validator's predicate,
    %% `(Port band bnot 16#ffff) =:= 0', rejects any value outside 0..65535.
    %% A `$name' mapping cannot run a `{validators, ...}', so without an
    %% equivalent check in the translation this renders cleanly today and
    %% only fails later, inside ranch.
    Result = render(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = wamp_rawsocket\n",
        "listeners.pub.port = 99999\n"
    ]),
    ?assertMatch({error, apply_translations, _}, Result).

stream_and_http_integer_options_reject_non_positive_values(Config) ->
    %% Each key below inherited a legacy `{validators, ["pos_integer"]}':
    %% `acceptors_pool_size' and `backlog' from both `api_gateway.http.*' and
    %% `wamp.tcp.*'; `ping.max_attempts' from `wamp.tcp.*' alone;
    %% `websocket.ping.max_attempts' from `wamp.websocket.*'; and
    %% `http.max_headers' from the 23-key `api_gateway.http.*' group that
    %% gained the `http.' prefix. None of their datatypes admit an atom, so
    %% checking the raw conf value cannot reject a legitimate default.
    %%
    %% `http.max_cookies' is the one that inherited nothing: cowlib's own type
    %% for it is `non_neg_integer()', and zero there means every request
    %% carrying a Cookie header at all is answered with a 400 — which would
    %% break the OIDC and CSRF flows on the listener. It is checked as a
    %% positive integer with the rest rather than admitting a value whose only
    %% effect is that outage.
    Base = [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18080\n",
        "listeners.pub.services = wamp_ws\n"
    ],
    BadLines = [
        "listeners.pub.acceptors_pool_size = 0\n",
        "listeners.pub.backlog = 0\n",
        "listeners.pub.ping.max_attempts = 0\n",
        "listeners.pub.websocket.ping.max_attempts = 0\n",
        "listeners.pub.http.max_headers = 0\n",
        "listeners.pub.http.max_cookies = 0\n"
    ],
    [
        ?assertMatch(
            {error, apply_translations, _}, render(Config, Base ++ [Line])
        )
     || Line <- BadLines
    ],
    %% The lower bound itself is a legitimate value, not a rejected one.
    [{pub, Spec}] = inventory(Config, Base ++ ["listeners.pub.backlog = 1\n"]),
    ?assertEqual(
        1, key_value:get([transport_opts, socket_opts, backlog], Spec)
    ).

cors_max_age_rejects_negative(Config) ->
    %% `api_gateway.http.cors.max_age' carried
    %% `{validators, ["non_neg_integer"]}'. `wamp.tcp.*' has no `cors', so
    %% this key has exactly one legacy origin.
    BadResult = render(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18080\n",
        "listeners.pub.services = api_gateway\n",
        "listeners.pub.cors.max_age = -1\n"
    ]),
    ?assertMatch({error, apply_translations, _}, BadResult),
    [{pub, Spec}] = inventory(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18080\n",
        "listeners.pub.services = api_gateway\n",
        "listeners.pub.cors.max_age = 0\n"
    ]),
    ?assertEqual(<<"0">>, key_value:get([cors, max_age], Spec)).

linger_timeout_rejects_below_minus_one(Config) ->
    %% `wamp.tcp.linger.timeout' carried
    %% `{validators, ["duration or -1..0"]}', whose actual predicate is
    %% `N >= -1' with no upper bound. Its `http.' sibling,
    %% `api_gateway.http.linger.timeout', carried no validator at all, so
    %% the check applies to the flat key only — see
    %% `http_and_stream_idle_timeout_are_distinct' for the `http.' one still
    %% rendering.
    Result = render(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = wamp_rawsocket\n",
        "listeners.pub.port = 18080\n",
        "listeners.pub.linger.timeout = -2\n"
    ]),
    ?assertMatch({error, apply_translations, _}, Result).

linger_timeout_is_in_seconds(Config) ->
    %% `bondy_config:normalise_socket_opts/1' passes this value straight into
    %% `{linger, {true, N}}', and `inet' documents that component as SECONDS
    %% (`kernel/src/inet.erl:1124', OTP 28.5). The datatype was `{duration, ms}',
    %% so `1s' rendered 1000 and asked the kernel for a 1000-SECOND blocking
    %% close. The assertion is `1'.
    Linger = fun(Value) ->
        [{raw, Spec}] = inventory(Config, [
            "listeners.raw.transport = tcp\n",
            "listeners.raw.protocol = wamp_rawsocket\n",
            "listeners.raw.port = 18082\n",
            "listeners.raw.linger.timeout = " ++ Value ++ "\n"
        ]),
        key_value:get(
            [transport_opts, socket_opts, linger_timeout], Spec, undefined
        )
    end,

    ?assertEqual(1, Linger("1s")),
    ?assertEqual(30, Linger("30s")),
    ?assertEqual(60, Linger("1m")),

    %% A sub-second value rounds UP, so it can never reach the socket as `0'.
    %% That matters more than the rounding does: `{linger, {true, 0}}' is not
    %% "linger briefly", it is abort on close — discard the send buffer, send
    %% RST — so a `500ms' that floored to zero would silently turn a graceful
    %% close into a reset. `cuttlefish_duration:parse/2' uses
    %% `cuttlefish_util:ceiling/1'; measured.
    ?assertEqual(1, Linger("500ms")),
    ?assertEqual(1, Linger("1ms")),
    ?assertEqual(2, Linger("1500ms")),

    %% A bare integer is NOT unit-converted by cuttlefish
    %% (`cuttlefish_datatypes.erl:232'), so that form already meant seconds
    %% before this change and is unaffected by it. It is also the form the `-1'
    %% sentinel arrives in — `"-1"' as a duration STRING is a parse error — which
    %% is why the datatype has to keep its `integer' alternative.
    ?assertEqual(1, Linger("1")),
    ?assertEqual(-1, Linger("-1")).

a_security_header_can_be_switched_off_on_its_own(Config) ->
    %% `security_headers.enabled = off' is all-or-nothing, so without a per-header
    %% value meaning "off" there was no way to keep two headers and drop the
    %% third. It matters most for `hsts', which a TLS listener now sends by
    %% default.
    [{pub, Spec}] = inventory(Config, [
        "listeners.pub.transport = tls\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18083\n",
        "listeners.pub.services = api_gateway\n",
        "listeners.pub.tls.certfile = /tmp/c.pem\n",
        "listeners.pub.tls.keyfile = /tmp/k.pem\n",
        "listeners.pub.security_headers.hsts = off\n",
        "listeners.pub.security_headers.frame_options = SAMEORIGIN\n"
    ]),
    Headers = key_value:get([security_headers], Spec, #{}),

    %% `off' renders as `undefined', which is what
    %% `bondy_http_security_headers:build_headers/2' drops, and what beats the
    %% TLS listener's HSTS default in `with_option_defaults/1' — the merge fills
    %% only ABSENT keys, so a present `undefined' wins.
    ?assertEqual(undefined, key_value:get(hsts, Headers, missing)),

    %% The sibling is unaffected: this is per-header, not another `enabled'.
    ?assertEqual(
        ~"SAMEORIGIN", key_value:get(frame_options, Headers, missing)
    ),

    %% And a real value is still a binary rather than an atom, so the extended
    %% datatype falls through to `string' for everything that is not literally
    %% `off'. `office' is a value, not a typo.
    [{pub2, Spec2}] = inventory(Config, [
        "listeners.pub2.transport = tcp\n",
        "listeners.pub2.protocol = http\n",
        "listeners.pub2.port = 18080\n",
        "listeners.pub2.services = api_gateway\n",
        "listeners.pub2.security_headers.frame_options = office\n"
    ]),
    ?assertEqual(
        ~"office",
        key_value:get([security_headers, frame_options], Spec2, missing)
    ).

all_116_keys_reach_their_documented_paths(Config) ->
    %% Pins the hand-written route table: renders every one of the 116
    %% `listeners.$name.*' keys in a single listener and asserts the whole
    %% resulting spec, so a wrong path silently relocating an operator's
    %% setting shows up as a map mismatch rather than passing unnoticed.
    Lines = [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18099\n",
        "listeners.pub.path = /tmp/bondy-pub.sock\n",
        "listeners.pub.services = api_gateway, wamp_ws\n",
        "listeners.pub.enabled = on\n",
        "listeners.pub.start_phase = early\n",
        "listeners.pub.ip = 127.0.0.1\n",
        "listeners.pub.ip_version = 4\n",
        "listeners.pub.acceptors_pool_size = 16\n",
        "listeners.pub.max_connections = 4096\n",
        "listeners.pub.backlog = 1024\n",
        "listeners.pub.keepalive = on\n",
        "listeners.pub.nodelay = on\n",
        "listeners.pub.reuseport = on\n",
        "listeners.pub.sndbuf = 64KB\n",
        "listeners.pub.recbuf = 64KB\n",
        "listeners.pub.buffer = 128KB\n",
        "listeners.pub.handshake_timeout = 5s\n",
        "listeners.pub.linger.timeout = 2s\n",
        "listeners.pub.idle_timeout = 30s\n",
        "listeners.pub.auth_timeout = 7s\n",
        "listeners.pub.hibernate = idle\n",
        "listeners.pub.proxy_protocol = on\n",
        "listeners.pub.proxy_protocol.mode = strict\n",
        "listeners.pub.proxy_protocol.trusted_proxies = 10.0.0.0/8\n",
        "listeners.pub.ping.enabled = on\n",
        "listeners.pub.ping.idle_timeout = 10s\n",
        "listeners.pub.ping.timeout = 5s\n",
        "listeners.pub.ping.max_attempts = 3\n",
        "listeners.pub.http.active_n = 5\n",
        "listeners.pub.http.buffer.min = 1KB\n",
        "listeners.pub.http.buffer.max = 128KB\n",
        "listeners.pub.http.idle_timeout = 45s\n",
        "listeners.pub.http.inactivity_timeout = 60s\n",
        "listeners.pub.http.initial_stream_flow_size = 64KB\n",
        "listeners.pub.http.invalid_response_headers = error_terminate\n",
        "listeners.pub.http.linger.timeout = 4s\n",
        "listeners.pub.http.max_authority_length = 255\n",
        "listeners.pub.http.max_authorization_header_value_length = 8192\n",
        "listeners.pub.http.max_concurrent_streams = 128\n",
        "listeners.pub.http.max_cookie_header_value_length = 4096\n",
        "listeners.pub.http.max_cookies = 50\n",
        "listeners.pub.http.max_empty_lines = 5\n",
        "listeners.pub.http.max_header_name_length = 64\n",
        "listeners.pub.http.max_header_value_length = 4096\n",
        "listeners.pub.http.max_headers = 100\n",
        "listeners.pub.http.max_keepalive = 1000\n",
        "listeners.pub.http.max_method_length = 32\n",
        "listeners.pub.http.max_request_line_length = 8000\n",
        "listeners.pub.http.max_skip_body_length = 1000000\n",
        "listeners.pub.http.request_timeout = 5s\n",
        "listeners.pub.http.reset_idle_timeout_on_send = on\n",
        "listeners.pub.http.sendfile = on\n",
        "listeners.pub.http.versions = 2, 1.1\n",
        "listeners.pub.cors.enabled = on\n",
        "listeners.pub.cors.allowed_origins = https://a.example.com\n",
        "listeners.pub.cors.allowed_methods = GET,POST\n",
        "listeners.pub.cors.allowed_headers = content-type\n",
        "listeners.pub.cors.max_age = 3600\n",
        "listeners.pub.security_headers.enabled = on\n",
        "listeners.pub.security_headers.hsts = max-age=31536000\n",
        "listeners.pub.security_headers.frame_options = DENY\n",
        "listeners.pub.security_headers.content_type_options = nosniff\n",
        "listeners.pub.security_headers.content_security_policy = "
        "default-src 'self'\n",
        "listeners.pub.server_header = bondy-test\n",
        "listeners.pub.websocket.ping.enabled = on\n",
        "listeners.pub.websocket.ping.idle_timeout = 15s\n",
        "listeners.pub.websocket.ping.timeout = 5s\n",
        "listeners.pub.websocket.ping.max_attempts = 4\n",
        "listeners.pub.websocket.idle_timeout = 60s\n",
        "listeners.pub.websocket.max_frame_size = 8MB\n",
        "listeners.pub.websocket.hibernate = idle\n",
        "listeners.pub.websocket.compression_enabled = on\n",
        "listeners.pub.websocket.deflate.level = 6\n",
        "listeners.pub.websocket.deflate.mem_level = 8\n",
        "listeners.pub.websocket.deflate.strategy = default\n",
        "listeners.pub.websocket.deflate.server_context_takeover = takeover\n",
        "listeners.pub.websocket.deflate.client_context_takeover = "
        "no_takeover\n",
        "listeners.pub.websocket.deflate.server_max_window_bits = 12\n",
        "listeners.pub.websocket.deflate.client_max_window_bits = 10\n",
        "listeners.pub.sse.ping.enabled = on\n",
        "listeners.pub.sse.ping.interval = 20s\n",
        "listeners.pub.sse.idle_timeout = 90s\n",
        "listeners.pub.longpoll.poll_timeout = 25s\n",
        "listeners.pub.longpoll.idle_timeout = 30s\n",
        "listeners.pub.mcp.protocol_versions = 2026-07-28, 2025-11-25\n",
        "listeners.pub.mcp.public_base_uri = https://mcp.example.com\n",
        "listeners.pub.mcp.max_body_size = 2MB\n",
        "listeners.pub.mcp.max_inflight = 32\n",
        "listeners.pub.mcp.idle_timeout = 5m\n",
        "listeners.pub.mcp.list.default_page_size = 100\n",
        "listeners.pub.mcp.schema.max_depth = 16\n",
        "listeners.pub.mcp.schema.max_validation_ms = 100ms\n",
        "listeners.pub.rate_limit.connection.enabled = on\n",
        "listeners.pub.rate_limit.connection.rate = 30\n",
        "listeners.pub.rate_limit.connection.capacity = 60\n",
        "listeners.pub.rate_limit.handshake.enabled = on\n",
        "listeners.pub.rate_limit.handshake.rate = 10\n",
        "listeners.pub.rate_limit.handshake.capacity = 20\n",
        "listeners.pub.rate_limit.auth.enabled = on\n",
        "listeners.pub.rate_limit.auth.rate = 5\n",
        "listeners.pub.rate_limit.auth.capacity = 10\n",
        "listeners.pub.rate_limit.http.enabled = on\n",
        "listeners.pub.rate_limit.http.rate = 50\n",
        "listeners.pub.rate_limit.http.capacity = 100\n",
        "listeners.pub.rate_limit.message.enabled = on\n",
        "listeners.pub.rate_limit.message.rate = 500\n",
        "listeners.pub.rate_limit.message.capacity = 1000\n",
        "listeners.pub.tls.certfile = /tmp/certs/cert.pem\n",
        "listeners.pub.tls.keyfile = /tmp/certs/key.pem\n",
        "listeners.pub.tls.cacertfile = /tmp/certs/ca.pem\n",
        "listeners.pub.tls.versions = 1.2, 1.3\n",
        "listeners.pub.tls.verify = verify_peer\n",
        "listeners.pub.tls.fail_if_no_peer_cert = on\n"
    ],
    [{pub, Spec}] = inventory(Config, Lines),
    Expected = #{
        transport => tcp,
        protocol => http,
        port => 18099,
        path => "/tmp/bondy-pub.sock",
        services => [api_gateway, wamp_ws],
        enabled => true,
        start_phase => early,
        ip => {127, 0, 0, 1},
        server_header => "bondy-test",
        transport_opts => #{
            num_acceptors => 16,
            max_connections => 4096,
            handshake_timeout => 5000,
            socket_opts => #{
                ip_version => inet,
                backlog => 1024,
                keepalive => true,
                nodelay => true,
                reuseport => true,
                sndbuf => 65536,
                recbuf => 65536,
                buffer => 131072,
                %% Seconds, from `linger.timeout = 2s'. The `http.' sibling
                %% below is milliseconds; see
                %% `http_and_stream_idle_timeout_are_distinct'.
                linger_timeout => 2
            }
        },
        idle_timeout => 30000,
        auth_timeout => 7000,
        hibernate => idle,
        proxy_protocol => #{
            enabled => true,
            mode => strict,
            trusted_proxies => "10.0.0.0/8"
        },
        ping => #{
            enabled => true,
            idle_timeout => 10000,
            timeout => 5000,
            max_attempts => 3
        },
        rate_limit => #{
            connection => #{enabled => true, rate => 30, capacity => 60},
            handshake => #{enabled => true, rate => 10, capacity => 20},
            auth => #{enabled => true, rate => 5, capacity => 10},
            http => #{enabled => true, rate => 50, capacity => 100},
            message => #{enabled => true, rate => 500, capacity => 1000}
        },
        protocol_opts => #{
            active_n => 5,
            dynamic_buffer => #{min => 1024, max => 131072},
            idle_timeout => 45000,
            inactivity_timeout => 60000,
            initial_stream_flow_size => 65536,
            invalid_response_headers => error_terminate,
            linger_timeout => 4000,
            max_authority_length => 255,
            max_authorization_header_value_length => 8192,
            max_concurrent_streams => 128,
            max_cookie_header_value_length => 4096,
            %% Rendered into `protocol_opts' with the rest of the
            %% `listeners.$name.http.*' block although Cowboy's protocol loop
            %% does not read it: cowlib takes it per call, and
            %% `bondy_http_utils:parse_cookies/1' reads it back from here.
            max_cookies => 50,
            max_empty_lines => 5,
            max_header_name_length => 64,
            max_header_value_length => 4096,
            max_headers => 100,
            max_keepalive => 1000,
            max_method_length => 32,
            max_request_line_length => 8000,
            max_skip_body_length => 1000000,
            request_timeout => 5000,
            reset_idle_timeout_on_send => true,
            sendfile => true
        },
        %% NOT inside `protocol_opts': `bondy_listener_ranch' consumes it to
        %% derive ALPN and Cowboy's `protocols'; Cowboy itself never reads a
        %% `versions' key. The h2-first order also proves rendering preserves
        %% the operator's order rather than normalising it.
        http_versions => [http2, http],
        cors => #{
            enabled => true,
            allowed_origins => [<<"https://a.example.com">>],
            allowed_methods => <<"GET,POST">>,
            allowed_headers => <<"content-type">>,
            max_age => <<"3600">>
        },
        security_headers => #{
            enabled => true,
            hsts => <<"max-age=31536000">>,
            frame_options => <<"DENY">>,
            content_type_options => <<"nosniff">>,
            content_security_policy => <<"default-src 'self'">>
        },
        websocket => #{
            ping => #{
                enabled => true,
                idle_timeout => 15000,
                timeout => 5000,
                max_attempts => 4
            },
            idle_timeout => 60000,
            max_frame_size => 8388608,
            hibernate => idle,
            compress => true,
            deflate_opts => #{
                level => 6,
                mem_level => 8,
                strategy => default,
                server_context_takeover => takeover,
                client_context_takeover => no_takeover,
                server_max_window_bits => 12,
                client_max_window_bits => 10
            }
        },
        sse => #{
            ping => #{enabled => true, interval => 20000},
            idle_timeout => 90000
        },
        longpoll => #{
            poll_timeout => 25000,
            idle_timeout => 30000
        },
        mcp => #{
            protocol_versions => [<<"2026-07-28">>, <<"2025-11-25">>],
            public_base_uri => <<"https://mcp.example.com">>,
            max_body_size => 2097152,
            max_inflight => 32,
            idle_timeout => 300000,
            list => #{default_page_size => 100},
            schema => #{max_depth => 16, max_validation_ms => 100}
        },
        tls => #{
            certfile => "/tmp/certs/cert.pem",
            keyfile => "/tmp/certs/key.pem",
            cacertfile => "/tmp/certs/ca.pem",
            versions => ['tlsv1.2', 'tlsv1.3'],
            verify => verify_peer,
            fail_if_no_peer_cert => true
        }
    },
    ?assertEqual(Expected, Spec).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% Renders `Lines' (a bondy.conf fragment) and returns the generated app env,
%% or cuttlefish's `{error, Phase, Errors}'.
render(Config, Lines) ->
    Dir = ?config(priv_dir, Config),
    File = filename:join(Dir, "bondy_" ++ os:getpid() ++ ".conf"),
    ok = file:write_file(File, iolist_to_binary(Lines)),
    Schema = cuttlefish_schema:files(
        filelib:wildcard(filename:join(?config(schema_dir, Config), "*.schema"))
    ),
    Conf = cuttlefish_conf:file(File),
    cuttlefish_generator:map(Schema, Conf).

%% Renders and returns `bondy_router.listeners', failing the case if the render
%% itself failed.
inventory(Config, Lines) ->
    case render(Config, Lines) of
        {error, _, _} = Error ->
            ct:fail({render_failed, Error});
        AppEnv ->
            proplists:get_value(
                listeners,
                proplists:get_value(bondy_router, AppEnv, []),
                undefined
            )
    end.

%% Walks up from this module's beam and from the current directory looking for
%% the directory that holds `schema/bondy.schema'. CT runs with its own working
%% directory, so neither a relative path nor the cwd alone locates the schema.
repo_root() ->
    Candidates = [filename:dirname(code:which(?MODULE)), cwd()],
    case lists:filtermap(fun walk_up/1, Candidates) of
        [Root | _] -> Root;
        [] -> ct:fail({schema_dir_not_found, Candidates})
    end.

cwd() ->
    {ok, Dir} = file:get_cwd(),
    Dir.

walk_up(Dir) -> walk_up(Dir, 10).

walk_up(_Dir, 0) ->
    false;
walk_up(Dir, N) ->
    case filelib:is_regular(filename:join([Dir, "schema", "bondy.schema"])) of
        true ->
            {true, Dir};
        false ->
            case filename:dirname(Dir) of
                Dir -> false;
                Parent -> walk_up(Parent, N - 1)
            end
    end.
