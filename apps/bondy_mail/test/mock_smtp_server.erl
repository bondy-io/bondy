%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(mock_smtp_server).

-moduledoc """
A real SMTP server, in-process, for Common Test suites.

This is a `gen_smtp_server_session` callback module rather than a mock of the
client. That distinction is the point: stubbing `gen_smtp_client` would remove
exactly the part most likely to be wrong -- AUTH negotiation, a 4xx against a
5xx, a connection dropping mid-`DATA`, and the bytes actually on the wire. A
server speaks the protocol, so the code under test does too.

Modelled on `mock_auth_http_server` in `bondy_http_connector`, and offering the
same three things: failure injection, latency injection, and a record of what
was received.

The failures that are not reply codes are here too, because they are the ones a
mocked client could never produce: a relay that will not offer `STARTTLS` to a
client declared to require it, and a connection dropped mid-`DATA`.

    init_per_suite(Config) ->
        {ok, Port} = mock_smtp_server:start(),
        [{smtp_port, Port} | Config].

    my_test(_) ->
        ok = mock_smtp_server:fail_data("451 try again later"),
        %% ... send ...
        [Msg] = mock_smtp_server:messages(),
        ?assertEqual([~"user@example.com"], maps:get(to, Msg)).

Behaviour is held in a public ETS table owned by a keeper process, so it
survives the transient process that runs `init_per_suite/1` and can be changed
from a test case while the server is running.
""".

-behaviour(gen_smtp_server_session).

-define(TAB, ?MODULE).
-define(KEEPER, mock_smtp_server_keeper).
-define(REF, mock_smtp_server_listener).

-record(state, {}).

%% API
-export([auth_required/1]).
-export([clear/0]).
-export([fail_data/1]).
-export([fail_mail/1]).
-export([fail_rcpt/1]).
-export([fail_next_data/1]).
-export([drop_data/1]).
-export([starttls/1]).
-export([latency/1]).
-export([messages/0]).
-export([port/0]).
-export([start/0]).
-export([start/1]).
-export([stop/0]).

%% GEN_SMTP_SERVER_SESSION CALLBACKS
-export([code_change/3]).
-export([handle_AUTH/4]).
-export([handle_DATA/4]).
-export([handle_EHLO/3]).
-export([handle_HELO/2]).
-export([handle_MAIL/2]).
-export([handle_MAIL_extension/2]).
-export([handle_RCPT/2]).
-export([handle_RCPT_extension/2]).
-export([handle_RSET/1]).
-export([handle_STARTTLS/1]).
-export([handle_VRFY/2]).
-export([handle_other/3]).
-export([init/4]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Start the server on an ephemeral port.".
-spec start() -> {ok, inet:port_number()}.

start() ->
    start(0).

-doc "Start the server on `Port`, or an ephemeral port when `Port` is 0.".
-spec start(Port :: inet:port_number()) -> {ok, inet:port_number()}.

start(Port) ->
    ok = ensure_keeper(),
    {ok, _} = application:ensure_all_started(ranch),
    _ = gen_smtp_server:stop(?REF),
    {ok, _Pid} = gen_smtp_server:start(
        ?REF,
        ?MODULE,
        [
            [
                {port, Port},
                {address, {127, 0, 0, 1}},
                {hostname, "mock.test"},
                {sessionoptions, []}
            ]
        ]
    ),
    Actual = ranch:get_port(?REF),
    true = ets:insert(?TAB, {port, Actual}),
    {ok, Actual}.

-doc "Stop the server. Recorded messages are discarded.".
-spec stop() -> ok.

stop() ->
    _ = gen_smtp_server:stop(?REF),
    case whereis(?KEEPER) of
        undefined ->
            ok;
        Pid ->
            Ref = monitor(process, Pid),
            Pid ! stop,
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 5000 -> ok
            end
    end.

-doc "Return the port the server is listening on.".
-spec port() -> inet:port_number().

port() ->
    [{port, Port}] = ets:lookup(?TAB, port),
    Port.

-doc """
Discard recorded messages and every injected behaviour.

Call at the start of a test case: injected failures are sticky by design, so
that a case can assert a relay stays broken across several attempts.
""".
-spec clear() -> ok.

clear() ->
    Port = port(),
    true = ets:delete_all_objects(?TAB),
    true = ets:insert(?TAB, {port, Port}),
    ok.

-doc "Return every message accepted, oldest first.".
-spec messages() -> [map()].

messages() ->
    MS = [{{{message, '$1'}, '$2'}, [], [{{'$1', '$2'}}]}],
    [M || {_Seq, M} <- lists:keysort(1, ets:select(?TAB, MS))].

-doc """
Answer every `DATA` with `Reply` until cleared.

Use a `4xx` reply to exercise the transient path and a `5xx` to exercise the
permanent one -- that distinction is the whole of the classification contract.
""".
-spec fail_data(Reply :: string()) -> ok.

fail_data(Reply) ->
    set(fail_data, Reply).

-doc """
Answer the next `N` `DATA` commands with `Reply`, then behave normally.

This is what makes "retry, then succeed" testable: the relay refuses long
enough to force a retry and then accepts, so the case asserts recovery rather
than just failure.
""".
-spec fail_next_data({N :: pos_integer(), Reply :: string()}) -> ok.

fail_next_data({N, Reply}) ->
    set(fail_next_data, {N, Reply}).

-doc """
Drop the connection during `DATA` instead of answering it.

The failure a reply code cannot express: the relay accepted the message and
then went away, so the client never learns whether it was delivered. That has
to classify as transient -- it may well work next time -- and it arrives at the
client as a closed socket rather than as any part of the protocol.
""".
-spec drop_data(Enabled :: boolean()) -> ok.

drop_data(Enabled) ->
    set(drop_data, Enabled).

-doc """
Advertise `STARTTLS` in the `EHLO` response, or do not.

Off is the interesting setting: a relay declared `transport = starttls` must
fail rather than continue in plaintext, and the failure has to be permanent --
retrying a relay that does not offer an upgrade only repeats the same answer.
""".
-spec starttls(Enabled :: boolean()) -> ok.

starttls(Enabled) ->
    set(starttls, Enabled).

-doc "Answer every `MAIL FROM` with `Reply` until cleared.".
-spec fail_mail(Reply :: string()) -> ok.

fail_mail(Reply) ->
    set(fail_mail, Reply).

-doc "Answer every `RCPT TO` with `Reply` until cleared.".
-spec fail_rcpt(Reply :: string()) -> ok.

fail_rcpt(Reply) ->
    set(fail_rcpt, Reply).

-doc """
Require authentication, and accept only `{Username, Password}`.

Advertising AUTH is what makes the client attempt it, so this also exercises
`auth = if_available`.
""".
-spec auth_required({Username :: string(), Password :: string()} | false) -> ok.

auth_required(Value) ->
    set(auth, Value).

-doc "Delay every `DATA` by `Millis`, to exercise timeouts.".
-spec latency(Millis :: non_neg_integer()) -> ok.

latency(Millis) ->
    set(latency, Millis).

%% =============================================================================
%% GEN_SMTP_SERVER_SESSION CALLBACKS
%% =============================================================================

-doc false.
init(Hostname, _SessionCount, _Address, _Options) ->
    {ok, [Hostname, " ESMTP mock_smtp_server"], #state{}}.

-doc false.
handle_HELO(_Hostname, State) ->
    {ok, 655360, State}.

-doc false.
handle_EHLO(_Hostname, Extensions0, State) ->
    Extensions =
        case get(starttls, true) of
            true -> Extensions0;
            false -> proplists:delete("STARTTLS", Extensions0)
        end,
    Advertised =
        case get(auth, false) of
            false ->
                Extensions;
            _ ->
                %% CRAM-MD5 is deliberately not advertised. It sends a digest
                %% rather than the password, so this mock cannot tell a right
                %% credential from a wrong one -- and a client that picked it
                %% would make every authentication case pass regardless of what
                %% was configured.
                Extensions ++ [{"AUTH", "PLAIN LOGIN"}]
        end,
    {ok, Advertised, State}.

-doc false.
handle_AUTH(_Type, Username, Password, State) ->
    case get(auth, false) of
        false ->
            error;
        {U, P} ->
            Ok =
                to_list(Username) == U andalso
                    credential_matches(Password, P),
            case Ok of
                true -> {ok, State};
                false -> error
            end
    end.

-doc false.
handle_STARTTLS(State) ->
    State.

-doc false.
handle_MAIL(From, State) ->
    true = record(mail_from, unbracket(From)),
    case get(fail_mail, undefined) of
        undefined -> {ok, State};
        Reply -> {error, Reply, State}
    end.

-doc false.
handle_MAIL_extension(_Extension, _State) ->
    error.

-doc false.
handle_RCPT(To, State) ->
    true = record(rcpt_to, unbracket(To)),
    case get(fail_rcpt, undefined) of
        undefined -> {ok, State};
        Reply -> {error, Reply, State}
    end.

-doc false.
handle_RCPT_extension(_Extension, _State) ->
    error.

-doc false.
handle_DATA(From, To, Data, State) ->
    ok = maybe_sleep(),
    case get(drop_data, false) of
        true ->
            %% Kills the session process, which closes the socket without a
            %% reply. `gen_smtp_client` sees the close, not an SMTP code.
            exit(dropped);
        false ->
            ok
    end,
    case data_reply() of
        {error, Reply} ->
            {error, Reply, State};
        ok ->
            N = ets:update_counter(?TAB, message_seq, {2, 1}, {message_seq, 0}),
            Message = #{
                from => unbracket(From),
                to => [unbracket(R) || R <- To],
                data => Data,
                headers => parse_headers(Data)
            },
            true = ets:insert(?TAB, {{message, N}, Message}),
            {ok, integer_to_list(N), State}
    end.

-doc false.
handle_RSET(State) ->
    State.

-doc false.
handle_VRFY(_Address, State) ->
    {error, "252 unsupported", State}.

-doc false.
handle_other(_Verb, _Args, State) ->
    {"500 unsupported", State}.

-doc false.
terminate(Reason, State) ->
    {ok, Reason, State}.

-doc false.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% A sticky failure applies until cleared; a counted one decrements and then
%% lets the message through, which is what "retry then succeed" needs.
data_reply() ->
    case get(fail_data, undefined) of
        undefined -> counted_reply();
        Reply -> {error, Reply}
    end.

%% @private
counted_reply() ->
    case get(fail_next_data, undefined) of
        undefined ->
            ok;
        {N, Reply} when N > 1 ->
            ok = set(fail_next_data, {N - 1, Reply}),
            {error, Reply};
        {1, Reply} ->
            true = ets:delete(?TAB, fail_next_data),
            {error, Reply};
        _ ->
            ok
    end.

%% @private
maybe_sleep() ->
    case get(latency, 0) of
        0 -> ok;
        Millis -> timer:sleep(Millis)
    end.

%% @private
%% Only PLAIN and LOGIN are advertised, so the credential always arrives as the
%% password itself. Anything else is refused rather than waved through: a mock
%% that accepts what it cannot check turns every authentication case green.
credential_matches(Password, Expected) when is_binary(Password) ->
    to_list(Password) == Expected;
credential_matches(_Other, _Expected) ->
    false.

%% @private
%% SMTP puts a path in angle brackets. Recording the bare address keeps the
%% assertions in a suite about addresses rather than about envelope syntax.
unbracket(<<$<, Rest/binary>>) ->
    case binary:last(Rest) of
        $> -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> <<$<, Rest/binary>>
    end;
unbracket(Other) ->
    Other.

%% @private
record(Key, Value) ->
    N = ets:update_counter(?TAB, {seq, Key}, {2, 1}, {{seq, Key}, 0}),
    ets:insert(?TAB, {{Key, N}, Value}).

%% @private
%% Only the header block, which is what assertions are made against. The body
%% is kept whole in `data`.
parse_headers(Data) ->
    case binary:split(Data, ~"\r\n\r\n") of
        [Block, _Body] -> header_lines(Block);
        _ -> #{}
    end.

%% @private
header_lines(Block) ->
    Lines = binary:split(Block, ~"\r\n", [global]),
    lists:foldl(
        fun(Line, Acc) ->
            case binary:split(Line, ~": ") of
                [Name, Value] -> maps:put(string:lowercase(Name), Value, Acc);
                _ -> Acc
            end
        end,
        #{},
        Lines
    ).

%% @private
set(Key, Value) ->
    true = ets:insert(?TAB, {Key, Value}),
    ok.

%% @private
get(Key, Default) ->
    case ets:lookup(?TAB, Key) of
        [{Key, Value}] -> Value;
        [] -> Default
    end.

%% @private
to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.

%% @private
ensure_keeper() ->
    case whereis(?KEEPER) of
        undefined ->
            Self = self(),
            _ = spawn(fun() -> keeper(Self) end),
            receive
                {?KEEPER, ready} -> ok
            after 5000 -> error(mock_smtp_server_keeper_timeout)
            end;
        _ ->
            ok
    end.

%% @private
keeper(Parent) ->
    true = register(?KEEPER, self()),
    _ = ets:new(?TAB, [named_table, public, set]),
    Parent ! {?KEEPER, ready},
    receive
        stop -> ok
    end.
