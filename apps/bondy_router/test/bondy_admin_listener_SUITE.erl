%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Drives the built-in Admin API over real sockets on a booted node.
%%
%% Two cases are a PAIR and only mean something together: the Admin API must be
%% reachable on a listener declaring `admin_api` and unreachable on one
%% declaring only `api_gateway`. Either alone is satisfied by a node that mounts
%% the specification nowhere, which is exactly the state this suite exists to
%% catch.
%%
%% The remaining cases are about `admin_local`, the internal Unix-domain
%% listener no `bondy.conf` can remove, disable or misconfigure. They assert it
%% BOUND — a completed request over the socket — rather than that it appears in
%% the inventory.
%% =============================================================================
-module(bondy_admin_listener_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([admin_api_is_served_on_the_admin_listener/1]).
-export([admin_api_is_absent_from_the_public_listener/1]).
-export([stored_specs_are_absent_from_the_admin_listeners/1]).
-export([admin_local_is_injected_without_configuration/1]).
-export([admin_local_socket_is_bound_and_serves/1]).

-define(ADMIN, admin).
-define(PUBLIC, api_gateway_http).

%% A stored API Gateway specification, loaded by this suite so the OTHER
%% direction of the split can be falsified.
-define(SPEC_ID, <<"com.example.adminsplit.api">>).
-define(SPEC_REALM, <<"com.example.adminsplit">>).
-define(SPEC_BASE_PATH, <<"/adminsplit/v1.0">>).
-define(SPEC_PATH, "/adminsplit/v1.0/things").

%% A path of the built-in Admin API specification
%% (`priv/specs/bondy_admin_api.json`). Its version's `base_path` is
%% `/[v1.0]` — an optional Cowboy segment — so the unprefixed form routes.
-define(ADMIN_API_PATH, "/realms").

all() ->
    [
        admin_api_is_served_on_the_admin_listener,
        admin_api_is_absent_from_the_public_listener,
        stored_specs_are_absent_from_the_admin_listeners,
        admin_local_is_injected_without_configuration,
        admin_local_socket_is_bound_and_serves,
        http_requests_are_rate_limited,
        listener_scope_http_budget_is_enforced,
        realm_scope_http_budget_is_enforced,
        oauth2_draws_from_the_auth_class
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    ok = load_stored_spec(),
    Config.

end_per_suite(Config) ->
    try
        bondy_http_gateway:delete(?SPEC_ID)
    catch
        _:_ -> ok
    end,
    {save_config, Config}.

%% =============================================================================
%% CASES
%% =============================================================================

admin_api_is_served_on_the_admin_listener(_Config) ->
    {ok, Status, _, _} = get_path(?ADMIN, ?ADMIN_API_PATH),
    assert_routed(Status).

admin_api_is_absent_from_the_public_listener(_Config) ->
    %% The public listener declares `api_gateway` and not `admin_api`, so realm
    %% administration is not reachable on it.
    {ok, Status, _, _} = get_path(?PUBLIC, ?ADMIN_API_PATH),
    ?assertEqual(404, Status).

stored_specs_are_absent_from_the_admin_listeners(_Config) ->
    %% The other direction of the split, and the one the previous case cannot
    %% cover: a listener declaring `admin_api` must NOT serve the specifications
    %% in storage. This is what keeps a customer's API specification off the
    %% listener that administers realms, users and grants.
    %%
    %% TWO independent mechanisms produce that outcome, and the weaker one hides
    %% the stronger one, so both are pinned separately:
    %%
    %%   1. `bondy_http_gateway:rebuild_dispatch_tables/0` recompiles only
    %%      listeners declaring `api_gateway`, so a spec stored at runtime never
    %%      reaches an admin listener's table at all.
    %%   2. A listener that does not declare `api_gateway` has no `api_gateway`
    %%      CARRIER, so `bondy_http_services:dispatch/1` never runs the clause
    %%      that asks the gateway for stored routes — they are absent even when
    %%      the table IS rebuilt, which is what happens on every listener start.
    %%
    %% Asserting only over HTTP tests (1) and leaves (2) unfalsified: with (2)
    %% defeated the admin listener still answers 404, because its table was
    %% compiled before this suite stored anything. Verified when (2) was a
    %% `services` membership test inside `routes/3` — removing that test left
    %% every case green. Since the carrier split it is not a test to remove:
    %% `resolve_carriers/3` would have to produce a carrier no service named.
    {ok, Public, _, _} = get_path(?PUBLIC, ?SPEC_PATH),
    ?assertNotEqual(404, Public),

    %% Mechanism 1.
    {ok, Admin, _, _} = get_path(?ADMIN, ?SPEC_PATH),
    ?assertEqual(404, Admin),
    ?assertEqual(404, uds_get(admin_local_path(), ?SPEC_PATH)),

    %% Mechanism 2: recompile the admin listeners' tables with the
    %% specification in storage — the state a node restart would produce — and
    %% assert the routes are still not there.
    ok = recompile(?ADMIN),
    ok = recompile(admin_local),

    {ok, AdminAfter, _, _} = get_path(?ADMIN, ?SPEC_PATH),
    ?assertEqual(404, AdminAfter),
    ?assertEqual(404, uds_get(admin_local_path(), ?SPEC_PATH)),

    %% Each still serves its OWN specification, so the assertions above are
    %% about the stored spec and not about a table that lost every route.
    assert_routed(element(2, get_path(?ADMIN, ?ADMIN_API_PATH))),
    assert_routed(uds_get(admin_local_path(), ?ADMIN_API_PATH)).

admin_local_is_injected_without_configuration(_Config) ->
    %% `admin_local` is in no inventory an operator or this harness can write:
    %% neither `bondy_ct`'s declared one nor the built-in default mentions it,
    %% and the manager appends it. All three halves are asserted, because the
    %% latter two are what make the first a guarantee rather than a coincidence —
    %% an operator cannot pre-empt the injected entry with one of their own, and
    %% `bondy_listener_config:resolve/2` rejects the name outright if they try.
    ?assertEqual(
        false, lists:keymember(admin_local, 1, bondy_config:get(listeners, []))
    ),
    ?assertEqual(
        false,
        lists:keymember(
            admin_local, 1, bondy_listener_config:default_inventory()
        )
    ),
    {ok, Listener} = bondy_listener_manager:listener(admin_local),
    ?assertMatch(#{transport := uds, bind := {path, _}}, Listener),
    ?assertEqual(true, lists:member(admin_api, maps:get(services, Listener))),

    ?assertMatch(
        {error, {invalid_listener, admin_local, reserved_name}},
        bondy_listener_config:resolve(
            [
                {admin_local, #{
                    transport => tcp,
                    protocol => http,
                    port => 0,
                    services => [admin]
                }}
            ],
            fun bondy_config:get/2
        )
    ).

admin_local_socket_is_bound_and_serves(_Config) ->
    Path = admin_local_path(),

    %% The socket node exists. `filelib:is_file/1` CANNOT express this: a bound
    %% Unix domain socket has `file_info.type = other`, and `filelib:is_file/1`
    %% answers true only for `regular` and `directory` — verified directly, it
    %% returns `false` for a socket this node is listening on.
    ?assertMatch(
        {ok, #file_info{type = other}}, file:read_file_info(Path)
    ),

    %% And it is owner-only. The socket file's mode is the only access control a
    %% Unix domain listener has, and `gen_tcp:listen/2` creates the node with
    %% the process umask — 0755 under the umask here, 0777 under a umask of 0.
    %% Asserting the low 9 bits rather than `=/= 0777` so a partial narrowing
    %% fails too.
    {ok, #file_info{mode = Mode}} = file:read_file_info(Path),
    ?assertEqual(8#600, Mode band 8#777),

    %% And it SERVES. File existence alone is not evidence of a listener: a
    %% socket file outlives the process that created it, so a stale one from a
    %% previous boot is indistinguishable by any filesystem predicate
    %% (`gen_tcp:connect/4` on such a file returns `econnrefused` — verified).
    %% Completing a request is what proves the bind, the accept and the handler.
    %%
    %% `/ping` comes from the `admin` service and replies 204 with no
    %% authentication (`bondy_admin_ping_http_handler:init/2`).
    ?assertEqual(204, uds_get(Path, "/ping")),

    %% The Admin API is mounted here too, which is the point of the safety net:
    %% a node whose every TCP listener failed to bind is still administrable.
    assert_routed(uds_get(Path, ?ADMIN_API_PATH)).

%% The gateway REST handler's `rate_limited` hook draws from the `http`
%% class per source IP. Enabling ONLY that class both trips it and PINS
%% it — a hook drawing from any other class would never see a 429 here.
%% Statuses are not asserted before exhaustion: the `{http, 127.0.0.1}`
%% bucket is shared with any other suite in a run, so only "rapid
%% requests trip 429" and "off means served" are contract.
http_requests_are_rate_limited(_) ->
    {ok, Before, _, _} = get_path(?ADMIN, ?ADMIN_API_PATH),
    ?assertNotEqual(429, Before),
    ok = bondy_config:set([security, rate_limit], #{
        enabled => true,
        http => #{rate => 1, capacity => 2}
    }),
    try
        Results = [
            get_path(?ADMIN, ?ADMIN_API_PATH)
         || _ <- lists:seq(1, 6)
        ],
        {ok, Last, Headers, _} = lists:last(Results),
        ?assertEqual(429, Last),
        ?assertMatch({_, _}, lists:keyfind(<<"retry-after">>, 1, Headers))
    after
        ok = bondy_config:set([security, rate_limit], undefined)
    end,
    %% Off again: the same source IP serves immediately — the verdict is
    %% config-driven, no depleted bucket outlives the feature.
    {ok, After, _, _} = get_path(?ADMIN, ?ADMIN_API_PATH),
    ?assertNotEqual(429, After).

%% The LISTENER scope of the rate-limit chain, on the wire: with the
%% NODE scope entirely off, a budget on this listener's own
%% `rate_limit.http` block throttles requests arriving through it — the
%% seat passes the cowboy `ref` (the listener name) as the listener
%% dimension. Same contract discipline as the node-scope case above:
%% only "rapid requests trip 429" and "off means served" are asserted.
listener_scope_http_budget_is_enforced(_) ->
    ok = bondy_config:set([security, rate_limit], #{enabled => false}),
    ok = bondy_config:set(
        [?ADMIN, rate_limit], #{http => #{rate => 1, capacity => 2}}
    ),
    try
        Results = [
            get_path(?ADMIN, ?ADMIN_API_PATH)
         || _ <- lists:seq(1, 6)
        ],
        {ok, Last, Headers, _} = lists:last(Results),
        ?assertEqual(429, Last),
        ?assertMatch({_, _}, lists:keyfind(<<"retry-after">>, 1, Headers))
    after
        ok = bondy_config:set([?ADMIN, rate_limit], undefined),
        ok = bondy_config:set([security, rate_limit], undefined)
    end,
    {ok, After, _, _} = get_path(?ADMIN, ?ADMIN_API_PATH),
    ?assertNotEqual(429, After).

%% NODE and LISTENER scopes entirely off, a budget in the REALM's own
%% `rate_limit` property throttles requests the gateway serves on that
%% realm — the seat passes the API specification's realm as the realm
%% dimension. The Admin API runs on the master realm, so its property is
%% the one under test; clearing it must restore service (the chain no
%% longer consults the bucket).
realm_scope_http_budget_is_enforced(_) ->
    ok = bondy_config:set([security, rate_limit], #{enabled => false}),
    Master = <<"com.leapsight.bondy">>,
    _ = bondy_realm:update(Master, #{
        rate_limit => #{
            http => #{per_caller => #{rate => 1, capacity => 2}}
        }
    }),
    try
        Results = [
            get_path(?ADMIN, ?ADMIN_API_PATH)
         || _ <- lists:seq(1, 6)
        ],
        {ok, Last, Headers, _} = lists:last(Results),
        ?assertEqual(429, Last),
        ?assertMatch({_, _}, lists:keyfind(<<"retry-after">>, 1, Headers))
    after
        _ = bondy_realm:update(Master, #{rate_limit => undefined}),
        ok = bondy_config:set([security, rate_limit], undefined)
    end,
    {ok, After, _, _} = get_path(?ADMIN, ?ADMIN_API_PATH),
    ?assertNotEqual(429, After).

%% The OAuth2 endpoints draw from the `auth` class — the shared per-IP
%% credential-guessing budget WAMP AUTHENTICATE consumes — while the
%% gateway hook does NOT: with only `auth` enabled, the OAuth2 callback
%% throttles and the gateway callback stays open. A distinct loopback
%% peer keys buckets no other suite touches.
oauth2_draws_from_the_auth_class(_) ->
    Req = #{ref => ?ADMIN, peer => {{127, 0, 0, 88}, 5000}, headers => #{}},
    %% The handler state is built by the handler itself — its
    %% `rate_limited` reads the realm dimension from it, so a hand-rolled
    %% stand-in would not exercise the real seat.
    {cowboy_rest, _, OauthSt} = bondy_oauth2_rest_handler:init(Req, #{
        realm_uri => <<"com.leapsight.bondy">>,
        token_path => <<"/token">>,
        revoke_path => <<"/revoke">>
    }),
    ok = bondy_config:set([security, rate_limit], #{
        enabled => true,
        auth => #{rate => 1, capacity => 1}
    }),
    try
        ?assertMatch(
            {false, _, _},
            bondy_oauth2_rest_handler:rate_limited(Req, OauthSt)
        ),
        ?assertMatch(
            {{true, _}, _, _},
            bondy_oauth2_rest_handler:rate_limited(Req, OauthSt)
        ),
        ?assertMatch(
            {false, _, _},
            bondy_http_gateway_rest_handler:rate_limited(Req, #{})
        )
    after
        ok = bondy_config:set([security, rate_limit], undefined)
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

admin_local_path() ->
    {ok, #{transport := uds, bind := {path, Path}}} =
        bondy_listener_manager:listener(admin_local),
    Path.

%% Rebuilds one listener's dispatch table from its current services and the
%% current contents of storage — what `bondy_listener_ranch:start/1` does. A
%% running listener reads its table through `{persistent_term, Key}`, so this
%% takes effect without restarting it.
recompile(Name) ->
    {ok, Listener} = bondy_listener_manager:listener(Name),
    bondy_listener_ranch:recompile_dispatch(Listener).

%% A minimal stored specification with a static action, so the public listener
%% answers it without authentication and the assertion turns purely on whether
%% the route is mounted.
load_stored_spec() ->
    _ = bondy_realm:create(#{
        uri => ?SPEC_REALM,
        description => <<"Admin/public exposure split">>,
        security_enabled => false
    }),
    ok = bondy_http_gateway:load(#{
        <<"id">> => ?SPEC_ID,
        <<"name">> => ?SPEC_ID,
        <<"host">> => <<"_">>,
        <<"realm_uri">> => ?SPEC_REALM,
        <<"variables">> => #{<<"schemes">> => [<<"http">>]},
        <<"defaults">> => #{
            <<"timeout">> => 15000,
            <<"schemes">> => <<"{{variables.schemes}}">>,
            %% Empty map = no security scheme, so the public listener
            %% answers without credentials and the assertion turns purely on
            %% whether the route is mounted.
            <<"security">> => #{}
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => ?SPEC_BASE_PATH,
                <<"paths">> => #{
                    <<"/things">> => #{
                        <<"is_collection">> => false,
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"type">> => <<"static">>,
                                <<"response">> => #{}
                            },
                            <<"response">> => #{
                                <<"on_result">> => #{<<"body">> => <<>>},
                                <<"on_error">> => #{<<"body">> => <<>>}
                            }
                        }
                    }
                }
            }
        }
    }),
    _ = bondy_http_gateway:rebuild_dispatch_tables(),
    ok.

%% Routed AND served. Not 404 means the route exists; not 5xx means the handler
%% ran to completion. 200, 401 and 403 all satisfy this, and which one is
%% returned depends on authentication, which this suite does not exercise.
%%
%% The 5xx half is not decoration. An HTTP listener with no `proxy_protocol`
%% option block — `admin_local` has none — made
%% `bondy_http_proxy_protocol:source_ip/1` fail with `function_clause` on every
%% request reaching `bondy_http_gateway_rest_handler:init/2`, which is a 500 on
%% a route that exists and which a not-404 assertion passes.
assert_routed(Status) ->
    ct:pal("status ~p", [Status]),
    ?assertNotEqual(404, Status),
    ?assert(Status < 500).

%% The port comes from the resolved inventory rather than a literal, so the case
%% follows a listener whose configured port changes.
get_path(Listener, Path) ->
    {ok, #{bind := {port, Port}}} = bondy_listener_manager:listener(Listener),
    Url = iolist_to_binary([
        "http://127.0.0.1:", integer_to_list(Port), Path
    ]),
    hackney:request(get, Url, [], <<>>, []).

%% A Unix domain socket needs a client that can address one, and hackney takes a
%% URL. `{packet, http_bin}` makes the emulator parse the status line, so this
%% is a complete HTTP/1.1 exchange with no dependency.
uds_get(Path, Target) ->
    {ok, Sock} = gen_tcp:connect(
        {local, Path}, 0, [binary, {active, false}, {packet, http_bin}], 5000
    ),
    Request = [
        "GET ",
        Target,
        " HTTP/1.1\r\n",
        "Host: localhost\r\n",
        "Connection: close\r\n\r\n"
    ],
    ok = gen_tcp:send(Sock, Request),
    Status =
        case gen_tcp:recv(Sock, 0, 5000) of
            {ok, {http_response, _Vsn, Code, _Reason}} -> Code;
            Other -> Other
        end,
    ok = gen_tcp:close(Sock),
    Status.
