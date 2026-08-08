%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_test_realm).

-moduledoc """
A stand-in for the router's realm module, for suites that need prototype
inheritance without a running router.

`bondy_mail` resolves a realm's prototype through whichever module is named by
the `realm_module` configuration key -- `bondy_realm` on a real node. This
implements the same one function over a map held in `persistent_term`, so a
suite can declare an inheritance chain in a line and assert what it admits.

    ok = bondy_mail_test_realm:install(#{~"com.child" => ~"com.proto"}),
    ~"com.proto" = bondy_mail_test_realm:prototype_uri(~"com.child").
""".

-define(KEY, {?MODULE, prototypes}).

%% API
-export([install/1]).
-export([prototype_uri/1]).
-export([uninstall/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Point `bondy_mail` at this module and declare the inheritance chain.

`Map` maps a realm URI to the prototype it inherits from.
""".
-spec install(Map :: #{binary() => binary()}) -> ok.

install(Map) when is_map(Map) ->
    ok = persistent_term:put(?KEY, Map),
    set_module(?MODULE).

-doc "Remove the resolver, so no realm inherits from anything.".
-spec uninstall() -> ok.

uninstall() ->
    _ = persistent_term:erase(?KEY),
    set_module(undefined).

%% @private
%% `bondy_mail_config` reads through `app_config`, which caches in
%% `persistent_term` at application start. `application:set_env/3` alone would
%% therefore be invisible to an already-running application -- which is exactly
%% when a suite wants to install this. `bondy_mail_config:set/2` writes both.
set_module(Module) ->
    ok = application:set_env(bondy_mail, realm_module, Module),
    ok = bondy_mail_config:set(realm_module, Module).

-doc """
Return the prototype `RealmUri` inherits from.

Answers `undefined` for a realm with no prototype, which is what the real
resolver does.
""".
-spec prototype_uri(RealmUri :: binary()) -> binary() | undefined.

prototype_uri(RealmUri) ->
    maps:get(RealmUri, persistent_term:get(?KEY, #{}), undefined).
