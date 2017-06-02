-module(juno_security_utils).
-include_lib("wamp/include/wamp.hrl").
-include("juno.hrl").

-type auth_error_reason()       ::  realm_not_found 
                                    | {missing_param, binary()} 
                                | {user_not_found, binary()}.
-type auth_scheme()         ::  {wampcra, binary(), binary(), map()}
                                | {basic, binary(), binary()}
	                            | {bearer, binary()}
	                            | {digest, [{binary(), binary()}]}.


-export([authenticate/3]).


%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(auth_scheme(), uri(), juno_session:peer()) -> 
    {ok, juno_security:context()} | {error, auth_error_reason()}.

authenticate({?TICKET_AUTH, AuthId, Signature}, Realm, Peer) ->
    authenticate({basic, AuthId, Signature}, Realm, Peer);
    
authenticate({?WAMPCRA_AUTH, AuthId, Signature}, Realm, Peer) ->
    juno_security:authenticate(
        Realm, ?CHARS2LIST(AuthId), {hash, Signature}, conn_info(Peer));

authenticate({bearer, _Token}, _Realm, _Peer) ->
    %% TODO support OAUTH2
    {error, {unsupported_scheme, <<"Bearer">>}};

authenticate({basic, Username, Pass}, Realm, Peer) ->
    juno_security:authenticate(
        Realm, ?CHARS2LIST(Username), Pass, conn_info(Peer));
    
authenticate({digest, _List}, _Realm, _Peer) ->
    %% TODO support
    {error, {unsupported_scheme, <<"Digest">>}};

authenticate(undefined, _Realm, _Peer) ->
     {error, undefined_scheme};

authenticate(_, _Realm, _Peer) ->
    %% TODO support via plugins
     {error, unsupported_scheme}.





%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
conn_info(#{peer := {IP, _Port}}) ->
    [{ip, IP}].