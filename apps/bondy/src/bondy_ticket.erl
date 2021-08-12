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
%% @doc
%% The ticket is a binary  that has the following claims:
%%
%% * id: provides a unique identifier for the ticket.
%% * "iss" (issuer): identifies the principal that issued the ticket. Most
%% of the time this is an application identifier (a.k.asl username or client_id)
%% but sometimes can be the WAMP session's username (a.k.a `authid').
%% * "sub" (subject): identifies the principal that is the subject of the ticket.
%% The Claims in a ticket are normally statements. This is the WAMP session's
%% username (a.k.a `authid').
%% * "aud" (audience): identifies the recipients that the ticket is intended for.
%% The value is `RealmUri'. Notice that if `RealmUri' is the uri of an SSO
%% Realm, this ticket grants access to all realms the user has access to i.e.
%% those realms using `RealmUri' as SSO realm.
%% * "exp" (expiration time): identifies the expiration time on or after which
%% the ticket MUST NOT be accepted for processing.  The processing of the "exp"
%% claim requires that the current date/time MUST be before the expiration date/
%% time listed in the "exp" claim. Bondy considers a small leeway of 2 mins by
%% default.
%% * "iat" (issued at): identifies the time at which the ticket was issued.
%% This claim can be used to determine the age of the ticket. Its value is a
%% timestamp in seconds.
%% * auth_time -- Time when the End-User authentication occurred. Its value is
%% a JSON number representing the number of seconds from 1970-01-01T0:0:0Z as
%% measured in UTC until the date/time.
%%
%% ## Ticket Storage
%% * Tickets for a user are stored on the
%% `{bondy_ticket, AuthRealm ++ Username}` prefix
%% * "User" is either a human user or application.
%% * Both humans and application can issue self-issued tickets if they have
%% been granted the `bondy.ticket.self_issue` permission.
%%
%% ## Ticket
%%
%% * `uri()` in the following table refers to the scope realm (not the
%% Authentication realm which is used in the prefix)
%%
%% |SCOPE NAME|Realm|Client Ticket|Client Instance ID|Key|Value|
%% |---|---|---|---|---|---|
%% |1. User|no|no|no|`username()`|`claims()`|
%% |2. User-Realm|yes|no|no|`uri()`|`claims()`|
%% |3. Client-User|yes|yes|yes|`client_id()`|`[{{uri(), instance_id()}, claims()}]`|
%% |4. Client-User|no|yes|no|`client_id()`|`[{undefined, claims()}]`|
%% |5. Client-User|no|yes|no|`client_id()`|`[{undefined, claims()}]`|
%% |6. Client-User|yes|yes|no|`client_id()`|`[{uri(), claims()}]`|

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

-define(FOLD_OPTS, [{resolver, lww}]).

-define(OPTS_VALIDATOR, #{
    <<"expiry_time_secs">> => #{
        alias => expiry_time_secs,
		key => expiry_time_secs,
        required => false,
        datatype => pos_integer
    },
    <<"sso_ticket">> => #{
        alias => sso_ticket,
        key => sso_ticket,
        required => true,
        datatype => boolean,
        default => false
    },
    <<"client_ticket">> => #{
        alias => client_ticket,
        key => client_ticket,
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

-type t()           ::   binary().
-type opts()        ::  #{
                            expiry_time_secs    =>  pos_integer(),
                            sso_ticket          =>  boolean(),
                            client_ticket       =>  t(),
                            client_instance_id  =>  binary()
                        }.
-type verify_opts() ::  #{
                            not_found_ok        =>  boolean(),
                            self_signed         =>  boolean()
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
-type issue_error() ::  no_such_user
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
%% @doc Generates a ticket to be used with the WAMP Ticket authentication
%% method. The function stores the ticket and a set of secondary indices in the
%% store (which replicates the data across the cluster).
%%
%% The keys used to store the ticket and indices are controlled by the scope of
%% the ticket. The scope is controlled by the options `Opts'.
%%
%% * **User scope**: the ticket was self-issued by the user without restricting
%% the scope to any realm. The ticket is scoped to the session's realm unless
%% the realm and user have SSO enabled in which case the ticket is scoped to
%% the SSO Realm, allowing the ticket to authenticate in any realm the user has
%% access to through the SSO Realm.
%%
%% @end
%% -----------------------------------------------------------------------------
-spec issue(Session :: bondy_session:t(), Opts :: opts()) ->
    {ok, Ticket :: t(), Claims :: claims()}
    | {error, issue_error()}
    | no_return().

issue(Session, Opts0) ->
    Opts = maps_utils:validate(Opts0, ?OPTS_VALIDATOR),
    do_issue(Session, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec verify(Ticket :: binary()) -> {ok, claims()} | {error, expired | invalid}.

verify(Ticket) ->
    verify(Ticket, #{not_found_ok => true}).


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

        %% TODO remove and use lookup
        is_expired(Claims) andalso throw(expired),
        ExpiresAt > IssuedAt orelse throw(invalid),

        Realm = bondy_realm:fetch(AuthRealmUri),

        Key = bondy_realm:get_public_key(Realm, Kid),
        Key =/= undefined orelse throw(invalid),

        {Verified, _, _} = jose_jwt:verify(Key, Ticket),
        Verified == true orelse throw(invalid),

        NotFoundOK = maps:get(not_found_ok, Opts, false),

        case lookup(AuthRealmUri, Authid, Scope) of
            {ok, Claims} = OK ->
                OK;
            {ok, _Other} ->
                throw(no_match);
            {error, not_found} when NotFoundOK == true ->
                %% We trust the signed JWT
                {ok, Claims};
            {error, not_found} ->
                %% TODO Try to retrieve from Claims.node
                %% or use Scope to lookup indices
                throw(invalid)
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
                error ->
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
    ok.



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
    %% Disabled for the time being
    %% ok = authorize(Session, Opts),

    RealmUri = bondy_session:realm_uri(Session),
    Authid = bondy_session:authid(Session),
    User = bondy_session:user(Session),
    SSORealmUri = bondy_rbac_user:sso_realm_uri(User),

    {AuthUri, ScopeUri} = case maps:get(sso_ticket, Opts) of
        true when SSORealmUri == undefined ->
            {SSORealmUri, RealmUri};
        true ->
            {SSORealmUri, SSORealmUri};
        false ->
            {RealmUri, RealmUri}
    end,

    Scope = scope(Session, Opts, ScopeUri),

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

    ok = store_ticket(AuthUri, Authid, Claims),

    {ok, Ticket, Claims}.


%% @private
% authorize(Session, Opts) ->
%     RBACCtxt = bondy_session:rbac_context(Session),
%     ok = bondy_rbac:authorize(<<"bondy.ticket.issue">>, RBACCtxt),

%     case maps:get(client_ticket, Opts, undefined) of
%         undefined ->
%             %% Requesting to issue a self-issued ticket
%             ok = bondy_rbac:authorize(<<"bondy.ticket.self_issue">>, RBACCtxt);
%         _ ->
%             ok
%     end.

%% @private
normalise_scope(Scope) ->
    Default = #{
        realm => undefined,
        client_id => undefined,
        client_instance_id => undefined
    },
    maps:merge(Default, Scope).


%% @private
store_key(Authid, #{realm := undefined, client_id := undefined}) ->
    %% Self-issued noscope ticket.
    Authid;

store_key(_, #{realm := Uri, client_id := undefined}) ->
    %% Self-issued w/realm-scope ticket.
    Uri;

store_key(_, #{client_id := ClientId}) ->
    %% Ticket issued by client with or without scope
    %% We have to update the value, so first we fetch it.
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
            %% Self-issued noscope ticket or w/realm-scope ticket.
            %% We just replace any existing ticket in this location
            ok = plum_db:put(Prefix, Key, Claims);

        Key ->
            %% Ticket issued by client with or without scope
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
scope(Session, #{client_ticket := Ticket} = Opts, Uri) when is_binary(Ticket) ->
    Authid = bondy_session:authid(Session),

    VerifyOpts = #{not_found_ok => false, self_signed => true},

    case verify(Ticket, VerifyOpts) of
        {ok, #{scope := #{client_id := Authid}}} ->
            %% A client is requesting a ticket issued to itself using it own
            %% self-issued ticket.
            throw(invalid_request);

        {ok, #{scope := #{client_id := ClientId}}} ->
            #{
                realm => Uri,
                client_id => ClientId,
                client_instance_id => maps:get(
                    client_instance_id, Opts, undefined
                )
            };
        {error, _Reason} ->
            %% TODO implement new Error standard
            error(#{
                code => invalid_value,
                description => <<"The value for 'client_ticket' did not pass the validator.">>,
                key => client_ticket,
                message => <<"The value for 'client_ticket' is not valid.">>
            })
    end;

scope(_, #{client_instance_id := _}, _) ->
    %% TODO implement new Error standard
    error(#{
        code => missing_required_value,
        description => <<"A value for 'client_instance_id' was defined but a value for 'client_ticket' was missing.">>,
        key => client_ticket,
        message => <<"A value for 'client_ticket' is required.">>
    });

scope(_, _, Uri) ->
    #{
        realm => Uri,
        client_id => undefined,
        client_instance_id => undefined
    }.


%% @private
issuer(Authid, #{client_id := undefined}) ->
    Authid;

issuer(_, #{client_id := ClientId}) ->
    ClientId.


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
