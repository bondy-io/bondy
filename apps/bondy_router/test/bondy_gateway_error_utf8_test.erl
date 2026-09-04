%% =============================================================================
%% EUnit suite for the UTF-8 safety of the HTTP gateway's MOPS error bodies.
%%
%% Every gateway error is rendered as a JSON body, and `json:encode/1` raises
%% `invalid_byte` / `unexpected_end` on a binary that is not valid UTF-8.
%%
%% `mops_eval/2,3` builds its `invalid_expression` message with
%% `io_lib:format("~p", [Term])`. With the default `printable_range` of
%% `latin1`, `~p` renders a binary whose bytes form a printable latin-1 run as
%% `<<"...">>` with those bytes VERBATIM — so the message is latin-1, not
%% UTF-8. `Term` is a runtime value out of the request context or an action
%% response (a backend HTTP body, a WAMP payload), so its bytes are not ours
%% to choose. The error path then raises while reporting an error, turning a
%% 400 into a 500 and losing the diagnostic entirely.
%%
%% These cases drive the real `mops_eval` in both gateway modules with
%% `mops:eval/2,3` mocked to raise the exact error they catch.
%% =============================================================================

-module(bondy_gateway_error_utf8_test).

-include_lib("eunit/include/eunit.hrl").

%% Values whose `~p` rendering is a printable latin-1 run, i.e. raw high bytes
%% on the wire. `sha256` is the everyday case: any binary hash has a ~4-in-10000
%% chance of rendering this way, and `ascii` is the control that must keep
%% working.
payloads() ->
    [
        {"latin1-word", <<"caf", 233>>},
        {"high-run", <<200, 201, 202, 203>>},
        {"nbsp", <<"a", 160, "b">>},
        {"all-255", <<255, 255>>},
        {"valid-utf8", <<195, 169>>},
        {"sha256", crypto:hash(sha256, <<"x">>)},
        {"ascii", <<"plain">>},
        {"nested-in-map", #{k => <<"caf", 233>>}},
        {"nested-in-list", [<<"caf", 233>>, ok, 1]}
    ].

setup() ->
    ok = meck:new(mops, [passthrough, non_strict]),
    ok.

cleanup(_) ->
    _ = meck:unload(mops),
    ok.

%% The property under test: whatever the gateway throws must survive
%% `json:encode/1`, because that is the next thing that happens to it.
assert_encodable(Label, Thrown) ->
    Encoded =
        try
            {ok, iolist_to_binary(json:encode(Thrown))}
        catch
            Class:Reason -> {raised, Class, Reason}
        end,
    ?assertMatch({Label, {ok, _}}, {Label, Encoded}).

utf8_error_bodies_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"rest_handler builds an encodable body", fun rest_handler_bodies/0},
        {"api_spec_parser builds an encodable body", fun spec_parser_bodies/0},
        {"the offending value is still shown", fun value_is_reported/0},
        {"the message stays readable", fun message_is_readable/0},
        {"a non-UTF-8 expression is also survivable",
            fun non_utf8_expression/0},
        {"a huge value cannot inflate the body", fun body_is_bounded/0}
    ]}.

%% `Term` is a runtime value out of an action response, so its size is chosen
%% by an upstream service, not by us. Rendering it whole turns a small
%% malformed request into an arbitrarily large 400 body and log line.
%% `bondy_error:format_term/1` caps it; a bare `io_lib:format("~p", ...)` at
%% the call site does not, which is what these modules used to do.
body_is_bounded() ->
    Expr = <<"{{action.result}}">>,
    Big = binary:copy(<<"A">>, 200_000),
    ok = meck:expect(mops, eval, fun(_E, _C, _O) ->
        error({invalid_expression, [Expr, Big]})
    end),
    ok = meck:expect(mops, eval, fun(_E, _C) ->
        error({invalid_expression, [Expr, Big]})
    end),
    lists:foreach(
        fun({Label, Msg}) ->
            ?assertMatch(
                {_, true},
                {Label, byte_size(Msg) < 16_384}
            )
        end,
        [
            {"rest_handler",
                message_of(fun() ->
                    bondy_http_gateway_rest_handler:mops_eval(Expr, #{}, #{})
                end)},
            {"api_spec_parser",
                message_of(fun() ->
                    bondy_http_gateway_api_spec_parser:mops_eval(Expr, #{})
                end)}
        ]
    ).

%% `Term` is not the only untrusted binary in the message: `Expr` is
%% interpolated raw as well, and `mops:eval/2,3` echoes back whatever it was
%% handed. `iolist_to_binary/1` will happily build a latin-1 message out of it,
%% so the assembled message needs the same UTF-8 gate the value does. This is
%% what distinguishes the two converters — without this case, swapping the
%% gate back to `iolist_to_binary/1` passes every other test here.
non_utf8_expression() ->
    Expr = <<"{{caf", 233, "}}">>,
    ok = meck:expect(mops, eval, fun(_E, _C, _O) ->
        error({invalid_expression, [Expr, <<"v">>]})
    end),
    ok = meck:expect(mops, eval, fun(_E, _C) ->
        error({invalid_expression, [Expr, <<"v">>]})
    end),
    Thrown = [
        {"rest_handler",
            caught(fun() ->
                bondy_http_gateway_rest_handler:mops_eval(Expr, #{}, #{})
            end)},
        {"api_spec_parser",
            caught(fun() ->
                bondy_http_gateway_api_spec_parser:mops_eval(Expr, #{})
            end)}
    ],
    [assert_encodable(Label, T) || {Label, T} <- Thrown],
    %% Encodable is necessary, not sufficient: gating the ASSEMBLED message
    %% also passes this far, by rendering the whole of it as an Erlang term
    %% (`<<"There was an error ..."...>>`, or a list of binaries). Only the
    %% bad fragment may be rendered; the frame around it stays text, and the
    %% value fragment is untouched.
    Prefix = <<"There was an error evaluating the MOPS expression '">>,
    Size = byte_size(Prefix),
    lists:foreach(
        fun({Label, #{<<"message">> := Msg}}) ->
            ?assertMatch(
                {Label, <<Prefix:Size/binary, _/binary>>}, {Label, Msg}
            ),
            ?assertNotEqual(
                {Label, nomatch},
                {Label, binary:match(Msg, <<"' with value '<<\"v\">>'">>)}
            ),
            ?assertMatch(
                {_, true},
                {Label,
                    is_binary(unicode:characters_to_binary(Msg, utf8, utf8))}
            )
        end,
        Thrown
    ).

caught(Fun) ->
    try
        Fun()
    catch
        throw:T -> T
    end.

%% Encodability alone is a weak oracle for `rest_handler`, which already
%% survived `json:encode/1` before this was fixed — but only by accident.
%% `bondy_error:to_binary/1` gates on `is_utf8/1` and falls back to rendering
%% the whole message with `~p` when it fails, so a latin-1 message came out
%% escaped end-to-end and mojibake'd:
%%
%%   <<"<<\"...with value '<<\\\"cafÃ©\\\">>'\">>">>
%%
%% i.e. double-wrapped in `<<" ">>` and with `é` shown as `Ã©`. Building the
%% message as UTF-8 in the first place keeps that fallback from firing, so
%% these assertions are what actually pin the `rest_handler` change.
message_is_readable() ->
    Expr = <<"{{action.result}}">>,
    Value = <<"caf", 233>>,
    ok = meck:expect(mops, eval, fun(_E, _C, _O) ->
        error({invalid_expression, [Expr, Value]})
    end),
    ok = meck:expect(mops, eval, fun(_E, _C) ->
        error({invalid_expression, [Expr, Value]})
    end),
    Messages = [
        {"rest_handler",
            message_of(fun() ->
                bondy_http_gateway_rest_handler:mops_eval(Expr, #{}, #{})
            end)},
        {"api_spec_parser",
            message_of(fun() ->
                bondy_http_gateway_api_spec_parser:mops_eval(Expr, #{})
            end)}
    ],
    lists:foreach(
        fun({Label, Msg}) ->
            %% not escaped whole by the not-valid-UTF-8 fallback
            ?assertNotMatch({_, <<"<<\"", _/binary>>}, {Label, Msg}),
            %% the value reads as `café`, not as `cafÃ©`
            ?assertNotEqual(
                {Label, nomatch},
                {Label, binary:match(Msg, <<"caf", 195, 169>>)}
            ),
            ?assertEqual(
                {Label, nomatch},
                {Label, binary:match(Msg, <<"caf", 195, 131, 194, 169>>)}
            ),
            %% and it is still valid UTF-8
            ?assertMatch(
                {_, true},
                {Label,
                    is_binary(unicode:characters_to_binary(Msg, utf8, utf8))}
            )
        end,
        Messages
    ).

message_of(Fun) ->
    case
        try
            Fun()
        catch
            throw:T -> T
        end
    of
        #{<<"message">> := Msg} -> Msg
    end.

rest_handler_bodies() ->
    Expr = <<"{{action.result}}">>,
    lists:foreach(
        fun({Label, Term}) ->
            ok = meck:expect(mops, eval, fun(_E, _C, _O) ->
                error({invalid_expression, [Expr, Term]})
            end),
            Thrown =
                try
                    bondy_http_gateway_rest_handler:mops_eval(Expr, #{}, #{}),
                    no_throw
                catch
                    throw:T -> T
                end,
            ?assertNotEqual(no_throw, Thrown),
            assert_encodable(Label, Thrown)
        end,
        payloads()
    ).

spec_parser_bodies() ->
    Expr = <<"{{variables.foo}}">>,
    lists:foreach(
        fun({Label, Term}) ->
            ok = meck:expect(mops, eval, fun(_E, _C) ->
                error({invalid_expression, [Expr, Term]})
            end),
            Thrown =
                try
                    bondy_http_gateway_api_spec_parser:mops_eval(Expr, #{}),
                    no_throw
                catch
                    throw:T -> T
                end,
            ?assertNotEqual(no_throw, Thrown),
            assert_encodable(Label, Thrown)
        end,
        payloads()
    ).

%% Encodability must not be bought by dropping the value — the message exists
%% to tell the operator WHICH value failed. A test asserting only "does not
%% raise" would pass if the term were replaced by a constant.
value_is_reported() ->
    Expr = <<"{{variables.foo}}">>,
    ok = meck:expect(mops, eval, fun(_E, _C) ->
        error({invalid_expression, [Expr, <<"needle-12345">>]})
    end),
    Thrown =
        try
            bondy_http_gateway_api_spec_parser:mops_eval(Expr, #{})
        catch
            throw:T -> T
        end,
    Json = iolist_to_binary(json:encode(Thrown)),
    ?assertNotEqual(nomatch, binary:match(Json, <<"needle-12345">>)),
    ?assertNotEqual(nomatch, binary:match(Json, Expr)).
