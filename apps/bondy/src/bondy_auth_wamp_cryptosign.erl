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
        Key = maps_utils:get_path(
            [authextra, <<"pubkey">>], Details, undefined
        ),
        Key =/= undefined orelse throw(missing_pubkey),

        Keys = bondy_rbac_user:authorized_keys(bondy_auth:user(Ctxt)),

        case lists:member(Key, Keys) of
            true ->
                Message = enacl:randombytes(32),
                Extra = #{
                    challenge => hex_utils:bin_to_hexstr(Message),
                    channel_binding => undefined %% TODO
                },
                NewState = State#{
                    pubkey => Key,
                    expected_message => Message
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

authenticate(EncMessage, _, _, #{pubkey := PK} = State)
when is_binary(EncMessage) ->
    try
        SignedMessage = decode_hex(EncMessage),
        ExpectedMessage = maps:get(expected_message, State),

        %% Verify that the message was signed using the Ed25519 key
        case enacl:sign_open(SignedMessage, PK) of
            {ok, ExpectedMessage} ->
                {ok, #{}, State};

            {ok, _} ->
                %% Message does not match the expected
                {error, authentication_failed, State};

            {error, failed_verification} ->
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
    try hex_utils:hexstr_to_bin(HexString) of
        Bin when byte_size(Bin) == 96 ->
            Bin;
        _ ->
            throw(invalid_siognature_length)
    catch
        throw:Reason ->
            throw(Reason);
        error:_ ->
            throw(invalid_hex_encoding)
    end.





