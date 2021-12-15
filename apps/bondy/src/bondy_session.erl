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
-behaviour(bondy_sensitive).
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(SESSION_SPACE, ?MODULE).

-record(session, {
    %% TODO The session ID should definitively be a UUID and not a random
    %% integer, this is something we need to change on the WAMP SPEC and adopt
    %% in all clients
    id                              ::  integer(),
    type = client                   ::  bondy_ref:type(),
    tab                             ::  maybe(ets:tid()),
    realm_uri                       ::  uri(),
    ref                             ::  bondy_ref:t(),
    %% The {IP, Port} of the client
    peer                            ::  maybe(peer()),
    %% User-Agent HTTP header or WAMP equivalent
    agent                           ::  binary(),
    %% Sequence number used for ID generation
    seq = 0                         ::  non_neg_integer(),
    %% Peer WAMP Roles played by peer
    roles                           ::  maybe(map()),
    %% WAMP Auth
    security_enabled = true         ::  boolean(),
    is_anonymous = false            ::  boolean(),    authid                          ::  maybe(binary()),
    authrole                        ::  maybe(binary()),
    authroles = []                  ::  [binary()],
    authmethod                      ::  maybe(binary()),
    rbac_context                    ::  maybe(bondy_rbac:context()),
    %% Expiration and Limits
    created                         ::  pos_integer(),
    expires_in                      ::  pos_integer() | infinity,
    meta = #{}                      ::  map()
}).

-type peer()                    ::  {inet:ip_address(), inet:port_number()}.
-type t()                       ::  #session{}.

-type details()                 ::  #{
                                        session => id(),
                                        authid => id(),
                                        authrole => binary(),
                                        authmethod => binary(),
                                        authprovider => binary(),
                                        transport => #{
                                            agent => binary(),
                                            peername => binary()
                                        }
                                    }.

-type properties()              ::  #{
                                        roles := map(),
                                        agent => binary(),
                                        authid => binary(),
                                        authrole => binary(),
                                        authroles => [binary()],
                                        authmethod => binary(),
                                        is_anonymous => boolean(),
                                        roles => peer()
                                    }.

-export_type([t/0]).

%% At the moment we export the id() type defined by the includes. In the future
%% this should be a UUID or KSUID but not a random integer.
-export_type([id/0]).
-export_type([peer/0]).
-export_type([properties/0]).
-export_type([details/0]).


%% BONDY_SENSITIVE CALLBACKS
-export([format_status/2]).

%% API
-export([agent/1]).
-export([authid/1]).
-export([authmethod/1]).
-export([authrole/1]).
-export([authroles/1]).
-export([close/1]).
-export([created/1]).
-export([fetch/1]).
-export([id/1]).
-export([incr_seq/1]).
-export([info/1]).
-export([is_security_enabled/1]).
-export([list/0]).
-export([list/1]).
-export([list_refs/1]).
-export([list_refs/2]).
-export([lookup/1]).
-export([lookup/2]).
-export([new/2]).
-export([new/3]).
-export([node/1]).
-export([nodestring/1]).
-export([peer/1]).
-export([pid/1]).
-export([rbac_context/1]).
-export([realm_uri/1]).
-export([ref/1]).
-export([refresh_rbac_context/1]).
-export([roles/1]).
-export([size/0]).
-export([store/1]).
-export([to_external/1]).
-export([type/1]).
-export([update/1]).
-export([user/1]).

-ifdef(TEST).

-export([table/1]).

-endif.

-on_load(on_load/0).



%% =============================================================================
%% BONDY_SENSITIVE CALLBACKS
%% =============================================================================



-spec format_status(Opt :: normal | terminate, Session :: t()) -> term().

format_status(_Opt, #session{} = S) ->
    S#session{
        authid = bondy_sensitive:wrap(S#session.authid),
        rbac_context = bondy_sensitive:wrap(S#session.rbac_context),
        meta = bondy_sensitive:wrap(S#session.meta)
    }.



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Creates a new transient session (not persisted)
%% @end
%% -----------------------------------------------------------------------------
-spec new(uri() | bondy_realm:t(), properties()) ->
    t() | no_return().

new(RealmUri, Opts) when is_binary(RealmUri) ->
    new(get_id(RealmUri), bondy_realm:fetch(RealmUri), Opts);

new(Realm, Opts) when is_map(Opts) ->
    RealmUri = bondy_realm:uri(Realm),
    new(get_id(RealmUri), Realm, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(id(), uri() | bondy_realm:t(), properties()) ->
    t() | no_return().

new(Id, RealmUri, Opts) when is_binary(RealmUri) ->
    new(Id, bondy_realm:fetch(RealmUri), Opts);

new(Id, Realm, Opts) when is_map(Opts) ->
    RealmUri = bondy_realm:uri(Realm),
    IsSecurityEnabled = bondy_realm:is_security_enabled(RealmUri),

    S1 = parse_details(Opts, #session{}),

    Ref = bondy_ref:new(
        S1#session.type,
        RealmUri,
        self(),
        Id
    ),

    S1#session{
        id = Id,
        %% We added for convenience as it is also in ref
        realm_uri = RealmUri,
        ref = Ref,
        security_enabled = IsSecurityEnabled,
        created = erlang:system_time(seconds)
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec type(t()) -> bondy_ref:type().

type(#session{type = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Creates a new session provided the RealmUri exists or can be dynamically
%% created.
%% It calls {@link bondy_utils:get_realm/1} which will fail with an exception
%% if the realm does not exist or cannot be created
%% -----------------------------------------------------------------------------
-spec store(t()) -> ok | no_return().

store(#session{} = S0) ->
    Id = S0#session.id,
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),
    S = S0#session{tab = Tab},

    true == ets:insert_new(Tab, S)
        orelse error({integrity_constraint_violation, Id}),

    ok = bondy_event_manager:notify({session_opened, S}),

    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(t()) -> ok.

update(#session{id = Id} = S) ->
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),
    true = ets:insert(Tab, S),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec close(t()) -> ok.

close(#session{} = S) ->
    Id = S#session.id,
    RealmUri = S#session.realm_uri,
    Secs = erlang:system_time(seconds) - S#session.created,
    ok = bondy_event_manager:notify({session_closed, S, Secs}),

    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),
    true = ets:delete(Tab, Id),

    ?LOG_DEBUG(#{
        description => "Session closed",
        realm => RealmUri,
        session_id => Id
    }),

    ok.


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

realm_uri(#session{ref = Ref}) ->
    bondy_ref:realm_uri(Ref);

realm_uri(Id) when is_integer(Id) ->
    realm_uri(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec roles(id() | t()) -> map().

roles(#session{roles = Val}) ->
    Val;

roles(Id) ->
    roles(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc Returns the identifier for the owner of this session
%% @end
%% -----------------------------------------------------------------------------
-spec ref(t()) -> bondy_ref:client() | bondy_ref:relay().

ref(#session{ref = Ref}) ->
    Ref;

ref(Id) when is_integer(Id) ->
    ref(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the pid of the process managing the transport that the session
%% identified by Id runs on.
%% @end
%% -----------------------------------------------------------------------------
-spec pid(id() | t()) -> pid().

pid(#session{ref = Ref}) ->
    bondy_ref:pid(Ref);

pid(Id) when is_integer(Id) ->
    pid(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the node of the process managing the transport that the session
%% identified by Id runs on.
%% @end
%% -----------------------------------------------------------------------------
-spec node(t()) -> atom().

node(#session{ref = Ref}) ->
    bondy_ref:node(Ref);

node(Id) when is_integer(Id) ->
    bondy_session:node(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the node of the process managing the transport that the session
%% identified by Id runs on.
%% @end
%% -----------------------------------------------------------------------------
-spec nodestring(t()) -> nodestring().

nodestring(#session{ref = Ref}) ->
    bondy_ref:nodestring(Ref);

nodestring(Id) when is_integer(Id) ->
    bondy_session:nodestring(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc Returns the time at which the session was created, Its value is a
%% timestamp in seconds.
%% @end
%% -----------------------------------------------------------------------------
-spec created(t()) -> pos_integer().

created(#session{created = Val}) ->
    Val;

created(Id) when is_integer(Id) ->
    created(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec agent(t()) -> binary() | undefined.

agent(#session{agent = Val}) ->
    Val;

agent(Id) when is_integer(Id) ->
    agent(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peer(t()) -> peer().

peer(#session{peer = Val}) ->
    Val;

peer(Id) when is_integer(Id) ->
    peer(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authid(t()) -> bondy_rbac_user:username().

authid(#session{authid = Val}) ->
    Val;

authid(Id) when is_integer(Id) ->
    authid(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authrole(t()) -> maybe(bondy_rbac_group:name()).

authrole(#session{authrole = undefined, authroles = []}) ->
    <<"undefined">>;

authrole(#session{authrole = undefined, authroles = [Role]}) ->
    Role;

authrole(#session{authrole = undefined}) ->
    <<"multiple">>;

authrole(#session{authrole = Val}) ->
    Val;

authrole(Id) when is_integer(Id) ->
    authrole(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authroles(t()) -> [bondy_rbac_group:name()].

authroles(#session{authroles = Val}) ->
    Val;

authroles(Id) when is_integer(Id) ->
    authroles(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authmethod(t()) -> binary().

authmethod(#session{authmethod = Val}) ->
    Val;

authmethod(Id) when is_integer(Id) ->
    authmethod(fetch(Id)).


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
-spec rbac_context(id() | t()) -> bondy_rbac:context().

rbac_context(#session{id = Id} = Session) ->
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),

    try ets:lookup_element(Tab, Id, #session.rbac_context) of
        undefined ->
            NewCtxt = get_context(Session),
            ok = update_context(Id, NewCtxt),
            NewCtxt;
        Ctxt ->
            refresh_context(Id, Ctxt)
    catch
        error:badarg ->
            %% Session not in ets, the case for an HTTP session
            get_context(Session)
    end;

rbac_context(Id) when is_integer(Id) ->
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),

    case ets:lookup_element(Tab, Id, #session.rbac_context) of
        undefined ->
            rbac_context(fetch(Id));
        Ctxt ->
            refresh_context(Id, Ctxt)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec refresh_rbac_context(id() | t()) -> bondy_rbac:context().

refresh_rbac_context(#session{id = Id} = Session) ->
    update_context(Id, get_context(Session));

refresh_rbac_context(Id) when is_integer(Id) ->
    refresh_rbac_context(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec incr_seq(id() | t()) -> map().

incr_seq(#session{tab = undefined}) ->
    bondy_utils:get_id(global);

incr_seq(#session{id = Id}) ->
    incr_seq(Id);

incr_seq(Id) when is_integer(Id), Id >= 0 ->
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),
    try
        ets:update_counter(Tab, Id, {#session.seq, 1, ?MAX_ID, 0})
    catch
        error:badarg ->
            bondy_utils:get_id(global)
    end.



%% -----------------------------------------------------------------------------
%% @doc Returns the number of sessions in the tuplespace.
%% @end
%% -----------------------------------------------------------------------------
-spec size() -> non_neg_integer().

size() ->
    %% TODO replace with CRDT Counter
    tuplespace:size(?SESSION_SPACE).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_security_enabled(t()) -> boolean().

is_security_enabled(#session{security_enabled = Val}) ->
    Val;

is_security_enabled(Id) ->
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),
    ets:lookup_element(Tab, Id, #session.security_enabled).



%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the session identified by Id from the tuplespace or 'not_found'
%% if it doesn't exist.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(id() | bondy_ref:t()) -> t() | {error, not_found}.

lookup(Id) when is_integer(Id) ->
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),

    case ets:lookup(Tab, Id)  of
        [#session{} = Session] ->
            Session;
        [] ->
            {error, not_found}
    end;

lookup(Ref) ->
    lookup(bondy_ref:realm_uri(Ref), bondy_ref:session_id(Ref)).


%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the session identified by Id from the tuplespace or 'not_found'
%% if it doesn't exist.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(RealmUri :: uri(), Id :: id()) -> t() | {error, not_found}.

lookup(RealmUri, Id) ->
    case do_lookup(Id) of
        #session{realm_uri = Val} = Session when Val == RealmUri ->
            Session;
        _ ->
            {error, not_found}
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
    Tabs = tuplespace:tables(?SESSION_SPACE),
    [to_external(X) || T <- Tabs, X <- ets:tab2list(T)];

list(_) ->
    Tabs = tuplespace:tables(?SESSION_SPACE),
    lists:append([ets:tab2list(T) || T <- Tabs]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
list_refs(N) ->
    list_refs('_', N).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
list_refs(RealmUri, N) when is_integer(N), N >= 1 ->
    Tabs = tuplespace:tables(?SESSION_SPACE),
    do_list_refs(Tabs, RealmUri, N).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(t()) -> details().

to_external(#session{} = S) ->
    #{
        session => S#session.id,
        authid => S#session.authid,
        authrole => authrole(S),
        authmethod => S#session.authmethod,
        authprovider => <<"com.leapsight.bondy">>,
        'x_authroles' => S#session.authroles,
        transport => #{
            agent => S#session.agent,
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
get_id(RealmUri) ->
    get_id(RealmUri, 20).


%% @private
get_id(RealmUri, N) when N > 0 ->
    Id = bondy_utils:get_id(global),
    case lookup(RealmUri, Id) of
        {error, not_found} ->
            Id;
        _ ->
            get_id(RealmUri, N - 1)
    end;

get_id(_, 0) ->
    error(session_id_collision).


%% @private
%% @doc Called by -on_load() directive.
%% @end
on_load() ->
    Pattern = erlang:make_tuple(
        record_info(size, session), '_', [{1, session}]
    ),
    persistent_term:put({?MODULE, pattern}, Pattern),
    ok.


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

parse_details(peer, V, Session) ->
    case bondy_data_validators:peer(V) of
        true ->
            Session#session{peer = V};
        false ->
            error({invalid_options, peer})
    end;

parse_details(type, V, Session) ->
    lists:member(V, bondy_ref:types())
        orelse error({invalid_options, type}),

    Session#session{type = V};

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
-spec do_lookup(id()) -> t() | {error, not_found}.

do_lookup(Id) ->
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),
    case ets:lookup(Tab, Id)  of
        [#session{} = Session] ->
            Session;
        [] ->
            {error, not_found}
    end.


%% @private
refresh_context(Id, Ctxt) ->
    case bondy_rbac:refresh_context(Ctxt) of
        {true, NewCtxt} ->
            ok = update_context(Id, NewCtxt),
            NewCtxt;
        {false, Ctxt} ->
            Ctxt
    end.


%% @private
update_context(Id, Context) ->
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),
    _ = ets:update_element(Tab, Id, {#session.rbac_context, Context}),
    ok.


%% @private
do_list_refs([], _, _) ->
    ?EOT;

do_list_refs([Tab | Tabs], RealmUri, N)
when is_binary(RealmUri) orelse RealmUri == '_' ->
    Pattern0 = persistent_term:get({?MODULE, pattern}),
    Pattern = Pattern0#session{
        realm_uri = '$1',
        ref = '$2'
    },
    Conds = case RealmUri of
        '_' -> [];
        _ ->  [{'=:=', '$1', RealmUri}]
    end,
    Projection = [{'$2'}],
    MS = [{Pattern, Conds, Projection}],

    case ets:select(Tab, MS, N) of
        {L, Cont} ->
            FunCont = fun() ->
                do_list_refs({continuation, Tabs, RealmUri, N, Cont})
            end,
           {L, FunCont};
        ?EOT ->
            do_list_refs(Tabs, RealmUri, N)
    end.


%% @private
do_list_refs({continuation, [], _, _, ?EOT}) ->
    ?EOT;

do_list_refs({continuation, Tabs, RealmUri, N, ?EOT}) ->
    do_list_refs(Tabs, RealmUri, N);

do_list_refs({continuation, Tabs, RealmUri, N, Cont0}) ->
    case ets:select(Cont0) of
        ?EOT ->
            ?EOT;
        {L, Cont} ->
            FunCont = fun() ->
                do_list_refs({continuation, Tabs, RealmUri, N, Cont})
            end,
            {L, FunCont}
    end.


%% @private
get_context(#session{is_anonymous = true, realm_uri = Uri}) ->
    bondy_rbac:get_context(Uri, anonymous);

get_context(#session{authid = Authid, realm_uri = Uri}) ->
    bondy_rbac:get_context(Uri, Authid).


-ifdef(TEST).

table(Id) ->
    tuplespace:locate_table(?SESSION_SPACE, Id).

-else.
-endif.
