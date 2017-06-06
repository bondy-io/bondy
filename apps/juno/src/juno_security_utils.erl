-module(juno_security_utils).
-include_lib("wamp/include/wamp.hrl").
-include("juno.hrl").

-type auth_error_reason()       ::  realm_not_found 
                                    | {missing_param, binary()} 
                                    | {user_not_found, binary()}
                                    | {invalid_scheme, binary()}.

-type auth_scheme()                 ::  wampcra | basic | bearer | digest.                              
-type auth_scheme_val()             ::  {wampcra, binary(), binary(), map()}
                                    | {basic, binary(), binary()}
	                                | {bearer, binary()}
	                                | {digest, [{binary(), binary()}]}.


-export([authenticate/4]).


%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(
    auth_scheme(), auth_scheme_val(), uri(), juno_session:peer()) -> 
    {ok, juno_security:context() | map()} | {error, auth_error_reason()}.

authenticate(?TICKET_AUTH, {?TICKET_AUTH, AuthId, Signature}, Realm, Peer) ->
    authenticate(basic, {basic, AuthId, Signature}, Realm, Peer);
    
authenticate(?WAMPCRA_AUTH, {?WAMPCRA_AUTH, AuthId, Signature}, Realm, Peer) ->
    juno_security:authenticate(
        Realm, ?CHARS2LIST(AuthId), {hash, Signature}, conn_info(Peer));

authenticate(bearer, {bearer, Token}, Realm, _Peer) ->
    %% TODO support OAUTH2
    case juno_oauth2:verify_jwt(Realm, Token) of
        {true, Claims}  ->
           {ok, Claims};
        {expired, _} ->
            {error, invalid_token};
        {false, _Claims} ->
            {error, invalid_scheme}
    end;

authenticate(basic, {basic, Username, Pass}, Realm, Peer) ->
    juno_security:authenticate(
        Realm, ?CHARS2LIST(Username), Pass, conn_info(Peer));
    
authenticate(digest, {digest, _List}, _Realm, _Peer) ->
    %% TODO support
    {error, invalid_scheme};

authenticate(_, undefined, _Realm, _Peer) ->
    {error, invalid_scheme};

authenticate(_, _Scheme, _Realm, _Peer) ->
    {error, invalid_scheme}.



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
conn_info({IP, _Port}) ->
    [{ip, IP}].