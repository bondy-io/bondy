%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_origin_bans).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Node-shared origin ban list.

A single ETS `set` table per node, keyed by `Origin :: binary()`. All
instances on the node refuse remote events from a banned origin
without invoking `verify_event/2`.

Banning is a *per-replica trust decision*: if an origin is malicious
for one instance it is malicious for every instance, since the origin
identifies the *replica*, not a per-instance role. The library
exposes the mechanism (`ban/2,3`, `unban/1`, `is_banned/1`, `list/0`);
**policy is the consumer's** — typically driven by inspecting the
detected-equivocation rows in `bondy_oplog_quarantine` and
applying a chosen threshold.

## Concurrency

Writes (ban / unban) flow through the gen_server. Reads
(`is_banned/1`, `list/0`) go directly to ETS — created with
`read_concurrency` and `protected` access, so the hot path on every
`append_remote` is a single ETS lookup, no gen_server round-trip.
""").

-define(TABLE, bondy_oplog_origin_bans_tab).

-record(origin_ban, {
    origin :: binary(),
    banned_at :: integer(),
    reason :: term(),
    proof :: undefined | term()
}).

-record(state, {}).

-type ban_entry() :: #{
    origin := binary(),
    banned_at := integer(),
    reason := term(),
    proof := undefined | term()
}.

-export_type([ban_entry/0]).

%% Lifecycle
-export([start_link/0]).
-export([child_spec/0]).

%% Writes
-export([ban/2]).
-export([ban/3]).
-export([unban/1]).

%% Reads
-export([is_banned/1]).
-export([list/0]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

%% =============================================================================
%% LIFECYCLE
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

%% =============================================================================
%% WRITES
%% =============================================================================

?DOC("""
Bans `Origin`. Subsequent `append_remote/2` calls for events from this
origin will be rejected with `{error, banned_origin}` without invoking
the validator.

`Reason` is opaque; useful values are e.g.
`{equivocation, ProofTerm}` or operator-supplied tags. Synchronous —
the ban is effective on return.
""").
-spec ban(Origin :: binary(), Reason :: term()) -> ok.

ban(Origin, Reason) ->
    ban(Origin, Reason, undefined).

-spec ban(Origin :: binary(), Reason :: term(), Proof :: term() | undefined) ->
    ok.

ban(Origin, Reason, Proof) when is_binary(Origin) ->
    gen_server:call(?MODULE, {ban, Origin, Reason, Proof}).

?DOC("""
Removes `Origin` from the ban list. Idempotent. Synchronous.
""").
-spec unban(Origin :: binary()) -> ok.

unban(Origin) when is_binary(Origin) ->
    gen_server:call(?MODULE, {unban, Origin}).

%% =============================================================================
%% READS
%% =============================================================================

?DOC("""
Returns `true` if `Origin` is currently banned, `false` otherwise.
Direct ETS read, no gen_server round-trip.
""").
-spec is_banned(Origin :: binary()) -> boolean().

is_banned(Origin) when is_binary(Origin) ->
    ets:member(?TABLE, Origin).

?DOC("""
Returns all current bans as a list of maps.
""").
-spec list() -> [ban_entry()].

list() ->
    [
        #{
            origin => O,
            banned_at => BA,
            reason => R,
            proof => P
        }
     || #origin_ban{origin = O, banned_at = BA, reason = R, proof = P} <-
            ets:tab2list(?TABLE)
    ].

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init([]) ->
    process_flag(trap_exit, true),
    _Tab = ets:new(?TABLE, [
        named_table,
        set,
        protected,
        {keypos, #origin_ban.origin},
        {read_concurrency, true}
    ]),
    {ok, #state{}}.

handle_call({ban, Origin, Reason, Proof}, _From, State) ->
    Entry = #origin_ban{
        origin = Origin,
        banned_at = os:system_time(millisecond),
        reason = Reason,
        proof = Proof
    },
    true = ets:insert(?TABLE, Entry),
    ?LOG_NOTICE(#{
        description => "origin banned",
        origin => Origin,
        reason => Reason
    }),
    {reply, ok, State};
handle_call({unban, Origin}, _From, State) ->
    true = ets:delete(?TABLE, Origin),
    {reply, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
