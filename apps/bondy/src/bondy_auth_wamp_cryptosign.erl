%% =============================================================================
%%  bondy_auth_wamp_cryptosign.erl -
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
%% ## References
%% * [BrowserAuth](http://www.browserauth.net)
%% * [Binding Security Tokens to TLS Channels](https://www.ietf.org/proceedings/90/slides/slides-90-uta-0.pdf)
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_auth_wamp_cryptosign).

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

        true == bondy_rbac_user:has_authorized_keys(User)
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
    | {error, Reason :: any(), NewState :: state()}.

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
                % Message = enacl:randombytes(32),
                Message = <<187,172,178,156,100,104,78,221,32,249,69,117,86,248,250,66,113,22,86,98,229,238,44,121,191,227,190,84,187,131,183,38>>,

                NewState = State#{
                    pubkey => Key,
                    message => Message
                },

                Extra = #{
                    challenge => encode_hex(Message),
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
        Signature = decode_hex(EncSignature),
        Message = maps:get(message, State),

        %% Verify that the message was signed using the Ed25519 key
        case enacl:sign_verify_detached(Signature, Message, PK) of
            true ->
                {ok, #{}, State};

            false ->
                %% Message does not match the expected
                {error, invalid_signature, State}
        end
    catch
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



