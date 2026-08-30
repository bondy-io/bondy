%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rbac_authorize_api_SUITE).

-moduledoc """
`bondy.rbac.authorize`'s two-tier realm rule, and the master-realm refusal on
the `bondy.cert_manager.*` family.

Both are the same underlying subject — which realm a `bondy.*` procedure lets a
caller act on — and both were defects found on 2026-08-31 while auditing
`bondy_wamp_api_utils`'s argument validators.

`bondy.rbac.authorize` reads a REALM as its first positional argument, so
`validate_call_args/3`'s realm comparison is the rule: an ordinary realm's
session may name only its own realm, a master-realm session may name any. It
previously took three arguments with the realm read from the context, which put
the `authid` in the slot the validator reads as a realm — and since a username
never equals a realm URI, every tenant session was refused. Only a master
session got through, able to ask solely about master-realm principals, so the
procedure could not do what `docs/router/reference/wamp_api/rbac.md` says it
does for any caller at all.

The `bondy.cert_manager.*` procedures take no realm and are node state, so the
rule there is simply master-or-nothing. Two of the six validated nothing.

WHAT THIS DOES NOT COVER: the RBAC grant itself. Every case here runs against
realms with security disabled, so `bondy_rbac:authorize/3` short-circuits and
the `wamp.call` permission is never the thing refusing — which is deliberate,
because that short-circuit is exactly the configuration in which the handler
check is the only remaining gate. `bondy_rbac_SUITE` covers grant matching.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM_A, ~"com.example.authorize.a").
-define(REALM_B, ~"com.example.authorize.b").
-define(USER_A, ~"authorize_user_a").
-define(PROC, ~"com.example.thing.get").

all() ->
    [
        a_tenant_session_may_check_its_own_realm,
        a_tenant_session_may_name_its_own_realm_explicitly,
        a_tenant_session_may_not_name_another_realm,
        a_master_session_may_name_any_realm,
        a_master_session_naming_no_realm_asks_about_master,
        an_unknown_authid_answers_false_rather_than_erroring,
        too_few_arguments_is_an_arity_error,
        too_many_arguments_is_an_arity_error,
        cert_manager_refuses_a_tenant_session,
        cert_manager_answers_a_master_session
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    _ = [
        begin
            R = bondy_realm:create(Uri),
            ok = bondy_realm:disable_security(R)
        end
     || Uri <- [?REALM_A, ?REALM_B]
    ],
    %% One real user with one real grant, so a `true` in the cases below is a
    %% grant being found rather than the check answering `true` for everything.
    _ = bondy_rbac_user:add(
        ?REALM_A,
        bondy_rbac_user:new(#{
            username => ?USER_A, password => ~"aWamp2Password"
        })
    ),
    ok = bondy_rbac:grant(?REALM_A, #{
        roles => [?USER_A],
        permissions => [~"wamp.call"],
        uri => ?PROC
    }),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

%% =============================================================================
%% bondy.rbac.authorize — the two-tier realm rule
%% =============================================================================

%% The documented three-argument call. The realm argument is optional, so a
%% tenant session keeps calling exactly as the reference page describes and the
%% validator prepends the only realm it could have named.
%%
%% This is the case that was BROKEN: it answered `not_authorized` for every
%% tenant session.
a_tenant_session_may_check_its_own_realm(_) ->
    ?assertEqual(
        true, call(?REALM_A, [?USER_A, ~"wamp.call", ?PROC])
    ),
    %% The falsifier: the same user, a resource it holds no grant on. Without
    %% it a check that answered `true` unconditionally would pass above.
    ?assertEqual(
        false, call(?REALM_A, [?USER_A, ~"wamp.call", ~"com.example.other"])
    ).

%% The four-argument form, naming its own realm. Same answer, and the form a
%% caller writes when it wants to be explicit.
a_tenant_session_may_name_its_own_realm_explicitly(_) ->
    ?assertEqual(
        true, call(?REALM_A, [?REALM_A, ?USER_A, ~"wamp.call", ?PROC])
    ).

%% The confinement. A session in realm A naming realm B is refused — not
%% answered `false`, which would leak that B has no such grant, but refused.
a_tenant_session_may_not_name_another_realm(_) ->
    E = call_error(?REALM_A, [?REALM_B, ?USER_A, ~"wamp.call", ?PROC]),
    ?assertEqual(?WAMP_NOT_AUTHORIZED, E#error.error_uri),
    %% And in the other direction, so the case is about the realm being
    %% DIFFERENT rather than about realm B in particular.
    E2 = call_error(?REALM_B, [?REALM_A, ?USER_A, ~"wamp.call", ?PROC]),
    ?assertEqual(?WAMP_NOT_AUTHORIZED, E2#error.error_uri).

%% The master realm's tier: any realm, including a tenant's. This is what the
%% procedure could never do before — a master session's realm came from its own
%% context, so it could only ask about master-realm principals.
a_master_session_may_name_any_realm(_) ->
    ?assertEqual(
        true,
        call(?MASTER_REALM_URI, [?REALM_A, ?USER_A, ~"wamp.call", ?PROC])
    ),
    ?assertEqual(
        false,
        call(
            ?MASTER_REALM_URI,
            [?REALM_A, ?USER_A, ~"wamp.call", ~"com.example.other"]
        )
    ).

%% The vacuity guard for the case above: a master session that names no realm
%% still gets ITS OWN, not a wildcard. Without this, "any realm" could be read
%% as "the realm argument is ignored for master".
a_master_session_naming_no_realm_asks_about_master(_) ->
    %% `?USER_A` exists in realm A, not in master, so a master-scoped check
    %% answers `false` for the very grant that answers `true` in realm A.
    ?assertEqual(
        false, call(?MASTER_REALM_URI, [?USER_A, ~"wamp.call", ?PROC])
    ),
    ?assertEqual(
        true,
        call(?MASTER_REALM_URI, [?REALM_A, ?USER_A, ~"wamp.call", ?PROC])
    ).

%% Documented: "A nonexistent `authid` is not an error: it behaves as an
%% identity holding no grants, so the check returns `false`."
an_unknown_authid_answers_false_rather_than_erroring(_) ->
    ?assertEqual(
        false,
        call(?REALM_A, [?REALM_A, ~"no_such_user_at_all", ~"wamp.call", ?PROC])
    ).

%% The realm argument is optional, not the permission and resource. Two
%% arguments cannot be completed into a valid call, so it is an arity error
%% rather than a check against a resource nobody named.
too_few_arguments_is_an_arity_error(_) ->
    E = call_error(?REALM_A, [?USER_A, ~"wamp.call"]),
    ?assertEqual(?WAMP_INVALID_ARGUMENT, E#error.error_uri).

too_many_arguments_is_an_arity_error(_) ->
    E = call_error(
        ?REALM_A, [?REALM_A, ?USER_A, ~"wamp.call", ?PROC, ~"extra"]
    ),
    ?assertEqual(?WAMP_INVALID_ARGUMENT, E#error.error_uri).

%% =============================================================================
%% bondy.cert_manager.* — master or nothing
%% =============================================================================

%% Both of these validated NOTHING before 2026-08-31: they ignored the context
%% and ran. The CA trust store and a listener's certificate are node state, so a
%% tenant session reloading them reaches every other realm the node serves —
%% and in a realm with security disabled, which these are,
%% `bondy_rbac:authorize/3` short-circuits and this check is all that is left.
cert_manager_refuses_a_tenant_session(_) ->
    lists:foreach(
        fun(Proc) ->
            E = call_error(?REALM_A, Proc, []),
            ?assertEqual(?WAMP_NOT_AUTHORIZED, E#error.error_uri, Proc)
        end,
        [?BONDY_CERT_RELOAD_CACERTS, ?BONDY_CERT_ROTATE_ALL]
    ).

%% The falsifier: the guard must refuse the wrong realm, not the procedure.
cert_manager_answers_a_master_session(_) ->
    lists:foreach(
        fun(Proc) ->
            ?assertMatch(
                {reply, #result{}}, dispatch(?MASTER_REALM_URI, Proc, []), Proc
            )
        end,
        [?BONDY_CERT_RELOAD_CACERTS, ?BONDY_CERT_ROTATE_ALL]
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% Through `bondy_wamp_api:handle_call/2`, so the dispatch clause under test is
%% the one that serves the URI.
dispatch(RealmUri, Proc, Args) ->
    Ctxt = bondy_context:local_context(RealmUri),
    M = bondy_wamp_message:call(1, #{}, Proc, Args),
    bondy_wamp_api:handle_call(M, Ctxt).

%% @private
call(RealmUri, Args) ->
    case dispatch(RealmUri, ?BONDY_RBAC_AUTHORIZE, Args) of
        {reply, #result{args = [Reply]}} -> Reply;
        Other -> ct:fail({expected_result, Other})
    end.

%% @private
call_error(RealmUri, Args) ->
    call_error(RealmUri, ?BONDY_RBAC_AUTHORIZE, Args).

%% @private
%% The unauthorized path THROWS rather than replying, which is how
%% `bondy_wamp_api_utils` reports refusal.
call_error(RealmUri, Proc, Args) ->
    try dispatch(RealmUri, Proc, Args) of
        {reply, #error{} = E} -> E;
        Other -> ct:fail({expected_error, Proc, Other})
    catch
        error:#error{} = E -> E
    end.
