%% =============================================================================
%%  bondy_ticket.erl -
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

%% -----------------------------------------------------------------------------
%% @doc This module implements the functions to issue and manage authentication
%% tickets.
%%
%% An authentication ticket (**ticket**) is a signed (and possibly encrypted)
%% assertion of a user's identity, that a client can use to authenticate the
%% user without the need to ask it to re-enter its credentials.
%%
%% Tickets MUST be issued by a session that was opened using an authentication
%% method that is neither `ticket' nor `anonymous' authentication.
%%
%% ### Claims
%%
%% * id: provides a unique identifier for the ticket.
%% * issued_by: identifies the principal that issued the ticket. Most
%% of the time this is an application identifier (a.k.asl username or client_id)
%% but sometimes can be the WAMP session's username (a.k.a `authid').
%% * authid: identifies the principal that is the subject of the ticket.
%% The Claims in a ticket are normally statements. This is the WAMP session's
%% username (a.k.a `authid').
%% * authrealm: identifies the recipients that the ticket is intended for.
%% The value is `RealmUri'.
%% * expires_at: identifies the expiration time on or after which
%% the ticket MUST NOT be accepted for processing.  The processing of the "exp"
%% claim requires that the current date/time MUST be before the expiration date/
%% time listed in the "exp" claim. Bondy considers a small leeway of 2 mins by
%% default.
%% * issued_at: identifies the time at which the ticket was issued.
%% This claim can be used to determine the age of the ticket. Its value is a
%% timestamp in seconds.
%% * issued_on: the bondy nodename in which the ticket was issued.
%% * scope: the scope of the ticket, consisting of
%%     * realm: If `undefined' the ticket grants access to all realms the user
%% has access to by the authrealm (an SSO realm). Otherwise, the value is the
%% realm this ticket is valid on.
%%
%% ## Claims Storage
%%
%% Claims for a ticket are stored in PlumDB using the prefix
%% `{bondy_ticket, Suffix :: binary()}' where Suffix is the concatenation of
%% the authentication realm's URI and the user's username (a.k.a `authid') and
%% a key which is derived by the ticket's scope. The scope itself is the result
%% of the combination of the different options provided by the {@link issue/2}
%% function.
%%
%% Thes decision to use this key as opposed to the ticket's unique identifier
%% is to bounds the number of tickets a user can have at any point in time in
%% order to reduce data storage and traffic.
%%
%% ### Ticket Scopes
%% A ticket can be issued using different scopes. The scope is determined based
%% on the options used to issue the ticket.
%%
%% #### Local scope
%% The ticket was issued with `allow_sso' option set to `false' or when set to
%% `true' the user did not have SSO credentials, and the option `client_ticket'
%% was not provided.
%% The ticket can be used to authenticate on the session's realm only.
%%
%% **Authorization**
%% To be able to issue this ticket, the session must have been granted the
%% permission `<<"bondy.issue">>' on the `<<"bondy.ticket.scope.local">>'
%% resource.
%%
%%
%% #### SSO Scope
%% The ticket was issued with `allow_sso' option set to `true' and the user has
%% SSO credentials, and the option `client_ticket' was not provided.
%% The ticket can be used to authenticate  on any realm the user has access to
%% through SSO.
%%
%% **Authorization**
%% To be able to issue this ticket, the session must have been granted the
%% permission `<<"bondy.issue">>' on the `<<"bondy.ticket.scope.sso">>'
%% resource.
%%
%% #### Client-Local scope
%% The ticket was issued with `allow_sso' option set to `false' or when set to
%% `true' the user did not have SSO credentials, and the option `client_ticket'
%% was provided having a valid ticket issued by a client
%% (a local or sso ticket).
%% The ticket can be used to authenticate on the session's realm only.
%%
%% **Authorization**
%% To be able to issue this ticket, the session must have been granted the
%% permission `<<"bondy.issue">>' on the `<<"bondy.ticket.scope.client_local">>'
%% resource.
%%
%%
%% #### Client-SSO scope
%% The ticket was issued with `allow_sso' option set to `true' and the user has
%% SSO credentials, and the option `client_ticket' was provided having a valid
%% ticket issued by a client ( a local or sso ticket).
%% The ticket can be used to authenticate on any realm the user has access to
%% through SSO.
%%
%% **Authorization**
%% To be able to issue this ticket, the session must have been granted the
%% permission `<<"bondy.issue">>' on the `<<"bondy.ticket.scope.client_local">>'
%% resource.
%%
%% ### Scope Summary
%% * `uri()' in the following table refers to the scope realm (not the
%% Authentication realm which is used in the prefix)
%%
%% |SCOPE|Allow SSO|Client Ticket|Client Instance ID|Key|Value|
%% |---|---|---|---|---|---|
%% |Local|no|no|no|`uri()'|`claims()'|
%% |SSO|yes|no|no|`username()'|`claims()'|
%% |Client-Local|no|yes|no|`client_id()'|`[{uri(), claims()}]'|
%% |Client-Local|no|yes|yes|`client_id()'|`[{{uri(), instance_id()}, claims()}]'|
%% |Client-SSO|yes|yes|no|`client_id()'|`[{undefined, claims()}]'|
%% |Client-SSO|yes|yes|yes|`client_id()'|`[{{undefined, instance_id()}, claims()}]'|
%%
%% ### Permissions Summary
%% Issuing tickets requires the user to be granted certain permissions beyond the WAMP permission required to call the procedures.
%% |Scope|Permission|Resource|
%% |---|---|---|
%% |Local|`bondy.issue'|`bondy.ticket.scope.local'|
%% |SSO|`bondy.issue'|`bondy.ticket.scope.sso'|
%% |Client-Local|`bondy.issue'|`bondy.ticket.scope.client_local'|
%% |Client-SSO|`bondy.issue'|`bondy.ticket.scope.client_sso'|
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_ticket).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").

-define(NOW, erlang:system_time(second)).
-define(LEEWAY_SECS, 120). % 2 mins

-define(PDB_PREFIX(L),
    {bondy_ticket, binary_utils:join(L, <<",">>)}
).

-define(OPTS_VALIDATOR, #{
    <<"expiry_time_secs">> => #{
        alias => expiry_time_secs,
        key => expiry_time_secs,
        required => false,
        datatype => pos_integer
    },
    <<"allow_sso">> => #{
        alias => allow_sso,
        key => allow_sso,
        required => true,
        datatype => boolean,
        default => true
    },
    <<"client_ticket">> => #{
        alias => client_ticket,
        key => client_ticket,
        required => false,
        datatype => binary
    },
    <<"client_id">> => #{
        alias => client_id,
        key => client_id,
        required => false,
        datatype => binary
    },
    <<"client_instance_id">> => #{
        alias => client_instance_id,
        key => client_instance_id,
        required => false,
        datatype => binary
    }
}).

-type t()           ::  binary().
-type opts()        ::  #{
                            expiry_time_secs    =>  pos_integer(),
                            allow_sso           =>  boolean(),
                            client_ticket       =>  t(),
                            client_id           =>  binary(),
                            client_instance_id  =>  binary()
                        }.
-type verify_opts() ::  #{
                            allow_not_found     =>  boolean()
                        }.
-type scope()       ::  #{
                            realm               :=  maybe(uri()),
                            client_id           :=  maybe(authid()),
                            client_instance_id  :=  maybe(binary())
                        }.
-type claims()      ::  #{
                            id                  :=  ticket_id(),
                            authrealm           :=  uri(),
                            authid              :=  authid(),
                            authmethod          :=  binary(),
                            issued_by           :=  authid(),
                            issued_on           :=  node(),
                            issued_at           :=  pos_integer(),
                            expires_at          :=  pos_integer(),
                            scope               :=  scope(),
                            kid                 :=  binary()
                        }.
-type ticket_id()   ::  binary().
-type authid()      ::  bondy_rbac_user:username().
-type issue_error() ::  {no_such_user, authid()}
                        | no_such_realm
                        | invalid_request
                        | invalid_ticket
                        | not_authorized.
-export_type([t/0]).
-export_type([claims/0]).
-export_type([scope/0]).
-export_type([opts/0]).


-export([verify/1]).
-export([issue/2]).
-export([lookup/3]).
-export([revoke/1]).
-export([revoke_all/2]).
-export([revoke_all/3]).




%% -----------------------------------------------------------------------------
%% @doc Issues a ticket to be used with the WAMP Ticket authentication
%% method. The function stores the ticket claims data and replicates it across
%% all nodes in the cluster.
%%
%% The session `Session' must have been opened using an authentication
%% method that is neither `ticket' nor `anonymous' authentication.
%%
%% The function takes an options map `opts()' that can contain the following
%% keys:
%% * `expiry_time_secs': the expiration time on or after which the ticket MUST
%% NOT be accepted for processing. This is a request that might not be honoured
%% by the router as it depends on the router configuration, so the returned
%% value might defer.
%% To issue a client-scoped ticket, either the option `client_ticket' or
%% `client_id' must be present. The `client_ticket' option takes a valid ticket
%% issued by a different user (normally a
%% client). Otherwise the call will return the error tuple with reason
%% `invalid_request'.
%% @end
%% -----------------------------------------------------------------------------
-spec issue(Session :: bondy_session:t(), Opts :: opts()) ->
    {ok, Ticket :: t(), Claims :: claims()}
    | {error, issue_error()}
    | no_return().

issue(Session, Opts0) ->
    Opts = maps_utils:validate(Opts0, ?OPTS_VALIDATOR),
    try
        Authmethod = bondy_session:authmethod(Session),
        Allowed = bondy_config:get([security, ticket, authmethods]),

        lists:member(Authmethod, Allowed) orelse throw({
            not_authorized,
            <<"The authentication method '", Authmethod/binary, "' you used to establish this session is not in the list of methods allowed to issue tickets (configuration option 'security.ticket.authmethods').">>
        }),

        do_issue(Session, Opts)
    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec verify(Ticket :: binary()) -> {ok, claims()} | {error, expired | invalid}.

verify(Ticket) ->
    verify(Ticket, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec verify(Ticket :: binary(), Opts :: verify_opts()) ->
    {ok, claims()} | {error, expired | invalid}.

verify(Ticket, Opts) ->
    try
        {jose_jwt, Claims0} = jose_jwt:peek(Ticket),
        Claims = bondy_utils:to_existing_atom_keys(Claims0),

        #{
            authrealm := AuthRealmUri,
            authid := Authid,
            issued_at := IssuedAt,
            expires_at := ExpiresAt,
            % issued_on := Node,
            scope := Scope,
            kid := Kid
        } = Claims,

        is_expired(Claims) andalso throw(expired),
        ExpiresAt > IssuedAt orelse throw(invalid),

        Realm = bondy_realm:fetch(AuthRealmUri),

        Key = bondy_realm:get_public_key(Realm, Kid),
        Key =/= undefined orelse throw(invalid),

        {Verified, _, _} = jose_jwt:verify(Key, Ticket),
        Verified == true orelse throw(invalid),

        case is_persistent(scope_type(Scope)) of
            true ->
                AllowNotFound = allow_not_found(Opts),

                case lookup(AuthRealmUri, Authid, Scope) of
                    {ok, Claims} = OK ->
                        OK;
                    {ok, _Other} ->
                        throw(no_match);
                    {error, not_found} when AllowNotFound == true ->
                        %% We trust the signed JWT
                        {ok, Claims};
                    {error, not_found} ->
                        %% TODO Try to retrieve from Claims.node
                        %% or use Scope to lookup indices
                        throw(invalid)
                end;
            false ->
                {ok, Claims}
        end

    catch
        error:{badkey, _} ->
            {error, invalid};

        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(
    RealmUri :: uri(),
    Authid :: bondy_rbac_user:username(),
    Scope :: scope()) -> {ok, Claims :: claims()} | {error, no_found}.

lookup(RealmUri, Authid, Scope) ->
    Key = store_key(Authid, normalise_scope(Scope)),
    Prefix = ?PDB_PREFIX([RealmUri, Authid]),
    Opts = [{resolver, fun ticket_resolver/2}, {allow_put, true}],

    case plum_db:get(Prefix, Key, Opts) of
        undefined ->
            {error, not_found};
        Claims when is_map(Claims) ->
            {ok, Claims};
        List when is_list(List) ->
            %% List :: [claims()]
            LKey = list_key(Scope),
            case lists:keyfind(LKey, 1, List) of
                {LKey, Claims} ->
                    {ok, Claims};
                false ->
                    {error, not_found}
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke(maybe(t())) -> ok | {error, any()}.

revoke(undefined) ->
    ok;

revoke(Ticket) when is_binary(Ticket) ->
    case verify(Ticket) of
        {ok, Claims} ->
            revoke(Claims);
        {error, _} = Error ->
            Error
    end;

revoke(Claims) when is_map(Claims) ->
    #{
        % id := Id,
        % authrealm := AuthRealmUri,
        % authid := Authid,
        % scope := Scope
    } = Claims,

    %% TODO find ID and delete
    %% TODO delete entry in authid index and maybe in client index depending on scope
    error(not_implemented).



%% -----------------------------------------------------------------------------
%% @doc Revokes all tickets issued to user with `Username' in realm `RealmUri'.
%% Notice that the ticket could have been issued by itself or by a client
%% application.
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_all(RealmUri :: uri(), Authid :: bondy_rbac_user:username()) ->
    ok.

revoke_all(RealmUri, Authid) ->
    Prefix = ?PDB_PREFIX([RealmUri, Authid]),
    Fun = fun
        ({_, ?TOMBSTONE}) ->
            ok;
        ({Key, _}) ->
            plum_db:delete(Prefix, Key)
    end,
    plum_db:foreach(Fun, Prefix, [{resolver, lww}]).


%% -----------------------------------------------------------------------------
%% @doc Revokes all tickets issued to user with `Username' in realm `RealmUri'
%% matching the scope `Scope'.
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_all(
    RealmUri :: uri(),
    Username ::  all | bondy_rbac_user:username(),
    Scope :: scope()) -> ok.

revoke_all(_RealmUri, _Authid, _Scope) ->
    % Prefix = ?PDB_PREFIX([RealmUri, Authid]),
    % Key = store_key(Authid, Scope),
    % Realm = maps:get(realm, Scope, undefined),
    % InstanceId = maps:get(client_instance_id, Scope, undefined),

    % Fun = fun
    %     ({_, ?TOMBSTONE}) ->
    %         ok;
    %     ({K, Claims}) when K == Key andalso is_map(Claims)->
    %         plum_db:delete(Prefix, Key);
    %     ({K, L0}) when K == Key andalso is_list(L0) ->
    %         %% List :: [claims()]
    %         LKey = list_key(Scope),
    %         case lists:keyfind(LKey, 1, List) of
    %             {LKey, Claims} ->
    %                 {ok, Claims};
    %             error ->
    %                 {error, not_found}
    %         end
    %         plum_db:update(Prefix, Key, L1);
    %     (_) ->
    %         ok
    % end,
    % %% We use ticket resolver as we want to preserve the per client ticket list
    % plum_db:foreach(Fun, Prefix, [{resolver, ticket_resolver/2}]).
    error(not_implemented).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_issue(Session, Opts) ->
    RealmUri = bondy_session:realm_uri(Session),
    Authid = bondy_session:authid(Session),
    User = bondy_session:user(Session),
    SSORealmUri = bondy_rbac_user:sso_realm_uri(User),

    {AuthUri, ScopeUri} = case maps:get(allow_sso, Opts) of
        true when SSORealmUri =/= undefined ->
            %% The ticket can be used to authenticate on all user realms
            %% connected to this SSORealmUri
            {SSORealmUri, undefined};
        _ ->
            %% SSORealmUri is undefined or SSO was not allowed,
            %% the scope realm can only be the session realm
            {RealmUri, RealmUri}
    end,

    Scope = scope(Session, Opts, ScopeUri),
    ScopeType = scope_type(Scope),
    AuthCtxt = bondy_session:rbac_context(Session),

    ok = authorize(ScopeType, AuthCtxt),

    AuthRealm = bondy_realm:fetch(AuthUri),
    Kid = bondy_realm:get_random_kid(AuthRealm),

    IssuedAt = ?NOW,
    ExpiresAt = IssuedAt + expiry_time_secs(Opts),

    Claims = #{
        id => bondy_utils:uuid(),
        authrealm => AuthUri,
        authid => Authid,
        authmethod => bondy_session:authmethod(Session),
        issued_by => issuer(Authid, Scope),
        issued_on => atom_to_binary(bondy_peer_service:mynode(), utf8),
        issued_at => IssuedAt,
        expires_at => ExpiresAt,
        scope => Scope,
        kid => Kid
    },

    JWT = jose_jwt:from(Claims),

    %% We first sign (jose lib does not still support nested JWS in JWE, so we
    %% do it our way)
    PrivKey = bondy_realm:get_private_key(AuthRealm, Kid),
    {_, Ticket} = jose_jws:compact(jose_jwt:sign(PrivKey, JWT)),

    case is_persistent(ScopeType) of
        true ->
            ok = store_ticket(AuthUri, Authid, Claims);
        false ->
            ok
    end,

    {ok, Ticket, Claims}.


%% @private
normalise_scope(Scope) ->
    Default = #{
        realm => undefined,
        client_id => undefined,
        client_instance_id => undefined
    },
    maps:merge(Default, Scope).


%% @private
scope(Session, #{client_ticket := Ticket} = Opts, Uri)
when is_binary(Ticket) ->
    Authid = bondy_session:authid(Session),

    %% We are relaxed here as these are signed by us.
    VerifyOpts = #{allow_not_found => true},

    case verify(Ticket, VerifyOpts) of
        {ok, #{scope := #{client_id := Val}}} when Val =/= undefined ->
            %% Nested tickets are not allowed
            throw(invalid_request);

        {ok, #{issued_by := Authid}} ->
            %% A client is requesting a ticket issued to itself using its own
            %% client_ticket.
            throw(invalid_request);

        {ok, #{authid := ClientId, scope := Scope}} ->
            Id0 = maps:get(client_instance_id, Scope),
            Id = maps:get(client_instance_id, Opts, Id0),

            undefined =:= Id0 orelse Id =:= Id0 orelse throw(invalid_request),

            #{
                realm => Uri,
                client_id => ClientId,
                client_instance_id => Id
            };

        {error, _Reason} ->
            %% TODO implement new Error standard
            error(#{
                code => invalid_value,
                description => <<"The value for 'client_ticket' is not valid.">>,
                key => client_ticket,
                message => <<"The value for 'client_ticket' is not either not a ticket, it has an invalid signature or it is expired.">>
            })
    end;

scope(Session, Opts, Uri) ->
    Authid = bondy_session:authid(Session),
    ClientId = maps:get(client_id, Opts, undefined),
    InstanceId = maps:get(client_instance_id, Opts, undefined),

    %% Throw exception if client is requesting a ticket issued to itself
    Authid =/= ClientId orelse throw(invalid_request),

    #{
        realm => Uri,
        client_id => ClientId,
        client_instance_id => InstanceId
    }.


%% -----------------------------------------------------------------------------
%% %% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
authorize(ScopeType, AuthCtxt) ->

    case ScopeType of
        sso ->
            ok = bondy_rbac:authorize(
                <<"bondy.issue">>, <<"bondy.ticket.scope.sso">>, AuthCtxt
            );
        client_sso ->
            ok = bondy_rbac:authorize(
                <<"bondy.issue">>, <<"bondy.ticket.scope.client_sso">>, AuthCtxt
            );
        local ->
            ok = bondy_rbac:authorize(
                <<"bondy.issue">>, <<"bondy.ticket.scope.local">>, AuthCtxt
            );
        client_local ->
            ok = bondy_rbac:authorize(
                <<"bondy.issue">>, <<"bondy.ticket.scope.client_local">>,
                AuthCtxt
            )
    end.


scope_type(#{realm := undefined, client_id := undefined}) ->
    sso;

scope_type(#{realm := undefined, client_id := _}) ->
    client_sso;

scope_type(#{client_id := undefined}) ->
    local;

scope_type(#{client_id := _}) ->
    client_local.



is_persistent(Type) ->
    bondy_config:get([security, ticket, Type, persistence], true).



%% @private
store_key(Authid, Scope) ->
    store_key(Authid, Scope, scope_type(Scope)).


%% @private
store_key(Authid, #{client_instance_id := undefined}, sso) ->
    Authid;

store_key(Authid, #{client_instance_id := Id}, sso) ->
    <<Authid/binary, $,, Id/binary>>;

store_key(_, #{realm := Uri, client_instance_id := undefined}, local) ->
    Uri;

store_key(_, #{realm := Uri, client_instance_id := Id}, local) ->
    <<Uri/binary, $,, Id/binary>>;

store_key(_, #{client_id := ClientId}, _) ->
    %% client scope or client_realm scope ticket
    %% client_instance_id handled internally by list_key
    ClientId.


%% @private
list_key(#{realm := Uri, client_instance_id := Id}) ->
    {Uri, Id}.


%% @private
store_ticket(RealmUri, Authid, Claims) ->
    Prefix = ?PDB_PREFIX([RealmUri, Authid]),
    Scope = maps:get(scope, Claims),
    Key = store_key(Authid, Scope),

    case maps:get(client_id, Scope) of
        undefined ->
            %% local | sso ticket scope type
            %% We just replace any existing ticket in this location
            ok = plum_db:put(Prefix, Key, Claims);

        _ ->
            %% client_local | client_sso scope type
            %% We have to update the value, so first we fetch it.
            Opts = [{resolver, fun ticket_resolver/2}, {allow_put, true}],
            Tickets0 = plum_db:get(Prefix, Key, Opts),
            Tickets = update_tickets(Scope, Claims, Tickets0),
            ok = plum_db:put(Prefix, Key, Tickets)
    end.


%% @private
update_tickets(_, Claims, undefined) ->
    [Claims];

update_tickets(Scope, Claims, Tickets) when is_map(Scope) ->
    update_tickets(list_key(Scope), Claims, Tickets);

update_tickets({_, _} = Key, Claims, Tickets) ->
    lists:sort(
        lists:keystore(Key, 1, Tickets, {Key, Claims})
    ).


%% @private
expiry_time_secs(#{expiry_time_secs := Val})
when is_integer(Val) andalso Val > 0 ->
    expiry_time_secs(Val);

expiry_time_secs(#{}) ->
    Default = bondy_config:get([security, ticket, expiry_time_secs]),
    expiry_time_secs(Default);

expiry_time_secs(Val) when is_integer(Val) ->
    Max = bondy_config:get([security, ticket, max_expiry_time_secs]),
    min(Val, Max).


%% @private
issuer(Authid, #{client_id := undefined}) ->
    Authid;

issuer(_, #{client_id := ClientId}) ->
    ClientId.


%% @private
allow_not_found(#{allow_not_found := Value}) ->
    Value;

allow_not_found(_) ->
    bondy_config:get([security, ticket, allow_not_found]).


%% @private
is_expired(#{expires_at := Exp}) ->
    Exp =< ?NOW + ?LEEWAY_SECS.


%% @private
ticket_resolver(?TOMBSTONE, L) when is_list(L) ->
    maybe_tombstone(remove_expired(L));

ticket_resolver(L, ?TOMBSTONE) when is_list(L) ->
    maybe_tombstone(remove_expired(L));

ticket_resolver(L1, L2) when is_list(L1) andalso is_list(L2) ->
    %% Lists are sorted already as we sort them every time we put
    maybe_tombstone(
        remove_expired(lists:umerge(L1, L2))
    );

ticket_resolver(?TOMBSTONE, Ticket) when is_map(Ticket) ->
    case is_expired(Ticket) of
        true -> ?TOMBSTONE;
        Ticket -> Ticket
    end;

ticket_resolver(Ticket, ?TOMBSTONE) when is_map(Ticket) ->
    ticket_resolver(?TOMBSTONE, Ticket);

ticket_resolver(TicketA, TicketB)
when is_map(TicketA) andalso is_map(TicketB) ->
    case {is_expired(TicketA), is_expired(TicketB)} of
        {true, true} -> ?TOMBSTONE;
        {false, true} -> TicketA;
        {true, false} -> TicketB;
        {false, false} ->
            ExpA = maps:get(expires_at, TicketA),
            ExpB = maps:get(expires_at, TicketB),
            case ExpA >= ExpB of
                true -> ExpA;
                false -> ExpB
            end
    end.


%% @private
remove_expired(L) ->
    %% TODO
    L.


%% @private
maybe_tombstone([]) ->
    ?TOMBSTONE;

maybe_tombstone(L) ->
    L.
