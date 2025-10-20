%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_stdlib_error).

-type t() :: #{
    type := atom(),
    code := binary(),
    nature := transient | permanent,
    message := binary(),
    details := map(),
    metadata := map(),
    causes := [t()],
    source := atom(),
    doc_uri := binary()
}.

-export_type([t/0]).

-export([new/1]).
-export([exception/1]).
-export([message/1]).
-export([to_map/1]).
-export([normalize/1]).
-export([attrs/1]).
-export([attrs/2]).
-export([is_type/1]).



%% =============================================================================
%% API
%% =============================================================================


new(Opts) when is_map(Opts) ->
    _ = validate_type(maps:get(type, Opts, undefined)),
    exception(Opts).

is_type(#{
    type := T,
    code := _,
    nature := _,
    message := _,
    details := Details,
    metadata := _,
    causes := Causes,
    source := _,
    doc_uri := _
}) when is_atom(T), is_map(Details), is_list(Causes) -> true;
is_type(_) -> false.


exception(Opts0) when is_map(Opts0) ->
    Keep = [type, nature, message, details, metadata, causes, source],
    Opts = maps:with(Keep, Opts0),

    Type = validate_type(maps:get(type, Opts, undefined)),

    Causes0 = maps:get(causes, Opts, []),
    Causes1 = lists:all(fun(C) -> is_type(C) end, Causes0),

    Attrs0 = attrs(Type),
    Code = maps:get(code, Attrs0),
    Namespace = namespace(Code),

    Merged0 = maps:merge(Attrs0, maps:remove(causes, Opts)),
    Merged1 = Merged0#{
        causes => Causes1,
        doc_uri => iolist_to_binary(
            io_lib:format("/errors/~s/~s", [Namespace, to_list(Code)])
        )
    },

    #{
      type => maps:get(type, Merged1, undefined),
      code => maps:get(code, Merged1, ~""),
      nature => maps:get(nature, Merged1, transient),
      message => maps:get(message, Merged1, ~""),
      details => maps:get(details, Merged1, #{}),
      metadata => maps:get(metadata, Merged1, #{}),
      causes => maps:get(causes, Merged1, []),
      source => maps:get(source, Merged1, undefined),
      doc_uri => maps:get(doc_uri, Merged1, ~"")
    }.


-spec message(t()) -> binary().

message(#{type := Type} = E) ->
    Msg      = maps:get(message, E, ~""),
    Code     = maps:get(code, E, ~""),
    Nature   = maps:get(nature, E, transient),
    Source   = maps:get(source, E, wellos),
    Details  = maps:get(details, E, #{}),
    Causes   = maps:get(causes, E, []),
    Metadata = maps:get(metadata, E, #{}),
    DocUri   = maps:get(doc_uri, E, ~""),

    io_lib:format(
        "[~p] ~p~n   code = ~p,~n   nature = ~p,~n   source = ~p,~n   details = ~p,~n   causes = ~p,~n   metadata = ~p,~n   doc_uri = ~p)",
        [Type, Msg, Code, Nature, Source, Details, Causes, Metadata, DocUri]
    ).

to_map(E=#{}) ->
    #{
      type => maps:get(type, E, undefined),
      code => maps:get(code, E, ~""),
      nature => maps:get(nature, E, transient),
      message => maps:get(message, E, ~""),
      details => maps:get(details, E, #{}),
      metadata => maps:get(metadata, E, #{}),
      source => maps:get(source, E, wellos),
      causes => [cause_to_map(C) || C <- maps:get(causes, E, [])],
      doc_uri => maps:get(doc_uri, E, ~"")
    }.

%% --------------------------------------------------------------------------------
%% Public helpers mirrored from Elixir (normalize/attrs)
%% --------------------------------------------------------------------------------

normalize(List) when is_list(List) ->
    [normalize(X) || X <- List];

normalize({Msg, Opts}) when is_map(Opts), (is_list(Msg) orelse is_binary(Msg)) ->
    BinMsg = iolist_to_binary(Msg),
    re:replace(
        BinMsg,
        ~"%{([A-Za-z0-9_]+)}",
        fun
            (RegExpRes, _M, _S) ->
                KeyBin = maps:get(1, RegExpRes),
                KeyAtom
                    = try
                        list_to_existing_atom(binary_to_list(KeyBin))
                    catch _:_ ->
                        undefined
                    end,

                Val =
                    case KeyAtom of
                        undefined ->
                            KeyBin;

                        _ ->
                            maps:get(KeyAtom, Opts, KeyBin)
                    end,
                iolist_to_binary(humanized_string(Val))
        end,
    [{return, binary}, global]
).

attrs(Error, undefined) ->
    attrs(Error);

attrs(Error, null) ->
    attrs(Error);

attrs(Error, UserMsg) when is_binary(UserMsg); is_list(UserMsg) ->
    Base = attrs(Error),
    Msg0 = maps:get(message, Base, ~""),
    Base#{
        message := <<(iolist_to_binary(Msg0))/binary, $\s, (iolist_to_binary(UserMsg))/binary>>
    }.



%% =============================================================================
%% PRIVATE
%% =============================================================================



validate_type(Term) when is_atom(Term) ->
    Term;

validate_type(Term) ->
    erlang:error({badarg, {type, Term}}).

namespace(Code) ->
    namespace_bin(iolist_to_binary(Code)).

namespace_bin(<<C, _/binary>>) when C >= $0, C =< $9 ->
    [];

namespace_bin(<<C, Rest/binary>>) ->
    [C | namespace_bin(Rest)];

namespace_bin(<<>>) ->
    [].

cause_to_map(E=#{ type := _ }) ->
    to_map(E);

cause_to_map(Other) ->
    io_lib:format("~p", [Other]).


humanized_string(List) when is_list(List) ->
    bondy_humanized:join(List);

humanized_string(Term) ->
    io_lib:format("~s", [to_list(Term)]).


to_list(B) when is_binary(B) ->
    binary_to_list(B);

to_list(L) when is_list(L) ->
    L;

to_list(A) when is_atom(A) ->
    atom_to_list(A);

to_list(Other) ->
    io_lib:format("~p", [Other]).

%% --------------------------------------------------------------------------------
%% Attribute tables: each returns a MAP now
%% --------------------------------------------------------------------------------

%% System Errors
attrs(internal_server_error) ->
    #{code => ~"S001", message => ~""};

attrs(service_unavailable) ->
    #{code => ~"S002", message => ~""};

attrs(gateway_timeout) ->
    #{code => ~"S003", message => ~""};

attrs(disk_full) ->
    #{code => ~"S004", message => ~"Out of disk space"};

attrs(out_of_memory) ->
    #{code => ~"S005", message => ~"Out of memory"};

attrs(too_many_connections) ->
    #{code => ~"S006", message => ~""};

attrs(too_many_processes) ->
    #{code => ~"S007", message => ~""};

attrs(insufficient_resources) ->
    #{code => ~"S008", message => ~""};


%% Limits
attrs(rate_limit_exceeded) ->
    #{code => ~"L001", message => ~"Rate limit exceeded"};

attrs(quota_exceeded) ->
    #{code => ~"L002", message => ~"Resource quota exceeded"};

attrs(too_many_requests) ->
    #{code => ~"L003", message => ~"Request limit exceeded"};

attrs(too_many_sessions) ->
    #{code => ~"L004", message => ~"Session limit exceeded"};

attrs(too_large_payload) ->
    #{code => ~"L005", message => ~"Payload set too large"};

attrs(too_large_result) ->
    #{code => ~"L006", message => ~"Result set too large"};


%% Access Control - AuthN
attrs(invalid_credentials) ->
    #{code => ~"A001", nature => permanent, message => ~""};


%% Access Control - AuthZ
attrs(forbidden) ->
    #{code => ~"C001", nature => permanent, message => ~""};

attrs(insufficient_permissions) ->
    #{code => ~"C002", nature => permanent,
      message => ~"The authorization grant type is not supported by the authorization server."};

attrs(role_not_allowed) ->
    #{code => ~"C003", nature => permanent, message => ~""};

attrs(token_expired) ->
    #{code => ~"A002", nature => permanent, message => ~""};

attrs(token_invalid) ->
    #{code => ~"C001", nature => permanent,
      message => ~"The provided authorization grant (e.g., authorization code, resource owner credentials) or refresh token is invalid, expired, revoked, does not match the redirection URI used in the authorization request, or was issued to another client. The client MAY request a new access token and retry the protected resource request."};


%% Client
attrs(bad_request) ->
    #{code => ~"C001", nature => permanent, message => ~""};

attrs(not_found) ->
    #{code => ~"C002", message => ~"The requested resource was not found."};

attrs(method_not_allowed) ->
    #{code => ~"C003", nature => permanent, message => ~""};

attrs(request_timeout) ->
    #{code => ~"C004", message => ~""};

attrs(badarg) -> attrs(argument_error);
attrs(argument_error) ->
    #{code => ~"C005", message => ~"Invalid argument"};

attrs(inconsistency_error) ->
    #{code => ~"C005", nature => permanent,
                                  message => ~"The values provided for the a set of properties or keys are inconsistent."};

attrs(conflict) ->
    #{code => ~"C006", message => ~""};


%% Clustering
attrs(node_down) ->
    #{code => ~"K001", message => ~""};

attrs(cluster_not_formed) ->
    #{code => ~"K002", message => ~""};

attrs(partition_detected) ->
    #{code => ~"K003", message => ~""};


%% Database Connection & Authentication
attrs(connection_failed) ->
    #{code => ~"D001", message => ~"Database connection failed"};

attrs(connection_timeout) ->
    #{code => ~"D002", message => ~"Connection attempt timed out"};

attrs(authentication_failed) ->
    #{code => ~"D003", nature => permanent, message => ~"Invalid database credentials"};

attrs(authorization_failed) ->
    #{code => ~"D004", nature => permanent, message => ~"Permission denied"};

attrs(network_error) ->
    #{code => ~"D005", message => ~"Network or protocol error"};


%% Database Query & Syntax
attrs(query_failed) ->
    #{code => ~"D010", message => ~"Query execution failed"};

attrs(query_timeout) ->
    #{code => ~"D011", message => ~"Query execution timed out"};

attrs(query_syntax_error) ->
    #{code => ~"D012", nature => permanent, message => ~"Query syntax error"};

attrs(invalid_parameter) ->
    #{
        code => ~"D013",
        nature => permanent,
        message => ~"Invalid parameter or type binding"
    };

attrs(invalid_identifier) ->
    #{
        code => ~"D014",
        nature => permanent,
        message => ~"Invalid or unknown identifier"
    };

%% Database Constraint & Data Integrity
attrs(unique_constraint_violation) ->
    #{code => ~"D020", nature => permanent, message => ~"Unique constraint violation"};

attrs(foreign_key_violation) ->
    #{code => ~"D021", nature => permanent, message => ~"Foreign key constraint violation"};

attrs(not_null_violation) ->
    #{code => ~"D022", nature => permanent, message => ~"NOT NULL constraint violation"};

attrs(check_violation) ->
    #{code => ~"D023", nature => permanent, message => ~"CHECK constraint violation"};

attrs(exclusion_violation) ->
    #{code => ~"D024", nature => permanent, message => ~"Exclusion constraint violation"};

attrs(duplicate_row) ->
    #{code => ~"D024", nature => permanent, message => ~"Exclusion constraint violation"};

%% Database Transaction & Locking
attrs(transaction_failed) ->
    #{code => ~"D030", message => ~"Transaction failed"};

attrs(deadlock_detected) ->
    #{code => ~"D031", message => ~"Deadlock detected"};

attrs(serialization_failure) ->
    #{code => ~"D032", message => ~"Serialization failure"};

attrs(lock_timeout) ->
    #{code => ~"D033", message => ~"Lock wait timeout exceeded"};

attrs(invalid_transaction_state) ->
    #{code => ~"D034", message => ~"Invalid transaction state"};

%% Database Schema & Object
attrs(undefined_table) ->
    #{code => ~"D050", nature => permanent, message => ~"Table not found"};

attrs(undefined_column) ->
    #{code => ~"D051", nature => permanent, message => ~"Column not found"};

attrs(duplicate_table) ->
    #{code => ~"D052", nature => permanent, message => ~"Table already exists"};

attrs(duplicate_column) ->
    #{code => ~"D053", nature => permanent, message => ~"Column already exists"};

attrs(invalid_index) ->
    #{code => ~"D054", nature => permanent, message => ~"Invalid or missing index"};

attrs(invalid_schema) ->
    #{code => ~"D055", nature => permanent, message => ~"Schema not found or invalid"};


%% Database Driver / Client
attrs(driver_error) ->
    #{code => ~"D060", message => ~"Driver or client error"};

attrs(unsupported_feature) ->
    #{code => ~"D061", message => ~"Unsupported SQL feature"};

attrs(encoding_error) ->
    #{code => ~"D062", message => ~"Invalid character encoding"};

%% Files (POSIX) - messages via inet:format_error/1
attrs(eacces = Err) ->
    #{code => ~"F001", message => inet:format_error(Err)};

attrs(ebadf = Err) ->
    #{code => ~"F002", message => inet:format_error(Err)};

attrs(ebusy = Err) ->
    #{code => ~"F003", message => inet:format_error(Err)};

attrs(echild = Err) ->
    #{code => ~"F004", message => inet:format_error(Err)};

attrs(edeadlk = Err) ->
    #{code => ~"F005", message => inet:format_error(Err)};

attrs(edquot = Err) ->
    #{code => ~"F006", message => inet:format_error(Err)};

attrs(eexist = Err) ->
    #{code => ~"F007", message => inet:format_error(Err)};

attrs(efault = Err) ->
    #{code => ~"F008", message => inet:format_error(Err)};

attrs(efbig = Err) ->
    #{code => ~"F009", message => inet:format_error(Err)};

attrs(eintr = Err) ->
    #{code => ~"F010", message => inet:format_error(Err)};

attrs(einval = Err) ->
    #{code => ~"F011", message => inet:format_error(Err)};

attrs(eio = Err) ->
    #{code => ~"F012", message => inet:format_error(Err)};

attrs(eisdir = Err) ->
    #{code => ~"F013", message => inet:format_error(Err)};

attrs(eloop = Err) ->
    #{code => ~"F014", message => inet:format_error(Err)};

attrs(emfile = Err) ->
    #{code => ~"F015", message => inet:format_error(Err)};

attrs(emlink = Err) ->
    #{code => ~"F016", message => inet:format_error(Err)};

attrs(enametoolong = Err) ->
    #{code => ~"F017", message => inet:format_error(Err)};

attrs(enfile = Err) ->
    #{code => ~"F018", message => inet:format_error(Err)};

attrs(enoent = Err) ->
    #{code => ~"F019", message => inet:format_error(Err)};

attrs(enoexec = Err) ->
    #{code => ~"F020", message => inet:format_error(Err)};

attrs(enolck = Err) ->
    #{code => ~"F021", message => inet:format_error(Err)};

attrs(enomem = Err) ->
    #{code => ~"F022", message => inet:format_error(Err)};

attrs(enospc = Err) ->
    #{code => ~"F023", message => inet:format_error(Err)};

attrs(enotdir = Err) ->
    #{code => ~"F024", message => inet:format_error(Err)};

attrs(enotempty = Err) ->
    #{code => ~"F025", message => inet:format_error(Err)};

%% Inference Services
attrs(invalid_input) ->
    #{code => ~"I001", nature => permanent, message => ~""};

attrs(input_too_large) ->
    #{code => ~"I002", nature => permanent, message => ~""};

attrs(model_not_found) ->
    #{code => ~"I003", nature => permanent, message => ~""};

attrs(hallucination) ->
    #{code => ~"I004", message => ~""};

%% Network
attrs(network_unreachable) ->
    #{code => ~"N001", message => ~""};

attrs(dns_lookup_failed) ->
    #{code => ~"N002", message => ~""};

attrs(timeout) ->
    #{code => ~"N003", message => ~"Operation timeout"};

attrs(eaddrinuse = Err) ->
    #{code => ~"N004", message => inet:format_error(Err)};

attrs(eaddrnotavail = Err) ->
    #{code => ~"N005", message => inet:format_error(Err)};

attrs(eafnosupport = Err) ->
    #{code => ~"N006", message => inet:format_error(Err)};

attrs(ealready = Err) ->
    #{code => ~"N007", message => inet:format_error(Err)};

attrs(econnaborted = Err) ->
    #{code => ~"N008", message => inet:format_error(Err)};

attrs(econnrefused = Err) ->
    #{code => ~"N009", message => inet:format_error(Err)};

attrs(econnreset = Err) ->
    #{code => ~"N010", message => inet:format_error(Err)};

attrs(ehostunreach = Err) ->
    #{code => ~"N011", message => inet:format_error(Err)};

attrs(einprogress = Err) ->
    #{code => ~"N012", message => inet:format_error(Err)};

attrs(enetdown = Err) ->
    #{code => ~"N013", message => inet:format_error(Err)};

attrs(enetreset = Err) ->
    #{code => ~"N014", message => inet:format_error(Err)};

attrs(enetunreach = Err) ->
    #{code => ~"N015", message => inet:format_error(Err)};

attrs(enobufs = Err) ->
    #{code => ~"N016", message => inet:format_error(Err)};

attrs(enoprotoopt = Err) ->
    #{code => ~"N017", message => inet:format_error(Err)};

attrs(enotconn = Err) ->
    #{code => ~"N018", message => inet:format_error(Err)};

attrs(enotsock = Err) ->
    #{code => ~"N019", message => inet:format_error(Err)};

attrs(epfnosupport = Err) ->
    #{code => ~"N020", message => inet:format_error(Err)};

attrs(eproto = Err) ->
    #{code => ~"N021", message => inet:format_error(Err)};

attrs(eprotonosupport = Err) ->
    #{code => ~"N022", message => inet:format_error(Err)};

attrs(eprototype = Err) ->
    #{code => ~"N023", message => inet:format_error(Err)};

attrs(eshutdown = Err) ->
    #{code => ~"N024", message => inet:format_error(Err)};

attrs(esocktnosupport = Err) ->
    #{code => ~"N025", message => inet:format_error(Err)};

attrs(etimedout = Err) ->
    #{code => ~"N026", message => inet:format_error(Err)};

attrs(etoomanyrefs = Err) ->
    #{code => ~"N027", message => inet:format_error(Err)};

%% Other POSIX
attrs(eagain = Err) ->
    #{code => ~"O001", message => inet:format_error(Err)};

attrs(ecanceled = Err) ->
    #{code => ~"O002", message => inet:format_error(Err)};

attrs(enomsg = Err) ->
    #{code => ~"O004", message => inet:format_error(Err)};

attrs(enosys = Err) ->
    #{code => ~"O005", message => inet:format_error(Err)};

attrs(eoverflow = Err) ->
    #{code => ~"O006", message => inet:format_error(Err)};

attrs(eremote = Err) ->
    #{code => ~"O007", message => inet:format_error(Err)};

attrs(eremoteio = Err) ->
    #{code => ~"O008", message => inet:format_error(Err)};

attrs(estale = Err) ->
    #{code => ~"O009", message => inet:format_error(Err)};

attrs(etime = Err) ->
    #{code => ~"O010", message => inet:format_error(Err)};


%% Fallback
attrs(Term) ->
    #{
        code => ~"S999",
        message => ~"Unknown error",
        details => #{
            reason => io_lib:format("~p",[Term])
        }
    }.
