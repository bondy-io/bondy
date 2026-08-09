%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_error).
-moduledoc """
The canonical structured error value used across Bondy.

An error is a map (`t/0`) carrying its identity, a human-readable explanation,
structured context and an optional chain of causes. It is protocol-agnostic:
this module knows nothing about WAMP, HTTP or any other transport. Protocol
projections live elsewhere (`bondy_wamp_error` for WAMP, `bondy_http_utils` for
HTTP status codes) and are derived from the values defined here.

## Identity

An error has three identifiers, in decreasing order of authority:

- `uri` is the **normative** identity, e.g. `~"bondy.error.not_found"`. It is
  what a WAMP `ERROR` message carries as its error URI and what every mapping
  table (HTTP status, documentation) is keyed by. Always prefer it.
- `code` is a short token that exists for **backwards compatibility** with the
  error payloads Bondy has emitted historically. Its value is fixed per error
  type and is not always derivable from `uri`. New code should not branch on it.
- `handle` is a stable support/documentation handle such as `~"C010"`. It is
  never interpreted by software; it exists so an operator can quote it.

## Client-safe vs internal context

`details` is **client-safe**: it is sanitised (see `sanitise/1`) and included in
every outward-facing projection. `metadata` is **internal**: it holds
stacktraces, raw exception reasons and anything else that must never cross the
process boundary towards a peer. `to_map/1` omits it; `to_log_map/1` keeps it.

When an error carries no safe explanation - typically an unexpected crash - it
is reported as `internal_error` with a generated `trace_id`. The `trace_id`
appears both in the client-facing payload and in the log entry, so an operator
can correlate the two without the client ever seeing the underlying term.

## JSON safety

`to_map/1` is guaranteed to return a term that a JSON encoder accepts: every
key is a binary and every value is a binary, number, boolean, `null`, list or
map. Terms with no JSON counterpart (tuples, pids, references, ports, funs) are
rendered as text, and both nesting depth and total size are bounded.

## Message templating

Catalogue messages and descriptions may contain `%{key}` placeholders, which are
interpolated from `details` when the error is built. This keeps the prose in one
place instead of being assembled by string concatenation at each raise site.

## Adding an error type

Add a clause to the catalogue and list the new type in `types/0`. The tests then
require that its handle is unique, that its URI round-trips through
`type_of_uri/1`, and that it maps to a 4xx or 5xx HTTP status.

Where a type shares another's URI - `badarg` and `invalid_argument` both mean
`wamp.error.invalid_argument` - mark all but one as sharing, so that
`type_of_uri/1` has a single answer. Where a type must keep emitting a `code`
Bondy has emitted before, set that code explicitly rather than letting it derive
from the URI.
""".

-include("bondy_stdlib.hrl").

%% Maximum nesting depth retained by sanitise/1 before a term is rendered as
%% text. Deep terms are usually accidental (a whole state record, a stacktrace)
%% and are worthless to a peer.
-define(MAX_DEPTH, 8).

%% Approximate upper bound, in bytes, for any single sanitised binary.
-define(MAX_BYTES, 4096).

-define(ELLIPSIS, "...").

-type t() :: #{
    type := atom(),
    uri := binary(),
    code := binary(),
    handle := binary(),
    nature := nature(),
    message := binary(),
    description := binary(),
    details := map(),
    metadata := map(),
    causes := [t()],
    source := optional(atom()),
    trace_id := optional(binary()),
    doc_uri := binary()
}.

-doc """
Whether retrying the operation unchanged could succeed. A `permanent` error is
caused by the request itself and will fail identically on retry.
""".
-type nature() :: transient | permanent.

-doc """
The fields a caller may supply when building an error. Everything else is
derived from the catalogue.
""".
-type opts() :: #{
    message => binary(),
    description => binary(),
    details => map(),
    metadata => map(),
    causes => [t()],
    source => atom(),
    trace_id => binary()
}.

-doc """
A catalogue entry: the fixed attributes of an error type.
""".
-type entry() :: #{
    uri := binary(),
    code := binary(),
    handle := binary(),
    nature := nature(),
    message := binary(),
    description := binary(),
    canonical := boolean()
}.

-export_type([entry/0]).
-export_type([nature/0]).
-export_type([opts/0]).
-export_type([t/0]).

%% API
-export([catalogue/1]).
-export([format/1]).
-export([format_error/2]).
-export([from_exception/3]).
-export([from_term/1]).
-export([internal/1]).
-export([internal/3]).
-export([is_type/1]).
-export([new/1]).
-export([new/2]).
-export([sanitise/1]).
-export([to_log_map/1]).
-export([to_map/1]).
-export([type_of_uri/1]).
-export([types/0]).
-export([uri/1]).
-export([wrap/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Builds an error of the given type, with no additional context.
""".
-spec new(Type :: atom()) -> t().

new(Type) ->
    new(Type, #{}).

-doc """
Builds an error of the given type.

`Opts` overrides the catalogue defaults for `message` and `description` and
supplies `details`, `metadata`, `causes`, `source` and `trace_id`. Any `%{key}`
placeholder in the message or description is interpolated from `details`.

Raises `{badarg, {type, Type}}` if `Type` is not an atom.
""".
-spec new(Type :: atom(), Opts :: opts()) -> t().

new(Type, Opts) when is_atom(Type) andalso is_map(Opts) ->
    #{
        uri := Uri,
        code := Code,
        handle := Handle,
        nature := Nature,
        message := DefaultMessage,
        description := DefaultDescription
    } = catalogue(Type),

    Details = sanitise(maps:get(details, Opts, #{})),

    #{
        type => Type,
        uri => Uri,
        code => Code,
        handle => Handle,
        nature => Nature,
        message => interpolate(
            maps:get(message, Opts, DefaultMessage), Details
        ),
        description => interpolate(
            maps:get(description, Opts, DefaultDescription), Details
        ),
        details => Details,
        metadata => maps:get(metadata, Opts, #{}),
        causes => to_causes(maps:get(causes, Opts, [])),
        source => maps:get(source, Opts, undefined),
        trace_id => maps:get(trace_id, Opts, undefined),
        doc_uri => <<"/errors/", Handle/binary>>
    };
new(Type, _) ->
    error({badarg, {type, Type}}).

-doc """
Returns `true` if `Term` is a well-formed error value.
""".
-spec is_type(Term :: any()) -> boolean().

is_type(#{
    type := Type,
    uri := Uri,
    code := _,
    handle := _,
    nature := Nature,
    message := _,
    description := _,
    details := Details,
    metadata := Metadata,
    causes := Causes,
    source := _,
    trace_id := _,
    doc_uri := _
}) when
    is_atom(Type) andalso
        is_binary(Uri) andalso
        is_map(Details) andalso
        is_map(Metadata) andalso
        is_list(Causes) andalso
        (Nature == transient orelse Nature == permanent)
->
    true;
is_type(_) ->
    false.

-doc """
Converts any term into an error value. Total: it never raises, whatever it is
given.

Recognises the error shapes Bondy produces today - bare atoms, tagged tuples,
already-projected error maps - and maps them onto catalogue types. A term it
does not recognise becomes an `internal_error` carrying a generated `trace_id`,
with the original term retained in `metadata` and therefore visible to the logs
but never to a peer.
""".
-spec from_term(Term :: any()) -> t().

from_term(Term) ->
    try
        do_from_term(Term)
    catch
        _:_ ->
            %% do_from_term/1 is meant to be total. If it ever is not, an
            %% opaque internal error is still a better outcome than an
            %% exception raised from inside an error handler.
            internal(Term)
    end.

-doc """
Converts a caught exception into an error value.

The stacktrace and the exception class are placed in `metadata`, so they reach
the logs but never a peer. If `Reason` is a term `from_term/1` recognises, its
identity is preserved and only the stacktrace is added.
""".
-spec from_exception(
    Class :: error | exit | throw,
    Reason :: any(),
    Stacktrace :: list()
) -> t().

from_exception(Class, Reason, Stacktrace) ->
    #{metadata := Metadata} = Error = from_term(Reason),
    Error#{
        metadata => Metadata#{
            class => Class,
            stacktrace => Stacktrace
        }
    }.

-doc """
Builds an opaque `internal_error` from any term.

The result carries a fresh `trace_id` and confines `Term` to `metadata`, so a
peer learns only that something failed while an operator can join the reply to
the log entry holding the actual reason.

Use this wherever a failure has to be reported but cannot be described safely --
including outside a `catch`, where there is a reason but no exception. Returning
a bare `internal_error` instead would break the catalogue's contract: the peer
gets nothing to quote and the two halves cannot be joined.

`internal/3` is the equivalent for a caught exception.
""".
-spec internal(Term :: any()) -> t().

internal(Term) ->
    new(internal_error, #{
        trace_id => trace_id(),
        metadata => #{reason => Term}
    }).

-doc """
Builds an opaque `internal_error` from a caught exception.

Unlike `from_exception/3` this never adopts the exception's identity: the
result is always a generic internal error carrying a fresh `trace_id`, with the
class, reason and stacktrace confined to `metadata`.

Use it in catch-all handlers that reply to a peer. The peer learns only that
something failed and gets the `trace_id`; the operator finds the same
`trace_id` on the log entry, alongside the actual reason.
""".
-spec internal(
    Class :: error | exit | throw,
    Reason :: any(),
    Stacktrace :: list()
) -> t().

internal(Class, Reason, Stacktrace) ->
    new(internal_error, #{
        trace_id => trace_id(),
        metadata => #{
            class => Class,
            reason => Reason,
            stacktrace => Stacktrace
        }
    }).

-doc """
Adds `Cause` to the head of `Error`'s cause chain.
""".
-spec wrap(Error :: t(), Cause :: t() | any()) -> t().

wrap(#{causes := Causes} = Error, Cause) ->
    Error#{causes => [maybe_from_term(Cause) | Causes]}.

-doc """
Projects an error into a client-facing map.

Every key is a binary and every value is JSON-encodable. `metadata` is omitted;
`trace_id` is included only when one was assigned.
""".
-spec to_map(Error :: t()) -> map().

to_map(#{} = Error) ->
    Details = sanitise(maps:get(details, Error, #{})),

    %% Every scalar goes through `to_binary/1`, not `maps:get/3` raw. This is
    %% the JSON projection, so producing JSON-encodable output is its contract
    %% — it must not depend on every construction path having normalised its
    %% input. Sanitising `details` alone would leave `code`, `message`,
    %% `description`, `uri`, `handle` and `doc_uri` able to carry a non-UTF-8
    %% binary straight into `json:encode/1`.
    %%
    %% `to_binary/1` rather than `sanitise/1`: sanitise also truncates, and a
    %% description is not something this projection should silently shorten.
    Canonical = #{
        ~"code" => to_binary(maps:get(code, Error, ~"")),
        ~"message" => to_binary(maps:get(message, Error, ~"")),
        ~"description" => to_binary(maps:get(description, Error, ~"")),
        ~"uri" => to_binary(maps:get(uri, Error, ~"")),
        ~"handle" => to_binary(maps:get(handle, Error, ~"")),
        ~"nature" => atom_to_binary(maps:get(nature, Error, transient), utf8),
        ~"details" => Details,
        ~"causes" => [to_map(C) || C <- maps:get(causes, Error, [])],
        ~"doc_uri" => to_binary(maps:get(doc_uri, Error, ~""))
    },

    Map =
        case maps:get(trace_id, Error, undefined) of
            undefined -> Canonical;
            TraceId -> Canonical#{~"trace_id" => TraceId}
        end,

    %% Details are also spliced in at the top level, because that is where
    %% `key', `value', `limit' and `keys' have always appeared and clients read
    %% them from there. The canonical keys win on collision. This duplication is
    %% the price of not breaking existing clients and should be dropped, along
    %% with `code', in the next major version.
    maps:merge(Details, Map).

-doc """
Projects an error into a map suitable for `?LOG_ERROR/1` and friends.

Unlike `to_map/1` this retains `metadata` and uses atom keys, matching the
structured logging convention used across the codebase.
""".
-spec to_log_map(Error :: t()) -> map().

to_log_map(#{} = Error) ->
    Base = #{
        description => maps:get(message, Error, ~""),
        type => maps:get(type, Error, undefined),
        uri => maps:get(uri, Error, ~""),
        nature => maps:get(nature, Error, transient),
        details => maps:get(details, Error, #{}),
        causes => [to_log_map(C) || C <- maps:get(causes, Error, [])]
    },

    Optional = maps:filter(
        fun(_, V) -> V =/= undefined end,
        #{
            source => maps:get(source, Error, undefined),
            trace_id => maps:get(trace_id, Error, undefined)
        }
    ),

    maps:merge(
        maps:merge(Base, Optional), maps:get(metadata, Error, #{})
    ).

-doc """
Renders an error as a single human-readable line, with its causes appended.
""".
-spec format(Error :: t()) -> binary().

format(#{} = Error) ->
    Uri = maps:get(uri, Error, ~""),
    Message = maps:get(message, Error, ~""),
    Details = maps:get(details, Error, #{}),

    Head0 = <<Uri/binary, ": ", Message/binary>>,
    Head =
        case map_size(Details) of
            0 -> Head0;
            _ -> <<Head0/binary, " ", (format_term(Details))/binary>>
        end,

    case maps:get(causes, Error, []) of
        [] ->
            Head;
        Causes ->
            iolist_to_binary(
                [Head | [<<" <- ", (format(C))/binary>> || C <- Causes]]
            )
    end.

-doc """
`error_info` formatter for use with `erlang:error/3`.

A module that raises with `[{error_info, #{module => ?MODULE, cause => Cause}}]`
can delegate its own `format_error/2` to this function.
""".
-spec format_error(Reason :: any(), StackTrace :: list()) -> map().

format_error(Reason, [{Module, _, _, Info} | _]) when is_list(Info) ->
    ErrorInfo = proplists:get_value(error_info, Info, #{}),
    Cause = maps:get(cause, ErrorInfo, #{}),
    Cause#{
        general => format_term(Reason),
        module => Module
    };
format_error(Reason, _) ->
    #{general => format_term(Reason)}.

-doc """
Coerces a term into one a JSON encoder accepts.

Map keys become binaries. Atoms become binaries, except `true`, `false` and
`null`, which are preserved, and `undefined`, which becomes `null`. Terms with
no JSON counterpart are rendered as text. Nesting and binary size are both
bounded; anything beyond is truncated rather than dropped silently.
""".
-spec sanitise(Term :: any()) -> any().

sanitise(Term) ->
    sanitise(Term, ?MAX_DEPTH).

-doc """
Returns the catalogue entry for an error type.

An unknown atom that names a POSIX error resolves to a POSIX entry; any other
unknown term resolves to the `unknown_error` entry.
""".
-spec catalogue(Type :: atom()) -> entry().

catalogue(Type) ->
    case entry(Type) of
        undefined ->
            case posix_message(Type) of
                {ok, Message} -> posix_entry(Type, Message);
                error -> entry(unknown_error)
            end;
        Entry ->
            Entry
    end.

-doc """
Returns the URI identifying an error type.
""".
-spec uri(Type :: atom()) -> binary().

uri(Type) ->
    maps:get(uri, catalogue(Type)).

-doc """
Returns the canonical error type for a URI, or `undefined`.

Several types may share a URI; only the canonical one is returned.
""".
-spec type_of_uri(Uri :: binary()) -> optional(atom()).

type_of_uri(Uri) when is_binary(Uri) ->
    Pred = fun(Type) ->
        case entry(Type) of
            #{uri := EntryUri, canonical := true} -> EntryUri == Uri;
            _ -> false
        end
    end,

    case lists:search(Pred, types()) of
        {value, Type} -> Type;
        false -> undefined
    end.

-doc """
Returns every catalogued error type.

POSIX error types are not listed: they are resolved dynamically from OTP's own
table so that the two can never drift apart.
""".
-spec types() -> [atom()].

types() ->
    [
        %% System
        internal_error,
        unknown_error,
        service_unavailable,
        unavailable,
        temporarily_unavailable,
        gateway_timeout,
        bad_gateway,
        disk_full,
        out_of_memory,
        too_many_connections,
        too_many_processes,
        insufficient_resources,
        system_shutdown,
        noproc,
        overload,
        overloaded,
        %% Limits
        rate_limit_exceeded,
        quota_exceeded,
        too_many_requests,
        too_many_sessions,
        too_large_payload,
        too_many_results,
        body_max_bytes_exceeded,
        payload_size_exceeded,
        %% Authentication
        invalid_credentials,
        authentication_failed,
        token_expired,
        token_invalid,
        not_auth_method,
        no_such_principal,
        no_such_user,
        %% Authorization
        forbidden,
        not_authorized,
        unauthorized,
        authorization_failed,
        insufficient_permissions,
        role_not_allowed,
        no_such_role,
        %% Client / request
        bad_request,
        invalid_request,
        not_found,
        already_exists,
        method_not_allowed,
        request_timeout,
        timeout,
        argument_error,
        badarg,
        invalid_argument,
        invalid_value,
        missing_required_value,
        property_range_limit,
        inconsistency_error,
        invalid_data,
        invalid_uri,
        conflict,
        proxy_protocol_error,
        %% Cluster
        node_down,
        cluster_not_formed,
        partition_detected,
        %% Mail
        mail_not_configured,
        no_such_relay,
        relay_not_permitted,
        sender_not_permitted,
        invalid_recipient,
        mail_rejected,
        mail_delivery_failed,
        relay_unavailable,
        mail_queue_full,
        %% WAMP
        no_such_realm,
        no_such_procedure,
        no_such_registration,
        no_such_subscription,
        no_such_session,
        procedure_already_exists,
        option_not_allowed,
        disclose_me_not_allowed,
        no_eligible_callee,
        no_available_callee,
        protocol_violation,
        feature_not_supported,
        invalid_feature_request,
        invalid_payload,
        canceled,
        not_in_session,
        deprecated_procedure,
        %% Gateway / OAuth2
        oauth2_invalid_request,
        oauth2_invalid_client,
        oauth2_invalid_grant,
        oauth2_unauthorized_client,
        oauth2_unsupported_grant_type,
        oauth2_invalid_scope,
        unsupported_token_type,
        invalid_scheme,
        invalid_expression
    ].

%% =============================================================================
%% PRIVATE: TERM CONVERSION
%% =============================================================================

%% @private
maybe_from_term(Term) ->
    case is_type(Term) of
        true -> Term;
        false -> from_term(Term)
    end.

%% @private
do_from_term(Term) ->
    case is_type(Term) of
        true -> Term;
        false -> convert(Term)
    end.

%% @private
%% Already-projected error maps. Accepted so that an error can round-trip
%% through a map - a relay hop, a stored payload - without losing its identity.
convert(#{~"uri" := Uri} = Map) when is_binary(Uri) ->
    from_projection(Uri, Map);
convert(#{uri := Uri} = Map) when is_binary(Uri) ->
    from_projection(Uri, binary_keys(Map));
convert(#{~"code" := Code} = Map) ->
    from_legacy_map(Code, Map);
convert(#{code := Code} = Map) ->
    from_legacy_map(Code, binary_keys(Map));
%% A doubly-wrapped error, produced by the `error({error, Reason})` idiom.
convert({error, Reason}) ->
    do_from_term(Reason);
%% Validation failures raised by maps_utils:validate/2 and by hand across the
%% codebase.
convert({missing_required_value, Key}) ->
    new(missing_required_value, #{details => #{key => Key}});
convert({invalid_value, Key, Value}) ->
    new(invalid_value, #{details => #{key => Key, value => Value}});
convert({invalid_value, Key, Value, Description}) ->
    new(invalid_value, #{
        description => to_binary(Description),
        details => #{key => Key, value => Value}
    });
convert({property_range_limit, Key, Limit}) ->
    new(property_range_limit, #{details => #{key => Key, limit => Limit}});
convert({inconsistency_error, Keys}) when is_list(Keys) ->
    new(inconsistency_error, #{details => keys_details(Keys)});
convert({inconsistency_error, Keys, Description}) when is_list(Keys) ->
    new(inconsistency_error, #{
        description => to_binary(Description),
        details => keys_details(Keys)
    });
convert({inconsistency_error, Key}) ->
    convert({inconsistency_error, [Key]});
%% Identity
convert({no_such_realm, Uri}) ->
    new(no_such_realm, #{details => #{realm_uri => Uri}});
convert({no_such_user, Authid}) ->
    new(no_such_user, #{details => #{authid => Authid}});
%% Decoding and request framing
convert({badarg, {decoding, Format}}) ->
    new(invalid_data, #{details => #{format => Format}});
convert({badarg, {body_max_bytes_exceeded, Max}}) ->
    new(body_max_bytes_exceeded, #{details => #{max_bytes => Max}});
convert({badarg, Map}) when is_map(Map) ->
    convert(Map);
convert({badarg, Message}) when
    is_binary(Message) orelse is_list(Message) orelse is_atom(Message)
->
    new(invalid_argument, #{message => to_binary(Message)});
%% Cowboy request errors
convert({request_error, Key, Description}) when is_atom(Key) ->
    new(invalid_request, #{
        description => to_binary(Description),
        details => #{key => Key}
    });
convert({request_error, {Key, _}, Description}) when is_atom(Key) ->
    new(invalid_request, #{
        description => to_binary(Description),
        details => #{key => Key}
    });
convert({badheader, Header, Description}) when is_binary(Header) ->
    new(invalid_argument, #{
        message => <<"The header '", Header/binary, "' is malformed.">>,
        description => to_binary(Description),
        details => #{header => Header}
    });
%% A known type carrying an overriding message, and optionally a description.
%% These two clauses must stay last among the tuple clauses: they are the
%% catch-all for the `{Code, Message}` and `{Code, Message, Description}`
%% shapes.
%% A binary first element is a code rather than a tag, and has always been
%% treated as one.
convert({Code, Message}) when
    is_binary(Code) andalso
        (is_binary(Message) orelse is_list(Message) orelse is_atom(Message))
->
    Base = from_code(Code),
    Base#{message => to_binary(Message)};
convert({Type, Message} = Term) when
    is_atom(Type) andalso
        (is_binary(Message) orelse is_list(Message) orelse is_atom(Message))
->
    known_or_internal(Type, Term, #{message => to_binary(Message)});
convert({Code, Message, Description}) when
    is_binary(Code) andalso
        (is_binary(Message) orelse is_list(Message) orelse is_atom(Message))
->
    Base = from_code(Code),
    Base#{
        message => to_binary(Message),
        description => to_binary(Description)
    };
convert({Type, Message, Description} = Term) when
    is_atom(Type) andalso
        (is_binary(Message) orelse is_list(Message) orelse is_atom(Message))
->
    known_or_internal(Type, Term, #{
        message => to_binary(Message),
        description => to_binary(Description)
    });
convert(Type) when is_atom(Type) ->
    case entry(Type) of
        undefined ->
            case posix_message(Type) of
                {ok, _} -> new(Type);
                error -> internal(Type)
            end;
        _ ->
            new(Type)
    end;
convert(Code) when is_binary(Code) ->
    from_code(Code);
convert(Term) ->
    internal(Term).

%% @private
%% A bare binary has historically been treated as a `code', not a URI: an
%% already-qualified value is kept, anything else becomes a `bondy.error.*' URI.
from_code(Code0) ->
    Code = to_binary(Code0),
    case type_of_uri(Code) of
        undefined ->
            case type_of_code(Code) of
                unknown_error ->
                    Base = new(unknown_error),
                    Base#{
                        uri => safe_uri(qualify(Code), maps:get(uri, Base)),
                        code => Code
                    };
                Type ->
                    new(Type)
            end;
        Type ->
            new(Type)
    end.

%% @private
qualify(<<"wamp.", _/binary>> = Uri) ->
    Uri;
qualify(<<"bondy.", _/binary>> = Uri) ->
    Uri;
qualify(<<"com.", _/binary>> = Uri) ->
    Uri;
qualify(Code) ->
    <<"bondy.error.", Code/binary>>.

%% @private
%% A malformed URI cannot go on the wire: WAMP validates the error URI of every
%% ERROR message, so letting one through would turn a reportable error into a
%% crash at the point of reply. It is also the one field that would otherwise
%% carry a peer's bytes through to a JSON encoder unexamined.
safe_uri(Candidate, Fallback) when is_binary(Candidate) ->
    case is_uri(Candidate) of
        true -> Candidate;
        false -> Fallback
    end;
safe_uri(_, Fallback) ->
    Fallback.

%% @private
is_uri(<<>>) ->
    false;
is_uri(Bin) ->
    is_uri_chars(Bin).

%% @private
is_uri_chars(<<>>) ->
    true;
is_uri_chars(<<C, Rest/binary>>) when
    (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        C == $_ orelse C == $. orelse C == $-
->
    is_uri_chars(Rest);
is_uri_chars(_) ->
    false.

%% @private
%% A type we know about keeps its identity. One we do not is reported as an
%% internal error, because we cannot vouch for the safety of a message we did
%% not author.
known_or_internal(Type, Term, Opts) ->
    case entry(Type) of
        undefined -> internal(Term);
        _ -> new(Type, Opts)
    end.

%% @private
%% Rebuilds an error from one of its own projections. The URI is authoritative;
%% everything else is taken from the projection when present.
from_projection(Uri0, Map) ->
    Type =
        case type_of_uri(Uri0) of
            undefined -> unknown_error;
            Found -> Found
        end,

    Base = new(Type, #{details => maps:get(~"details", Map, #{})}),
    Uri = safe_uri(Uri0, maps:get(uri, Base)),

    Base#{
        uri => Uri,
        metadata => rejected_uri(Uri0, Uri),
        code => to_binary(maps:get(~"code", Map, maps:get(code, Base))),
        message => to_binary(
            maps:get(~"message", Map, maps:get(message, Base))
        ),
        description => to_binary(
            maps:get(~"description", Map, maps:get(description, Base))
        ),
        causes => to_causes(maps:get(~"causes", Map, []))
    }.

%% @private
%% Keeps a rejected URI for the logs, so that a peer sending a malformed one is
%% diagnosable rather than silently normalised away.
rejected_uri(Uri, Uri) ->
    #{};
rejected_uri(Rejected, _) ->
    #{rejected_uri => format_term(Rejected)}.

%% @private
%% An error map in the shape Bondy emitted before this catalogue existed. Its
%% `code' may be an atom, a bare token or a full URI, and any other key is
%% context. Still reachable from stored payloads and from peers.
from_legacy_map(Code0, Map) ->
    Code = to_binary(Code0),
    Type =
        case type_of_uri(Code) of
            undefined -> type_of_code(Code);
            Found -> Found
        end,

    Details = maps:without(
        [~"code", ~"message", ~"description", ~"status_code"], Map
    ),
    Base = new(Type, #{details => Details}),

    Base#{
        code => Code,
        message => to_binary(
            maps:get(~"message", Map, maps:get(message, Base))
        ),
        description => to_binary(
            maps:get(~"description", Map, maps:get(description, Base))
        )
    }.

%% @private
type_of_code(Code) ->
    Pred = fun(Type) -> maps:get(code, entry(Type)) == Code end,

    case lists:search(Pred, types()) of
        {value, Type} -> Type;
        false -> unknown_error
    end.

%% @private
keys_details(Keys) ->
    Text = iolist_to_binary(
        [$[, lists:join(~", ", [to_binary(K) || K <- Keys]), $]]
    ),
    #{keys => Keys, keys_text => Text}.

%% @private
%% A W3C Trace Context `trace-id': 32 lowercase hex characters. Generated from
%% a UUIDv7 so the identifier is also time-ordered, which makes error ids sort
%% chronologically and carry their own timestamp.
trace_id() ->
    bondy_uuidv7:format(bondy_uuidv7:new(), #{mode => compact_hex}).

%% @private
to_causes(Causes) when is_list(Causes) ->
    [maybe_from_term(C) || C <- Causes];
to_causes(_) ->
    [].

%% =============================================================================
%% PRIVATE: RENDERING
%% =============================================================================

%% @private
%% Replaces every `%{key}` in Template with the corresponding entry of Details.
interpolate(Template, Details) when
    is_binary(Template) andalso is_map(Details)
->
    case binary:match(Template, ~"%{") of
        nomatch -> Template;
        _ -> iolist_to_binary(interpolate_parts(Template, Details))
    end;
interpolate(Template, Details) ->
    interpolate(to_binary(Template), Details).

%% @private
interpolate_parts(Bin, Details) ->
    case binary:split(Bin, ~"%{") of
        [Bin] ->
            [Bin];
        [Head, Rest] ->
            case binary:split(Rest, ~"}") of
                [_] ->
                    %% An unterminated placeholder is left exactly as written:
                    %% silently swallowing the rest of the sentence would be
                    %% worse than showing the mistake.
                    [Head, ~"%{", Rest];
                [Key, Tail] ->
                    [
                        Head,
                        substitute(Key, Details)
                        | interpolate_parts(Tail, Details)
                    ]
            end
    end.

%% @private
%% An absent key is left as-is rather than blanked, so a missing substitution is
%% visible instead of producing a sentence with a hole in it.
substitute(Key, Details) ->
    case maps:find(Key, Details) of
        {ok, Value} -> to_binary(Value);
        error -> <<"%{", Key/binary, "}">>
    end.

%% @private
%% Renders any term as text. The `t' modifier and unicode:characters_to_binary/1
%% are both required: `~p' of a term holding characters above U+00FF yields a
%% list iolist_to_binary/1 cannot accept.
format_term(Term) ->
    Chars = io_lib:format("~0tp", [Term]),
    case unicode:characters_to_binary(Chars) of
        Bin when is_binary(Bin) -> truncate(Bin);
        _ -> truncate(iolist_to_binary(io_lib:format("~0w", [Term])))
    end.

%% @private
%% Truncation happens at a byte offset, which can land in the middle of a
%% multi-byte character; the trailing partial character is dropped so the result
%% stays valid UTF-8 and therefore still encodable.
truncate(Bin) when byte_size(Bin) =< ?MAX_BYTES ->
    Bin;
truncate(Bin) ->
    Head = binary:part(Bin, 0, ?MAX_BYTES),
    <<(trim_to_character_boundary(Head))/binary, ?ELLIPSIS>>.

%% @private
trim_to_character_boundary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Valid when is_binary(Valid) -> Valid;
        {incomplete, Valid, _} -> Valid;
        {error, Valid, _} -> Valid
    end.

%% @private
is_utf8(Bin) ->
    is_binary(unicode:characters_to_binary(Bin, utf8, utf8)).

%% @private
%% A binary that is not valid UTF-8 has no JSON string representation, so it is
%% rendered rather than passed through.
to_binary(Term) when is_binary(Term) ->
    case is_utf8(Term) of
        true -> Term;
        false -> format_term(Term)
    end;
to_binary(Term) when is_atom(Term) ->
    atom_to_binary(Term, utf8);
to_binary(Term) when is_integer(Term) ->
    integer_to_binary(Term);
to_binary(Term) when is_float(Term) ->
    float_to_binary(Term, [short]);
to_binary(Term) when is_list(Term) ->
    %% `iolist_to_binary/1` accepts any list of bytes, so a latin-1 char list
    %% such as `[171]` converts happily to `<<171>>` — which is NOT valid UTF-8
    %% and makes `json:encode/1` raise `{invalid_byte, 171}`. Re-enter through
    %% the binary clause so the result faces the same `is_utf8/1` gate a
    %% caller-supplied binary does, and falls back to `format_term/1` when it
    %% fails. Without this, list input was the one way to smuggle invalid UTF-8
    %% past a converter whose whole job is to produce JSON-safe output.
    try iolist_to_binary(Term) of
        Bin -> to_binary(Bin)
    catch
        _:_ -> format_term(Term)
    end;
to_binary(Term) ->
    format_term(Term).

%% @private
binary_keys(Map) ->
    maps:fold(fun(K, V, Acc) -> maps:put(to_binary(K), V, Acc) end, #{}, Map).

%% =============================================================================
%% PRIVATE: JSON SAFETY
%% =============================================================================

%% @private
sanitise(Term, Depth) when Depth =< 0 ->
    format_term(Term);
sanitise(Term, _) when is_binary(Term) ->
    truncate(to_binary(Term));
sanitise(Term, _) when is_number(Term) ->
    Term;
sanitise(true, _) ->
    true;
sanitise(false, _) ->
    false;
sanitise(null, _) ->
    null;
sanitise(undefined, _) ->
    null;
sanitise(Term, _) when is_atom(Term) ->
    atom_to_binary(Term, utf8);
sanitise(Term, Depth) when is_map(Term) ->
    maps:fold(
        fun(K, V, Acc) ->
            maps:put(sanitise_key(K), sanitise(V, Depth - 1), Acc)
        end,
        #{},
        Term
    );
sanitise(Term, Depth) when is_list(Term) ->
    %% A string is far more useful rendered as text than as an array of code
    %% points, and a JSON encoder cannot tell the two apart either.
    case is_text(Term) andalso unicode:characters_to_binary(Term) of
        false -> sanitise_list(Term, Depth, []);
        Bin when is_binary(Bin) -> truncate(Bin);
        _ -> format_term(Term)
    end;
sanitise(Term, _) ->
    format_term(Term).

%% @private
%% A JSON object key is always a string, so whatever the key sanitises to is
%% then rendered as one.
sanitise_key(Key) ->
    case sanitise(Key, 1) of
        Bin when is_binary(Bin) -> Bin;
        Other -> to_binary(Other)
    end.

%% @private
%% An improper list has no JSON counterpart, so a list that turns out not to be
%% proper is rendered as text instead of being half-converted.
sanitise_list([], _, Acc) ->
    lists:reverse(Acc);
sanitise_list([H | T], Depth, Acc) ->
    sanitise_list(T, Depth, [sanitise(H, Depth - 1) | Acc]);
sanitise_list(Tail, _, Acc) ->
    format_term({improper_list, lists:reverse(Acc), Tail}).

%% @private
is_text([]) ->
    false;
is_text(Term) ->
    try
        io_lib:printable_unicode_list(Term)
    catch
        _:_ ->
            %% Improper lists reach printable_unicode_list/1 as a bad argument.
            false
    end.

%% =============================================================================
%% PRIVATE: CATALOGUE
%% =============================================================================

%% @private
%% OTP has no predicate for "is this atom a POSIX error", but its formatter
%% announces the ones it does not know. Deriving the set this way keeps us in
%% step with OTP instead of maintaining a copy of its table.
posix_message(Type) when is_atom(Type) ->
    case inet:format_error(Type) of
        "unknown POSIX error" ++ _ -> error;
        Message -> {ok, list_to_binary(Message)}
    end;
posix_message(_) ->
    error.

%% @private
posix_entry(Type, Message) ->
    Name = atom_to_binary(Type, utf8),
    #{
        uri => <<"bondy.error.", Name/binary>>,
        code => Name,
        handle => <<"P-", Name/binary>>,
        nature => transient,
        message => Message,
        description => ~"",
        canonical => true
    }.

%% @private
%% Builds a catalogue entry. `code` defaults to the URI's last segment, which is
%% what we want for every error type with no historical payload to preserve.
entry(Uri, Handle, Nature, Message) ->
    entry(Uri, Handle, Nature, Message, ~"").

%% @private
entry(Uri, Handle, Nature, Message, Description) ->
    #{
        uri => Uri,
        code => lists:last(binary:split(Uri, ~".", [global])),
        handle => Handle,
        nature => Nature,
        message => Message,
        description => Description,
        canonical => true
    }.

%% @private
%% Marks an entry as sharing another type's URI. Only the canonical type is
%% returned by type_of_uri/1.
shared_uri(Entry) ->
    Entry#{canonical => false}.

%% @private
%% Overrides the derived `code` with the value Bondy has historically emitted
%% for this error. See the module documentation.
legacy(Entry, Code) ->
    Entry#{code => Code}.

%% -----------------------------------------------------------------------------
%% System
%% -----------------------------------------------------------------------------

%% @private
-spec entry(Type :: any()) -> optional(entry()).

entry(internal_error) ->
    entry(
        ~"bondy.error.internal_error",
        ~"S001",
        transient,
        ~"Internal system error.",
        <<
            "The request could not be completed because of an unexpected "
            "condition. Quote the trace_id when reporting this."
        >>
    );
entry(unknown_error) ->
    entry(
        ~"bondy.error.unknown_error",
        ~"S002",
        transient,
        ~"An unknown error occurred."
    );
entry(service_unavailable) ->
    entry(
        ~"wamp.error.unavailable",
        ~"S003",
        transient,
        ~"The service is temporarily unavailable.",
        ~"The condition is temporary. The client MAY retry after a short delay."
    );
entry(unavailable) ->
    entry(
        ~"bondy.error.unavailable",
        ~"S004",
        transient,
        ~"The request could not be completed at this time.",
        <<
            "One or more cluster nodes could not be reached, so the result could "
            "not be confirmed. Retry; a repeated failure indicates a node or "
            "network problem."
        >>
    );
entry(temporarily_unavailable) ->
    entry(
        ~"bondy.error.temporarily_unavailable",
        ~"S005",
        transient,
        ~"The server is temporarily unable to complete authentication.",
        <<
            "The authorization server is currently unable to handle the request "
            "due to a temporary condition: it has not yet confirmed its security "
            "state with the cluster (anti-entropy freshness fence). The client "
            "MAY retry after a short delay."
        >>
    );
entry(gateway_timeout) ->
    entry(
        ~"bondy.error.gateway_timeout",
        ~"S006",
        transient,
        ~"The upstream service did not respond in time."
    );
entry(bad_gateway) ->
    entry(
        ~"bondy.error.bad_gateway",
        ~"S007",
        transient,
        ~"The upstream service returned an invalid response."
    );
entry(disk_full) ->
    entry(~"bondy.error.disk_full", ~"S008", transient, ~"Out of disk space.");
entry(out_of_memory) ->
    entry(~"bondy.error.out_of_memory", ~"S009", transient, ~"Out of memory.");
entry(too_many_connections) ->
    entry(
        ~"bondy.error.too_many_connections",
        ~"S010",
        transient,
        ~"The connection limit has been reached."
    );
entry(too_many_processes) ->
    entry(
        ~"bondy.error.too_many_processes",
        ~"S011",
        transient,
        ~"The process limit has been reached."
    );
entry(insufficient_resources) ->
    entry(
        ~"bondy.error.insufficient_resources",
        ~"S012",
        transient,
        ~"There are insufficient resources to complete the request."
    );
entry(system_shutdown) ->
    %% A close reason rather than an error URI, but it reaches the same
    %% projections and so needs an entry.
    entry(
        ~"wamp.close.system_shutdown",
        ~"S013",
        transient,
        ~"The system is shutting down."
    );
entry(noproc) ->
    shared_uri(
        entry(
            ~"wamp.error.unavailable",
            ~"S014",
            transient,
            ~"The service is temporarily unavailable."
        )
    );
entry(overload) ->
    shared_uri(
        entry(
            ~"bondy.error.too_many_requests",
            ~"S015",
            transient,
            ~"The server is shedding load. Retry after a short delay."
        )
    );
entry(overloaded) ->
    shared_uri(
        entry(
            ~"bondy.error.too_many_requests",
            ~"S016",
            transient,
            ~"The server is shedding load. Retry after a short delay."
        )
    );
%% -----------------------------------------------------------------------------
%% Limits
%% -----------------------------------------------------------------------------

entry(rate_limit_exceeded) ->
    entry(
        ~"bondy.error.rate_limit_exceeded",
        ~"L001",
        transient,
        ~"Rate limit exceeded."
    );
entry(quota_exceeded) ->
    entry(
        ~"bondy.error.quota_exceeded",
        ~"L002",
        permanent,
        ~"Resource quota exceeded."
    );
entry(too_many_requests) ->
    entry(
        ~"bondy.error.too_many_requests",
        ~"L003",
        transient,
        ~"Request limit exceeded."
    );
entry(too_many_sessions) ->
    entry(
        ~"bondy.error.too_many_sessions",
        ~"L004",
        transient,
        ~"Session limit exceeded."
    );
entry(too_large_payload) ->
    entry(
        ~"bondy.error.too_large_payload",
        ~"L005",
        permanent,
        ~"The payload is too large."
    );
entry(too_many_results) ->
    entry(
        ~"bondy.error.too_many_results",
        ~"L006",
        permanent,
        ~"The result set is too large for this procedure.",
        <<
            "This spec-compliant 'wamp.*' meta procedure returns a bounded "
            "result, and the set exceeds that bound on this cluster. Use the "
            "paginated 'bondy.*' equivalent (e.g. 'bondy.registration.list') with "
            "the '_limit' and '_cursor' options."
        >>
    );
entry(body_max_bytes_exceeded) ->
    entry(
        ~"bondy.error.body_max_bytes_exceeded",
        ~"L007",
        permanent,
        <<
            "The body content size exceeds the allowable limit of %{max_bytes} "
            "bytes."
        >>,
        ~"The body cannot be larger than the defined maximum allowed."
    );
entry(payload_size_exceeded) ->
    entry(
        ~"wamp.error.payload_size_exceeded",
        ~"L008",
        permanent,
        ~"The payload size exceeds the allowable limit."
    );
%% -----------------------------------------------------------------------------
%% Authentication
%% -----------------------------------------------------------------------------

entry(invalid_credentials) ->
    entry(
        ~"bondy.error.invalid_credentials",
        ~"A001",
        permanent,
        ~"The credentials provided are invalid."
    );
entry(authentication_failed) ->
    entry(
        ~"wamp.error.authentication_failed",
        ~"A002",
        permanent,
        ~"Authentication failed."
    );
entry(token_expired) ->
    entry(
        ~"bondy.error.token_expired",
        ~"A003",
        permanent,
        ~"The token has expired."
    );
entry(token_invalid) ->
    entry(
        ~"bondy.error.token_invalid",
        ~"A004",
        permanent,
        ~"The token is invalid.",
        <<
            "The provided authorization grant (e.g., authorization code, resource "
            "owner credentials) or refresh token is invalid, expired, revoked, "
            "does not match the redirection URI used in the authorization "
            "request, or was issued to another client. The client MAY request a "
            "new access token and retry the protected resource request."
        >>
    );
entry(not_auth_method) ->
    entry(
        ~"wamp.error.not_auth_method",
        ~"A005",
        permanent,
        ~"The authentication method requested is not supported."
    );
entry(no_such_principal) ->
    entry(
        ~"wamp.error.no_such_principal",
        ~"A006",
        permanent,
        ~"The request failed because the authid provided does not exist."
    );
entry(no_such_user) ->
    legacy(
        shared_uri(
            entry(
                ~"wamp.error.no_such_principal",
                ~"A007",
                permanent,
                <<
                    "The request failed because the authid provided does not "
                    "exist."
                >>
            )
        ),
        ~"wamp.error.no_such_principal"
    );
%% -----------------------------------------------------------------------------
%% Authorization
%% -----------------------------------------------------------------------------

entry(forbidden) ->
    entry(
        ~"bondy.error.forbidden",
        ~"Z001",
        permanent,
        ~"The operation is forbidden."
    );
entry(not_authorized) ->
    entry(
        ~"wamp.error.not_authorized",
        ~"Z002",
        permanent,
        ~"You have no authorisation to perform this operation."
    );
entry(unauthorized) ->
    shared_uri(
        entry(
            ~"wamp.error.not_authorized",
            ~"Z007",
            permanent,
            ~"You have no authorisation to perform this operation."
        )
    );
entry(authorization_failed) ->
    entry(
        ~"wamp.error.authorization_failed",
        ~"Z003",
        transient,
        ~"Authorization could not be determined.",
        <<
            "The router was unable to determine whether the operation is "
            "permitted. This is a server-side condition, not a rejection."
        >>
    );
entry(insufficient_permissions) ->
    entry(
        ~"bondy.error.insufficient_permissions",
        ~"Z004",
        permanent,
        ~"You do not have sufficient permissions to perform this operation."
    );
entry(role_not_allowed) ->
    entry(
        ~"bondy.error.role_not_allowed",
        ~"Z005",
        permanent,
        ~"The role requested is not allowed."
    );
entry(no_such_role) ->
    entry(
        ~"wamp.error.no_such_role",
        ~"Z006",
        permanent,
        ~"The role provided does not exist."
    );
%% -----------------------------------------------------------------------------
%% Client / request
%% -----------------------------------------------------------------------------

entry(bad_request) ->
    entry(
        ~"bondy.error.bad_request",
        ~"C001",
        permanent,
        ~"The request is malformed."
    );
entry(invalid_request) ->
    legacy(
        entry(
            ~"bondy.error.invalid_request",
            ~"C002",
            permanent,
            ~"The request is malformed.",
            <<
                "The request is missing a required parameter, includes an "
                "unsupported parameter value, repeats a parameter, includes "
                "multiple credentials, utilizes more than one mechanism for "
                "authenticating the client, or is otherwise malformed."
            >>
        ),
        ~"invalid_request"
    );
entry(not_found) ->
    entry(
        ~"bondy.error.not_found",
        ~"C003",
        permanent,
        ~"The requested resource was not found."
    );
entry(already_exists) ->
    entry(
        ~"bondy.error.already_exists",
        ~"C004",
        permanent,
        ~"The resource already exists."
    );
entry(method_not_allowed) ->
    entry(
        ~"bondy.error.method_not_allowed",
        ~"C005",
        permanent,
        ~"The method is not allowed for this resource."
    );
entry(request_timeout) ->
    entry(
        ~"bondy.error.request_timeout",
        ~"C006",
        transient,
        ~"The request timed out."
    );
entry(timeout) ->
    entry(
        ~"wamp.error.timeout", ~"C007", transient, ~"The operation timed out."
    );
entry(argument_error) ->
    shared_uri(
        entry(
            ~"wamp.error.invalid_argument",
            ~"C008",
            permanent,
            ~"Invalid argument."
        )
    );
entry(badarg) ->
    shared_uri(
        entry(
            ~"wamp.error.invalid_argument",
            ~"C018",
            permanent,
            ~"Invalid argument."
        )
    );
entry(invalid_argument) ->
    legacy(
        entry(
            ~"wamp.error.invalid_argument",
            ~"C009",
            permanent,
            ~"Invalid argument."
        ),
        ~"invalid_argument"
    );
entry(invalid_value) ->
    legacy(
        entry(
            ~"bondy.error.invalid_value",
            ~"C010",
            permanent,
            ~"The operation failed due to an invalid value.",
            ~"The value for property '%{key}' is invalid."
        ),
        ~"invalid_value"
    );
entry(missing_required_value) ->
    legacy(
        entry(
            ~"bondy.error.missing_required_value",
            ~"C011",
            permanent,
            ~"The operation failed due to a missing required value.",
            ~"A value for '%{key}' is required."
        ),
        ~"missing_required_value"
    );
entry(property_range_limit) ->
    legacy(
        entry(
            ~"bondy.error.property_range_limit",
            ~"C012",
            permanent,
            ~"The operation failed because a property range limit was reached.",
            <<
                "The value for property '%{key}' already contains the maximum "
                "number of values allowed (%{limit})."
            >>
        ),
        ~"property_range_limit"
    );
entry(inconsistency_error) ->
    legacy(
        entry(
            ~"bondy.error.inconsistency_error",
            ~"C013",
            permanent,
            ~"The operation failed due to inconsistent values.",
            ~"The values provided for the keys %{keys_text} are inconsistent."
        ),
        ~"invalid_argument"
    );
entry(invalid_data) ->
    legacy(
        entry(
            ~"bondy.error.invalid_data",
            ~"C014",
            permanent,
            ~"The data provided is not a valid %{format}.",
            <<
                "Make sure the data type you are sending matches a supported mime "
                "type and that it matches the request content-type header."
            >>
        ),
        ~"invalid_data"
    );
entry(invalid_uri) ->
    entry(
        ~"wamp.error.invalid_uri",
        ~"C015",
        permanent,
        ~"The URI provided is invalid."
    );
entry(conflict) ->
    entry(
        ~"bondy.error.conflict",
        ~"C016",
        permanent,
        ~"The request conflicts with the current state of the resource."
    );
entry(proxy_protocol_error) ->
    entry(
        ~"bondy.error.proxy_protocol_error",
        ~"C017",
        permanent,
        ~"Operation forbidden.",
        ~"The source IP Address couldn't be determined."
    );
%% -----------------------------------------------------------------------------
%% Cluster
%% -----------------------------------------------------------------------------

entry(node_down) ->
    entry(~"bondy.error.node_down", ~"K001", transient, ~"The node is down.");
entry(cluster_not_formed) ->
    entry(
        ~"bondy.error.cluster_not_formed",
        ~"K002",
        transient,
        ~"The cluster has not been formed yet."
    );
entry(partition_detected) ->
    entry(
        ~"bondy.error.partition_detected",
        ~"K003",
        transient,
        ~"A network partition has been detected."
    );
%% -----------------------------------------------------------------------------
%% Mail
%%
%% A mail relay is operator-owned infrastructure, and none of these entries
%% describes it. `details` carries the relay's configured NAME -- which the
%% caller supplied in the first place, or could read from
%% `bondy.mail.relay.list` -- and nothing else. No hostname, no username, no
%% credential, and never the text of an SMTP reply: a relay's banner is written
%% by someone other than us and can say anything at all.
%% -----------------------------------------------------------------------------

entry(mail_not_configured) ->
    entry(
        ~"bondy.error.mail_not_configured",
        ~"M001",
        permanent,
        ~"Outbound email is not configured on this node.",
        <<
            "No mail relay has been declared, so there is nothing to send "
            "through. An operator enables outbound email by declaring at least "
            "one 'mail.relay.$name.*' in bondy.conf. A relay that is declared "
            "but unusable -- its credential could not be resolved, or it will "
            "not meet a security setting its own declaration requires -- is "
            "reported here too: in both cases an operator must act before any "
            "message can go out, and neither retrying nor changing the message "
            "helps."
        >>
    );
entry(no_such_relay) ->
    entry(
        ~"bondy.error.no_such_relay",
        ~"M002",
        permanent,
        ~"There is no mail relay named '%{relay}'.",
        <<
            "Either the request named a relay that is not declared on this "
            "node, or it named none while several are declared and no "
            "'mail.default_relay' has been set."
        >>
    );
entry(relay_not_permitted) ->
    entry(
        ~"bondy.error.relay_not_permitted",
        ~"M003",
        permanent,
        ~"This realm may not use the mail relay '%{relay}'.",
        <<
            "Which realms may send through a relay is part of that relay's "
            "declaration, and is closed by default. A realm is admitted by "
            "being named, or by inheriting from a prototype that is named."
        >>
    );
entry(sender_not_permitted) ->
    entry(
        ~"bondy.error.sender_not_permitted",
        ~"M004",
        permanent,
        ~"The sender address is not permitted for the mail relay '%{relay}'.",
        <<
            "A request that names no sender is given the relay's own, so it "
            "cannot claim anyone else's. A request that does name one must fall "
            "inside that relay's 'allowed_from', which is empty by default: a "
            "relay whose owner has not said which domains it owns does not let "
            "a caller choose."
        >>
    );
entry(invalid_recipient) ->
    entry(
        ~"bondy.error.invalid_recipient",
        ~"M005",
        permanent,
        ~"The address '%{address}' is not a valid email address.",
        <<
            "Addresses are checked before a message is queued, so a malformed "
            "one is reported here rather than by the relay long afterwards."
        >>
    );
entry(mail_rejected) ->
    entry(
        ~"bondy.error.mail_rejected",
        ~"M006",
        permanent,
        ~"The mail relay refused the message.",
        <<
            "The relay declined permanently, so the same message offered again "
            "is declined again. A rejected recipient, a refused sender and a "
            "message the relay considers unacceptable all arrive here. Change "
            "the message rather than retrying it."
        >>
    );
entry(mail_delivery_failed) ->
    entry(
        ~"bondy.error.mail_delivery_failed",
        ~"M007",
        transient,
        ~"The message could not be delivered.",
        <<
            "Delivery was attempted and did not complete. Bondy has already "
            "retried within the request's deadline, so retry with backoff "
            "rather than immediately."
        >>
    );
entry(relay_unavailable) ->
    entry(
        ~"bondy.error.relay_unavailable",
        ~"M008",
        transient,
        %% No '%{relay}' here: this is also raised from the transport, which
        %% reports a network failure without carrying the relay's name, and
        %% `bondy_error` leaves an unsatisfiable placeholder visible rather than
        %% blanking it. `details.relay` carries the name whenever it is known.
        ~"The mail relay is unavailable.",
        <<
            "The relay could not be reached, or would not accept mail. Message "
            "routing is unaffected either way: a failing relay degrades "
            "outbound email and nothing else."
        >>
    );
entry(mail_queue_full) ->
    entry(
        ~"bondy.error.mail_queue_full",
        ~"M009",
        transient,
        ~"The mail relay '%{relay}' cannot accept the message at this time.",
        <<
            "The relay's queue has reached its bound. This is how backpressure "
            "is applied: the message is refused immediately rather than the "
            "caller being made to wait on a relay that is not keeping up. Retry "
            "with backoff."
        >>
    );
%% -----------------------------------------------------------------------------
%% WAMP
%% -----------------------------------------------------------------------------

entry(no_such_realm) ->
    legacy(
        entry(
            ~"wamp.error.no_such_realm",
            ~"W001",
            permanent,
            ~"The request failed because the realm provided does not exist.",
            ~"A realm named '%{realm_uri}' could not be found."
        ),
        ~"wamp.error.no_such_realm"
    );
entry(no_such_procedure) ->
    entry(
        ~"wamp.error.no_such_procedure",
        ~"W002",
        permanent,
        ~"There are no registered procedures matching the uri '%{procedure_uri}'.",
        <<
            "Either no registration exists for the requested procedure or the "
            "match policy used did not match any registered procedures."
        >>
    );
entry(no_such_registration) ->
    entry(
        ~"wamp.error.no_such_registration",
        ~"W003",
        permanent,
        ~"No registration exists for the supplied RegistrationId."
    );
entry(no_such_subscription) ->
    entry(
        ~"wamp.error.no_such_subscription",
        ~"W004",
        permanent,
        ~"No subscription exists for the supplied SubscriptionId."
    );
entry(no_such_session) ->
    entry(
        ~"wamp.error.no_such_session",
        ~"W005",
        permanent,
        ~"No session exists for the supplied SessionId."
    );
entry(procedure_already_exists) ->
    entry(
        ~"wamp.error.procedure_already_exists",
        ~"W006",
        permanent,
        ~"A procedure is already registered under this URI."
    );
entry(option_not_allowed) ->
    entry(
        ~"wamp.error.option_not_allowed",
        ~"W007",
        permanent,
        ~"The option requested is not allowed."
    );
entry(disclose_me_not_allowed) ->
    %% The URI's last segment is `not_allowed', which is too generic to serve as
    %% a code on its own.
    legacy(
        entry(
            ~"wamp.error.disclose_me.not_allowed",
            ~"W008",
            permanent,
            ~"Caller disclosure is not allowed."
        ),
        ~"disclose_me_not_allowed"
    );
entry(no_eligible_callee) ->
    entry(
        ~"wamp.error.no_eligible_callee",
        ~"W009",
        transient,
        ~"There is no eligible callee for this procedure."
    );
entry(no_available_callee) ->
    entry(
        ~"wamp.error.no_available_callee",
        ~"W010",
        transient,
        ~"There is no available callee for this procedure."
    );
entry(protocol_violation) ->
    entry(
        ~"wamp.error.protocol_violation",
        ~"W011",
        permanent,
        ~"The peer violated the WAMP protocol."
    );
entry(feature_not_supported) ->
    entry(
        ~"wamp.error.feature_not_supported",
        ~"W016",
        permanent,
        ~"The feature requested is not supported by this peer."
    );
entry(invalid_feature_request) ->
    legacy(
        entry(
            ~"bondy.error.invalid_feature_request",
            ~"W017",
            permanent,
            ~"Invalid feature requested."
        ),
        ~"invalid_feature_request"
    );
entry(invalid_payload) ->
    entry(
        ~"wamp.error.invalid_payload",
        ~"W012",
        permanent,
        ~"The payload could not be decoded."
    );
entry(canceled) ->
    entry(
        ~"wamp.error.canceled",
        ~"W013",
        permanent,
        ~"The operation was cancelled."
    );
entry(not_in_session) ->
    entry(
        ~"bondy.error.not_in_session",
        ~"W014",
        permanent,
        ~"The operation requires an established session."
    );
entry(deprecated_procedure) ->
    entry(
        ~"bondy.error.deprecated_procedure",
        ~"W015",
        permanent,
        ~"The procedure '%{procedure_uri}' has been deprecated."
    );
%% -----------------------------------------------------------------------------
%% Gateway / OAuth2
%%
%% The `code` of every OAuth2 entry is the value RFC 6749 mandates for the
%% `error` field of the response body, and must not be changed.
%% -----------------------------------------------------------------------------

entry(oauth2_invalid_request) ->
    legacy(
        shared_uri(
            entry(
                ~"bondy.error.invalid_request",
                ~"G001",
                permanent,
                ~"The request is malformed.",
                <<
                    "The request is missing a required parameter, includes an "
                    "unsupported parameter value (other than grant type), repeats "
                    "a parameter, includes multiple credentials, utilizes more "
                    "than one mechanism for authenticating the client, or is "
                    "otherwise malformed."
                >>
            )
        ),
        ~"invalid_request"
    );
entry(oauth2_invalid_client) ->
    legacy(
        entry(
            ~"bondy.error.invalid_client",
            ~"G002",
            permanent,
            ~"Unknown client or unsupported authentication method.",
            <<
                "Client authentication failed (e.g., unknown client, no client "
                "authentication included, or unsupported authentication method)."
            >>
        ),
        ~"invalid_client"
    );
entry(oauth2_invalid_grant) ->
    legacy(
        entry(
            ~"bondy.error.invalid_grant",
            ~"G003",
            permanent,
            <<
                "The access or refresh token provided is expired, revoked, "
                "malformed, or invalid."
            >>,
            <<
                "The provided authorization grant (e.g., authorization code, "
                "resource owner credentials) or refresh token is invalid, "
                "expired, revoked, does not match the redirection URI used in the "
                "authorization request, or was issued to another client. The "
                "client MAY request a new access token and retry the protected "
                "resource request."
            >>
        ),
        ~"invalid_grant"
    );
entry(oauth2_unauthorized_client) ->
    legacy(
        entry(
            ~"bondy.error.unauthorized_client",
            ~"G004",
            permanent,
            <<
                "The authenticated client is not authorized to use this "
                "authorization grant type."
            >>
        ),
        ~"unauthorized_client"
    );
entry(oauth2_unsupported_grant_type) ->
    legacy(
        entry(
            ~"bondy.error.unsupported_grant_type",
            ~"G005",
            permanent,
            <<
                "The requested scope is invalid, unknown, malformed, or exceeds "
                "the scope granted by the resource owner."
            >>
        ),
        ~"unsupported_grant_type"
    );
entry(oauth2_invalid_scope) ->
    legacy(
        entry(
            ~"bondy.error.invalid_scope",
            ~"G006",
            permanent,
            ~"The requested scope is invalid, unknown or malformed.",
            <<
                "The authorization grant type is not supported by the "
                "authorization server."
            >>
        ),
        ~"invalid_scope"
    );
entry(unsupported_token_type) ->
    legacy(
        entry(
            ~"bondy.error.unsupported_token_type",
            ~"G007",
            transient,
            <<
                "The authorization server does not support the revocation of the "
                "presented token type. That is, the client tried to revoke an "
                "access token on a server not supporting this feature."
            >>,
            <<
                "If the server responds with HTTP status code 503, the client "
                "must assume the token still exists and may retry after a "
                "reasonable delay. The server may include a 'Retry-After' header "
                "in the response to indicate how long the service is expected to "
                "be unavailable to the requesting client."
            >>
        ),
        ~"unsupported_token_type"
    );
entry(invalid_scheme) ->
    legacy(
        shared_uri(
            entry(
                ~"bondy.error.invalid_client",
                ~"G008",
                permanent,
                <<
                    "The authorization scheme is missing or the one provided is "
                    "not the one required."
                >>,
                <<
                    "Client authentication failed (e.g., unknown client, no "
                    "client authentication included, or unsupported "
                    "authentication method)."
                >>
            )
        ),
        ~"invalid_client"
    );
entry(invalid_expression) ->
    legacy(
        entry(
            ~"bondy.error.http_gateway.invalid_expression",
            ~"G009",
            permanent,
            ~"There was an error evaluating the API Gateway expression.",
            <<
                "This might be due to an error in the action expression (mops) "
                "itself or as a result of a key missing in the response to a "
                "gateway action (WAMP or HTTP call)."
            >>
        ),
        %% The gateway has always emitted the full URI as the code here.
        ~"bondy.error.http_gateway.invalid_expression"
    );
entry(_) ->
    undefined.
