%% =============================================================================
%%  bondy_email_backend.erl -
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
%%
%% Copyright (c) 2012-2014 Kivra
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
%% =============================================================================


-module(bondy_email_backend).

-define(TIMEOUT, 120000). %gen_server:call/3


-type email()           ::  {binary(), binary()}.
-type message_element() ::  binary() | {html, binary()} | {text, binary()}.
-type message()         ::  message_element() | list(message_element()).
-type dirtyemailprim()  ::  atom() | list() | binary().
-type dirtyemail()      ::  {dirtyemailprim(), dirtyemailprim()}.
-type maybedirtyemail() ::  email() | dirtyemail() | dirtyemailprim().
-type host()            ::  inet:hostname() | inet:ip_address().
-type port_number()     ::  inet:port_number().

-export_type([email/0]).
-export_type([message/0]).

-export([send/5]).
-export([send/6]).
-export([start/4]).
-export([stop/3]).



%% =============================================================================
%% BACKEND CALLBACKS
%% =============================================================================



-callback start(Host :: host(), Port :: port_number(), Options :: key_value:t()) ->
    {ok, Ctxt :: map()} | {error, any()}.


-callback stop(Host :: host(), Port :: port_number()) -> ok | {error, any()}.


-callback send(
    To :: email(),
    From :: email(),
    Subject :: binary(),
    Message :: message(),
    Options :: any()) ->
    {ok, any()} | {error, any()}.



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start(
    Backend :: module(),
    Host :: host(),
    Port :: port_number(),
    Opts :: proplists:proplist()) -> {ok, Ctxt :: map()} | {error, any()}.

start(Backend, Host, Port, Opts) ->
    Backend:start(Host, Port, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec stop(Backend :: module(), Host :: host(), Port :: port_number()) -> ok.

stop(Backend, Host, Port) ->
    Backend:stop(Host, Port).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec send(Backend :: module(), maybedirtyemail(), maybedirtyemail(), binary(), message()) ->
    {ok, term()} | {error, term()}.

send(Backend, To, From, Subject, Message) ->
    send(Backend, To, From, Subject, Message, #{}).


%% -----------------------------------------------------------------------------
%% @doc Sends an email and returns ok or error depending on the outcome
%% @end
%% -----------------------------------------------------------------------------
-spec send(
    module(), maybedirtyemail(), maybedirtyemail(), binary(), message(), map()) ->
    {ok, term()} | {error, term()}.

send(Backend, To0, From0, Subject0, Message0, Options) ->
    To = sanitize_param(To0),
    From = sanitize_param(From0),
    Subject = ensure_binary(Subject0),
    Message = sanitize_message(Message0),

    Backend:send(
        To,
        From,
        Subject,
        Message,
        Options
    ).



%% =============================================================================
%% PRIVATE
%% =============================================================================



-spec sanitize_param(maybedirtyemail()) -> email().

sanitize_param({V1, V2}) ->
    {ensure_binary(V1), ensure_binary(V2)};

sanitize_param(Val) ->
    {ensure_binary(Val), ensure_binary(Val)}.

%% @private
sanitize_message({html, Msg}) ->
    [{<<"html">>, ensure_binary(Msg)}];

sanitize_message({text, Msg}) ->
    [{<<"text">>, ensure_binary(Msg)}];

sanitize_message(Msg) when is_list(Msg) ->
    lists:foldl(
        fun(Element, Acc) ->
            case Element of
                {html, H} -> [{<<"html">>, ensure_binary(H)} | Acc];
                {text, H} -> [{<<"text">>, ensure_binary(H)} | Acc]
            end
        end,
        [],
        Msg
    );

sanitize_message(Msg) ->
    [{<<"text">>, ensure_binary(Msg)}].


%% @private
ensure_binary(Term) when is_binary(Term) ->
    Term;

ensure_binary(Term) when is_list(Term) ->
    list_to_binary(Term);

ensure_binary(Term) when is_atom(Term) ->
    atom_to_binary(Term, utf8).
