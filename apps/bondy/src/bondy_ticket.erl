%% ===========================================================================
%%  bondy_ticket.erl -
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
%% ===========================================================================

%% -----------------------------------------------------------------------------
%% @doc This module implements the functions to issue and manage authentication
%% tickets.
%%
%% <h1>Overview</h1>
%% An authentication ticket is a signed (and possibly encrypted)
%% assertion of a user's identity, that a client can use to authenticate the
%% user without the need to ask it to re-enter its credentials.
%%
%% Tickets MUST be issued by a session that was opened using an authentication
%% method that is neither `ticket' nor `anonymous' authentication.
%%
%% == Claims ==
%%
%% <ul>
%% <li>`id': provides a unique identifier for the ticket.</li>
%% <li>`issued_by': identifies the principal that issued the ticket. Most
%% of the time this is an application identifier (a.k.asl username or client_id)
%% but sometimes can be the WAMP session's username (a.k.a `authid').</li>
%% <li>`authid': identifies the principal that is the subject of the ticket.
%% The Claims in a ticket are normally statements. This is the WAMP session's
%% username (a.k.a `authid').</li>
%% <li>`authrealm': identifies the recipients that the ticket is intended for.
%% The value is `RealmUri'.</li>
%% <li>`expires_at': identifies the expiration time on or after which
%% the ticket MUST NOT be accepted for processing.  The processing of th thia
%% claim requires that the current date/time MUST be before the expiration date/
%% time listed in the &quot;exp&quot; claim. Bondy considers a small leeway of
%% 2 mins by default.</li>
%% <li>`issued_at': identifies the time at which the ticket was issued.
%% This claim can be used to determine the age of the ticket. Its value is a
%% timestamp in seconds.</li>
%% <li>`issued_on': the bondy nodename in which the ticket was issued.</li>
%% <li>`scope': the scope of the ticket, consisting of</li>
%% <li>`realm': If `all' the ticket grants access to all realms the user
%% has access to by the authrealm (an SSO realm). Otherwise, the value is the
%% realm this ticket is valid on.</li>
%% </ul>
%%
%% == Claims Storage ==
%%
%% Claims for a ticket are stored in PlumDB using the prefix
%% `{bondy_ticket, Suffix :: binary()}' where `Suffix' is the concatenation of
%% the authentication realm's URI and the user's username (a.k.a `authid') and
%% a key which is derived by the ticket's scope. The scope itself is the result
%% of the combination of the different options provided by the {@link issue/2}
%% function.
%%
%% The decision to use this key as opposed to the ticket's unique identifier
%% is so that we are able to bound the number of tickets a user can have at any
%% point in time in order to reduce data storage and cluster replication
%% traffic.
%%
%% == Ticket Scopes ==
%% A ticket can be issued using different scopes. The scope is determined based
%% on the options used to issue the ticket.
%%
%% There are 4 scopes:
%%
%% <ol>
%% <li>Local scope</li>
%% <li>SSO scope</li>
%% <li>Client-Local scope</li>
%% <li>Client-SSO scope</li>
%% </ol>
%%
%% === Local scope ===
%% The ticket was issued with `allow_sso' option set to `false' or when set to
%% `true' the user did not have SSO credentials, and the option `client_ticket'
%% was not provided.
%% The ticket can be used to authenticate on the session's realm only.
%%
%% ==== Authorization ====
%% To be able to issue this ticket, the user must have been granted
%% permission `<<"bondy.issue">>' on the `<<"bondy.ticket.scope.local">>'
%% resource.
%%
%% === SSO Scope ===
%% The ticket was issued with `allow_sso' option set to `true', the user has
%% SSO credentials, and the option `client_ticket' was not provided.
%% The ticket can be used to authenticate on any realm the user has access to
%% through SSO.
%%
%% ==== Authorization ====
%% To be able to issue this ticket, the user must have been granted
%% permission `<<"bondy.issue">>' on the `<<"bondy.ticket.scope.sso">>'
%% resource.
%%
%% === Client-Local scope ===
%% The ticket was issued with `allow_sso' option set to `false' or when set to
%% `true' the user did not have SSO credentials, and the option `client_ticket'
%% was provided having a valid ticket issued by a client
%% (a local or sso ticket).
%% The ticket can be used to authenticate on the session's realm by the
%% specified client only.
%%
%% ==== Authorization ====
%% To be able to issue this ticket, the session must have been granted
%% permission `<<"bondy.issue">>' on the `<<"bondy.ticket.scope.client_local">>'
%% resource.
%%
%% === Client-SSO scope ===
%% The ticket was issued with `allow_sso' option set to `true' and the user has
%% SSO credentials, and the option `client_ticket' was provided having a valid
%% ticket issued by a client (a local or sso ticket).
%% The ticket can be used to authenticate on any realm the user has access to
%% through SSO only by the specified client.
%%
%% ==== Authorization ====
%% To be able to issue this ticket, the session must have been granted
%% permission `<<"bondy.issue">>' on the `<<"bondy.ticket.scope.client_local">>'
%% resource.
%%
%% === Scope Summary ===
%%
%% *Keys:*
%% * `uri()' in the following table refers to the scope realm (not the
%% Authentication realm which is used in the prefix)
%%
%% <div class="markdown">
%% |SCOPE|Allow SSO|Client Ticket|Client Instance ID|Key|Value|
%% |---|---|---|---|---|---|
%% |Local|no|no|no|`uri()'|`t()'|
%% |SSO|yes|no|no|`username()'|`t()'|
%% |Client-Local|no|yes|no|`client_id()'|`[{uri(), t()}]'|
%% |Client-Local|no|yes|yes|`client_id()'|`[{{uri(), instance_id()}, t()}]'|
%% |Client-SSO|yes|yes|no|`client_id()'|`[{all, t()}]'|
%% |Client-SSO|yes|yes|yes|`client_id()'|`[{{all, instance_id()}, t()}]'|
%% </div>
%%
%% === Permissions Summary ===
%% Issuing tickets requires the user to be granted certain permissions beyond
%% the WAMP permission required to call the procedures.
%%
%% <div class="markdown">
%% |Scope|Permission|Resource|
%% |---|---|---|
%% |Local|`bondy.issue'|`bondy.ticket.scope.local'|
%% |SSO|`bondy.issue'|`bondy.ticket.scope.sso'|
%% |Client-Local|`bondy.issue'|`bondy.ticket.scope.client_local'|
%% |Client-SSO|`bondy.issue'|`bondy.ticket.scope.client_sso'|
%% </div>
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_ticket).
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_plum_db.hrl").
-include("bondy_security.hrl").

-define(NOW, erlang:system_time(second)).
-define(LEEWAY_SECS, 2 * 60). % 2 mins

%% TODO review, using a dynamic prefix is a bad idea, turn this into
%% {?PLUM_DB_TICKET_TAB, Realm} and use key composition which allow for
%% iteration using first prefixes
-define(PLUM_DB_PREFIX(Uri), {?PLUM_DB_TICKET_TAB, Uri}).

-define(OPTS_VALIDATOR, #{
    expiry_time_secs => #{
        alias => ~"expiry_time_secs",
        key => expiry_time_secs,
        required => false,
        datatype => pos_integer
    },
    allow_sso => #{
        alias => ~"allow_sso",
        key => allow_sso,
        required => true,
        datatype => boolean,
        default => true
    },
    client_id => #{
        alias => ~"client_id",
        key => client_id,
        required => false,
        datatype => binary
    },
    device_id => #{
        alias => ~"device_id",
        key => device_id,
        required => false,
        datatype => binary
    },
    client_ticket => #{
        alias => ~"client_ticket",
        key => client_ticket,
        required => false,
        datatype => binary
    }
}).

-type t()           ::  #{
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
-type opts()        ::  #{
                            expiry_time_secs    =>  pos_integer(),
                            allow_sso           =>  boolean(),
                            client_ticket       =>  jwt(),
                            client_id           =>  binary(),
                            device_id  =>  binary()
                        }.
-type verify_opts() ::  #{
                            allow_not_found     =>  boolean()
                        }.
-type scope()       ::  #{
                            realm               :=  optional(uri()),
                            client_id           :=  optional(authid()),
                            device_id  :=  optional(binary())
                        }.
-type jwt()         ::  binary().
-type ticket_id()   ::  binary().
-type authid()      ::  bondy_rbac_user:username().
-type issue_error() ::  {no_such_user, authid()}
                        | {no_such_realm, uri()}
                        | {invalid_request, binary()}
                        | invalid_ticket
                        | not_authorized.


-export_type([t/0]).
-export_type([jwt/0]).
-export_type([ticket_id/0]).
-export_type([scope/0]).
-export_type([opts/0]).


-export([issue/2]).
-export([lookup/3]).
-export([remove_expired/0]).
-export([revoke/1]).
-export([revoke/3]).
-export([revoke_all/1]).
-export([revoke_all/2]).
-export([revoke_all/3]).
-export([verify/1]).



%% =============================================================================
%% API
%% =============================================================================



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
    {ok, Ticket :: jwt(), Claims :: t()}
    | {error, issue_error()}
    | no_return().

issue(Session, Opts0) ->
    try
        Opts = maps_utils:validate(Opts0, ?OPTS_VALIDATOR),
        Authmethod = bondy_session:authmethod(Session),
        Allowed = bondy_config:get([security, ticket, authmethods]),

        lists:member(Authmethod, Allowed) orelse throw({
            not_authorized,
            <<
                "The authentication method '", Authmethod/binary,
                "' you used to establish this session is not in the list of "
                "methods allowed to issue tickets (configuration option "
                "'security.ticket.authmethods')."
            >>
        }),

        do_issue(Session, Opts)
    catch
        throw:Reason ->
            {error, Reason};

        _:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec verify(Ticket :: binary()) -> {ok, t()} | {error, expired | invalid}.

verify(Ticket) ->
    verify(Ticket, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec verify(Ticket :: binary(), Opts :: verify_opts()) ->
    {ok, t()} | {error, expired | invalid}.

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

        error:{badarg, _} ->
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
    Scope :: scope()) -> {ok, Claims :: t()} | {error, no_found}.

lookup(RealmUri, Authid, Scope) ->
    Prefix = ?PLUM_DB_PREFIX(RealmUri),
    Key = lookup_key(Authid, Scope),
    Opts = [{resolver, fun ticket_resolver/2}, {allow_put, true}],

    case plum_db:get(Prefix, Key, Opts) of
        undefined ->
            {error, not_found};
        Claims when is_map(Claims) ->
            {ok, Claims};
        List when is_list(List) ->
            %% List :: [t()]
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
-spec revoke(optional(t())) -> ok | {error, any()}.

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
        authrealm := RealmUri,
        authid := Authid,
        scope := Scope
    } = Claims,
    revoke(RealmUri, Authid, Scope).


%% -----------------------------------------------------------------------------
%% @doc `RealmUri' should eb aht value of the ticket's `authrealm' claim
%% @end
%% -----------------------------------------------------------------------------
-spec revoke(
    RealmUri :: uri(),
    Authid :: bondy_rbac_user:username(),
    Scope :: scope()) -> ok.

revoke(RealmUri, Authid, Scope)
when is_binary(RealmUri), is_binary(Authid), is_map(Scope) ->
    Prefix = ?PLUM_DB_PREFIX(RealmUri),
    Key = lookup_key(Authid, Scope),
    plum_db:delete(Prefix, Key).


%% -----------------------------------------------------------------------------
%% @doc Revokes all tickets issued to all users in realm `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_all(RealmUri :: uri()) -> ok.

revoke_all(RealmUri) when is_binary(RealmUri) ->
    Prefix = ?PLUM_DB_PREFIX(RealmUri),
    Fun = fun({Key, _}) -> plum_db:delete(Prefix, Key) end,
    %% We cannot use keys_only as it will currently ignore remove_tombstones
    Opts = [{remove_tombstones, true}, {resolver, lww}],
    ok = plum_db:foreach(Fun, Prefix, Opts).


%% -----------------------------------------------------------------------------
%% @doc Revokes all tickets issued to user with `Username' in realm `RealmUri'.
%% Notice that the ticket could have been issued by itself or by a client
%% application.
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_all(RealmUri :: uri(), Authid :: bondy_rbac_user:username()) ->
    ok.

revoke_all(RealmUri, Authid) ->
    %% The tickets for a user are distributed across all the plum_db partitions
    %% because we are sharding by key
    Prefix = ?PLUM_DB_PREFIX(RealmUri),
    Fun = fun
        ({{Term, _, _} = Key, _}) when Term == Authid ->
            plum_db:delete(Prefix, Key);
        (_) ->
            %% No longer the user's ticket
            throw(break)
    end,
    Opts = [
        {first, {Authid, '_', '_'}},
        {remove_tombstones, true},
        {resolver, lww}
    ],
    plum_db:foreach(Fun, Prefix, Opts).


%% -----------------------------------------------------------------------------
%% @doc Revokes all tickets issued to user with `Username' in realm `RealmUri'
%% matching the scope `Scope'.
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_all(
    RealmUri :: uri(),
    Authid ::  all | bondy_rbac_user:username(),
    Scope :: scope()) -> ok.

revoke_all(_RealmUri, _Authid, _Scope) ->
    % Prefix = ?PLUM_DB_PREFIX([RealmUri, Authid]),
    % Key = store_key(Authid, Scope),
    % Realm = maps:get(realm, Scope, undefined),
    % InstanceId = maps:get(device_id, Scope, undefined),

    % Fun = fun
    %     ({_, ?TOMBSTONE}) ->
    %         ok;
    %     ({K, Claims}) when K == Key andalso is_map(Claims)->
    %         plum_db:delete(Prefix, Key);
    %     ({K, L0}) when K == Key andalso is_list(L0) ->
    %         %% List :: [t()]
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


remove_expired() ->
    % Prefix = {?PLUM_DB_TICKET_TAB, '_'},
    % Fun = fun
    %     ({{Prefix, Key}, O}, ok) ->
    %         %% fold_elements does not currently respect opts, so we manually
    %         %% resolve
    %         case plum_db_object:values(plum_db_object:resolve(O, lww)) of
    %             ['$deleted'] ->
    %                 ok;
    %             [Val] ->
    %                 plum_db:delete(Prefix, Key)
    %         end
    % end,
    % Opts = [],
    % plum_db:fold_elements(Fun, ok, Prefix, Opts).

    ok.


%% ===========================================================================
%% PRIVATE
%% ===========================================================================



%% @private
do_issue(Session, Opts) ->
    RealmUri = bondy_session:realm_uri(Session),
    AuthRealmUri = bondy_session:authrealm(Session),
    Authid = bondy_session:authid(Session),
    User = bondy_session:user(Session),
    SSORealmUri = bondy_rbac_user:sso_realm_uri(User),

    ScopeUri = case maps:get(allow_sso, Opts) of
        true when SSORealmUri =/= undefined ->
            %% The ticket can be used to authenticate on all user realms
            %% connected to this SSORealmUri
            undefined;
        _ ->
            %% SSORealmUri is undefined or SSO was not allowed,
            %% the scope realm can only be the session realm
            RealmUri
    end,

    Scope = scope(Session, Opts, ScopeUri),
    ScopeType = scope_type(Scope),
    AuthCtxt = bondy_session:rbac_context(Session),

    ok = authorize(ScopeType, AuthCtxt),

    AuthRealm = bondy_realm:fetch(AuthRealmUri),
    Kid = bondy_realm:get_random_kid(AuthRealm),

    IssuedAt = ?NOW,
    ExpiresAt = IssuedAt + expiry_time_secs(Opts),

    Claims = #{
        id => bondy_utils:uuid(),
        authrealm => AuthRealmUri,
        authid => Authid,
        authmethod => bondy_session:authmethod(Session),
        issued_by => issuer(Authid, Scope),
        issued_on => atom_to_binary(bondy_config:node(), utf8),
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
            ok = store_ticket(AuthRealmUri, Authid, Claims);
        false ->
            ok
    end,

    {ok, Ticket, Claims}.



%% @private
scope(Session, #{client_ticket := Ticket} = Opts, Uri)
when is_binary(Ticket) ->
    Authid = bondy_session:authid(Session),

    %% We are relaxed here as these are signed by us.
    VerifyOpts = #{allow_not_found => true},

    case verify(Ticket, VerifyOpts) of
        {ok, #{scope := #{client_id := Val}}} when Val =/= all ->
            throw({invalid_request, "Nested tickets are not allowed"});

        {ok, #{issued_by := Authid}} ->
            %% A client is requesting a ticket issued to itself using its own
            %% client_ticket.
            throw({invalid_request, "Self-granting ticket not allowed"});

        {ok, #{authid := ClientId, scope := Scope}} ->
            Id0 = maps:get(device_id, Scope),
            Id = maps:get(device_id, Opts, Id0),

            all =:= Id0 orelse Id =:= Id0
                orelse throw({invalid_request, "invalid device_id"}),

            bondy_auth_scope:new(Uri, ClientId, Id);

        {error, _Reason} ->
            %% TODO implement new Error standard
            error(#{
                code => invalid_value,
                description => <<
                    "The value for 'client_ticket' is not valid."
                >>,
                key => client_ticket,
                message => <<
                    "The value for 'client_ticket' is not either not a ticket,"
                    " it has an invalid signature or it is expired."
                >>
            })
    end;

scope(Session, Opts, Uri) ->
    Authid = bondy_session:authid(Session),
    ClientId = maps:get(client_id, Opts, all),
    InstanceId = maps:get(device_id, Opts, all),

    %% Throw exception if client is requesting a ticket issued to itself
    Authid =/= ClientId orelse throw(invalid_request),

    #{
        realm => Uri,
        client_id => ClientId,
        device_id => InstanceId
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


scope_type(#{realm := all, client_id := all}) ->
    sso;

scope_type(#{realm := all, client_id := _}) ->
    client_sso;

scope_type(#{client_id := all}) ->
    local;

scope_type(#{client_id := _}) ->
    client_local.


%% @private
is_persistent(Type) ->
    bondy_config:get([security, ticket, Type, persistence], true).


%% @private
store_key(Authid, Scope) ->
    store_key(Authid, Scope, scope_type(Scope)).


%% @private
store_key(Authid, #{client_id := ClientId}, Type)
when ClientId =/= all andalso
(Type == client_local orelse Type == client_sso) ->
    %% client scope or client_realm scope ticket
    %% device_id handled internally by list_key
    {Authid, ClientId, <<>>};

store_key(Authid, #{device_id := all}, sso) ->
    {Authid, <<>>, <<>>};

store_key(Authid, #{device_id := Id}, sso) ->
    {Authid, <<>>, Id};

store_key(Authid, #{realm := Uri, device_id := all}, local) ->
    {Authid, Uri, <<>>};

store_key(Authid, #{realm := Uri, device_id := Id}, local) ->
    {Authid, Uri, Id}.

%% @private
lookup_key(Authid, Scope) ->
    store_key(Authid, normalise_scope(Scope)).


%% @private
normalise_scope(Scope) ->
    Default = #{
        realm => all,
        client_id => all,
        device_id => all
    },
    maps:merge(Default, Scope).


%% @private
list_key(#{realm := Uri, device_id := Id}) ->
    {Uri, Id}.


%% @private
store_ticket(AuthRealmUri, Authid, Claims) ->
    Prefix = ?PLUM_DB_PREFIX(AuthRealmUri),
    Scope = maps:get(scope, Claims),
    Key = store_key(Authid, Scope),

    case maps:get(client_id, Scope) of
        all ->
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
issuer(Authid, #{client_id := all}) ->
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
ticket_resolver(?TOMBSTONE, ?TOMBSTONE) ->
    ?TOMBSTONE;

ticket_resolver(?TOMBSTONE, L) when is_list(L) ->
    maybe_tombstone(remove_expired(L));

ticket_resolver(L, ?TOMBSTONE) when is_list(L) ->
    maybe_tombstone(remove_expired(L));

ticket_resolver(L1, L2) when is_list(L1) andalso is_list(L2) ->
    %% Lists are sorted already as we sort them every time we put
    maybe_tombstone(
        remove_expired(lists:umerge(L1, L2))
    );

ticket_resolver(?TOMBSTONE, T) when is_map(T) ->
    case is_expired(T) of
        true -> ?TOMBSTONE;
        T -> T
    end;

ticket_resolver(T, ?TOMBSTONE) when is_map(T) ->
    ticket_resolver(?TOMBSTONE, T);

ticket_resolver(TA, TB)
when is_map(TA) andalso is_map(TB) ->
    case {is_expired(TA), is_expired(TB)} of
        {true, true} -> ?TOMBSTONE;
        {false, true} -> TA;
        {true, false} -> TB;
        {false, false} ->
            ExpA = maps:get(expires_at, TA),
            ExpB = maps:get(expires_at, TB),
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
