%% =============================================================================
%%  bondy_session.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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
-include("bondy_security.hrl").

-define(SESSION_SPACE, ?MODULE).

-record(session, {
    id                              ::  bondy_session_id:t(),
    %% WAMP ID
    external_id                     ::  id(),
    type = client                   ::  bondy_ref:type(),
    realm_uri                       ::  uri(),
    authrealm                       ::  uri(),
    authid                          ::  optional(binary()),
    authrole                        ::  optional(binary()),
    authroles = []                  ::  [binary()],
    authmethod                      ::  optional(binary()),
    authmethod_details              ::  optional(authmethod_details()),
    ref                             ::  bondy_ref:t(),
    %% The {IP, Port} of the client
    peer                            ::  optional(peer()),
    %% User-Agent HTTP header or WAMP equivalent
    agent                           ::  binary(),
    %% Peer WAMP Roles played by peer
    roles                           ::  optional(map()),
    %% WAMP Auth
    security_enabled = true         ::  boolean(),
    is_anonymous = false            ::  boolean(),
    rbac_context                    ::  optional(bondy_rbac:context()),
    is_persistent = false           ::  boolean(),
    %% Expiration and Limits
    created                         ::  pos_integer(),
    expires_at                      ::  pos_integer() | infinity,
    meta = #{}                      ::  map()
}).

-type peer()                    ::  {inet:ip_address(), inet:port_number()}.
-type peer_role()               ::  caller | callee | subscriber | publisher.
-type t()                       ::  #session{}.
-type t_or_id()                 ::  t() | bondy_session_id:t().
-type authmethod_details()      ::  #{
                                        id => bondy_ticket:ticket_id(),
                                        scope => bondy_ticket:scope()
                                    }.
-type external()                ::  #{
                                        session => id(),
                                        authid => id(),
                                        authrole => binary(),
                                        authmethod => binary(),
                                        authprovider => binary(),
                                        authextra => #{
                                            x_authroles => [binary()]
                                        },
                                        transport => #{
                                            agent => binary(),
                                            peername => binary()
                                        }
                                    }.

-type properties()              ::  #{
                                        id := bondy_session_id:t(),
                                        roles := map(),
                                        security_enabled := boolean(),
                                        agent => binary(),
                                        authid => binary(),
                                        authmethod => binary(),
                                        authrealm => uri(),
                                        authrole => binary(),
                                        authroles => [binary()],
                                        is_anonymous => boolean(),
                                        peer => {
                                            inet:ip_address(),
                                            inet:port_number()
                                        },
                                        roles => peer(),
                                        type => bondy_ref:ref_type()
                                    }.
-type match_opts()              ::  #{
                                        limit => pos_integer(),
                                        exclude => bondy_session_id:t(),
                                        return => object | ref | external
                                    }.
-type match_opts_aux()              ::  #{
                                        limit => pos_integer(),
                                        exclude => bondy_session_id:t(),
                                        return => object | ref | external,
                                        match_spec := ets:match_spec()
                                    }.
-type match_ret()               ::  {[match_proj()] , continuation() | eot()}
                                    | eot()
                                    | [match_proj()].
-type continuation()            ::  #{
                                        continuation := ets:continuation(),
                                        tabs := [ets:tab()],
                                        opts := match_opts_aux()
                                    }.
-type match_proj()              ::  t() | {uri(), bondy_ref:t()} | external().
-type eot()                     ::  ?EOT.

-export_type([t/0]).
-export_type([peer_role/0]).
-export_type([properties/0]).
-export_type([external/0]).



%% BONDY_SENSITIVE CALLBACKS
-export([format_status/2]).

%% API
-export([agent/1]).
-export([authid/1]).
-export([authrealm/1]).
-export([authmethod/1]).
-export([authmethod_details/1]).
-export([authrole/1]).
-export([authroles/1]).
-export([close/2]).
-export([created/1]).
-export([external_id/1]).
-export([features/2]).
-export([features/3]).
-export([fetch/1]).
-export([id/1]).
-export([is_anonymous/1]).
-export([is_persistent/1]).
-export([is_security_enabled/1]).
-export([list/0]).
-export([list/1]).
-export([match/1]).
-export([match/2]).
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
    new(bondy_session_id:new(), bondy_realm:fetch(RealmUri), Opts);

new(Realm, Opts) when is_map(Opts) ->
    new(bondy_session_id:new(), Realm, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(bondy_session_id:t(), uri() | bondy_realm:t(), properties()) ->
    t() | no_return().

new(Id, RealmUri, Opts) when is_binary(RealmUri) ->
    new(Id, bondy_realm:fetch(RealmUri), Opts);

new(Id, Realm, Opts) when is_binary(Id) andalso is_map(Opts) ->
    RealmUri = bondy_realm:uri(Realm),
    IsSecurityEnabled = bondy_realm:is_security_enabled(RealmUri),

    S1 = parse_properties(Opts, #session{}),

    Ref = bondy_ref:new(S1#session.type, self(), Id),

    S1#session{
        %% We choose seconds as we are not interested in the accuracy of time
        %% but rather in the uniquenes and URL friendliness of the ID
        id = Id,
        external_id = bondy_session_id:to_external(Id),
        realm_uri = RealmUri,
        ref = Ref,
        security_enabled = IsSecurityEnabled,
        created = erlang:system_time(second)
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
-spec store(t()) -> {ok, t()} | no_return().

store(#session{} = S0) ->
    Id = S0#session.id,
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),

    try
        %% We obtain a WAMP session id by trying to store the index, which
        %% will retry in case we have a collision and finally fail
        ExtId = bondy_session_id:to_external(Id),

        NewId = store_index(ExtId, Id),

        S = S0#session{
            id = NewId,
            external_id = bondy_session_id:to_external(NewId)
        },

        %% Finally we store the updated session
        true == ets:insert_new(Tab, S)
            orelse error({integrity_constraint_violation, Id}),

        ok = bondy_event_manager:notify({session_opened, S}),

        {ok, S}

    catch
        throw:session_id_collision ->
            error(session_id_collision)
    end.


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
-spec close(t(), Reason :: optional(uri())) -> ok.

close(#session{} = S, Reason)
when is_binary(Reason) orelse Reason == undefined ->
    Id = S#session.id,
    ExtId = S#session.external_id,
    RealmUri = S#session.realm_uri,

    %% Cleanup session
    Tab1 = tuplespace:locate_table(?SESSION_SPACE, Id),
    true = ets:delete(Tab1, Id),

    %% Cleanup index
    Tab2 = tuplespace:locate_table(?SESSION_SPACE, ExtId),
    true = ets:delete(Tab2, ExtId),

    %% Cleanup counters
    ok = bondy_message_id:purge_session(RealmUri, Id),

    %% Revoke Tickets and Tokens
    ok = maybe_revoke_tickets(S, Reason),

    %% Notify internally
    Secs = erlang:system_time(second) - S#session.created,
    ok = bondy_event_manager:notify({session_closed, S, Secs}),

    ?LOG_DEBUG(#{
        description => "Session closed",
        realm => RealmUri,
        session_id => Id,
        protocol_session_id => ExtId,
        reason => Reason
    }),

    ok.


%% -----------------------------------------------------------------------------
%% @doc Returns the value used on session storage. The keys is a Id-sortable
%% unique ID (globally unique, collision free without coordination) across a
%% Bondy cluster. This differs from the session's `id' property which is a
%% random integer as defined by the WAMP protocol.
%%
%% Whereas the chances of collision using the WAMP `id' are minimal, there is
%% still is a possibility that a collision can occur in a big cluster with
%% millions of connections.
%% @end
%% -----------------------------------------------------------------------------
-spec id(t()) -> bondy_session_id:t().

id(#session{id = Id}) ->
    Id.


%% -----------------------------------------------------------------------------
%% @doc Returns the WAMP session identifier.
%% This is the id exposed to WAMP clients via the protocol interactions.
%% @end
%% -----------------------------------------------------------------------------
-spec external_id(t_or_id()) -> id().

external_id(#session{external_id = Id}) ->
    Id;

external_id(Id) when is_binary(Id) ->
    lookup_field(Id, #session.external_id).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(t_or_id()) -> uri().

realm_uri(#session{realm_uri = Val}) ->
    Val;

realm_uri(Id) when is_binary(Id) ->
    lookup_field(Id, #session.realm_uri).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec roles(t_or_id()) -> map().

roles(#session{roles = Val}) ->
    Val;

roles(Id) when is_binary(Id) ->
    lookup_field(Id, #session.roles).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec features(Session :: t_or_id(), Role :: peer_role()) -> map().

features(Session, Role)
when Role == caller; Role == callee; Role == subscriber; Role == published ->
    Roles = lookup_field(Session, #session.roles),
    case maps:find(Role, Roles) of
        {ok, Value} ->
            Value;
        error ->
            #{}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec features(t_or_id(), Role :: peer_role(), With :: [atom()]) ->
    map().

features(Session, Role, With) when is_list(With) ->
    maps:with(With, features(Session, Role)).


%% -----------------------------------------------------------------------------
%% @doc Returns the identifier for the owner of this session
%% @end
%% -----------------------------------------------------------------------------
-spec ref(Session :: t_or_id()) -> bondy_ref:client() | bondy_ref:relay().

ref(Session) ->
    lookup_field(Session, #session.ref).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the pid of the process managing the transport that the session
%% identified by Id runs on.
%% @end
%% -----------------------------------------------------------------------------
-spec pid(Session :: t_or_id()) -> optional(pid()).

pid(Session) ->
    bondy_ref:pid(ref(Session)).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the node of the process managing the transport that the session
%% identified by Id runs on.
%% @end
%% -----------------------------------------------------------------------------
-spec node(Session :: t_or_id()) -> atom().

node(Session) ->
    bondy_ref:node(ref(Session)).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the node of the process managing the transport that the session
%% identified by Id runs on.
%% @end
%% -----------------------------------------------------------------------------
-spec nodestring(t_or_id()) -> nodestring().

nodestring(Session) ->
    bondy_ref:nodestring(ref(Session)).


%% -----------------------------------------------------------------------------
%% @doc Returns the time at which the session was created, Its value is a
%% timestamp in seconds.
%% @end
%% -----------------------------------------------------------------------------
-spec created(Session :: t()) -> pos_integer().

created(Session) ->
    lookup_field(Session, #session.created).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec agent(t_or_id()) -> binary() | undefined.

agent(Session) ->
    lookup_field(Session, #session.agent).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peer(t_or_id()) -> peer().

peer(Session) ->
    lookup_field(Session, #session.peer).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authrealm(t_or_id()) -> uri().

authrealm(Session) ->
    lookup_field(Session, #session.authrealm).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authid(t_or_id()) -> bondy_rbac_user:username().

authid(Session) ->
    lookup_field(Session, #session.authid).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authrole(t()) -> binary().

authrole(#session{authrole = undefined, authroles = []}) ->
    <<"undefined">>;

authrole(#session{authrole = undefined, authroles = [Role]}) ->
    Role;

authrole(#session{authrole = undefined, authroles = Roles}) ->
    %% WAMP2 does not currently support multiple roles, so we return a comma
    %% separated values of all user roles (groups)
    binary_utils:join(Roles, <<$,>>);

authrole(#session{authrole = Val}) ->
    Val;

authrole(Id) when is_binary(Id) ->
    authrole(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authroles(t_or_id()) -> [bondy_rbac_group:name()].

authroles(Session) ->
    lookup_field(Session, #session.authroles).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authmethod(t_or_id()) -> binary().

authmethod(Session) ->
    lookup_field(Session, #session.authmethod).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authmethod_details(t_or_id()) -> optional(binary()).

authmethod_details(Session) ->
    lookup_field(Session, #session.authmethod_details).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec user(t()) -> bondy_rbac_user:t().

user(#session{realm_uri = Uri, authid = Id}) ->
    bondy_rbac_user:fetch(Uri, Id);

user(Id) when is_binary(Id) ->
    user(fetch(Id)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec rbac_context(t_or_id()) -> bondy_rbac:context().

rbac_context(#session{id = Id} = Session) ->
    %% We force the lookup to go to ets by passing Id as we want the latest
    %% updated value
    try lookup_field(Id, #session.rbac_context) of
        undefined ->
            NewCtxt = get_rbac_context(Session),
            ok = update_rbac_context(Id, NewCtxt),
            NewCtxt;
        Ctxt ->
            refresh_rbac_context(Id, Ctxt)
    catch
        error:badarg ->
            %% Session not in ets, the case for an HTTP session
            get_rbac_context(Session)
    end;

rbac_context(Id) when is_binary(Id) ->
    case lookup_field(Id, #session.rbac_context) of
        undefined ->
            rbac_context(fetch(Id));
        Ctxt ->
            refresh_rbac_context(Id, Ctxt)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec refresh_rbac_context(t_or_id()) -> bondy_rbac:context().

refresh_rbac_context(#session{id = Id} = Session) ->
    update_rbac_context(Id, get_rbac_context(Session));

refresh_rbac_context(Id) when is_binary(Id) ->
    refresh_rbac_context(fetch(Id)).



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
    lookup_field(Id, #session.security_enabled).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_persistent(t()) -> boolean().

is_persistent(#session{is_persistent = Val}) ->
    Val;

is_persistent(Id) ->
    lookup_field(Id, #session.is_persistent).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_anonymous(t()) -> boolean().

is_anonymous(#session{is_anonymous = Val}) ->
    Val;

is_anonymous(Id) ->
    lookup_field(Id, #session.is_anonymous).


%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the session identified by Id from the tuplespace or 'not_found'
%% if it doesn't exist.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(bondy_session_id:t()) -> {ok, t()} | {error, not_found}.

lookup(Id) when is_binary(Id) ->
    do_lookup(Id).


%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the session identified by Id from the tuplespace or 'not_found'
%% if it doesn't exist.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(RealmUri :: uri(), ExtId :: id()) ->
    {ok, t()} | {error, not_found}.

lookup(RealmUri, ExtId) ->
    case do_lookup(ExtId) of
        {ok, #session{realm_uri = Val} = Session} when Val == RealmUri ->
            {ok, Session};
        _ ->
            {error, not_found}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the session identified by Id from the tuplespace. If the session
%% does not exist it fails with reason '{badarg, Id}'.
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(bondy_session_id:t()) -> t() | no_return().

fetch(Id) ->
    case lookup(Id) of
        {ok, Session} ->
            Session;
        {error, not_found} ->
            error({badarg, Id})
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
list() ->
    list(#{return => object}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
list(?EOT) ->
    ?EOT;

list(#{continuation := _} = Cont) ->
    match(Cont);

list(Opts) when is_map(Opts) ->
    match(#{}, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
match(?EOT) ->
    ?EOT;

match(#{continuation := _} = Cont) ->
    do_match(Cont).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(Bindings :: #{atom() => '_' | term()}, Opts :: match_opts()) ->
    match_ret().

match(Bindings, Opts) ->
    Tabs = tuplespace:tables(?SESSION_SPACE),
    do_match(Tabs, Bindings, Opts).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(t()) -> external().

to_external(#session{} = S) ->
    Extra = case S#session.is_anonymous of
        true ->
            #{};
        false ->
            #{meta => bondy_rbac_user:meta(user(S))}
    end,

    #{
        session => S#session.external_id,
        authid => S#session.authid,
        authmethod => S#session.authmethod,
        authprovider => <<"com.leapsight.bondy">>,
        authrole => authrole(S),
        authextra => Extra#{
            session_guid => S#session.id,
            node => bondy_config:nodestring()
        },
        transport => #{
            peername => inet_utils:peername_to_binary(S#session.peer)
        }
    }.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc Called by -on_load() directive.
%% @end
%% -----------------------------------------------------------------------------
on_load() ->
    Size = record_info(size, session),
    Pattern = erlang:make_tuple(Size, '_', [{1, session}]),
    persistent_term:put({?MODULE, pattern}, Pattern),

    Fields = record_info(fields, session),
    Vars = [
        {X, list_to_atom("$" ++ integer_to_list(X - 1))}
        || X <- lists:seq(2, Size)
    ],
    Substitution = maps:from_list(lists:zip(Fields, Vars)),
    persistent_term:put({?MODULE, substitution}, Substitution),
    ok.


%% @private
lookup_field(#session{} = S, FieldIndex) when is_integer(FieldIndex) ->
    element(FieldIndex, S);

lookup_field(Id, FieldIndex) when is_binary(Id), is_integer(FieldIndex) ->
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),
    ets:lookup_element(Tab, Id, FieldIndex).


%% @private
store_index(ExtId, Id) ->
    store_index(ExtId, Id, 20).


%% @private
store_index(ExtId, Id, N) when N > 0 ->
    Tab = tuplespace:locate_table(?SESSION_SPACE, ExtId),

    case ets:insert_new(Tab, {index, ExtId, Id}) of
        true ->
            Id;
        false ->
            NewId = bondy_session_id:new(),
            NewExtId = bondy_session_id:to_external(NewId),
            store_index(NewExtId, NewId, N - 1)
    end;

store_index(_, _, 0) ->
    throw(session_id_collision).


%% @private
parse_properties(Opts, Session0)  when is_map(Opts) ->
    maps:fold(fun parse_properties/3, Session0, Opts).


%% @private
parse_properties(id, V, Session) ->
    case bondy_session_id:is_type(V) of
        true ->
            Session#session{id = V};
        false ->
            error({invalid_options, id})
    end;

parse_properties(roles, undefined, _) ->
    error({invalid_options, missing_client_role});

parse_properties(roles, Roles, Session) when is_map(Roles) ->
    length(maps:keys(Roles)) > 0 orelse
    error({invalid_options, missing_client_role}),
    Session#session{roles = parse_roles(Roles)};

parse_properties(agent, V, Session) when is_binary(V) ->
    Session#session{agent = V};

parse_properties(security_enabled, V, Session) when is_boolean(V) ->
    Session#session{security_enabled = V};

parse_properties(is_anonymous, V, Session) when is_boolean(V) ->
    Session#session{is_anonymous = V};

parse_properties(authrealm, V, Session) when is_binary(V) ->
    Session#session{authrealm = V};

parse_properties(authid, V, Session) when is_binary(V) ->
    Session#session{authid = V};

parse_properties(authrole, V, Session) when is_binary(V) ->
    Session#session{authrole = V};

parse_properties(authroles, V, Session) when is_list(V) ->
    Session#session{authroles = V};

parse_properties(authmethod, V, Session) when is_binary(V) ->
    Session#session{authmethod = V};

parse_properties(peer, V, Session) ->
    case bondy_data_validators:peer(V) of
        true ->
            Session#session{peer = V};
        false ->
            error({invalid_options, peer})
    end;

parse_properties(type, V, Session) ->
    lists:member(V, bondy_ref:types())
        orelse error({invalid_options, type}),

    Session#session{type = V};

parse_properties(_, _, Session) ->
    Session.


%% ------------------------------------------------------------------------
%% private
%% @doc Merges the client provided role features with the ones provided by
%% the router. This will become the feature set used by the router on
%% every session request.
%% This is a capability negotiation between client and router.
%% @end
%% ------------------------------------------------------------------------
parse_roles(Roles) ->
    maps:map(
        fun
            (Key, #{features := Requested}) ->
                Merged = merge_feature_flags(Key, Requested),
                #{features => Merged};
            (Key, #{}) ->
                Merged = merge_feature_flags(Key, #{}),
                #{features => Merged}
        end,
        Roles
    ).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
merge_feature_flags(Router, Req) when is_map(Router) andalso is_map(Req) ->
    Combiner = fun
        (_, true, true) -> true;
        (_, _, _) -> false
    end,
    maps:merge_with(Combiner, Req, Router);

merge_feature_flags(caller, Req) when is_map(Req) ->
    merge_feature_flags(?CALLER_FEATURES, Req);

merge_feature_flags(callee, Req) when is_map(Req) ->
    merge_feature_flags(?CALLEE_FEATURES, Req);

merge_feature_flags(publisher, Req) when is_map(Req) ->
    merge_feature_flags(?PUBLISHER_FEATURES, Req);

merge_feature_flags(subscriber, Req) when is_map(Req) ->
    merge_feature_flags(?SUBSCRIBER_FEATURES, Req);

merge_feature_flags(_, Req) ->
    Req.



%% @private
-spec do_lookup(id()) -> {ok, t()} | {error, not_found}.

do_lookup(Id) when is_binary(Id) ->
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),

    case ets:lookup(Tab, Id)  of
        [#session{} = Session] ->
            {ok, Session};
        [] ->
            {error, not_found}
    end;

do_lookup(ExtId) when is_integer(ExtId) ->
    %% We search by WAMP session id using an index
    Tab = tuplespace:locate_table(?SESSION_SPACE, ExtId),

    case ets:lookup(Tab, ExtId)  of
        [{index, ExtId, Id}] ->
            do_lookup(Id);
        [] ->
            {error, not_found}
    end.


%% @private
refresh_rbac_context(Id, Ctxt) ->
    case bondy_rbac:refresh_context(Ctxt) of
        {true, NewCtxt} ->
            ok = update_rbac_context(Id, NewCtxt),
            NewCtxt;
        {false, Ctxt} ->
            Ctxt
    end.


%% @private
update_rbac_context(Id, Context) ->
    Tab = tuplespace:locate_table(?SESSION_SPACE, Id),
    _ = ets:update_element(Tab, Id, {#session.rbac_context, Context}),
    ok.


%% @private
do_match(Tabs, Bindings, Opts0) ->
    Opts = Opts0#{match_spec => match_spec(Bindings, Opts0)},
    do_match(Tabs, Opts).


%% @private
do_match([], #{limit := N}) when is_integer(N), N > 0 ->
    ?EOT;

do_match([], _) ->
    [];

do_match([H | T], #{match_spec := MS, limit := N} = Opts)
when is_integer(N), N > 0 ->

    case ets:select(H, MS, N) of
        {L, ETSCont} ->
            Cont = #{
                continuation => ETSCont,
                tabs => T,
                opts => Opts
            },
           {match_format_ret(L, Opts), Cont};

        ?EOT ->
            do_match(T, Opts)
    end;

do_match(Tabs, #{match_spec := MS} = Opts) ->
    L = lists:foldl(
        fun(Tab, Acc) ->
            L0 = match_format_ret(ets:select(Tab, MS), Opts),
            [L0 | Acc]
        end,
        [],
        Tabs
    ),
    match_format_ret(lists:append(L), Opts).


%% @private
do_match(#{continuation := ?EOT, tabs := []}) ->
    ?EOT;

do_match(#{continuation := ?EOT, tabs := Tabs, opts := Opts}) ->
    do_match(Tabs, Opts);

do_match(#{continuation := Cont0, tabs := Tabs, opts := Opts} = Cont) ->
    case ets:select(Cont0) of
        ?EOT ->
            do_match(Tabs, Opts);
        {L0, ETSCont} ->
            L = match_format_ret(L0, Opts),
            {L, Cont#{continuation => ETSCont}}
    end.


%% @private
match_spec(Bindings, Opts) when is_map(Bindings) ->
    Substitution = persistent_term:get({?MODULE, substitution}),
    Pattern = persistent_term:get({?MODULE, pattern}),
    match_spec(Bindings, Opts, Pattern, Substitution).


%% @private
match_spec(Bindings, Opts, Pattern0, Substitution) when is_map(Bindings) ->
    Conditions0 = [],
    Acc = {Pattern0, Conditions0},

    {Pattern1, Conditions1} =
        maps:fold(
            fun
                (_, '_', {P, C}) ->
                    {P, C};

                (Key, Value, {P0, C0}) ->
                    {Index, Var} = maps:get(Key, Substitution),
                    P = setelement(Index, P0, Var),
                    C = [{'==', Var, ms_wrap(Value)} | C0],
                    {P, C}
            end,
            Acc,
            Bindings
        ),

    {Pattern2, Conditions2} =
        case maps:get(exclude, Opts, undefined) of
            undefined ->
                {Pattern1, Conditions1};

            SessionId when is_binary(SessionId) ->
                {Index0, Var0} = maps:get(id, Substitution),
                {
                    setelement(Index0, Pattern1, Var0),
                    [{'=/=', Var0, SessionId} | Conditions1]
                };

            SessionId when is_integer(SessionId) ->
                {Index0, Var0} = maps:get(external_id, Substitution),
                {
                    setelement(Index0, Pattern1, Var0),
                    [{'=/=', Var0, SessionId} | Conditions1]
                }
        end,

    Conditions = maybe_and(Conditions2),

    case maps:get(return, Opts, object) of
        ref ->
            {Index1, Var1} = maps:get(realm_uri, Substitution),
            Pattern3 = setelement(Index1, Pattern2, Var1),

            {Index2, Var2} = maps:get(ref, Substitution),
            Pattern = setelement(Index2, Pattern3, Var2),

            [{Pattern, Conditions, [{{Var1, Var2}}]}];

        object ->
            [{Pattern2, Conditions, ['$_']}];

        external ->
            [{Pattern2, Conditions, ['$_']}]

    end.


%% @private
ms_wrap(Term) when is_tuple(Term) ->
    {Term};

ms_wrap(Term) ->
    Term.


%% @private
match_format_ret([], _) ->
    [];

match_format_ret(L, #{return := external}) ->
    [to_external(S) || S <- L];

match_format_ret(L, _) ->
    %% Already formatted by match_spec
    L.


%% @private
maybe_and([]) ->
    [];

maybe_and([Clause]) ->
    [Clause];

maybe_and(Clauses) ->
    [list_to_tuple(['and' | Clauses])].


%% @private
get_rbac_context(#session{is_anonymous = true, realm_uri = Uri}) ->
    bondy_rbac:get_context(Uri, anonymous);

get_rbac_context(#session{authid = Authid, realm_uri = Uri}) ->
    bondy_rbac:get_context(Uri, Authid).


%% @private
maybe_revoke_tickets(Session, ?WAMP_CLOSE_LOGOUT) ->
    case authmethod(Session) of
        ?WAMP_TICKET_AUTH ->
            Authid = authid(Session),
            #{
                authrealm := Authrealm,
                scope := Scope
            } = authmethod_details(Session),
            bondy_ticket:revoke(Authrealm, Authid, Scope);

        ?WAMP_OAUTH2_AUTH ->
            %% TODO remove token for sessionID
            ok
    end;

maybe_revoke_tickets(_, _) ->
    %% No need to revoke tokens.
    %% In case of ?BONDY_USER_DELETED, the delete action would have already
    %% revoked all tokens for this user.
    ok.




%% =============================================================================
%% TEST
%% =============================================================================




-ifdef(TEST).

table(Term) ->
    tuplespace:locate_table(?SESSION_SPACE, Term).

-else.
-endif.
