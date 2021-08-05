%% =============================================================================
%%  bondy_session.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

%% =============================================================================
%% @doc
%% A Session (wamp session) is a transient conversation between two
%% WAMP Peers attached to a Realm and running over a Transport.
%%
%% Bondy implementation ties the lifetime of the underlying transport connection
%% for a WAMP connection to that of a WAMP Session
%% i.e. establish a new transport-layer connection as part of each new
%% session establishment.
%%
%% A Bondy Session is a not an application Session and is not a store for
%% application specific content (an application session store should be
%% implemented as a service i.e. a Callee).
%%
%% Currently sessions are not persistent i.e. if the connection closes the
%% session data will be lost.
%%
%% @end
%% =============================================================================
-module(bondy_session).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(SESSION_SPACE_NAME, ?MODULE).
-define(SESSION_SEQ_POS, #session.seq).
-define(DEFAULT_RATE, #rate_window{limit = 1000, duration = 1}).
-define(DEFAULT_QUOTA, #quota_window{limit = 1000, duration = 1}).% TODO


-record(quota_window, {
    limit                           ::  pos_integer(),
    %% time when the quota resets in secs
    renews                          ::  pos_integer(),
    %% number of requests remaining in quota
    remaining                       ::  pos_integer(),
    %% time in seconds during which quota is valid e.g.
    %% the length of the window
    duration                        ::  pos_integer()
}).
-type quota_window()                ::  #quota_window{}.

-record(rate_window, {
    %% max number of messages allowed during window
    limit                           ::  pos_integer(),
    %% duration of window in seconds
    duration                        ::  pos_integer()
}).
-type rate_window()                 ::  #rate_window{}.


-record(session, {
    id                              ::  id(),
    realm_uri                       ::  uri(),
    node                            ::  atom(),
    %% If owner of the session.
    %% This is either pid of the TCP or WS handler process or
    %% the cowboy handler.
    pid = self()                    ::  pid() | undefined,
    %% The {IP, Port} of the client
    peer                            ::  peer() | undefined,
    %% User-Agent HTTP header or WAMP equivalent
    agent                           ::  binary(),
    %% Sequence number used for ID generation
    seq = 0                         ::  non_neg_integer(),
    %% Peer WAMP Roles played by peer
    roles                           ::  map() | undefined,
    %% WAMP Auth
    security_enabled = true         ::  boolean(),
    is_anonymous = false            ::  boolean(),    authid                          ::  binary() | undefined,
    authrole                        ::  binary() | undefined,
    authroles = []                  ::  [binary()],
    authmethod                      ::  binary() | undefined,
    %% Expiration and Limits
    created                         ::  pos_integer(),
    expires_in                      ::  pos_integer() | infinity,
    rate = ?DEFAULT_RATE            ::  rate_window(),
    quota = ?DEFAULT_QUOTA          ::  quota_window()
}).

-type peer()                    ::  {inet:ip_address(), inet:port_number()}.
-type t()                       ::  #session{}.
-type session_opts()            ::  #{roles => map()}.
-type details()                 ::  #{
                                        session => id(),
                                        authid => id(),
                                        authrole => binary(),
                                        authmethod => binary(),
                                        authprovider => binary(),
                                        transport => #{
                                            peername => binary()
                                        }
                                    }.

-export_type([t/0]).
-export_type([peer/0]).
-export_type([session_opts/0]).
-export_type([details/0]).


-export([agent/1]).
-export([close/1]).
-export([created/1]).
-export([node/1]).
-export([fetch/1]).
-export([id/1]).
-export([incr_seq/1]).
-export([list/0]).
-export([list/1]).
-export([list_peer_ids/1]).
-export([list_peer_ids/2]).
-export([lookup/1]).
-export([new/3]).
-export([new/4]).
-export([open/3]).
-export([open/4]).
-export([peer/1]).
-export([peer_id/1]).
-export([pid/1]).
-export([realm_uri/1]).
-export([roles/1]).
-export([size/0]).
-export([to_external/1]).
-export([info/1]).
-export([update/1]).
-export([user/1]).
-export([is_security_enabled/1]).
% -export([stats/0]).

%% -export([features/1]).
%% -export([subscriptions/1]).
%% -export([registrations/1]).



%% =============================================================================
%% API
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc Creates a new transient session (not persisted)
%% @end
%% -----------------------------------------------------------------------------
-spec new(peer(), uri() | bondy_realm:t(), session_opts()) ->
    t() | no_return().

new(Peer, RealmUri, Opts) when is_binary(RealmUri) ->
    new(bondy_utils:get_id(global), Peer, bondy_realm:fetch(RealmUri), Opts);

new(Peer, Realm, Opts) when is_map(Opts) ->
    new(bondy_utils:get_id(global), Peer, Realm, Opts).


-spec new(id(), peer(), uri() | bondy_realm:t(), session_opts()) ->
    t() | no_return().

new(Id, Peer, RealmUri, Opts) when is_binary(RealmUri) ->
    new(Id, Peer, bondy_realm:fetch(RealmUri), Opts);

new(Id, Peer, Realm, Opts) when is_map(Opts) ->
    RealmUri = bondy_realm:uri(Realm),
    S0 = #session{
        id = Id,
        peer = Peer,
        realm_uri = RealmUri,
        node = bondy_peer_service:mynode(),
        created = erlang:system_time(seconds)
    },
    parse_details(Opts, S0).


%% -----------------------------------------------------------------------------
%% @doc
%% Creates a new session provided the RealmUri exists or can be dynamically
%% created. It assigns a new Id.
%% It calls {@link bondy_utils:get_realm/1} which will fail with an exception
%% if the realm does not exist or cannot be created
%% -----------------------------------------------------------------------------
-spec open(peer(), uri() | bondy_realm:t(), session_opts()) ->
    t() | no_return().

open(Peer, RealmUri, Opts) when is_binary(RealmUri) ->
    open(bondy_utils:get_id(global), Peer, bondy_realm:fetch(RealmUri), Opts);

open(Peer, Realm, Opts) when is_map(Opts) ->
    open(bondy_utils:get_id(global), Peer, Realm, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% Creates a new session provided the RealmUri exists or can be dynamically
%% created.
%% It calls {@link bondy_utils:get_realm/1} which will fail with an exception
%% if the realm does not exist or cannot be created
%% -----------------------------------------------------------------------------
-spec open(id(), peer(), uri() | bondy_realm:t(), session_opts()) ->
    t() | no_return().
open(Id, Peer, RealmUri, Opts) when is_binary(RealmUri) ->
    open(Id, Peer, bondy_realm:fetch(RealmUri), Opts);

open(Id, Peer, Realm, Opts) when is_map(Opts) ->
    RealmUri = bondy_realm:uri(Realm),
    S1 = new(Id, Peer, Realm, Opts),
    Agent = S1#session.agent,

    Pid = self(),

    case ets:insert_new(table(Id), S1) of
        true ->
            Pid = self(),
            true = gproc:reg_other({n, l, {session, RealmUri, Id}}, Pid),
            ok = bondy_event_manager:notify(
                {session_opened, RealmUri, Id, Agent, Peer, Pid}),
            S1;
        false ->
            error({integrity_constraint_violation, Id})
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(t()) -> ok.
update(#session{id = Id} = S) ->
    true = ets:insert(table(Id), S),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec close(t()) -> ok.

close(#session{id = Id} = S) ->
    Realm = S#session.realm_uri,
    Agent = S#session.agent,
    Peer = S#session.peer,
    Secs = erlang:system_time(seconds) - S#session.created,
    ok = bondy_event_manager:notify(
        {session_closed, Id, Realm, Agent, Peer, Secs}),
    true = ets:delete(table(Id), Id),
    _ = lager:debug("Session closed; session_id=~p, realm=~s", [Id, Realm]),
    ok;

close(Id) ->
    case lookup(Id) of
        #session{} = Session -> close(Session);
        _ -> ok
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec id(t()) -> id().

id(#session{id = Id}) ->
    Id.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(id() | t()) -> uri().

realm_uri(#session{realm_uri = Val}) ->
    Val;

realm_uri(Id) when is_integer(Id) ->
    #session{realm_uri = Val} = fetch(Id),
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec roles(id() | t()) -> map().

roles(#session{roles = Val}) ->
    Val;

roles(Id) ->
    #session{roles = Val} = fetch(Id),
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the identifier for the owner of this session
%% @end
%% -----------------------------------------------------------------------------
-spec peer_id(t()) -> local_peer_id().

peer_id(#session{} = S) ->
    {
        S#session.realm_uri,
        S#session.node,
        S#session.id,
        S#session.pid
    };

peer_id(Id) when is_integer(Id) ->
    peer_id(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the pid of the process managing the transport that the session
%% identified by Id runs on.
%% @end
%% -----------------------------------------------------------------------------
-spec pid(t()) -> pid().

pid(#session{pid = Pid}) ->
    Pid;

pid(Id) when is_integer(Id) ->
    #session{pid = Val} = fetch(Id),
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the node of the process managing the transport that the session
%% identified by Id runs on.
%% @end
%% -----------------------------------------------------------------------------
-spec node(t()) -> atom().

node(#session{node = Val}) ->
    Val;

node(Id) when is_integer(Id) ->
    #session{node = Val} = fetch(Id),
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the time at which the session was created, Its value is a
%% timestamp in seconds.
%% @end
%% -----------------------------------------------------------------------------
-spec created(t()) -> pos_integer().

created(#session{created = Val}) ->
    Val;

created(Id) when is_integer(Id) ->
    #session{created = Val} = fetch(Id),
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec agent(t()) -> binary() | undefined.

agent(#session{agent = Val}) ->
    Val;

agent(Id) when is_integer(Id) ->
    #session{agent = Val} = fetch(Id),
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peer(t()) -> peer().

peer(#session{peer = Val}) ->
    Val;

peer(Id) when is_integer(Id) ->
    #session{peer = Val} = fetch(Id),
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec user(t()) -> bondy_rbac_user:t().

user(#session{realm_uri = Uri, authid = Id}) ->
    bondy_rbac_user:fetch(Uri, Id);

user(Id) when is_integer(Id) ->
    user(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec incr_seq(id() | t()) -> map().

incr_seq(#session{id = Id}) ->
    incr_seq(Id);

incr_seq(Id) when is_integer(Id), Id >= 0 ->
    Tab = tuplespace:locate_table(?SESSION_SPACE_NAME, Id),
    ets:update_counter(Tab, Id, {?SESSION_SEQ_POS, 1, ?MAX_ID, 0}).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the number of sessions in the tuplespace.
%% @end
%% -----------------------------------------------------------------------------
-spec size() -> non_neg_integer().

size() ->
    tuplespace:size(?SESSION_SPACE_NAME).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_security_enabled(t()) -> boolean().

is_security_enabled(#session{security_enabled = Val}) ->
    Val;

is_security_enabled(Id) ->
    Tab = tuplespace:locate_table(?SESSION_SPACE_NAME, Id),
    ets:lookup_element(Tab, Id, #session.security_enabled).



%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the session identified by Id from the tuplespace or 'not_found'
%% if it doesn't exist.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(id()) -> t() | {error, not_found}.

lookup(Id) ->
    case do_lookup(Id) of
        #session{} = Session ->
            Session;
        Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the session identified by Id from the tuplespace. If the session
%% does not exist it fails with reason '{badarg, Id}'.
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(id()) -> t() | no_return().

fetch(Id) ->
    case lookup(Id) of
        {error, not_found} ->
            error({badarg, Id});
        Session ->
            Session
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
%% @TODO provide a limit and itereate on each table providing a custom
%% continuation
list() ->
    list(#{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
list(#{return := details_map}) ->
    Tabs = tuplespace:tables(?SESSION_SPACE_NAME),
    [to_external(X) || T <- Tabs, X <- ets:tab2list(T)];

list(_) ->
    Tabs = tuplespace:tables(?SESSION_SPACE_NAME),
    lists:append([ets:tab2list(T) || T <- Tabs]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
list_peer_ids(N) ->
    list_peer_ids('_', N).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
list_peer_ids(RealmUri, N) when is_integer(N), N >= 1 ->
    Tabs = tuplespace:tables(?SESSION_SPACE_NAME),
    do_list_peer_ids(Tabs, RealmUri, N).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(t()) -> details().

to_external(#session{} = S) ->
    #{
        session => S#session.id,
        authid => S#session.authid,
        authrole => S#session.authrole,
        authmethod => S#session.authmethod,
        authprovider => <<"com.leapsight.bondy">>,
        'x_authroles' => S#session.authroles,
        transport => #{
            peername => inet_utils:peername_to_binary(S#session.peer)
        }
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec info(t()) -> details().

info(#session{is_anonymous = true} = S) ->
    to_external(S);

info(#session{is_anonymous = false} = S) ->
    Map = to_external(S),
    Map#{'x_meta' => bondy_rbac_user:meta(user(S))}.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
parse_details(Opts, Session0)  when is_map(Opts) ->
    maps:fold(fun parse_details/3, Session0, Opts).


%% @private
parse_details(roles, undefined, _) ->
    error({invalid_options, missing_client_role});

parse_details(roles, Roles, Session) when is_map(Roles) ->
    length(maps:keys(Roles)) > 0 orelse
    error({invalid_options, missing_client_role}),
    Session#session{roles = parse_roles(Roles)};

parse_details(agent, V, Session) when is_binary(V) ->
    Session#session{agent = V};

parse_details(security_enabled, V, Session) when is_boolean(V) ->
    Session#session{security_enabled = V};

parse_details(is_anonymous, V, Session) when is_boolean(V) ->
    Session#session{is_anonymous = V};

parse_details(authid, V, Session) when is_binary(V) ->
    Session#session{authid = V};

parse_details(authrole, V, Session) when is_binary(V) ->
    Session#session{authrole = V};

parse_details(authroles, V, Session) when is_list(V) ->
    Session#session{authroles = V};

parse_details(authmethod, V, Session) when is_binary(V) ->
    Session#session{authmethod = V};

parse_details(_, _, Session) ->
    Session.



%% ------------------------------------------------------------------------
%% private
%% @doc
%% Merges the client provided role features with the ones provided by
%% the router. This will become the feature set used by the router on
%% every session request.
%% @end
%% ------------------------------------------------------------------------
parse_roles(Roles) ->
    parse_roles(maps:keys(Roles), Roles).


%% @private
parse_roles([], Roles) ->
    Roles;

parse_roles([caller|T], Roles) ->
    F = bondy_utils:merge_map_flags(
        maps:get(caller, Roles), ?CALLER_FEATURES),
    parse_roles(T, Roles#{caller => F});

parse_roles([callee|T], Roles) ->
    F = bondy_utils:merge_map_flags(
        maps:get(callee, Roles), ?CALLEE_FEATURES),
    parse_roles(T, Roles#{callee => F});

parse_roles([subscriber|T], Roles) ->
    F = bondy_utils:merge_map_flags(
        maps:get(subscriber, Roles), ?SUBSCRIBER_FEATURES),
    parse_roles(T, Roles#{subscriber => F});

parse_roles([publisher|T], Roles) ->
    F = bondy_utils:merge_map_flags(
        maps:get(publisher, Roles), ?PUBLISHER_FEATURES),
    parse_roles(T, Roles#{publisher => F});

parse_roles([_|T], Roles) ->
    parse_roles(T, Roles).

%% @private
table(Id) ->
    tuplespace:locate_table(?SESSION_SPACE_NAME, Id).


%% @private
-spec do_lookup(id()) -> t() | {error, not_found}.

do_lookup(Id) ->
    Tab = table(Id),
    case ets:lookup(Tab, Id)  of
        [#session{} = Session] ->
            Session;
        [] ->
            {error, not_found}
    end.



%% @private
do_list_peer_ids([], _, _) ->
    ?EOT;

do_list_peer_ids([Tab | Tabs], RealmUri, N)
when is_binary(RealmUri) orelse RealmUri == '_' ->
    Pattern = #session{
        id = '$3',
        realm_uri = '$1',
        node = '$2',
        pid = '$4',
        peer = '_',
        agent = '_',
        seq = '_',
        roles = '_',
        security_enabled = '_',
        is_anonymous = '_',
        authid = '_',
        authrole = '_',
        authroles = '_',
        authmethod = '_',
        created = '_',
        expires_in = '_',
        rate = '_',
        quota = '_'
    },
    Conds = case RealmUri of
        '_' -> [];
        _ ->  [{'=:=', '$1', RealmUri}]
    end,
    Projection = [{{'$1', '$2', '$3', '$4'}}],
    MS = [{Pattern, Conds, Projection}],

    case ets:select(Tab, MS, N) of
        {L, Cont} ->
            FunCont = fun() ->
                do_list_peer_ids({continuation, Tabs, RealmUri, N, Cont})
            end,
           {L, FunCont};
        ?EOT ->
            do_list_peer_ids(Tabs, RealmUri, N)
    end.


%% @private
do_list_peer_ids({continuation, [], _, _, ?EOT}) ->
    ?EOT;

do_list_peer_ids({continuation, Tabs, RealmUri, N, ?EOT}) ->
    do_list_peer_ids(Tabs, RealmUri, N);

do_list_peer_ids({continuation, Tabs, RealmUri, N, Cont}) ->
    case ets:select(Cont) of
        ?EOT ->
            ?EOT;
        {L, Cont} ->
            FunCont = fun() ->
                do_list_peer_ids({continuation, Tabs, RealmUri, N, Cont})
            end,
            {L, FunCont}
    end.