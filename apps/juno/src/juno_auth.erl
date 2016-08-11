%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2016. All rights reserved.
%% =============================================================================


-module(juno_auth).
-include("juno.hrl").
-include_lib("wamp/include/wamp.hrl").

-export([authenticate/2]).
-export([authenticate/3]).

-type error_reason()    ::  realm_not_found 
                            | {missing_param, binary()} 
                            | {user_not_found, binary()}.







%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(map(), juno_context:context()) -> 
    {ok, juno_context:context()} 
    | {challenge, 
        AuthMethod :: binary(), Challenge :: map(), juno_context:context()}
    | {error, error_reason(), juno_context:context()}.
authenticate(Details, #{realm_uri := Uri} = Ctxt) when is_map(Details) ->
    maybe_challenge(Details, get_realm(Uri), Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(binary(), map(), juno_context:context()) -> 
    {ok, juno_context:context()} 
    | {error, error_reason(), juno_context:context()}.
authenticate(Signature, Extra, #{authid := _, realm_uri := _Uri} = Ctxt) 
when is_binary(Signature), is_map(Extra) ->
    %% TODO    
    {ok, Ctxt}.


% authenticate(UserId, Details, Realm, Ctxt) ->



%% @private
maybe_challenge(_, not_found, #{realm_uri := Uri} = Ctxt) ->
    {error, {realm_not_found, Uri}, Ctxt};

maybe_challenge(#{authid := UserId} = Details, Realm, Ctxt0) ->
    Ctxt1 = Ctxt0#{authid => UserId, request_details => Details},
    case juno_realm:is_security_enabled(Realm) of
        true ->
            AuthMethods = maps:get(authmethods, Details, []),
            AuthMethod = juno_realm:select_auth_method(Realm, AuthMethods),
            % TODO Get User for Realm (change security module) and if not exist
            % return error else challenge
            case juno_user:lookup(UserId) of
                not_found ->
                    {error, {user_not_found, UserId}, Ctxt1};
                User ->
                    Ch = challenge(AuthMethod, User, Details, Ctxt1),
                    {challenge, AuthMethod, Ch, Ctxt1}
            end;
        false ->
            {ok, Ctxt1}
    end;

maybe_challenge(_, _, Ctxt) ->
    {error, {missing_param, <<"authid">>}, Ctxt}.


%% @private
challenge(?WAMPCRA_AUTH, User, Details, #{id := Id}) ->
    #{<<"username">> := UserId} = User,
    Ch0 = #{
        challenge => #{
            authmethod => ?WAMPCRA_AUTH,
            authid => UserId,
            authprovider => <<"juno">>, 
            authrole => maps:get(authrole, Details, <<"user">>), % @TODO
            nonce => juno_utils:get_nonce(),
            session => Id,
            timestamp => calendar:universal_time()
        }
    },
    
    case juno_user:password(User) of
        undefined ->
            Ch0;
        Pass ->
            #{
                auth_name := pbkdf2,
                hash_func := sha,
                iterations := Iter,
                salt := Salt
            } = Pass,
            Ch0#{
                salt => Salt,
                keylen => 16, % see juno_pw_auth.erl
                iterations => Iter
            }
    end;

challenge(?TICKET_AUTH, _UserId, _Details, _Ctxt) ->
    #{}.





%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
get_realm(Uri) ->
    case juno_config:automatically_create_realms() of
        true ->
            %% We force the creation of a new realm if it does not exist
            juno_realm:get(Uri);
        false ->
            %% Will throw an exception if it does not exist
            juno_realm:lookup(Uri)
    end.

