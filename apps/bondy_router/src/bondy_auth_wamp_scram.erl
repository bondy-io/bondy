%% =============================================================================
%%  bondy_auth_wamp_scram.erl -
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

-module(bondy_auth_wamp_scram).
-moduledoc """
Implements the WAMP SCRAM authentication method as a `bondy_auth` callback
module, performing the SCRAM challenge/response exchange and verifying the
client proof against the user's stored SCRAM password.
""".
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

-spec init(bondy_auth:context()) ->
    {ok, State :: state()} | {error, Reason :: any()}.

init(Ctxt) ->
    try
        %% TODO Fix this we should carry on with the challenge
        User = bondy_auth:user(Ctxt),
        User =/= undefined orelse throw(invalid_context),

        PWD = bondy_rbac_user:password(User),
        User =/= undefined andalso bondy_password:protocol(PWD) == scram orelse
            throw(invalid_context),

        {ok, maps:new()}
    catch
        throw:Reason ->
            {error, Reason}
    end.

-spec requirements() -> map().

requirements() ->
    #{
        identification => true,
        password => {true, #{protocols => [scram]}},
        authorized_keys => false
    }.

-spec challenge(
    Details :: map(), AuthCtxt :: bondy_auth:context(), State :: state()
) ->
    {true, Extra :: map(), NewState :: state()}
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
                %% No user exists for the provided authid (username). Fail via
                %% the normal error channel — throw (not error/1) so the catch
                %% below returns {error, authentication_failed, State}, which the
                %% router maps to the SAME generic ABORT as a wrong
                %% password/signature (bondy_wamp_protocol:abort_message/1). This
                %% prevents the client from telling "no such user" from "bad
                %% credentials" via the ABORT reason.
                %%
                %% NOTE: a fuller anti-enumeration SCRAM would instead proceed to
                %% a *mock* challenge here (a deterministic fake salt/iteration
                %% count derived from the authid) so an unknown user still
                %% receives a CHALLENGE. Without it a residual behavioural oracle
                %% remains: an unknown user is ABORTed immediately whereas a real
                %% user receives a CHALLENGE first. Tracked as a follow-up.
                throw(authentication_failed);
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

-spec authenticate(
    Signature :: binary(),
    DataIn :: map(),
    Ctxt :: bondy_auth:context(),
    CBState :: state()
) ->
    {ok, DataOut :: map(), CBState :: state()}
    | {error, Reason :: any(), CBState :: state()}.

authenticate(Signature, Extra, Ctxt, State) ->
    try
        ClientProof = base64_decode(Signature),

        %% Validate nonce from AUTHENTICATE.Extra matches CHALLENGE nonce
        ServerNonce = maps:get(server_nonce, State),
        ExpectedNonce = base64:encode(ServerNonce),
        RNonce = maps:get(<<"nonce">>, Extra, undefined),
        RNonce =:= ExpectedNonce orelse throw(invalid_nonce),

        %% Validate channel_binding matches HELLO
        CBindType = maps:get(channel_binding, State),
        RCBindType = maps:get(<<"channel_binding">>, Extra, undefined),
        RCBindType =:= CBindType orelse throw(invalid_channel_binding_type),

        do_authenticate(ClientProof, Ctxt, State)
    catch
        throw:Reason ->
            {error, Reason, State}
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
    {Nonce, CBindType};
parse_details(_) ->
    throw(missing_nonce).

%% @private
do_challenge(#{channel_binding := undefined} = State) ->
    #{client_nonce := ClientNonce, password := PWD} = State,

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

    ServerNonce = bondy_password_scram:server_nonce(ClientNonce),

    ChallengeExtra = #{
        nonce => base64:encode(ServerNonce),
        salt => base64:encode(Salt),
        kdf => KDF,
        iterations => Iterations,
        memory => Memory
    },

    NewState = State#{server_nonce => ServerNonce},

    {true, ChallengeExtra, NewState};
do_challenge(#{channel_binding := _} = State) ->
    {error, unsupported_channel_binding_type, State}.

%% @private
do_authenticate(ClientProof, Ctxt, State) ->
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
    % We do not support channel binding yet
    CBindData = undefined,

    AuthMessage = bondy_password_scram:auth_message(
        AuthId, ClientNonce, ServerNonce, Salt, Iterations, CBindType, CBindData
    ),
    ClientSignature = bondy_password_scram:client_signature(
        StoredKey, AuthMessage
    ),

    %% `recovered_client_key/2` is `crypto:exor/2`, which raises on operands of
    %% different sizes. `ClientProof` is whatever the client sent, so without
    %% this check a proof of the wrong length aborts the connection with a
    %% crash instead of an authentication failure -- reachable pre-auth by
    %% anyone who can reach the listener.
    case byte_size(ClientProof) =:= byte_size(ClientSignature) of
        false ->
            {error, authentication_failed, State};

        true ->
            RecClientKey = bondy_password_scram:recovered_client_key(
                ClientProof, ClientSignature
            ),
            RecStoredKey = bondy_password_scram:recovered_stored_key(
                RecClientKey
            ),

            %% SECURITY: constant-time. Matching `StoredKey` as a case pattern
            %% instead would compare byte-by-byte and stop at the first
            %% difference, so response time would reveal how much of the
            %% stored key a guess recovered.
            case bondy_password_scram:compare(RecStoredKey, StoredKey) of
                true ->
                    ServerSignature = bondy_password_scram:server_signature(
                        ServerKey, AuthMessage
                    ),
                    AuthExtra = #{
                        verifier =>
                            <<"v=", (base64:encode(ServerSignature))/binary>>
                    },
                    {ok, AuthExtra, State};

                false ->
                    {error, authentication_failed, State}
            end
    end.

%% TODO
%% if the authentication fails, the server SHALL respond with an ABORT message.
%% The server MAY include a SCRAM-specific error string in the ABORT message as
%% a Details.scram attribute. SCRAM error strings are listed in [RFC5802,
%% section 7](https://tools.ietf.org/html/rfc5802#section-7), under
%% server-error-value.
