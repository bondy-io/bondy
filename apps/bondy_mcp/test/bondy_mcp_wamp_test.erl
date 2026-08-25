%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Falsifiers for the pure MCP ⇄ WAMP mapping: §16.1's symmetric `@args`
%% flattening in both directions, §10.2's structured retryable
%% classification, the transport's header Value Encoding (sentinel decode
%% in both directions), RFC 6570 template binding with `uri_vars_schema`
%% coercion, and the wire `Tool` descriptor (camelCase annotations, the
%% permissive default input schema, the §7.5 hash in `_meta`).
-module(bondy_mcp_wamp_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% §16.1 arguments — both directions
%% =============================================================================

call_args_test() ->
    ?assertEqual(
        {ok, {[], #{<<"a">> => 1}}},
        bondy_mcp_wamp:call_args(#{<<"a">> => 1})
    ),
    ?assertEqual(
        {ok, {[1, 2], #{}}},
        bondy_mcp_wamp:call_args(#{<<"@args">> => [1, 2]})
    ),
    ?assertEqual(
        {ok, {[1], #{<<"n">> => <<"x">>}}},
        bondy_mcp_wamp:call_args(#{<<"@args">> => [1], <<"n">> => <<"x">>})
    ),
    %% @args must be a list; arguments must be an object.
    ?assertEqual(
        {error, badarg}, bondy_mcp_wamp:call_args(#{<<"@args">> => 1})
    ),
    ?assertEqual({error, badarg}, bondy_mcp_wamp:call_args([1])).

flatten_payload_test() ->
    ?assertEqual(#{}, bondy_mcp_wamp:flatten_payload([], #{})),
    ?assertEqual(#{}, bondy_mcp_wamp:flatten_payload(undefined, undefined)),
    ?assertEqual(
        #{<<"k">> => 1}, bondy_mcp_wamp:flatten_payload([], #{<<"k">> => 1})
    ),
    ?assertEqual(
        #{<<"@args">> => [1]}, bondy_mcp_wamp:flatten_payload([1], #{})
    ),
    ?assertEqual(
        #{<<"@args">> => [1], <<"k">> => 2},
        bondy_mcp_wamp:flatten_payload([1], #{<<"k">> => 2})
    ).

%% =============================================================================
%% Results and §10.2 errors
%% =============================================================================

call_result_test() ->
    R = bondy_mcp_wamp:call_result(#{
        request_id => 1,
        details => #{},
        args => [],
        kwargs => #{<<"total">> => 3}
    }),
    ?assertMatch(
        #{
            <<"resultType">> := <<"complete">>,
            <<"isError">> := false,
            <<"structuredContent">> := #{<<"total">> := 3},
            <<"content">> := [#{<<"type">> := <<"text">>, <<"text">> := _}]
        },
        R
    ),
    %% The compatibility text block is the JSON of structuredContent.
    #{<<"content">> := [#{<<"text">> := Text}]} = R,
    ?assertEqual(#{<<"total">> => 3}, json:decode(Text)).

call_error_classification_test() ->
    Retryable = fun(Uri) ->
        #{
            <<"isError">> := true,
            <<"structuredContent">> := #{<<"retryable">> := R},
            <<"_meta">> := #{<<"bondy:error_uri">> := Uri}
        } =
            bondy_mcp_wamp:call_error(#{
                error_uri => Uri, args => [], kwargs => #{}
            }),
        R
    end,
    %% Transient: declared but unregistered, no callee available, timeout.
    ?assert(Retryable(<<"wamp.error.no_such_procedure">>)),
    ?assert(Retryable(<<"wamp.error.no_available_callee">>)),
    ?assert(Retryable(<<"wamp.error.timeout">>)),
    %% Permanent for this principal: denial, and any application error.
    ?assertNot(Retryable(<<"wamp.error.not_authorized">>)),
    ?assertNot(Retryable(<<"com.acme.error.invoice_exists">>)),
    %% The error payload rides in structuredContent alongside the marker.
    ?assertMatch(
        #{<<"structuredContent">> := #{<<"reason">> := <<"dup">>}},
        bondy_mcp_wamp:call_error(#{
            error_uri => <<"com.acme.error.invoice_exists">>,
            args => [],
            kwargs => #{<<"reason">> => <<"dup">>}
        })
    ).

read_result_test() ->
    ?assertMatch(
        #{
            <<"resultType">> := <<"complete">>,
            <<"contents">> := [
                #{
                    <<"uri">> := <<"users:///1">>,
                    <<"mimeType">> := <<"application/json">>,
                    <<"text">> := _
                }
            ]
        },
        bondy_mcp_wamp:read_result(<<"users:///1">>, #{
            request_id => 1,
            details => #{},
            args => [],
            kwargs => #{<<"id">> => 1}
        })
    ).

%% =============================================================================
%% Tool descriptor
%% =============================================================================

tool_descriptor_test() ->
    Entry = #{
        realm => <<"r">>,
        name => <<"create_invoice">>,
        kind => tool,
        procedure => <<"com.acme.create">>,
        description => <<"Create">>,
        input_schema => #{<<"type">> => <<"object">>},
        output_schema => #{<<"type">> => <<"object">>},
        annotations => #{<<"destructive_hint">> => true, <<"x">> => 1},
        wamp_options => #{},
        source => #{},
        hash => <<"sha256:abc">>
    },
    ?assertEqual(
        #{
            <<"name">> => <<"create_invoice">>,
            <<"description">> => <<"Create">>,
            <<"inputSchema">> => #{<<"type">> => <<"object">>},
            <<"outputSchema">> => #{<<"type">> => <<"object">>},
            %% Overlay snake_case becomes the wire's camelCase; unknown
            %% annotation keys pass through.
            <<"annotations">> => #{<<"destructiveHint">> => true, <<"x">> => 1},
            <<"_meta">> => #{<<"bondy:hash">> => <<"sha256:abc">>}
        },
        bondy_mcp_wamp:tool_descriptor(Entry)
    ),
    %% No declared schema: the wire requires inputSchema, so the permissive
    %% object schema stands in; empty annotations are omitted.
    Minimal = bondy_mcp_wamp:tool_descriptor(#{
        realm => <<"r">>,
        name => <<"t">>,
        kind => tool,
        procedure => <<"p.q.r">>,
        annotations => #{},
        wamp_options => #{},
        source => #{},
        hash => <<"sha256:d">>
    }),
    ?assertEqual(
        #{<<"type">> => <<"object">>}, maps:get(<<"inputSchema">>, Minimal)
    ),
    ?assertNot(maps:is_key(<<"annotations">>, Minimal)),
    ?assertNot(maps:is_key(<<"description">>, Minimal)).

%% =============================================================================
%% Header value codec
%% =============================================================================

decode_header_value_test() ->
    ?assertEqual(
        {ok, <<"plain">>}, bondy_mcp_wamp:decode_header_value(<<"plain">>)
    ),
    Encoded = <<"=?base64?", (base64:encode(<<"café"/utf8>>))/binary, "?=">>,
    ?assertEqual(
        {ok, <<"café"/utf8>>}, bondy_mcp_wamp:decode_header_value(Encoded)
    ),
    %% A dangling sentinel is an error, not a passthrough: silently
    %% comparing the raw form would defeat the injection protection.
    ?assertEqual(
        {error, badarg},
        bondy_mcp_wamp:decode_header_value(<<"=?base64?xxx">>)
    ),
    ?assertEqual(
        {error, badarg},
        bondy_mcp_wamp:decode_header_value(<<"=?base64?!!not-b64!!?=">>)
    ).

encode_header_value_test() ->
    ?assertEqual({ok, <<"a">>}, bondy_mcp_wamp:encode_header_value(<<"a">>)),
    ?assertEqual({ok, <<"-7">>}, bondy_mcp_wamp:encode_header_value(-7)),
    ?assertEqual({ok, <<"true">>}, bondy_mcp_wamp:encode_header_value(true)),
    ?assertEqual({ok, <<"false">>}, bondy_mcp_wamp:encode_header_value(false)),
    ?assertEqual({error, badarg}, bondy_mcp_wamp:encode_header_value(#{})).

%% =============================================================================
%% Resource template binding
%% =============================================================================

template_entry() ->
    #{
        realm => <<"r">>,
        name => <<"user">>,
        kind => resource_template,
        procedure => <<"com.acme.users.get">>,
        uri_template => <<"users:///{id}">>,
        uri_vars_schema => #{<<"id">> => #{<<"type">> => <<"integer">>}},
        wamp_args => [],
        wamp_kwargs => #{<<"id">> => <<"{{id}}">>},
        annotations => #{},
        wamp_options => #{},
        source => #{},
        hash => <<"sha256:t">>
    }.

bind_template_test() ->
    %% The bound variable arrives TYPED (the schema says integer).
    ?assertEqual(
        {ok, {[], #{<<"id">> => 42}}},
        bondy_mcp_wamp:bind_template(template_entry(), <<"users:///42">>)
    ),
    ?assertEqual(
        nomatch,
        bondy_mcp_wamp:bind_template(template_entry(), <<"orders:///42">>)
    ),
    %% An empty capture is no match: expansion never produces one.
    ?assertEqual(
        nomatch,
        bondy_mcp_wamp:bind_template(template_entry(), <<"users:///">>)
    ),
    %% A value the declared type cannot carry rejects the read.
    ?assertEqual(
        {error, {invalid_var, <<"id">>}},
        bondy_mcp_wamp:bind_template(template_entry(), <<"users:///abc">>)
    ),
    %% Positional binding and embedded interpolation.
    E1 = (template_entry())#{
        uri_template => <<"files:///{box}/{name}">>,
        uri_vars_schema => #{
            <<"box">> => #{<<"type">> => <<"string">>},
            <<"name">> => #{<<"type">> => <<"string">>}
        },
        wamp_args => [<<"{{box}}">>],
        wamp_kwargs => #{<<"path">> => <<"{{box}}/{{name}}">>}
    },
    ?assertEqual(
        {ok, {[<<"inbox">>], #{<<"path">> => <<"inbox/a.txt">>}}},
        bondy_mcp_wamp:bind_template(E1, <<"files:///inbox/a.txt">>)
    ),
    %% Percent-encoded captures are decoded before use.
    ?assertEqual(
        {ok, {[<<"in box">>], #{<<"path">> => <<"in box/a.txt">>}}},
        bondy_mcp_wamp:bind_template(E1, <<"files:///in%20box/a.txt">>)
    ).

resolve_update_topic_test() ->
    %% A base resource: its own topic, only at its exact URI.
    Base = #{
        kind => resource,
        topic => <<"com.acme.ticks">>,
        uri => <<"wamp:r:com.acme.ticks">>
    },
    ?assertEqual(
        {ok, <<"com.acme.ticks">>},
        bondy_mcp_wamp:resolve_update_topic(Base, <<"wamp:r:com.acme.ticks">>)
    ),
    ?assertEqual(
        nomatch,
        bondy_mcp_wamp:resolve_update_topic(Base, <<"wamp:r:other">>)
    ),
    %% A template with an update_topic: the bound variable interpolates.
    WithTopic = (template_entry())#{
        update_topic => <<"com.acme.users.{{id}}.changed">>
    },
    ?assertEqual(
        {ok, <<"com.acme.users.42.changed">>},
        bondy_mcp_wamp:resolve_update_topic(WithTopic, <<"users:///42">>)
    ),
    ?assertEqual(
        nomatch,
        bondy_mcp_wamp:resolve_update_topic(WithTopic, <<"orders:///42">>)
    ),
    %% A variable failing its declared schema is silence, not an error —
    %% the subscription filter omits, it does not reject.
    ?assertEqual(
        nomatch,
        bondy_mcp_wamp:resolve_update_topic(WithTopic, <<"users:///abc">>)
    ),
    %% A matching template with no update source is distinguishable from
    %% a non-match.
    ?assertEqual(
        no_update_topic,
        bondy_mcp_wamp:resolve_update_topic(template_entry(), <<"users:///42">>)
    ),
    %% Tools have no update stream.
    ?assertEqual(
        nomatch,
        bondy_mcp_wamp:resolve_update_topic(
            #{kind => tool, procedure => <<"p.q">>}, <<"users:///42">>
        )
    ).

input_required_test() ->
    Elicit = #{
        <<"method">> => <<"elicitation/create">>,
        <<"params">> => #{<<"message">> => <<"who?">>}
    },
    %% Requests only, state only, and both are each a valid signal.
    ?assertMatch(
        {ok, #{input_requests := #{<<"q">> := _}, state := undefined}},
        bondy_mcp_wamp:input_required(#{
            kwargs => #{<<"input_requests">> => #{<<"q">> => Elicit}}
        })
    ),
    ?assertMatch(
        {ok, #{input_requests := R, state := <<"s">>}} when map_size(R) == 0,
        bondy_mcp_wamp:input_required(#{kwargs => #{<<"state">> => <<"s">>}})
    ),
    ?assertMatch(
        {ok, #{state := <<"s">>}},
        bondy_mcp_wamp:input_required(#{
            kwargs => #{
                <<"input_requests">> => #{<<"q">> => Elicit},
                <<"state">> => <<"s">>
            }
        })
    ),
    %% Neither present is a callee bug — the wire result MUST carry one.
    ?assertEqual(
        {error, badarg}, bondy_mcp_wamp:input_required(#{kwargs => #{}})
    ),
    ?assertEqual({error, badarg}, bondy_mcp_wamp:input_required(#{})),
    %% A request type outside the spec's three is refused whole.
    ?assertEqual(
        {error, badarg},
        bondy_mcp_wamp:input_required(#{
            kwargs => #{
                <<"input_requests">> => #{
                    <<"q">> => Elicit#{<<"method">> => <<"tools/call">>}
                }
            }
        })
    ),
    %% Shapeless request values are refused whole.
    ?assertEqual(
        {error, badarg},
        bondy_mcp_wamp:input_required(#{
            kwargs => #{<<"input_requests">> => #{<<"q">> => <<"nope">>}}
        })
    ),
    %% A JSON null for either field is absence, not a value.
    ?assertEqual(
        {error, badarg},
        bondy_mcp_wamp:input_required(#{
            kwargs => #{<<"input_requests">> => null, <<"state">> => null}
        })
    ).

input_required_result_test() ->
    Elicit = #{<<"method">> => <<"elicitation/create">>, <<"params">> => #{}},
    ?assertEqual(
        #{
            <<"resultType">> => <<"input_required">>,
            <<"inputRequests">> => #{<<"q">> => Elicit},
            <<"requestState">> => <<"sealed">>
        },
        bondy_mcp_wamp:input_required_result(#{<<"q">> => Elicit}, <<"sealed">>)
    ),
    %% Empty requests and no state each OMIT their key, never emit empties.
    ?assertEqual(
        #{
            <<"resultType">> => <<"input_required">>,
            <<"requestState">> => <<"sealed">>
        },
        bondy_mcp_wamp:input_required_result(#{}, <<"sealed">>)
    ),
    ?assertEqual(
        #{
            <<"resultType">> => <<"input_required">>,
            <<"inputRequests">> => #{<<"q">> => Elicit}
        },
        bondy_mcp_wamp:input_required_result(#{<<"q">> => Elicit}, undefined)
    ).

%% =============================================================================
%% SEP-414 trace context — both directions
%% =============================================================================

-define(TP, <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>).
-define(TS, <<"congo=t61rcWkgMzE">>).
-define(BG, <<"userId=alice">>).

trace_options_test() ->
    Meta = #{
        <<"traceparent">> => ?TP,
        <<"tracestate">> => ?TS,
        <<"baggage">> => ?BG,
        %% Alongside the protocol keys every modern request carries.
        <<"io.modelcontextprotocol/protocolVersion">> => <<"2026-07-28">>
    },
    ?assertEqual(
        #{'_traceparent' => ?TP, '_tracestate' => ?TS, '_baggage' => ?BG},
        bondy_mcp_wamp:trace_options(#{<<"_meta">> => Meta})
    ),
    %% traceparent alone maps alone — no invented siblings.
    ?assertEqual(
        #{'_traceparent' => ?TP},
        bondy_mcp_wamp:trace_options(
            #{<<"_meta">> => #{<<"traceparent">> => ?TP}}
        )
    ),
    %% W3C rule: tracestate/baggage WITHOUT a traceparent map to nothing.
    ?assertEqual(
        #{},
        bondy_mcp_wamp:trace_options(
            #{<<"_meta">> => #{<<"tracestate">> => ?TS, <<"baggage">> => ?BG}}
        )
    ),
    %% No _meta, empty _meta, non-map _meta: nothing maps, nothing raises.
    ?assertEqual(#{}, bondy_mcp_wamp:trace_options(#{})),
    ?assertEqual(
        #{}, bondy_mcp_wamp:trace_options(#{<<"_meta">> => #{}})
    ),
    ?assertEqual(
        #{}, bondy_mcp_wamp:trace_options(#{<<"_meta">> => 5})
    ),
    %% Non-string values are client garbage: a non-string traceparent
    %% voids the context; a non-string sibling is dropped alone.
    ?assertEqual(
        #{},
        bondy_mcp_wamp:trace_options(
            #{<<"_meta">> => #{<<"traceparent">> => 42}}
        )
    ),
    ?assertEqual(
        #{'_traceparent' => ?TP},
        bondy_mcp_wamp:trace_options(
            #{<<"_meta">> => #{<<"traceparent">> => ?TP, <<"baggage">> => 1}}
        )
    ).

trace_meta_test() ->
    Options = #{
        '_traceparent' => ?TP,
        '_tracestate' => ?TS,
        '_baggage' => ?BG,
        timeout => 5000
    },
    ?assertEqual(
        #{
            <<"traceparent">> => ?TP,
            <<"tracestate">> => ?TS,
            <<"baggage">> => ?BG
        },
        bondy_mcp_wamp:trace_meta(Options)
    ),
    ?assertEqual(
        #{<<"traceparent">> => ?TP},
        bondy_mcp_wamp:trace_meta(#{'_traceparent' => ?TP})
    ),
    %% W3C rule holds in this direction too.
    ?assertEqual(
        #{}, bondy_mcp_wamp:trace_meta(#{'_tracestate' => ?TS})
    ),
    ?assertEqual(#{}, bondy_mcp_wamp:trace_meta(#{})),
    %% The two directions are inverses over a full context.
    ?assertEqual(
        #{
            <<"traceparent">> => ?TP,
            <<"tracestate">> => ?TS,
            <<"baggage">> => ?BG
        },
        bondy_mcp_wamp:trace_meta(
            bondy_mcp_wamp:trace_options(#{
                <<"_meta">> => #{
                    <<"traceparent">> => ?TP,
                    <<"tracestate">> => ?TS,
                    <<"baggage">> => ?BG
                }
            })
        )
    ).
