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
-behaviour(bondy_auth_method).

-include("bondy_security.hrl").


%% bondy_auth_method CALLBACKS
-export([challenge/3]).
-export([authenticate/4]).



%% =============================================================================
%% bondy_auth_method CALLBACKS
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec challenge(
    bondy_security_user:t() | undefined,
    ReqDetails :: map(),
    bondy_context:t()) ->
    {ok, ChallengeExtra :: map(), ChallengeState :: map()}
    | {error, Reason :: any()}.

challenge(User, ReqDetails, _Ctxt) ->
    try
        case User of
            undefined ->
                %% This is the case were there was no user for the provided authid
                %% (username) and to avoid disclosing that information to an attacker we
                %% will continue with the challenge.
                challenge(undefined, ReqDetails, undefined);
            _ ->
                PWD = bondy_security_user:password(User),
                do_challenge(User, ReqDetails, PWD)
        end
    catch
        throw:Reason ->
            {error, Reason}
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec authenticate(
    EncodedSignature :: binary(),
    Extra :: any(),
    ChallengeState :: map(),
    Ctxt :: bondy_context:t()) ->
    {ok, Extra :: map()} | {error, Reason :: any()}.

authenticate(EncSignature, Extra, ChallengeState, Ctxt) ->
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
        ServerNonce = maps:get(server_nonce, ChallengeState),
        CBindType = maps:get(channel_binding, ChallengeState),
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
            ChallengeState,
            Ctxt
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
    CBindType = maps:get(<<"channel_binding">>, Map, undefined),
    {Nonce, CBindType};

parse_details(_) ->
    {undefined, undefined}.


%% @private
do_challenge(undefined, _, undefined) ->
    error(not_implemented);

do_challenge(_, _, undefined) ->
    {error, missing_password};

do_challenge(User, Details, #{protocol := scram} = Password) ->
    {EncodedNonce, CBindType} = parse_details(Details),
    ClientNonce = base64_decode(EncodedNonce),
    gen_challenge(User, Details, Password, ClientNonce, CBindType);

do_challenge(_, _, #{protocol := _}) ->
    {error, unsupported_password_protocol}.


%% @private
gen_challenge(_, _, _, undefined, _) ->
    {error, missing_nonce};

gen_challenge(_, _, _, _, CBindType) when CBindType =/= undefined ->
    {error, unsupported_channel_binding_type};

gen_challenge(User, Details, Password, ClientNonce, undefined = CBindType) ->
    %% Throws invalid_authrole
    Role = bondy_auth_method:valid_authrole(
        maps:get(authrole, Details, <<"user">>),
        User
    ),

    ServerNonce = bondy_password_scram:server_nonce(ClientNonce),
    Params = maps:get(params, Password),
    #{kdf := KDF, iterations := Iterations, salt := Salt} = Params,
    Memory = maps:get(memory, Params, null),

    ChallengeExtra = #{
        nonce => base64:encode(ServerNonce),
        salt => base64:encode(Salt),
        kdf => KDF,
        iterations => Iterations,
        memory => Memory
    },

    ChallengeState =  #{
        authprovider => ?BONDY_AUTH_PROVIDER,
        authmethod => ?WAMPCRA_AUTH,
        authrole => Role,
        '_authroles' => bondy_security_user:groups(User),
        password => Password,
        client_nonce => ClientNonce,
        server_nonce => ServerNonce,
        channel_binding => CBindType
    },

    {ok, ChallengeExtra, ChallengeState}.


%% @private
do_authenticate(RProof, ChallengeState, Ctxt) ->

    #{
        password := Password,
        client_nonce := ClientNonce,
        server_nonce := ServerNonce,
        channel_binding := CBindType
    } = ChallengeState,


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

    _Realm = bondy_context:realm_uri(Ctxt),
    AuthId = bondy_context:authid(Ctxt),
    {_IP, _} = bondy_context:peer(Ctxt),

    %% TODO Validate source with IP

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
    case bondy_password_scram:recovered_stored_key(RecClientKey) of
        StoredKey ->
            ServerSignature = bondy_password_scram:server_signature(
                ServerKey, AuthMessage
            ),
            AuthExtra = #{
                verifier => base64:encode(ServerSignature)
            },
            {ok, AuthExtra};
        _ ->
            {error, bad_password}
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