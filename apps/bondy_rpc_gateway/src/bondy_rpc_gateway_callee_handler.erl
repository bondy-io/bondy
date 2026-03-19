%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_callee_handler).

-moduledoc """
Stateless callback module for WAMP-to-HTTP procedure translation.

The Bondy dealer invokes `handle_wamp_call/2,3` via `erlang:apply/3` when a
WAMP client calls a registered procedure. This module translates the
caller's kwargs into an upstream HTTP request (path interpolation, query
params or JSON body), authenticates via the service's auth module, and
returns the HTTP response as a WAMP result or error.

## Dealer callback mechanism

The dealer's `apply_dynamic_callback` flattens args:

```
A = CBArgs ++ Args ++ KWArgs ++ Options
```

With `callback_args => [ProcConf]` and no positional args from the caller:

- When kwargs is a map: `handle_wamp_call(ProcConf, KWargsMap, OptionsMap)`
- When kwargs is undefined: `handle_wamp_call(ProcConf, OptionsMap)`

## Kwargs routing

Path template variables (`{{var}}`) are consumed from kwargs first.
Remaining kwargs are routed by HTTP method:

- GET, DELETE, HEAD → query parameters
- POST, PUT, PATCH → JSON request body

The optional `<<"_headers">>` kwarg is extracted before routing and
merged into the outgoing HTTP headers.

## Example

```erlang
%% GET /invoices/INV-001?status=paid
%% KWArgs = #{<<"id">> => <<"INV-001">>, <<"status">> => <<"paid">>}
%% → HTTP GET https://billing.example.com/api/invoices/INV-001?status=paid
%% (path template: /invoices/{{id}})
%% → {ok, #{}, [], #{<<"status">> => 200, <<"body">> => #{...}}}
```
""".

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_RETRIES, 3).
-define(RETRY_BACKOFF_MS, 300).

-export([handle_wamp_call/2]).
-export([handle_wamp_call/3]).

%% Exported for testing
-export([interpolate_path/2]).
-export([extract_path_vars/1]).
-export([route_kwargs/3]).
-export([http_to_wamp/2]).




%% ===================================================================
%% BONDY_DEALER CALLBACKS
%% ===================================================================

-doc """
Called when kwargs is undefined (dealer flattens to 2 args).
Delegates to `handle_wamp_call/3` with an empty kwargs map.
""".
-spec handle_wamp_call(map(), map()) ->
    {ok, map(), list(), map()} |
    {error, binary(), map(), list(), map()}.

handle_wamp_call(ProcConf, Options) ->
    handle_wamp_call(ProcConf, #{}, Options).

-doc """
Called when the WAMP client provides kwargs.

Checks service readiness (secret resolution status) before proceeding.
If the service's secrets are still pending, returns `bondy.error.bad_gateway`.
Otherwise merges any resolved secret vars into ProcConf and delegates
to the HTTP forwarding logic.
""".
-spec handle_wamp_call(map(), map(), map()) ->
    {ok, map(), list(), map()} |
    {error, binary(), map(), list(), map()}.

handle_wamp_call(ProcConf, KWArgs0, _Options) ->
    maybe
        #{service_name := ServiceName} ?= ProcConf,
        {ok, Vars} ?= bondy_rpc_gateway_manager:get_secrets(ServiceName),
        {ok, ProcConf1} ?= apply_secrets(ProcConf, Vars),
        do_handle_wamp_call(ProcConf1, KWArgs0)
    else
        {error, not_ready} ->
            wamp_error(
                <<"bondy.error.bad_gateway">>,
                503,
                <<"Service credentials pending">>
            )
    end.





%% =============================================================================
%% PRIVATE
%% =============================================================================

apply_secrets(ProcConf, SecretVars) ->
    AuthConf0 = maps:get(auth_conf, ProcConf),
    ExistingVars = maps:get(vars, AuthConf0, #{}),
    MergedVars = maps:merge(ExistingVars, SecretVars),
    AuthConf1 = AuthConf0#{vars => MergedVars},
    {ok, ProcConf#{auth_conf => AuthConf1}}.



do_handle_wamp_call(ProcConf, KWArgs0) ->
    #{
        service_name := ServiceName,
        base_url := BaseUrl,
        auth_mod := AuthMod,
        auth_conf := AuthConf,
        method := Method,
        path := PathTemplate
    } = ProcConf,

    Timeout = maps:get(timeout, ProcConf, ?DEFAULT_TIMEOUT),
    Retries = maps:get(retries, ProcConf, ?DEFAULT_RETRIES),
    Pool = maps:get(pool, ProcConf, default),

    try
        %% 1. Extract custom headers
        {CustomHeaders, KWArgs1} = extract_custom_headers(KWArgs0),

        %% 2. Interpolate path template — consumes matched keys
        {Path, KWArgs2} = interpolate_path(PathTemplate, KWArgs1),

        %% 3. Build URL and route remaining kwargs
        Endpoint = bondy_rpc_gateway_service:construct_url(BaseUrl, Path),
        {Url, Body} = route_kwargs(Method, Endpoint, KWArgs2),

        %% 4. Build headers
        BaseHeaders = [
            {<<"Content-Type">>, <<"application/json">>},
            {<<"Accept">>, <<"application/json">>}
            | CustomHeaders
        ],

        %% 5. Acquire token + apply auth
        Token = acquire_token(ServiceName, AuthMod, AuthConf),
        {FinalUrl, FinalHeaders} =
            AuthMod:apply_auth(Token, Url, BaseHeaders, AuthConf),

        ?LOG_INFO(#{
            msg => <<"WAMP→HTTP forwarding">>,
            service => ServiceName,
            method => Method,
            url => FinalUrl
        }),

        %% 6. Make HTTP request
        MethodAtom = method_to_atom(Method),
        Response = request_with_retry(
            MethodAtom, FinalUrl, FinalHeaders, Body, Retries, Timeout, Pool
        ),

        case Response of
            {ok, Status0, _RH0, _RespBody0}
              when Status0 =:= 401; Status0 =:= 403 ->
                ?LOG_WARNING(#{
                    msg => <<"Auth rejection, retrying with fresh token">>,
                    service => ServiceName,
                    status => Status0
                }),
                retry_with_fresh_token(
                    ServiceName, AuthMod, AuthConf,
                    Url, BaseHeaders, MethodAtom, Body,
                    Retries, Timeout, Pool
                );

            {ok, Status1, _RH1, RespBody1} ->
                http_to_wamp(Status1, RespBody1);

            {error, HttpErr} ->
                ?LOG_ERROR(#{
                    msg => <<"HTTP request failed">>,
                    service => ServiceName,
                    reason => HttpErr
                }),
                wamp_error(
                    <<"bondy.error.bad_gateway">>,
                    502,
                    <<"Upstream connection failed">>
                )
        end
    catch
        throw:{path_var_missing, Var} ->
            wamp_error(
                <<"wamp.error.invalid_argument">>,
                400,
                <<"Missing required path variable: ", Var/binary>>
            );

        throw:{auth_error, AuthErr} ->
            ?LOG_ERROR(#{
                msg => <<"Auth failed for WAMP procedure">>,
                service => ServiceName,
                reason => AuthErr
            }),
            wamp_error(
                <<"bondy.error.bad_gateway">>,
                503,
                <<"Authentication unavailable">>
            );

        Class:CatchReason:Stack ->
            ?LOG_ERROR(#{
                msg => <<"Unexpected error in WAMP handler">>,
                service => ServiceName,
                class => Class,
                reason => CatchReason,
                stacktrace => Stack
            }),
            wamp_error(
                <<"bondy.error.bad_gateway">>,
                500,
                <<"Internal error">>
            )
    end.


%% ===================================================================
%% Path interpolation
%% ===================================================================

-doc false.
-spec interpolate_path(binary(), map()) -> {binary(), map()}.
interpolate_path(Template, KWArgs) ->
    Vars = extract_path_vars(Template),
    lists:foldl(
        fun(Var, {TplAcc, KWAcc}) ->
            case maps:take(Var, KWAcc) of
                {Val, KWAcc1} ->
                    Pattern = <<"{{", Var/binary, "}}">>,
                    TplAcc1 = binary:replace(
                        TplAcc, Pattern, to_binary(Val)
                    ),
                    {TplAcc1, KWAcc1};
                error ->
                    throw({path_var_missing, Var})
            end
        end,
        {Template, KWArgs},
        Vars
    ).

-doc false.
-spec extract_path_vars(binary()) -> [binary()].
extract_path_vars(Template) ->
    case re:run(
        Template,
        <<"\\{\\{([^}]+)\\}\\}">>,
        [global, {capture, all_but_first, binary}]
    ) of
        {match, Matches} ->
            [Var || [Var] <- Matches];
        nomatch ->
            []
    end.


%% ===================================================================
%% Custom headers extraction
%% ===================================================================

extract_custom_headers(KWArgs) ->
    case maps:take(<<"_headers">>, KWArgs) of
        {HeadersMap, KWArgs1} when is_map(HeadersMap) ->
            Headers = maps:fold(
                fun(K, V, Acc) ->
                    [{to_binary(K), to_binary(V)} | Acc]
                end,
                [],
                HeadersMap
            ),
            {Headers, KWArgs1};
        _ ->
            {[], KWArgs}
    end.


%% ===================================================================
%% Kwargs routing by HTTP method
%% ===================================================================

route_kwargs(Method, Endpoint, KWArgs) when
        Method =:= get; Method =:= delete; Method =:= head ->
    %% GET/DELETE/HEAD: remaining kwargs become query params
    case map_size(KWArgs) of
        0 ->
            {Endpoint, <<>>};
        _ ->
            Params = maps:fold(
                fun(K, V, Acc) ->
                    [{to_binary(K), to_binary(V)} | Acc]
                end,
                [],
                KWArgs
            ),
            QS = uri_string:compose_query(Params),
            {<<Endpoint/binary, "?", QS/binary>>, <<>>}
    end;
route_kwargs(_Method, Endpoint, KWArgs) ->
    %% POST/PUT/PATCH: remaining kwargs become JSON body
    case map_size(KWArgs) of
        0 -> {Endpoint, <<>>};
        _ -> {Endpoint, iolist_to_binary(json:encode(KWArgs))}
    end.


%% ===================================================================
%% Token acquisition
%% ===================================================================

acquire_token(ServiceName, AuthMod, AuthConf) ->
    case bondy_rpc_gateway_token_cache:get(
            ServiceName, AuthMod, AuthConf) of
        {ok, Token} ->
            Token;
        {error, Reason} ->
            throw({auth_error, Reason})
    end.


%% ===================================================================
%% HTTP request with retry
%% ===================================================================

request_with_retry(Method, Url, Headers, Body, RetriesLeft, Timeout, Pool) ->
    Opts = [
        {connect_timeout, Timeout},
        {recv_timeout, Timeout},
        insecure,
        {pool, Pool},
        with_body
    ],
    case hackney:request(Method, Url, Headers, Body, Opts) of
        {ok, S, RH, RB} ->
            {ok, S, RH, RB};
        {error, _} when RetriesLeft > 0 ->
            Attempt = ?DEFAULT_RETRIES - RetriesLeft + 1,
            BackoffMs = round(
                ?RETRY_BACKOFF_MS * math:pow(2, Attempt - 1)
            ),
            ?LOG_WARNING(#{
                msg => <<"Retrying HTTP request">>,
                attempt => Attempt,
                backoff_ms => BackoffMs
            }),
            timer:sleep(BackoffMs),
            request_with_retry(
                Method, Url, Headers, Body, RetriesLeft - 1, Timeout, Pool
            );
        {error, Reason} ->
            {error, Reason}
    end.


%% ===================================================================
%% Auth retry on 401/403
%% ===================================================================

retry_with_fresh_token(
        ServiceName, AuthMod, AuthConf,
        Url, BaseHeaders, MethodAtom, Body,
        Retries, Timeout, Pool) ->
    bondy_rpc_gateway_token_cache:invalidate(ServiceName),
    case bondy_rpc_gateway_token_cache:get(
            ServiceName, AuthMod, AuthConf) of
        {ok, NewToken} ->
            {RetryUrl, RetryHeaders} =
                AuthMod:apply_auth(
                    NewToken, Url, BaseHeaders, AuthConf
                ),
            case request_with_retry(
                    MethodAtom, RetryUrl, RetryHeaders, Body,
                    Retries, Timeout, Pool) of
                {ok, Status, _RH, RespBody} ->
                    http_to_wamp(Status, RespBody);
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        msg => <<"Retry HTTP request failed">>,
                        service => ServiceName,
                        reason => Reason
                    }),
                    wamp_error(
                        <<"bondy.error.bad_gateway">>,
                        502,
                        <<"Upstream connection failed">>
                    )
            end;
        {error, Reason} ->
            throw({auth_error, Reason})
    end.


%% ===================================================================
%% HTTP status → WAMP result/error mapping
%% ===================================================================

http_to_wamp(Status, RespBody) when Status >= 200, Status < 300 ->
    DecodedBody = try json:decode(RespBody)
                  catch _:_ -> RespBody
                  end,
    {ok, #{}, [], #{<<"status">> => Status, <<"body">> => DecodedBody}};

http_to_wamp(Status, RespBody) ->
    ErrorUri = status_to_error_uri(Status),
    DecodedBody = try json:decode(RespBody)
                  catch _:_ -> RespBody
                  end,
    {error, ErrorUri, #{},
     [],
     #{<<"status">> => Status, <<"body">> => DecodedBody}}.


status_to_error_uri(400) -> <<"wamp.error.invalid_argument">>;
status_to_error_uri(422) -> <<"wamp.error.invalid_argument">>;
status_to_error_uri(401) -> <<"wamp.error.not_authorized">>;
status_to_error_uri(403) -> <<"wamp.error.not_authorized">>;
status_to_error_uri(404) -> <<"wamp.error.not_found">>;
status_to_error_uri(408) -> <<"wamp.error.timeout">>;
status_to_error_uri(504) -> <<"wamp.error.timeout">>;
status_to_error_uri(429) -> <<"bondy.error.too_many_requests">>;
status_to_error_uri(502) -> <<"bondy.error.bad_gateway">>;
status_to_error_uri(503) -> <<"bondy.error.bad_gateway">>;
status_to_error_uri(S) when S >= 400, S < 500 ->
    <<"bondy.error.invalid_argument">>;
status_to_error_uri(S) when S >= 500 ->
    <<"bondy.error.bad_gateway">>;
status_to_error_uri(_) ->
    <<"bondy.error.bad_gateway">>.


%% ===================================================================
%% Helpers
%% ===================================================================

wamp_error(Uri, Status, Message) ->
    {error, Uri, #{}, [],
     #{<<"status">> => Status, <<"message">> => Message}}.

method_to_atom(get) -> get;
method_to_atom(post) -> post;
method_to_atom(put) -> put;
method_to_atom(patch) -> patch;
method_to_atom(delete) -> delete;
method_to_atom(head) -> head;
method_to_atom(B) when is_binary(B) ->
    method_to_atom(binary_to_existing_atom(string:lowercase(B), utf8)).

to_binary(B) when is_binary(B)  -> B;
to_binary(A) when is_atom(A)    -> atom_to_binary(A);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(F) when is_float(F)   -> float_to_binary(F, [{decimals, 10}, compact]);
to_binary(L) when is_list(L)    -> list_to_binary(L).
