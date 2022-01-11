%% =============================================================================
%%  bondy_auth_wamp_cryptosign.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
%% ## References
%% * [BrowserAuth](http://www.browserauth.net)
%% * [Binding Security Tokens to TLS Channels](https://www.ietf.org/proceedings/90/slides/slides-90-uta-0.pdf)
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_auth_wamp_cryptosign).

-behaviour(bondy_auth).

-include("bondy_security.hrl").


-type state()           ::  map().
-type challenge_error() ::  missing_pubkey | no_matching_pubkey.


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

        User =/= undefined
        andalso true == bondy_rbac_user:has_authorized_keys(User)
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
        password => false,
        authorized_keys => true
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec challenge(
    Details :: map(), AuthCtxt :: bondy_auth:context(), State :: state()) ->
    {ok, Extra :: map(), NewState :: state()}
    | {error, challenge_error(), NewState :: state()}.

challenge(Details, Ctxt, State) ->
    try
        HexKey = maps_utils:get_path(
            [authextra, <<"pubkey">>], Details, undefined
        ),
        HexKey =/= undefined orelse throw(missing_pubkey),

        Key = decode_hex(HexKey),

        %% The stored keys are hex formatted so that we can easily compare here
        Keys = bondy_rbac_user:authorized_keys(bondy_auth:user(Ctxt)),

        case lists:member(Key, Keys) of
            true ->
                Challenge = enacl:randombytes(32),
                NewState = State#{
                    pubkey => Key,
                    challenge => Challenge
                },

                Extra = #{
                    challenge => encode_hex(Challenge),
                    channel_binding => undefined %% TODO
                },
                {ok, Extra, NewState};
            false ->
                {error, no_matching_pubkey, State}
        end
    catch
        throw:Reason ->
            {error, Reason, State}
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

authenticate(EncSignature, _, _, #{pubkey := PK} = State)
when is_binary(EncSignature) ->
    try
        Challenge = maps:get(challenge, State),
        Signature0 = decode_hex(EncSignature),
        Signature = normalise_signature(Signature0, Challenge),

        %% Verify that the Challenge was signed using the Ed25519 key
        case enacl:sign_verify_detached(Signature, Challenge, PK) of
            true ->
                {ok, #{}, State};

            false ->
                %% Challenge does not match the expected
                {error, invalid_signature, State}
        end
    catch
        error:badarg ->
            %% enacl failed
            {error, invalid_signature, State};
        error:invalid_signature ->
            %% normalise failed
            {error, invalid_signature, State};
        throw:invalid_hex_encoding ->
            {error, invalid_signature, State}
    end.





%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
decode_hex(HexString) ->
    try hex_utils:hexstr_to_bin(HexString)
    % of
    %     Bin when byte_size(Bin) == 96 ->
    %         Bin;
    %     _ ->
    %         throw(invalid_signature_length)
    catch
        throw:Reason ->
            throw(Reason);
        error:_ ->
            throw(invalid_hex_encoding)
    end.


%% @private
encode_hex(Bin) when is_binary(Bin) ->
    list_to_binary(hex_utils:bin_to_hexstr(Bin)).


%% @private
%% @doc As the cryptosign spec is not formal some clients e.g. Python
%% return Signature(64) ++ Challenge(32) while others e.g. JS return just the
%% Signature(64).
%% @end
normalise_signature(Signature, _) when byte_size(Signature) == 64->
    Signature;

normalise_signature(Signature, Challenge) when byte_size(Signature) == 96 ->
    case binary:match(Signature, Challenge) of
        {64, 32} ->
            binary:part(Signature, {0, 64});
        _ ->
            throw(invalid_signature)
    end;

normalise_signature(_, _) ->
    throw(invalid_signature).
