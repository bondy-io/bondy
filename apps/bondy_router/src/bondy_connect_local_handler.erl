%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_local_handler).

-moduledoc """
Router-side adapter for the `bondy_connect` **in-VM (local) transport**.

This is the `bondy`-app implementation of the `bondy_connect_local` handler
behaviour. It is the *only* place the in-VM transport touches the router core
(`bondy_router`, `bondy_session_manager`, …); `bondy_connect` itself names no
`bondy` module. `bondy_app:start/2` registers this module via
`bondy_connect_local:register_handler/1`, so on a router node `transport =>
local` works, while on a peer node (no `bondy` app) the transport is simply
unavailable.

The `bondy_connect_local` transport runs the callbacks here **in the connection
process**, so `bondy_session:new/4` builds the session `bondy_ref` targeting that
pid — every router delivery (`{$bondy_request, _, _, M}`) lands in the
connection's mailbox, where `handle_info/2` turns it into an inbound record.

**Authentication.** An in-VM peer is inside the trusted BEAM, so the WAMP
challenge methods do not apply: the session is opened **anonymous** (realm
authorization/grants/sources still enforced).
""".

-behaviour(bondy_connect_local).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").

%% A synthetic loopback peer for the session (the router's IP-based pipeline —
%% logging, events, source-based authz — expects a `{IP, Port}`).
-define(LOCAL_PEER, {{127, 0, 0, 1}, 0}).

%% The opaque session handle handed back to `bondy_connect_local'.
-record(local_session, {
    session :: bondy_session:t(),
    context :: bondy_context:t(),
    realm_uri :: binary()
}).

-export([open/3]).
-export([forward/2]).
-export([handle_info/2]).
-export([close/1]).

%% =============================================================================
%% bondy_connect_local CALLBACKS
%% =============================================================================

-spec open(RealmUri :: binary(), Roles :: map(), Opts :: map()) ->
    {ok, term(), bondy_wamp_message:t()} | {error, term()}.

open(RealmUri, Roles, _Opts) ->
    case bondy_realm:get(RealmUri) of
        {ok, _Realm} ->
            do_open(RealmUri, Roles);
        {error, not_found} ->
            {error, {no_such_realm, RealmUri}}
    end.

-spec forward(bondy_wamp_message:t(), term()) ->
    ok | {reply, bondy_wamp_message:t()} | {error, term()}.

forward(Msg, #local_session{context = Ctxt}) ->
    case bondy_router:forward(Msg, Ctxt) of
        {ok, _Ctxt1} ->
            ok;
        {reply, Reply, _Ctxt1} ->
            {reply, Reply};
        {stop, Reply, _Ctxt1} ->
            {reply, Reply}
    end.

-spec handle_info(term(), term()) -> {ok, [bondy_wamp_message:t()]} | ignore.

%% A WAMP message delivered by the router to the connection (peer) mailbox.
handle_info({?BONDY_REQ, _Pid, _RealmUri, M}, #local_session{}) ->
    {ok, [M]};
handle_info(_Info, #local_session{}) ->
    ignore.

-spec close(term()) -> ok.

close(#local_session{session = Session}) ->
    _ = catch bondy_session_manager:close(Session),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private Open the in-VM session and build the forwarding context + WELCOME.
do_open(RealmUri, Roles) ->
    SessionId = bondy_session_id:new(),
    Properties = #{
        roles => Roles,
        peer => ?LOCAL_PEER,
        authrealm => RealmUri,
        authid => bondy_utils:uuid(),
        authmethod => ?WAMP_ANON_AUTH,
        authrole => <<"anonymous">>,
        is_anonymous => true,
        type => client
    },
    try bondy_session_manager:open(SessionId, RealmUri, Properties) of
        {ok, Session} ->
            Ctxt = bondy_context:set_session(bondy_context:new(), Session),
            Welcome = welcome_msg(Session, RealmUri),
            LocalSession = #local_session{
                session = Session,
                context = Ctxt,
                realm_uri = RealmUri
            },
            {ok, LocalSession, Welcome};
        {error, _} = Error ->
            Error
    catch
        Class:Reason ->
            {error, {session_open_failed, Class, Reason}}
    end.

%% @private Synthesize the WELCOME for the already-open session, mirroring
%% `bondy_wamp_protocol:open_session/2'.
welcome_msg(Session, RealmUri) ->
    SessionId = bondy_session:external_id(Session),
    Info = bondy_session:to_external(Session),
    bondy_wamp_message:welcome(SessionId, Info#{
        realm => RealmUri,
        agent => bondy_router:agent(),
        roles => bondy_router:roles()
    }).
