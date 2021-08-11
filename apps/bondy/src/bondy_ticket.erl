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
% -type pattern()     ::  #{
%                             realm               :=  '_' | maybe(uri()),
%                             client_id           :=  '_' | maybe(authid()),
%                             client_instance_id  :=  '_' | maybe(binary())
%                         }.
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
-export([lookup/2]).
% -export([match/1]).
% -export([match/2]).
-export([revoke/1]).
-export([revoke/2]).
-export([revoke_all/2]).
-export([revoke_all/3]).




%% -----------------------------------------------------------------------------
%% @doc Generates a ticket to be used with the WAMP Ticket authentication
%% method.
%% The ticket is a ticket that has the following claims:
%%
%% * "jti" (ticket ID): provides a unique identifier for the ticket.
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
%% The function stores the ticket in the store and replicates it across the
%% cluster.
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
            id := Id,
            authrealm := AuthRealmUri,
            issued_at := IssuedAt,
            expires_at := ExpiresAt,
            % issued_on := Node,
            % scope := Scope,
            kid := Kid
        } = Claims,

        is_expired(Claims) andalso throw(expired),
        ExpiresAt > IssuedAt orelse throw(invalid),

        Realm = bondy_realm:fetch(AuthRealmUri),

        Key = bondy_realm:get_public_key(Realm, Kid),
        Key =/= undefined orelse throw(invalid),

        {Verified, _, _} = jose_jwt:verify(Key, Ticket),
        Verified == true orelse throw(invalid),

        NotFoundOK = maps:get(not_found_ok, Opts, false),

        case lookup(AuthRealmUri, Id) of
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
-spec lookup(RealmUri :: uri(), Id :: ticket_id()) ->
    {ok, Claims :: claims()} | {error, no_found}.

lookup(RealmUri, Id) ->
    Opts = [{resolver, fun ticket_resolver/2}, {allow_put, true}],
    case plum_db:get(?PDB_PREFIX([RealmUri]), Id, Opts) of
        undefined ->
            {error, not_found};
        Value ->
            case is_expired(Value) of
                true ->
                    ok = plum_db:delete(?PDB_PREFIX([RealmUri]), Id),
                    {error, not_found};
                false ->
                    {ok, Value}
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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec revoke(RealmUri :: uri(), Id :: binary()) -> ok | {error, any()}.

revoke(RealmUri, Id) ->
    Opts = [{resolver, lww}],
    revoke(plum_db:get(?PDB_PREFIX([RealmUri]), Id, Opts)).


%% -----------------------------------------------------------------------------
%% @doc Revokes all tickets issued to user with `Username' in realm `RealmUri'.
%% Notice that the ticket could have been issued by itself or by a client
%% application.
%% @end
%% -----------------------------------------------------------------------------
-spec revoke_all(RealmUri :: uri(), Username :: bondy_rbac_user:username()) ->
    ok.

revoke_all(RealmUri, Username) ->
    Opts = [{resolver, fun index_resolver/2}],

    case plum_db:get(?PDB_PREFIX([RealmUri, Username]), Username, Opts) of
        undefined ->
            ok;
        _Index ->
            error(not_implemented)
    end.


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
    error(no_implemented).


%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_issue(Session, Opts) ->
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
    Id = bondy_utils:uuid(),

    Claims = #{
        id => Id,
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

    ok = store_ticket(AuthUri, Authid, Id, Claims),

    {ok, Ticket, Claims}.


%% @private
store_ticket(RealmUri, Username, Id, #{scope := Scope} = Claims) ->
    ok = plum_db:put(?PDB_PREFIX([RealmUri]), Id, Claims),

    %% We conditionally update the user index
    ok = case get_index(RealmUri, Username) of
        undefined ->
            ok;
        UserIndex0 ->
            UserIndex = index_update(Scope, Id, UserIndex0),
            ok = plum_db:put(
                ?PDB_PREFIX([RealmUri, Username]), Username, UserIndex
            )
    end,

    #{client_id := ClientId} = Scope,

    %% We conditionally update the client index
    ok = case get_index(RealmUri, ClientId) of
        undefined ->
            ok;
        ClientIndex0 ->
            ClientIndex = index_update(Scope, Id, ClientIndex0),
            ok = plum_db:put(
                ?PDB_PREFIX([RealmUri, ClientId]), ClientId, ClientIndex
            )
    end,

    ok.


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
        {ok, #{client_id := Authid}} ->
            %% A client is requesting a ticket issued to itself using it own
            %% self-issued ticket.
            throw(invalid_request);

        {ok, #{client_id := ClientId}} ->
            #{
                realm => Uri,
                client_id => ClientId,
                client_instance_id => maps:get(client_instance_id, Opts)
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

scope_to_tuple(Scope) ->
    #{
        realm := Uri,
        client_id := ClientId,
        client_instance_id := InstanceId
    } = Scope,
    {Uri, ClientId, InstanceId}.


%% @private
issuer(Authid, #{client_id := undefined}) ->
    Authid;

issuer(_, #{client_id := ClientId}) ->
    ClientId.


%% @private
get_index(_, undefined) ->
    undefined;

get_index(RealmUri, Username) ->
    Opts = [{resolver, fun index_resolver/2}],
    case plum_db:get(?PDB_PREFIX([RealmUri, Username]), Username, Opts) of
        undefined -> [];
        Index -> Index
    end.


%% @private
index_update(_, _, undefined) ->
    undefined;

index_update(Scope, Id, Index) when is_map(Scope) ->
    index_update(scope_to_tuple(Scope), Id, Index);

index_update({_, _, _} = Key, Id, Index) ->
    lists:sort(lists:keystore(Key, 1, Index, {Key, Id})).


%% @private
is_expired(#{expires_at := Exp}) ->
    Exp =< ?NOW + ?LEEWAY_SECS.


%% @private
index_resolver(?TOMBSTONE, L) ->
    maybe_tombstone(remove_expired(L));

index_resolver(L, ?TOMBSTONE) ->
    maybe_tombstone(remove_expired(L));

index_resolver(L1, L2) when is_list(L1) andalso is_list(L2) ->
    %% Lists are sorted already as we sort them every time we put
    maybe_tombstone(
        remove_expired(lists:umerge(L1, L2))
    ).


%% @private
ticket_resolver(?TOMBSTONE, Ticket) ->
    case is_expired(Ticket) of
        true -> ?TOMBSTONE;
        Ticket -> Ticket
    end;

ticket_resolver(Ticket, ?TOMBSTONE) ->
    ticket_resolver(?TOMBSTONE, Ticket);

ticket_resolver(TicketA, TicketB) ->
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
