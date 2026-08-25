%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_upstream_sup).

-moduledoc """
Supervisor for the client direction (design §13): one
`bondy_mcp_upstream` per enabled `mcp.upstreams.$name` declaration.

Validates the declaration set as a whole before starting anything, and
an invalid set fails the application start — a declared upstream that
cannot be projected as declared is a configuration error to surface at
boot, not a surface to silently narrow:

- every upstream names an `http_connector` service, a realm and a
  prefix;
- prefixes are unique per realm across upstreams — the §13.3 namespace
  isolation: no upstream can shadow another's tool names — and outside
  the `wamp.` and `bondy.` reserved namespaces.

The explicit `identity` declaration (§13.1; `service` is the only value)
is enforced by `bondy_mcp_upstream:init/1` itself, the one point every
start path goes through — a child missing it fails to start, and with it
this supervisor and the application.
""".

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc false.
init([]) ->
    Upstreams = [
        U
     || U <- application:get_env(bondy_mcp, upstreams, []),
        maps:get(enabled, U, true)
    ],
    ok = validate(Upstreams),
    Children = [
        #{
            id => {bondy_mcp_upstream, maps:get(name, U)},
            start => {bondy_mcp_upstream, start_link, [U]},
            restart => permanent,
            shutdown => 5000,
            type => worker
        }
     || U <- Upstreams
    ],
    Flags = #{strategy => one_for_one, intensity => 5, period => 10},
    {ok, {Flags, Children}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
validate(Upstreams) ->
    ok = lists:foreach(fun validate_one/1, Upstreams),
    Pairs = [
        {maps:get(realm, U), maps:get(prefix, U)}
     || U <- Upstreams
    ],
    case Pairs -- lists:usort(Pairs) of
        [] ->
            ok;
        Dups ->
            error({invalid_upstream_config, {duplicate_prefix, Dups}})
    end.

%% @private
%% The §13.1 identity declaration is enforced by `bondy_mcp_upstream`'s
%% own `init/1` — the one point every start path (this supervisor, a
%% direct test/console start) goes through — so it is deliberately NOT
%% re-checked here. This validates only what the owner cannot see: the
%% set-level properties and the per-declaration required fields.
validate_one(#{name := Name} = U) ->
    Prefix = required(prefix, U),
    _ = required(realm, U),
    _ = required(service, U),
    case Prefix of
        <<"wamp.", _/binary>> ->
            error({invalid_upstream_config, {reserved_prefix, Name, Prefix}});
        <<"bondy.", _/binary>> ->
            error({invalid_upstream_config, {reserved_prefix, Name, Prefix}});
        _ ->
            ok
    end.

%% @private
required(Key, #{name := Name} = U) ->
    case maps:get(Key, U, undefined) of
        V when is_binary(V), V =/= <<>> ->
            V;
        _ ->
            error({invalid_upstream_config, {missing, Key, Name}})
    end.
