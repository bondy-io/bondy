%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_wamp).

-moduledoc """
The MCP ⇄ WAMP semantic mapping (design §5.1, §10.2, §16), over
`bondy_json_rpc`'s codec: pure functions with no transport and no process.

- **Arguments** (§16.1, symmetric): the reserved `@args` key carries WAMP
  positional arguments; everything else is a kwarg. The same flattening
  shapes a WAMP `RESULT` into MCP `structuredContent` (§16.2).
- **Errors** (§10.2): a WAMP error becomes a SUCCESSFUL `tools/call`
  response with `isError: true`, a structured `retryable` marker — agents
  parse structure reliably and infer badly from prose — and the original
  error URI in `_meta."bondy:error_uri"`. `no_such_procedure` classifies
  as retryable because the gateway only dispatches manifest-DECLARED
  entries: the manifest declares surface and the registry decides liveness
  (§7.7), so an unregistered declared procedure is a transient gap, not a
  permanent absence.
- **Resource templates** (§16.3): RFC 6570 level-1 URI matching, variable
  validation against the entry's `uri_vars_schema` (type coercion for the
  scalar types), and `{{var}}` interpolation into the entry's WAMP
  binding.
- **Header value codec**: the Streamable HTTP transport's Value Encoding
  — scalar-to-string conversion and the `=?base64?...?=` sentinel for
  values outside RFC 9110's field-value character set — used by the
  handler's header/body cross-checks (§10.1).
- **MRTR** (§11.1): validation of the callee's
  `bondy.error.mcp.input_required` signal payload — `input_requests`
  values MUST be one of the three request types the spec admits — and the
  `InputRequiredResult` wire shape, of which at least one of
  `inputRequests` / `requestState` MUST be present.
- **Trace context** (SEP-414, §15.4): a request's `_meta.traceparent` /
  `tracestate` / `baggage` ⇄ the `'_traceparent'` / `'_tracestate'` /
  `'_baggage'` WAMP extension options, verbatim in both directions
  (`trace_options/1` inbound, `trace_meta/1` for the §13 client
  direction).
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(ARGS_KEY, <<"@args">>).

%% The three request types an `inputRequests` value MUST be (spec, MRTR
%% server requirements). `roots/list` and `sampling/createMessage` are
%% deprecated-but-functional upstream and valid here (MCP-D24).
-define(MRTR_METHODS, [
    <<"elicitation/create">>,
    <<"roots/list">>,
    <<"sampling/createMessage">>
]).

%% Overlay annotation spellings (snake_case, the operator-facing §18.4
%% form) to the MCP wire's ToolAnnotations camelCase. Unknown keys pass
%% through untouched.
-define(ANNOTATION_KEYS, #{
    <<"destructive_hint">> => <<"destructiveHint">>,
    <<"read_only_hint">> => <<"readOnlyHint">>,
    <<"idempotent_hint">> => <<"idempotentHint">>,
    <<"open_world_hint">> => <<"openWorldHint">>
}).

-export([bind_template/2]).
-export([call_args/1]).
-export([call_error/1]).
-export([call_result/1]).
-export([decode_header_value/1]).
-export([encode_header_value/1]).
-export([flatten_payload/2]).
-export([input_required/1]).
-export([input_required_result/2]).
-export([read_result/2]).
-export([resolve_update_topic/2]).
-export([resource_descriptor/1]).
-export([resource_template_descriptor/1]).
-export([tool_descriptor/1]).
-export([tool_result/1]).
-export([trace_meta/1]).
-export([trace_options/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
The WAMP call options carrying a request's trace context (SEP-414,
§15.4): `params._meta`'s `traceparent` / `tracestate` / `baggage` map
onto the router's declared `'_traceparent'` / `'_tracestate'` /
`'_baggage'` extension options, values verbatim — never parsed. Per W3C
Trace Context, `tracestate` (and Baggage alongside it) is meaningful
only with a `traceparent`, so without a string `traceparent` nothing
maps; non-string values are dropped. `#{}` when the request carries no
context, so the result merges into call options unconditionally.
""".
-spec trace_options(Params :: map()) -> map().

trace_options(#{<<"_meta">> := #{<<"traceparent">> := TP} = Meta}) when
    is_binary(TP)
->
    Opts =
        case Meta of
            #{<<"tracestate">> := TS} when is_binary(TS) ->
                #{'_traceparent' => TP, '_tracestate' => TS};
            _ ->
                #{'_traceparent' => TP}
        end,
    case Meta of
        #{<<"baggage">> := BG} when is_binary(BG) ->
            Opts#{'_baggage' => BG};
        _ ->
            Opts
    end;
trace_options(Params) when is_map(Params) ->
    #{}.

-doc """
The `_meta` entries carrying a WAMP message's trace context — the
inverse of `trace_options/1`, for the client direction (§13): the
`'_traceparent'` / `'_tracestate'` / `'_baggage'` extension options of
a CALL's options (what the dealer hands an internal callback) map onto
SEP-414's `traceparent` / `tracestate` / `baggage`, values verbatim.
`#{}` when the message carries none.
""".
-spec trace_meta(Options :: map()) -> map().

trace_meta(#{'_traceparent' := TP} = Options) when is_binary(TP) ->
    Meta =
        case Options of
            #{'_tracestate' := TS} when is_binary(TS) ->
                #{<<"traceparent">> => TP, <<"tracestate">> => TS};
            _ ->
                #{<<"traceparent">> => TP}
        end,
    case Options of
        #{'_baggage' := BG} when is_binary(BG) ->
            Meta#{<<"baggage">> => BG};
        _ ->
            Meta
    end;
trace_meta(Options) when is_map(Options) ->
    #{}.

-doc """
The WAMP `{Args, KwArgs}` of an MCP `arguments` object (§16.1 reversed):
`@args` carries the positional list, every other key is a kwarg.
""".
-spec call_args(Arguments :: map()) ->
    {ok, {Args :: list(), KwArgs :: map()}} | {error, badarg}.

call_args(Arguments) when is_map(Arguments) ->
    case maps:take(?ARGS_KEY, Arguments) of
        {Args, KwArgs} when is_list(Args) -> {ok, {Args, KwArgs}};
        {_, _} -> {error, badarg};
        error -> {ok, {[], Arguments}}
    end;
call_args(_) ->
    {error, badarg}.

-doc """
§16.2's flattening of a WAMP payload: kwargs pass through, positional
arguments ride under `@args`.
""".
-spec flatten_payload(Args :: list() | undefined, KwArgs :: map() | undefined) ->
    map().

flatten_payload(Args, KwArgs) ->
    Kw =
        case KwArgs of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    case Args of
        L when is_list(L), L =/= [] -> Kw#{?ARGS_KEY => L};
        _ -> Kw
    end.

-doc """
A `CallToolResult` from a `bondy:call/5` success
(`#{args, kwargs, details, ...}`).
""".
-spec call_result(ResultMap :: map()) -> map().

call_result(#{args := Args, kwargs := KwArgs}) ->
    Structured = flatten_payload(Args, KwArgs),
    #{
        <<"resultType">> => <<"complete">>,
        <<"structuredContent">> => Structured,
        <<"content">> => [text_content(Structured)],
        <<"isError">> => false
    }.

-doc """
The WAMP shape of an upstream `CallToolResult` (§16 reversed — the client
direction, §13): `structuredContent` splits into `{Args, KwArgs}` exactly
as `call_args/1` splits `arguments`, so positional arguments round-trip
through a chained Bondy upstream; a result with no structured content
carries its `content` list as the single `content` kwarg. `isError: true`
maps to the fixed URI `bondy.error.mcp.upstream_tool_error` — an
upstream's `_meta."bondy:error_uri"` is deliberately NOT resurfaced as
the WAMP error URI, because upstream output is untrusted (§13.3) and must
not mint URIs in our namespaces.
""".
-spec tool_result(map()) ->
    {ok, Args :: list(), KwArgs :: map()}
    | {error, Uri :: binary(), Args :: list(), KwArgs :: map()}.

tool_result(Result) when is_map(Result) ->
    Structured =
        case maps:get(<<"structuredContent">>, Result, undefined) of
            M when is_map(M) ->
                M;
            _ ->
                #{<<"content">> => maps:get(<<"content">>, Result, [])}
        end,
    {Args, KwArgs} =
        case call_args(Structured) of
            {ok, AK} ->
                AK;
            {error, badarg} ->
                %% A foreign upstream using `@args` with a non-list value:
                %% not our convention, so not an error — pass through.
                {[], Structured}
        end,
    case maps:get(<<"isError">>, Result, false) of
        true ->
            {error, <<"bondy.error.mcp.upstream_tool_error">>, Args, KwArgs};
        _ ->
            {ok, Args, KwArgs}
    end.

-doc """
A `CallToolResult` with `isError: true` from a `bondy:call/5` error
(`#{error_uri, args, kwargs, ...}`), classified per §10.2. `retryable` is
structured data inside `structuredContent`; the original WAMP error URI
rides in `_meta."bondy:error_uri"`.
""".
-spec call_error(ErrorMap :: map()) -> map().

call_error(#{error_uri := Uri} = Error) ->
    Args = maps:get(args, Error, []),
    KwArgs = maps:get(kwargs, Error, #{}),
    Structured = (flatten_payload(Args, KwArgs))#{
        <<"retryable">> => is_retryable(Uri)
    },
    #{
        <<"resultType">> => <<"complete">>,
        <<"structuredContent">> => Structured,
        <<"content">> => [text_content(Structured)],
        <<"isError">> => true,
        <<"_meta">> => #{<<"bondy:error_uri">> => Uri}
    }.

-doc """
Validates the payload of a callee's `bondy.error.mcp.input_required`
signal (§11.1): kwargs may carry `input_requests` — a map whose values
must each be `#{"method", "params"}` with a method the spec admits — and
`state`, the callee's opaque continuation. At least one of the two must be
present (the wire result MUST carry one). `{error, badarg}` is a CALLEE
bug — the handler answers it as an internal error, never forwards it.
""".
-spec input_required(ErrorMap :: map()) ->
    {ok, #{input_requests := map(), state := any()}} | {error, badarg}.

input_required(Error) when is_map(Error) ->
    KwArgs =
        case maps:get(kwargs, Error, #{}) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    Requests = absent_to(maps:get(<<"input_requests">>, KwArgs, #{}), #{}),
    State = absent_to(maps:get(<<"state">>, KwArgs, undefined), undefined),
    case
        is_map(Requests) andalso
            (map_size(Requests) > 0 orelse State =/= undefined) andalso
            lists:all(
                fun is_input_request/1, maps:to_list(Requests)
            )
    of
        true -> {ok, #{input_requests => Requests, state => State}};
        false -> {error, badarg}
    end.

-doc """
The `InputRequiredResult` wire shape: `inputRequests` when the callee
requested any, `requestState` when a continuation was sealed. The caller
guarantees at least one (`input_required/1` refused the signal otherwise).
""".
-spec input_required_result(
    InputRequests :: map(), SealedState :: undefined | binary()
) -> map().

input_required_result(InputRequests, SealedState) ->
    R0 = #{<<"resultType">> => <<"input_required">>},
    R1 =
        case map_size(InputRequests) of
            0 -> R0;
            _ -> R0#{<<"inputRequests">> => InputRequests}
        end,
    case SealedState of
        undefined -> R1;
        _ -> R1#{<<"requestState">> => SealedState}
    end.

-doc """
A `ReadResourceResult` carrying the flattened WAMP result as one JSON text
resource content at `Uri`.
""".
-spec read_result(Uri :: binary(), ResultMap :: map()) -> map().

read_result(Uri, #{args := Args, kwargs := KwArgs}) ->
    Structured = flatten_payload(Args, KwArgs),
    #{
        <<"resultType">> => <<"complete">>,
        <<"contents">> => [
            #{
                <<"uri">> => Uri,
                <<"mimeType">> => <<"application/json">>,
                <<"text">> => iolist_to_binary(json:encode(Structured))
            }
        ]
    }.

-doc """
The MCP `Resource` descriptor of a compiled manifest entry of kind
`resource`. Like `tool_descriptor/1`, the §7.5 content hash rides in
`_meta."bondy:hash"`.
""".
-spec resource_descriptor(bondy_mcp_spec:t()) -> map().

resource_descriptor(#{name := Name, kind := resource} = Entry) ->
    D0 = #{
        <<"uri">> => maps:get(uri, Entry),
        <<"name">> => Name,
        <<"_meta">> => #{<<"bondy:hash">> => maps:get(hash, Entry)}
    },
    maybe_put(<<"description">>, maps:get(description, Entry, undefined), D0).

-doc """
The MCP `ResourceTemplate` descriptor of a compiled manifest entry of
kind `resource_template`.
""".
-spec resource_template_descriptor(bondy_mcp_spec:t()) -> map().

resource_template_descriptor(
    #{name := Name, kind := resource_template} = Entry
) ->
    D0 = #{
        <<"uriTemplate">> => maps:get(uri_template, Entry),
        <<"name">> => Name,
        <<"_meta">> => #{<<"bondy:hash">> => maps:get(hash, Entry)}
    },
    maybe_put(<<"description">>, maps:get(description, Entry, undefined), D0).

-doc """
The MCP `Tool` descriptor of a compiled manifest entry
(`bondy_mcp_spec:t()` of kind `tool`). A tool with no declared input
schema advertises the permissive empty object schema — `inputSchema` is
required on the wire. The §7.5 content hash rides in
`_meta."bondy:hash"` so a client or reviewer can pin what it saw.
""".
-spec tool_descriptor(bondy_mcp_spec:t()) -> map().

tool_descriptor(#{name := Name, kind := tool} = Entry) ->
    D0 = #{
        <<"name">> => Name,
        <<"inputSchema">> => maps:get(
            input_schema, Entry, #{<<"type">> => <<"object">>}
        ),
        <<"_meta">> => #{<<"bondy:hash">> => maps:get(hash, Entry)}
    },
    D1 = maybe_put(
        <<"description">>, maps:get(description, Entry, undefined), D0
    ),
    D2 = maybe_put(
        <<"outputSchema">>, maps:get(output_schema, Entry, undefined), D1
    ),
    case maps:get(annotations, Entry, #{}) of
        Empty when map_size(Empty) == 0 -> D2;
        Annotations -> D2#{<<"annotations">> => wire_annotations(Annotations)}
    end.

-doc """
Matches `Uri` against a `resource_template` entry and, on a match, binds
the template variables — validated and coerced against the entry's
`uri_vars_schema` — into the entry's `wamp_args` / `wamp_kwargs`.
""".
-spec bind_template(bondy_mcp_spec:t(), Uri :: binary()) ->
    {ok, {Args :: list(), KwArgs :: map()}}
    | nomatch
    | {error, {invalid_var, binary()}}.

bind_template(#{kind := resource_template} = Entry, Uri) ->
    Template = maps:get(uri_template, Entry),
    case match_template(tokenize(Template), Uri, #{}) of
        {ok, Raw} ->
            try coerce_vars(Raw, maps:get(uri_vars_schema, Entry, #{})) of
                Vars ->
                    Args = [
                        interpolate(V, Vars)
                     || V <- maps:get(wamp_args, Entry, [])
                    ],
                    KwArgs = maps:map(
                        fun(_, V) -> interpolate(V, Vars) end,
                        maps:get(wamp_kwargs, Entry, #{})
                    ),
                    {ok, {Args, KwArgs}}
            catch
                throw:{invalid_var, _} = Reason -> {error, Reason}
            end;
        nomatch ->
            nomatch
    end.

-doc """
The WAMP topic behind one concrete resource URI's update stream (§9.2): a
base resource whose `uri` equals `Uri` names its `topic` directly; a
resource template that matches `Uri` and declares an `update_topic` yields
that topic with the bound (and schema-coerced) variables interpolated.
`no_update_topic` when the entry matches but declares no update source;
`nomatch` when it does not match `Uri`, when interpolation yields
something other than a binary, or when a bound variable fails its declared
schema — a subscription filter silently omits such entries, it does not
error.
""".
-spec resolve_update_topic(bondy_mcp_spec:t(), Uri :: binary()) ->
    {ok, Topic :: binary()} | no_update_topic | nomatch.

resolve_update_topic(#{kind := resource, topic := Topic, uri := Uri}, Uri) ->
    {ok, Topic};
resolve_update_topic(#{kind := resource_template} = Entry, Uri) ->
    case maps:get(update_topic, Entry, undefined) of
        undefined ->
            case
                match_template(
                    tokenize(maps:get(uri_template, Entry)), Uri, #{}
                )
            of
                {ok, _} -> no_update_topic;
                nomatch -> nomatch
            end;
        UpdateTopic ->
            case
                match_template(
                    tokenize(maps:get(uri_template, Entry)), Uri, #{}
                )
            of
                {ok, Raw} ->
                    try
                        coerce_vars(Raw, maps:get(uri_vars_schema, Entry, #{}))
                    of
                        Vars ->
                            case interpolate(UpdateTopic, Vars) of
                                Topic when is_binary(Topic) -> {ok, Topic};
                                _ -> nomatch
                            end
                    catch
                        throw:{invalid_var, _} -> nomatch
                    end;
                nomatch ->
                    nomatch
            end
    end;
resolve_update_topic(_, _) ->
    nomatch.

-doc """
Decodes one header value per the transport's Value Encoding: a
`=?base64?...?=` sentinel is Base64 of the value's UTF-8; anything else is
the value itself. `{error, badarg}` for a malformed sentinel payload.
""".
-spec decode_header_value(binary()) -> {ok, binary()} | {error, badarg}.

decode_header_value(<<"=?base64?", Rest/binary>>) when byte_size(Rest) >= 2 ->
    Size = byte_size(Rest),
    case binary:part(Rest, Size - 2, 2) of
        <<"?=">> ->
            try
                {ok, base64:decode(binary:part(Rest, 0, Size - 2))}
            catch
                _:_ -> {error, badarg}
            end;
        _ ->
            {error, badarg}
    end;
decode_header_value(<<"=?base64?", _/binary>>) ->
    {error, badarg};
decode_header_value(Value) when is_binary(Value) ->
    {ok, Value}.

-doc """
The header string representation of a body value (the transport's type
conversion): strings as-is, integers in decimal, booleans lowercase.
Values with no defined conversion — objects, arrays, floats-with-exponent
subtleties aside — return `{error, badarg}` and simply cannot be mirrored.
""".
-spec encode_header_value(any()) -> {ok, binary()} | {error, badarg}.

encode_header_value(V) when is_binary(V) -> {ok, V};
encode_header_value(V) when is_integer(V) -> {ok, integer_to_binary(V)};
encode_header_value(true) -> {ok, <<"true">>};
encode_header_value(false) -> {ok, <<"false">>};
encode_header_value(V) when is_float(V) -> {ok, float_to_binary(V, [short])};
encode_header_value(_) -> {error, badarg}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Absent-or-null: the callee's kwargs arrive as decoded WAMP payload, and
%% a JSON `null` may surface as either atom depending on the serializer.
absent_to(undefined, Default) -> Default;
absent_to(null, Default) -> Default;
absent_to(V, _) -> V.

%% @private
is_input_request(
    {Key, #{<<"method">> := Method, <<"params">> := Params}}
) when is_binary(Key), is_map(Params) ->
    lists:member(Method, ?MRTR_METHODS);
is_input_request(_) ->
    false.

%% @private
text_content(Structured) ->
    #{
        <<"type">> => <<"text">>,
        <<"text">> => iolist_to_binary(json:encode(Structured))
    }.

%% @private
%% §10.2: transient conditions the agent should retry — the declared
%% procedure has no registered callee right now, no callee could take the
%% call, or the call timed out. Denial and everything else is permanent
%% for this principal.
is_retryable(?WAMP_NO_SUCH_PROCEDURE) -> true;
is_retryable(?WAMP_NO_AVAILABLE_CALLEE) -> true;
is_retryable(?WAMP_ERROR_TIMEOUT) -> true;
is_retryable(_) -> false.

%% @private
wire_annotations(Annotations) ->
    maps:fold(
        fun(K, V, Acc) ->
            maps:put(maps:get(K, ?ANNOTATION_KEYS, K), V, Acc)
        end,
        #{},
        Annotations
    ).

%% @private
maybe_put(_, undefined, Map) -> Map;
maybe_put(K, V, Map) -> Map#{K => V}.

%% @private
%% RFC 6570 level-1 template, tokenized as literals and variables. The
%% parser (`bondy_mcp_spec_parser`) already rejected malformed templates
%% at load; adjacent variables cannot arise because `{` is not a valid
%% variable character.
tokenize(Template) ->
    tokenize(Template, []).

tokenize(<<>>, Acc) ->
    lists:reverse(Acc);
tokenize(Bin, Acc) ->
    case binary:split(Bin, <<"{">>) of
        [Lit] ->
            lists:reverse([{lit, Lit} | Acc]);
        [<<>>, Rest] ->
            [Var, Tail] = binary:split(Rest, <<"}">>),
            tokenize(Tail, [{var, Var} | Acc]);
        [Lit, Rest] ->
            [Var, Tail] = binary:split(Rest, <<"}">>),
            tokenize(Tail, [{var, Var}, {lit, Lit} | Acc])
    end.

%% @private
%% Matches a URI against the token list. A variable captures up to the
%% next literal's FIRST occurrence (or the rest of the URI when last);
%% an empty capture is no match — RFC 6570 expansion of an undefined
%% variable would not have produced this URI.
match_template([], <<>>, Vars) ->
    {ok, Vars};
match_template([], _, _) ->
    nomatch;
match_template([{lit, Lit} | Rest], Uri, Vars) ->
    Size = byte_size(Lit),
    case Uri of
        <<Lit:Size/binary, Tail/binary>> -> match_template(Rest, Tail, Vars);
        _ -> nomatch
    end;
match_template([{var, Name}], Uri, Vars) when Uri =/= <<>> ->
    {ok, Vars#{Name => percent_decode(Uri)}};
match_template([{var, _}], <<>>, _) ->
    nomatch;
match_template([{var, Name}, {lit, Lit} | Rest], Uri, Vars) ->
    case binary:split(Uri, Lit) of
        [Value, Tail] when Value =/= <<>> ->
            match_template(
                [{lit, <<>>} | Rest], Tail, Vars#{Name => percent_decode(Value)}
            );
        _ ->
            nomatch
    end.

%% @private
percent_decode(Bin) ->
    case uri_string:percent_decode(Bin) of
        Decoded when is_binary(Decoded) -> Decoded;
        _ -> Bin
    end.

%% @private
%% Coerce each captured (string) variable to the type its schema declares;
%% a value the type cannot carry rejects the read.
coerce_vars(Raw, Schema) ->
    maps:map(
        fun(Name, Value) ->
            Type = maps:get(
                <<"type">>, maps:get(Name, Schema, #{}), <<"string">>
            ),
            coerce(Type, Name, Value)
        end,
        Raw
    ).

%% @private
coerce(<<"string">>, _, V) ->
    V;
coerce(<<"integer">>, Name, V) ->
    try
        binary_to_integer(V)
    catch
        _:_ -> throw({invalid_var, Name})
    end;
coerce(<<"number">>, Name, V) ->
    try
        binary_to_integer(V)
    catch
        _:_ ->
            try
                binary_to_float(V)
            catch
                _:_ -> throw({invalid_var, Name})
            end
    end;
coerce(<<"boolean">>, _, <<"true">>) ->
    true;
coerce(<<"boolean">>, _, <<"false">>) ->
    false;
coerce(<<"boolean">>, Name, _) ->
    throw({invalid_var, Name});
coerce(_, _, V) ->
    V.

%% @private
%% `{{var}}` interpolation into a WAMP binding value: a value that IS one
%% reference carries the typed variable; one with embedded references
%% substitutes their string forms; anything else passes through.
interpolate(V, Vars) when is_binary(V) ->
    case whole_ref(V) of
        {ok, Name} ->
            maps:get(Name, Vars, V);
        nomatch ->
            substitute(V, Vars)
    end;
interpolate(V, _) ->
    V.

%% @private
whole_ref(V) ->
    Size = byte_size(V),
    case V of
        <<"{{", Middle:(Size - 4)/binary, "}}">> when
            Size >= 5
        ->
            case binary:match(Middle, [<<"{">>, <<"}">>]) of
                nomatch -> {ok, Middle};
                _ -> nomatch
            end;
        _ ->
            nomatch
    end.

%% @private
substitute(V, Vars) ->
    maps:fold(
        fun(Name, Value, Acc) ->
            {ok, Str} = encode_header_value(coerce_to_scalar(Value)),
            binary:replace(
                Acc,
                <<"{{", Name/binary, "}}">>,
                Str,
                [global]
            )
        end,
        V,
        Vars
    ).

%% @private
coerce_to_scalar(V) when is_binary(V); is_integer(V); is_boolean(V) -> V;
coerce_to_scalar(V) when is_float(V) -> V.
