%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_message_id).
-moduledoc """
Generates WAMP message identifiers in the global, router and session scopes
as defined by the WAMP specification.
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(TAB, bondy_session_counter).

-export([init/0]).
-export([init_session/2]).
-export([session/2]).
-export([purge_session/2]).
-export([global/0]).
-export([router/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Initialises the ets table to support session-scoped identifiers.
This function has to be called during application startup.
""".
-spec init() -> ok.

init() ->
    Opts = [
        ordered_set,
        {keypos, 1},
        named_table,
        public,
        {read_concurrency, true},
        {write_concurrency, true},
        {decentralized_counters, true}
    ],
    {ok, ?TAB} = bondy_connect_table_manager:add(?TAB, Opts),
    ok.

-doc """
Starts the session-scoped counter of a session. `session/2` draws the session's
IDs from it until `purge_session/2` removes it.
""".
-spec init_session(
    RealmUri :: uri(),
    SessionOrId :: bondy_session:t() | bondy_session_id:t()
) -> ok.

init_session(RealmUri, SessionId) when
    is_binary(RealmUri) andalso is_binary(SessionId)
->
    Key = {RealmUri, SessionId},
    _ = ets:insert_new(?TAB, {Key, 0}),
    ok;
init_session(RealmUri, Session) ->
    init_session(RealmUri, bondy_session:id(Session)).

-doc """
Generates a WAMP message id in the global scope.
IDs in the global scope MUST be drawn *randomly* from a uniform
distribution over the complete range `[0, 2^53]`.
""".
-spec global() -> id().

global() ->
    bondy_wamp_utils:rand_uniform().

-doc """
Generates a WAMP message id in the router scope.
IDs in the router scope CAN be chosen freely by the specific router
implementation.
""".
-spec router(RealmUri :: uri()) -> id().

router(_) ->
    global().

-doc """
Generates a WAMP message id in the session scope.
IDs in the session scope MUST be incremented by 1 beginning with 1 and
wrapping to 1 after it reached `2^53` (for each direction -
Client-to-Router and Router-to-Client)
This is the Router-to-Client direction.

A session without a counter, one never initialised with `init_session/2` or
already purged with `purge_session/2`, gets a random ID from `router/1`, and no
counter is created for it.
""".
-spec session(
    RealmUri :: uri(),
    SessionOrId :: bondy_session:t() | bondy_session_id:t()
) -> id().

session(RealmUri, SessionId) when
    is_binary(RealmUri) andalso is_binary(SessionId)
->
    Key = {RealmUri, SessionId},
    try
        ets:update_counter(?TAB, Key, {2, 1, ?MAX_ID, 1})
    catch
        error:badarg ->
            %% `ets:member/2` raises for a missing table, so only a missing
            %% counter falls back.
            false = ets:member(?TAB, Key),
            router(RealmUri)
    end;
session(RealmUri, Session) ->
    session(RealmUri, bondy_session:id(Session)).

-doc """
Removes all counters associated with session identifier `SessionId`.
""".
-spec purge_session(
    RealmUri :: uri(),
    SessionOrId :: bondy_session:t() | bondy_session_id:t()
) -> ok.

purge_session(RealmUri, SessionId) when
    is_binary(RealmUri) andalso is_binary(SessionId)
->
    true = ets:match_delete(?TAB, {{RealmUri, SessionId}, '_'}),
    ok;
purge_session(RealmUri, Session) when is_binary(RealmUri) ->
    purge_session(RealmUri, bondy_session:id(Session)).
