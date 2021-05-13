%% =============================================================================
%%  bondy_auth_wamp_scram.erl -
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
-module(bondy_auth_wamp_scram).
-behaviour(bondy_auth).

-include("bondy_security.hrl").

-type state() :: map().

%% BONDY_AUTH CALLBACKS
-export([init/1]).
-export([requirements/0]).
-export([challenge/3]).
-export([authenticate/4]).



%% =============================================================================
%% BONDY_AUTH CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec init(bondy_auth:context()) ->
    {ok, State :: state()} | {error, Reason :: any()}.

init(Ctxt) ->
    try

        User = bondy_auth:user(Ctxt),
        User =/= undefined orelse throw(invalid_context),

        PWD = bondy_rbac_user:password(User),
        User =/= undefined andalso bondy_password:protocol(PWD) == scram
        orelse throw(invalid_context),

        {ok, maps:new()}

    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec requirements() -> map().

requirements() ->
    #{
        identification => true,
        password => {true, #{protocols => [scram]}},
        authorized_keys => false
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec challenge(
    Details :: map(), AuthCtxt :: bondy_auth:context(), State :: state()) ->
    {ok, Extra :: map(), NewState :: state()}
    | {error, Reason :: any(), NewState :: state()}.

challenge(Details, Ctxt, State0) ->
    try
        {EncodedNonce, CBindType} = parse_details(Details),
        State1 = State0#{
            client_nonce => base64_decode(EncodedNonce),
            channel_binding => CBindType
        },

        case bondy_auth:user(Ctxt) of
            undefined ->
                %% This is the case were there was no user for the provided
                %% authid (username) and to avoid disclosing that information
                %% to an attacker we will continue with the challenge.
                error(authentication_failed);
            _ ->
                User = bondy_auth:user(Ctxt),
                PWD = bondy_rbac_user:password(User),
                State2 = State1#{
                    user => User,
                    password => PWD
                },
                do_challenge(State2)
        end
    catch
        throw:Reason ->
            {error, Reason, State0}
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(
    Signature :: binary(),
    DataIn :: map(),
    Ctxt :: bondy_auth:context(),
    CBState :: state()) ->
    {ok, DataOut :: map(), CBState :: state()}
    | {error, Reason :: any(), CBState :: state()}.

authenticate(EncSignature, Extra, Ctxt, State) ->
    try
        %% Signature: The base64-encoded ClientProof
        %% nonce: The concatenated client-server nonce from the previous
        %% CHALLENGE message.
        %% channel_binding: Optional string containing the channel binding type
        %% that was sent in the original HELLO message.
        %% cbind_data: Optional base64-encoded channel binding data. MUST be
        %% present if and only if channel_binding is not null. The format of the
        %% binding data is dependent on the binding type.

        %% We need to check that:
        %% - The `AUTHENTICATE` message was received in due time (should be done
        %% already by bondy_wamp_protocol
        %% - nonce matches the one previously sent via CHALLENGE.
        %% - The channel_binding matches the one sent in the HELLO message.
        %% - The cbind_data sent by the client matches the channel binding data
        %% that the server sees on its side of the channel.
        ServerNonce = maps:get(server_nonce, State),
        CBindType = maps:get(channel_binding, State),
        CBindData = undefined, % We do not support channel binding yet

        RNonce = base64_decode(maps:get(<<"nonce">>, Extra, undefined)),
        RNonce == ServerNonce orelse throw(invalid_nonce),

        RCBindType = maps:get(<<"channel_binding">>, Extra, undefined),
        RCBindType == CBindType orelse throw(invalid_channel_binding_type),

        RCBindData = validate_cbind_data(RCBindType, CBindData),
        RCBindData =:= CBindData orelse throw(invalid_channel_binding_data),


        %% - The ClientProof is validated against the StoredKey and ServerKey
        %% stored in the User's password object
        do_authenticate(
            base64_decode(EncSignature),
            Ctxt,
            State
        )
    catch
        throw:Reason ->
            {error, Reason}
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
base64_decode(Nonce) ->
    try
        base64:decode(Nonce)
    catch
        _:_ ->
            throw(invalid_base64_format)
    end.


%% @private
parse_details(#{authextra := Map}) ->
    Nonce = maps:get(<<"nonce">>, Map, undefined),
    Nonce =/= undefined orelse throw(missing_nonce),

    CBindType = maps:get(<<"channel_binding">>, Map, undefined),
    {Nonce, CBindType}.


%% @private
do_challenge(#{channel_binding := undefined} = State) ->
    #{client_nonce := Nonce, password := PWD} = State,

    #{
        data := #{
            salt := Salt
        },
        params := #{
            kdf := KDF,
            iterations := Iterations
        } = Params
    } = PWD,

    %% Only in case KDF == argon2id13
    Memory = maps:get(memory, Params, null),

    ServerNonce = bondy_password_scram:server_nonce(Nonce),

    ChallengeExtra = #{
        nonce => base64:encode(ServerNonce),
        salt => base64:encode(Salt),
        kdf => KDF,
        iterations => Iterations,
        memory => Memory
    },

    NewState = State#{server_nonce => ServerNonce},

    {ok, ChallengeExtra, NewState};

do_challenge(#{channel_binding := _} = State) ->
    {error, unsupported_channel_binding_type, State}.


%% @private
do_authenticate(RProof, Ctxt, State) ->

    #{
        password := Password,
        client_nonce := ClientNonce,
        server_nonce := ServerNonce,
        channel_binding := CBindType
    } = State,


    #{
        data := #{
            salt := Salt,
            stored_key := StoredKey,
            server_key := ServerKey
        },
        params := #{
            iterations := Iterations
        }
    } = Password,

    AuthId = bondy_auth:user_id(Ctxt),
    CBindData = undefined, % We do not support channel binding yet

    AuthMessage = bondy_password_scram:auth_message(
        AuthId, ClientNonce, ServerNonce, Salt, Iterations, CBindType, CBindData
    ),
    ClientSignature = bondy_password_scram:client_signature(
        ServerKey, AuthMessage
    ),
    RecClientKey = bondy_password_scram:recovered_client_key(
        ClientSignature, RProof
    ),

    %% We finally compare the values
    case bondy_password_scram:recovered_stored_key(RecClientKey) of
        StoredKey ->
            ServerSignature = bondy_password_scram:server_signature(
                ServerKey, AuthMessage
            ),
            AuthExtra = #{
                verifier => base64:encode(ServerSignature)
            },
            {ok, AuthExtra, State};
        _ ->
            {error, authentication_failed, State}
    end.


validate_cbind_data(undefined, undefined) ->
    %% Not implemented yet
    ok.



%% TODO
%% if the authentication fails, the server SHALL respond with an ABORT message.
%% The server MAY include a SCRAM-specific error string in the ABORT message as
%% a Details.scram attribute. SCRAM error strings are listed in [RFC5802,
%% section 7](https://tools.ietf.org/html/rfc5802#section-7), under
%% server-error-value.