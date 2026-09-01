%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_api_utils).
-moduledoc """
Utility functions for the Bondy WAMP API, including validation of
administrative call arguments and the construction of WAMP error messages.

## Two families of argument validator, and which one a procedure wants

`bondy.*` procedures come in two shapes, and reading the wrong validator onto
a procedure is a silent defect rather than a compile error.

**A realm-first procedure** takes the realm it operates on as its FIRST
positional argument — `bondy.rbac.user.add(RealmUri, Data)`. Use
`validate_call_args/3,4` or `validate_admin_call_args/3,4`. They do three
things: check the arity, DEFAULT a missing realm argument to the session's own
realm, and refuse a session asking to operate on a realm that is not its own
unless it is the master realm. The defaulting is the point — a session already
in a realm should not have to name it.

**A procedure with no realm argument** takes something else first — an id, a
name, a document, or nothing at all. Use `call_args/3,4` or
`admin_call_args/3,4`. They check the arity EXACTLY and do nothing else.

Handing a realm-first validator to a procedure of the second kind is what the
second family exists to prevent, and it goes wrong in two ways. It pads: a call
one argument short is completed with the caller's realm URI, so
`bondy.realm.create()` with no arguments reaches `bondy_realm:create/1` with
the master realm's URI as its argument instead of being refused for arity. And
it authorises by accident: the realm-matching clause compares the first
argument against the session's realm, so a procedure whose first argument is
an id is refused for every non-master session — a real refusal, but not the
one anyone wrote, and it disappears the moment the argument happens to equal a
realm URI.

`admin_call_args/3,4` is the master-realm check written as itself. The two
families are otherwise interchangeable at the call site, so migrating a
procedure is a one-line change; `bondy_wamp_api_arity_test` reads which family
each dispatch clause reaches out of the compiled abstract code and drives the
short call against every procedure in the second family.
""".
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-export([error/2]).
-export([maybe_error/2]).
-export([deprecated_procedure_error/1]).
-export([no_such_procedure_error/1]).
-export([no_such_procedure_error/3]).
-export([no_such_registration_error/1]).
-export([node_spec/0]).
-export([dry_run/1]).
-export([dry_run_result/3]).
-export([wants_progress/1]).
-export([stream_pages/3]).
-export([encodable/1]).
-export([page_limit/3]).
-export([page_cursor/1]).
-export([page_extras/1]).
-export([deadline/1]).
-export([budget/2]).
-export([admin_call_args/3]).
-export([admin_call_args/4]).
-export([call_args/3]).
-export([call_args/4]).
-export([validate_admin_call_args/3]).
-export([validate_admin_call_args/4]).
-export([validate_call_args/3]).
-export([validate_call_args/4]).

-compile({no_auto_import, [error/2]}).

%% The most pages `stream_pages/3` will send before deciding the source is not
%% converging. Generous — 10k pages is far more than any bounded `bondy.*`
%% enumeration produces — because tripping it means a defective pager, not a
%% large result.
-define(STREAM_MAX_CHUNKS, 10000).

%% =============================================================================
%% API
%% =============================================================================

-spec node_spec() -> map().

node_spec() ->
    #{listen_addrs := Addrs0} = NodeSpec = partisan:node_spec(),

    NodeSpec#{
        name => partisan:nodestring(),
        listen_addrs => [
            Addr#{ip => list_to_binary(inet:ntoa(IP))}
         || #{ip := IP} = Addr <- Addrs0
        ]
    }.

-doc """
Whether this CALL asks for a DRY RUN: `dry_run` in its `KWArgs`.

A dry run performs every check the real call performs and then stops before
the first act that changes anything, replying with what it WOULD have done.
It is opt-in per procedure — `bondy_task_catalogue` says which ones — and a
procedure that does not read this simply acts, which is why the marker on the
reply (`dry_run_result/3`) matters as much as this does.

KWArgs rather than a CALL option: this is an argument to the procedure, and
for a `bondy.*` procedure Bondy is the callee. A `_`-prefixed option would say
the opposite — that the router should treat the call differently — which is
not what happens.

**An unrecognised value THROWS rather than defaulting.** Both defaults are
wrong: reading it as `false` runs for real a call that asked not to, and
reading it as `true` refuses to do work that was asked for. Only `true`,
`false` and their string spellings are accepted, and absence is `false`.
""".
-spec dry_run(bondy_wamp_message:call()) -> boolean() | no_return().

dry_run(#call{} = M) ->
    case kwarg(M, dry_run, ~"dry_run", false) of
        V when V == true; V == ~"true" ->
            true;
        V when V == false; V == ~"false" ->
            false;
        Other ->
            error(bad_dry_run_error(M, Other))
    end.

-doc """
The reply to a dry run: `Would`, a sentence naming what the real call would
have done, and `Detail`, whatever the procedure can say about it.

`dry_run => true` is on every such reply and is the load-bearing part. A
caller that sent `dry_run` and got back a plain success has no way to tell
"validated, nothing written" from "done" — and the caller most likely to make
that mistake is the one this convention exists for.
""".
-spec dry_run_result(
    bondy_wamp_message:call(), binary(), map()
) -> bondy_wamp_message:result().

dry_run_result(#call{request_id = ReqId}, Would, Detail) when
    is_binary(Would), is_map(Detail)
->
    bondy_wamp_message:result(ReqId, #{}, [
        Detail#{~"dry_run" => true, ~"would" => Would}
    ]).

-doc """
The `N` positional arguments of a call that takes NO realm argument.

Exactly `N`: neither fewer nor more. Nothing is defaulted and nothing is
prepended, so argument `1` is the argument the caller sent — which is the whole
difference from `validate_call_args/3`, and the reason a procedure whose first
argument is an id must use this one.

No authorisation of its own. The operation is on the session's own realm, so
the `wamp.call` permission the dealer already applies is the authority; use
`admin_call_args/3` where the procedure is master-realm-only.

Throws a `bondy_wamp_message:error()`.
""".
-spec call_args(wamp_call(), bondy_context:t(), non_neg_integer()) ->
    Args :: list() | no_return().

call_args(Msg, Ctxt, N) ->
    call_args(Msg, Ctxt, N, N).

-doc """
As `call_args/3`, for a procedure accepting between `Min` and `Max` positional
arguments.

Throws a `bondy_wamp_message:error()`.
""".
-spec call_args(
    wamp_call(), bondy_context:t(), non_neg_integer(), non_neg_integer()
) -> Args :: list() | no_return().

call_args(Msg, _Ctxt, Min, Max) ->
    exact_args(Msg, Min, Max).

-doc """
The `N` positional arguments of a master-realm-only call that takes NO realm
argument.

As `call_args/3`, plus the check `validate_admin_call_args/3` only reaches when
the call arrives with no arguments at all: the session must be in the master
realm. Written as itself rather than falling out of a realm comparison, so the
refusal does not depend on how many arguments the caller happened to send.

Throws a `bondy_wamp_message:error()`.
""".
-spec admin_call_args(wamp_call(), bondy_context:t(), non_neg_integer()) ->
    Args :: list() | no_return().

admin_call_args(Msg, Ctxt, N) ->
    admin_call_args(Msg, Ctxt, N, N).

-doc """
As `admin_call_args/3`, for a procedure accepting between `Min` and `Max`
positional arguments.

Throws a `bondy_wamp_message:error()`.
""".
-spec admin_call_args(
    wamp_call(), bondy_context:t(), non_neg_integer(), non_neg_integer()
) -> Args :: list() | no_return().

admin_call_args(Msg, Ctxt, Min, Max) ->
    %% Arity BEFORE authority, matching `do_validate_call_args/6`: a caller in
    %% the wrong realm sending the wrong number of arguments has always been
    %% told about the arity, and a suite asserting the refusal has to send the
    %% right count to reach it.
    Args = exact_args(Msg, Min, Max),
    case bondy_context:realm_uri(Ctxt) of
        ?MASTER_REALM_URI -> Args;
        _ -> error(unauthorized(Msg, Ctxt))
    end.

-doc """
The `limit` KWArg of a paginated `bondy.*` procedure: the caller's page size,
clamped to `Max` and falling back to `Default`.

KWArgs rather than a CALL option, for the reason `dry_run/1` gives: a page
size is an argument to the procedure, and for a `bondy.*` procedure Bondy is
the callee. It was `CALL.Options._limit` until 2026-09-01; the option form
never reached a callee at all, because `bondy_dealer` builds INVOCATION.Details
from `?WAMP_PPT_ATTRS ++ ?WAMP_TRACE_ATTRS` only, so no procedure outside the
static `bondy.*` table could ever have implemented it.

**Deliberately tolerant.** A junk or out-of-range limit falls back to
`Default` rather than erroring, because a page size has a sane default and
refusing the call would be a worse answer than bounding it. `page_cursor/1` is
strict for the opposite reason.
""".
-spec page_limit(
    bondy_wamp_message:call(), Default :: pos_integer(), Max :: pos_integer()
) -> pos_integer().

page_limit(#call{} = M, Default, Max) when
    is_integer(Default), Default > 0, is_integer(Max), Max >= Default
->
    case kwarg(M, limit, ~"limit", Default) of
        N when is_integer(N), N > 0, N =< Max ->
            N;
        _ ->
            Default
    end.

-doc """
The `cursor` KWArg of a paginated `bondy.*` procedure, or `undefined`.

Returned RAW: the caller decodes it, because the fingerprint a cursor must
carry belongs to the source that minted it. A non-binary value is returned as
it stands so the caller can refuse it — a resume position cannot be guessed,
which is why this has no tolerant fallback where `page_limit/3` does.
""".
-spec page_cursor(bondy_wamp_message:call()) -> term().

page_cursor(#call{} = M) ->
    kwarg(M, cursor, ~"cursor", undefined).

-doc """
The wire keys a pager put on its own result set.

`bondy_pagination:result/2` builds the three keys pagination itself owns
(`values`, `next`, `has_more`). A pager may add BINARY-keyed entries of its own
to that map, and this is what carries them onto every reply — the single-page
one and each progressive chunk alike. `bondy.alarm.history` uses it for
`not_reached`, which a caller must see BOTH ways: a page that is short because
a node could not be reached is not the same answer as a page that is short.
""".
-spec page_extras(bondy_pagination:result_set()) -> map().

page_extras(Page) when is_map(Page) ->
    maps:without([values, next, has_more], Page).

-doc """
The instant a CALL's `_deadline` option names, in `erlang:system_time`
milliseconds, or `infinity`.

`_deadline` is stated as a duration FROM NOW and read here as the instant it
means, because that is the only form a multi-step operation can keep comparing
against as it proceeds. Extension options pass WAMP validation UNTYPED, so
anything but a usable positive integer means no deadline rather than an error.

Shared with `bondy_dealer:promise_deadline/1`: a routed call and a static
`bondy.*` handler must not read the same option two ways.
""".
-spec deadline(map()) -> integer() | infinity.

deadline(Opts) when is_map(Opts) ->
    case maps:get('_deadline', Opts, undefined) of
        D when is_integer(D), D > 0 ->
            erlang:system_time(millisecond) + D;
        _ ->
            infinity
    end.

-doc """
How long a `bondy.*` handler may wait RIGHT NOW: what is left of `Deadline`,
never more than `Ceiling` and never less than zero.

The one rule for turning a caller's `_deadline` into a timeout, so a fan-out's
budget cannot be spelled two ways. `Ceiling` is the handler's own bound for the
wait — what it would have waited without a deadline — and the caller can only
ever shorten it. A caller cannot lengthen a wait the handler chose, because a
`_deadline` is a caller saying when to give up, not a caller granting patience.

Zero is a real answer and means DO NOT WAIT. A caller whose budget is gone must
get the fail-closed reading of whatever the wait was for — for
`bondy_cluster_api:survey/2` that is "this member is silent, so the leave is
unsafe", never "it answered".

Measured on `erlang:system_time/1` because that is the clock `deadline/1`
returns an instant on, and the clock `bondy_rpc_promise` stores its expiry on
(the expiry is part of the promise's ETS key). The three have to agree.
""".
-spec budget(Deadline :: integer() | infinity, Ceiling :: pos_integer()) ->
    non_neg_integer().

budget(infinity, Ceiling) when is_integer(Ceiling), Ceiling > 0 ->
    Ceiling;
budget(Deadline, Ceiling) when
    is_integer(Deadline), is_integer(Ceiling), Ceiling > 0
->
    min(Ceiling, max(0, Deadline - erlang:system_time(millisecond))).

-doc """
Whether this CALL asked for PROGRESSIVE RESULTS.

`receive_progress` reaches a static `bondy.*` handler only when this build
implements `progressive_call_results` AND the caller announced it in HELLO:
`bondy_dealer:maybe_strip_receive_progress/2` removes the option otherwise, and
it runs in `do_forward/2` BEFORE the `bondy.*` dispatch. So this is a plain
read of an already-gated option and needs no check of its own.
""".
-spec wants_progress(bondy_wamp_message:call()) -> boolean().

wants_progress(#call{options = Opts}) when is_map(Opts) ->
    maps:get(receive_progress, Opts, false) == true;
wants_progress(#call{}) ->
    false.

-doc """
Stream a paginated source to the caller as PROGRESSIVE RESULTS, one WAMP
RESULT per page.

`Fun` is the source's own pager: it takes `undefined` for the first page and a
`t:bondy_pagination:cursor/0` thereafter, and answers a
`t:bondy_pagination:result_set/0`. That is the SAME function the single-page
reply calls, so the two modes cannot answer differently — progressive is a
different delivery of one result, not a second implementation of it.

Each chunk carries `values` and `has_more`, the same keys
`bondy_pagination:to_external/1` produces, so a client parses one shape either
way. No `cursor`: there is nothing to resume, which is the whole point of
asking for progress instead of paging.

The last chunk is a FINAL result and every earlier one carries
`progress => true`, so the call settles exactly once. An error part-way through
is returned to the caller of this function to send as a WAMP ERROR, which also
settles the call — a caller that has already received chunks learns the
enumeration did not finish rather than waiting on a result that will not come.

Returns `ok` once the final result is sent; the calling `handle_call/3` then
returns `ok` so `bondy_dealer:apply_static_callback/3` does not send a second
reply.

**Bounded in TIME by the caller's `CALL.Options._deadline`.** That is what the
option is for: the WAMP call timeout is, for a progressive call, an inactivity
window that every chunk restarts, so a slowly-dripping stream is otherwise
unbounded (`bondy_dealer:promise_deadline/1` says the same thing about the
routed path). The FIRST page always runs — a stream that sent nothing would be
a worse answer than a truncated one — and the deadline is consulted only after
a chunk has gone out, so it can shorten a stream and never empty one.

Running out of deadline, and a source that never reports `has_more => false`
exhausting the chunk budget, both settle the call with an ERROR rather than a
final result. The asymmetry between them is in whose fault it is, and the two
are rendered differently by the caller: a spent deadline is the CALLER's own
bound and answers `wamp.error.timeout`; an exhausted chunk budget is a broken
pager and answers as an internal fault.

**Runs SYNCHRONOUSLY in the calling router process**, so it is for BOUNDED
enumerations — the alarm history ring is capped per node, which is why it is
the first user. A source that can answer an unbounded number of pages should
stay paginated, or move this loop to a worker, rather than hold that process
for the length of the stream.
""".
-spec stream_pages(
    bondy_wamp_message:call(),
    bondy_context:t(),
    fun(
        (bondy_pagination:cursor() | undefined) ->
            {ok, bondy_pagination:result_set()} | {error, term()}
    )
) -> ok | {error, term()}.

stream_pages(#call{} = M, Ctxt, Fun) when is_function(Fun, 1) ->
    stream_pages(
        M, Ctxt, Fun, undefined, ?STREAM_MAX_CHUNKS, deadline(M#call.options)
    ).

-doc """
A term as a WAMP-encodable one: the rendering a `bondy.*` read API puts
between its own terms and the encoder.

**Total.** Every term has an image, and that is the whole contract: a value
shape nobody anticipated renders with `~p` rather than reaching the encoder,
where a raise would kill the session of the caller who asked what is wrong —
usually while it reports on a fault somewhere else. Atoms become binaries; map
KEYS are rendered by the same rule, so a non-atom key cannot escape a
`maps:fold/3` as a `function_clause`; numbers and booleans stay themselves, so
a consumer can still compare them.

A non-empty list of characters renders as a STRING. That ambiguity is inherent
to Erlang and unresolvable in general; this resolves it the way a reader
expects, and a list of small integers that was NOT text is the price. `[]`
stays a list, because it far more often means "no elements" than "empty
string".

Every clause is pinned by `bondy_alarm_api_test` — including the charlist and
empty-list cases, which is why the alarm reading is the one that survived when
this was two copies — and by `bondy_task_api_test`.
""".
-spec encodable(term()) ->
    binary() | number() | boolean() | list() | map().

encodable(V) when is_binary(V) -> V;
encodable(V) when is_number(V) -> V;
encodable(V) when is_boolean(V) -> V;
encodable(V) when is_atom(V) -> atom_to_binary(V, utf8);
encodable(V) when is_map(V) ->
    maps:fold(fun(K, X, Acc) -> Acc#{key(K) => encodable(X)} end, #{}, V);
encodable(V) when is_list(V) ->
    case is_string(V) andalso unicode:characters_to_binary(V) of
        B when is_binary(B) -> B;
        _ -> [encodable(E) || E <- V]
    end;
encodable(V) ->
    printed(V).

-doc """
Throws a `bondy_wamp_message:error()`.
""".
validate_call_args(Msg, Ctxt, Min) ->
    validate_call_args(Msg, Ctxt, Min, Min).

-doc """
Throws a `bondy_wamp_message:error()`.
""".
validate_call_args(Msg, Ctxt, Min, Max) ->
    Len = args_len(args(Msg)),
    do_validate_call_args(Msg, Ctxt, Min, Max, Len, false).

-doc """
Throws a `bondy_wamp_message:error()`.
""".
validate_admin_call_args(Msg, Ctxt, Min) ->
    validate_admin_call_args(Msg, Ctxt, Min, Min).

-doc """
Throws a `bondy_wamp_message:error()`.
""".
validate_admin_call_args(Msg, Ctxt, Min, Max) ->
    Len = args_len(args(Msg)),
    do_validate_call_args(Msg, Ctxt, Min, Max, Len, true).

-doc """
Returns a CALL RESULT or ERROR based on the first Argument.
""".
maybe_error(ok, M) ->
    bondy_wamp_message:result(bondy_wamp_message:request_id(M), #{});
maybe_error({ok, Val}, M) ->
    bondy_wamp_message:result(bondy_wamp_message:request_id(M), #{}, [Val]);
maybe_error({'EXIT', {Reason, _}}, M) ->
    maybe_error({error, Reason}, M);
maybe_error(#error{} = Error, _) ->
    Error;
maybe_error({error, #error{} = Error}, _) ->
    Error;
maybe_error({error, Reason}, M) ->
    error(Reason, M);
maybe_error(Val, M) ->
    bondy_wamp_message:result(bondy_wamp_message:request_id(M), #{}, [Val]).

error({not_authorized, Reason}, M) ->
    Map = bondy_error:to_map(bondy_error:from_term(Reason)),

    %% This clause has always put the error map in Args rather than a message,
    %% unlike every other error reply. The shape is kept so existing clients
    %% keep reading Args[0], and the standard payload is added in KWArgs.
    bondy_wamp_message:error_from(
        M,
        #{},
        ?WAMP_NOT_AUTHORIZED,
        [Map],
        Map
    );
error(Reason, #call{} = M) ->
    bondy_wamp_error:to_wamp(Reason, M).

deprecated_procedure_error(#call{procedure_uri = Uri} = M) ->
    do_deprecated_procedure_error(M, Uri);
deprecated_procedure_error(#invocation{details = #{procedure := Uri}} = M) ->
    do_deprecated_procedure_error(M, Uri).

-doc """
Creates a `wamp_error()` based on a `wamp_call()`.
""".
no_such_procedure_error(#call{procedure_uri = Uri} = M) ->
    no_such_procedure_error(Uri, ?CALL, M#call.request_id);
no_such_procedure_error(#invocation{details = #{procedure := Uri}} = M) ->
    no_such_procedure_error(Uri, ?CALL, M#invocation.request_id).

no_such_procedure_error(ProcUri, MType, ReqId) ->
    Error = bondy_error:new(no_such_procedure, #{
        details => #{procedure_uri => ProcUri}
    }),
    bondy_wamp_error:to_wamp(Error, MType, ReqId, #{}).

no_such_registration_error(RegId) when is_integer(RegId) ->
    Error = bondy_error:new(no_such_registration, #{
        details => #{registration_id => RegId}
    }),
    bondy_wamp_error:to_wamp(Error, ?UNREGISTER, RegId, #{}).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% A map key, rendered. Total for the same reason `encodable/1` is, and it has
%% to be: a key that is neither an atom nor a binary raises INSIDE
%% `maps:fold/3`, where no `encodable/1` clause can catch it. `bondy_task_api`
%% shipped this partial and `bondy_task_api_test` was written for that defect.
key(K) when is_atom(K) -> atom_to_binary(K, utf8);
key(K) when is_binary(K) -> K;
key(K) -> printed(K).

%% @private
is_string([]) ->
    false;
is_string(L) ->
    lists:all(fun is_char/1, L).

%% @private
is_char(C) when is_integer(C) ->
    C == 9 orelse C == 10 orelse C == 13 orelse
        (C >= 32 andalso C < 16#D800) orelse
        (C > 16#DFFF andalso C < 16#110000);
is_char(_) ->
    false.

%% @private
printed(V) ->
    iolist_to_binary(io_lib:format("~p", [V])).

%% @private
%% One KWArg, read under BOTH spellings.
%%
%% KWArgs arrive from the wire with BINARY keys and from an internal caller
%% with ATOM keys, and a `bondy.*` handler is reached both ways. `dry_run/1`
%% reads its own the same way; this is that rule with the key names as
%% parameters, so the next KWArg does not add a third copy of it.
kwarg(#call{kwargs = KWArgs}, Atom, Bin, Default) when is_map(KWArgs) ->
    maps:get(Atom, KWArgs, maps:get(Bin, KWArgs, Default));
kwarg(#call{}, _, _, Default) ->
    Default.

%% @private
%% The arity half of `do_validate_call_args/6`, with neither the realm
%% defaulting nor the realm matching — and comparing `Len` against `Min`
%% directly rather than `Len + 1`, which is where the padding comes from.
exact_args(Msg, Min, Max) ->
    Args = to_list(args(Msg)),
    Len = length(Args),
    Len >= Min orelse
        error(
            arity_error(
                Msg,
                <<"The procedure requires at least ",
                    (integer_to_binary(Min))/binary, " positional arguments.">>,
                #{minimum_arity => Min}
            )
        ),
    Len =< Max orelse
        error(
            arity_error(
                Msg,
                <<"The procedure accepts at most ",
                    (integer_to_binary(Max))/binary, " positional arguments.">>,
                #{maximum_arity => Max}
            )
        ),
    Args.

%% @private
-doc """
Validates that the first argument of the call is a RealmUri, defaulting to
use the session Realm's uri if one is not provided. It uses the MinArity
to determine whether the RealmUri argument is present or not.
Once the Realm is established it validates it is is equal to the
session's Realm or any other in case the session's realm is the root realm.
""".
-spec do_validate_call_args(
    wamp_call(),
    bondy_context:t(),
    %% `0` is a real value for all three: `bondy.alarm.list` and its siblings
    %% take no arguments, and the `Min == 0` / `Len == 0` clauses below are
    %% what admit a master-realm caller with an empty argument list.
    MinArity :: non_neg_integer(),
    MaxArity :: non_neg_integer(),
    Len :: non_neg_integer(),
    AdminOnly :: boolean()
) -> Args :: list() | no_return().

do_validate_call_args(Msg, _, Min, _, Len, _) when Len + 1 < Min ->
    E = arity_error(
        Msg,
        <<"The procedure requires at least ", (integer_to_binary(Min))/binary,
            " positional arguments.">>,
        #{minimum_arity => Min}
    ),
    error(E);
do_validate_call_args(Msg, _, _, Max, Len, _) when Len > Max ->
    E = arity_error(
        Msg,
        <<"The procedure accepts at most ", (integer_to_binary(Max))/binary,
            " positional arguments.">>,
        #{maximum_arity => Max}
    ),
    error(E);
do_validate_call_args(Msg, Ctxt, Min, _, Len, AdminOnly) when Len == 0 ->
    %% We are missing the RealmUri argument, we default to the session's Realm
    case bondy_context:realm_uri(Ctxt) of
        Uri when AdminOnly == false ->
            [Uri];
        ?MASTER_REALM_URI when AdminOnly == true andalso Min == 0 ->
            [];
        ?MASTER_REALM_URI when AdminOnly == true ->
            [?MASTER_REALM_URI];
        _ ->
            error(unauthorized(Msg, Ctxt))
    end;
do_validate_call_args(
    #call{args = [Uri | _]} = Msg, Ctxt, Min, _, Len, AdminOnly
) when
    Len >= Min
->
    %% A call can only proceed if the session's Realm matches the one passed in
    %% the arguments, unless the session's Realm is the Root Realm which allows
    %% operations on other realms
    case bondy_context:realm_uri(Ctxt) of
        Uri when AdminOnly == false ->
            %% Matches arg URI
            to_list(args(Msg));
        ?MASTER_REALM_URI ->
            %% Users logged in root realm can operate on any realm
            to_list(args(Msg));
        _ ->
            error(unauthorized(Msg, Ctxt))
    end;
do_validate_call_args(Msg, Ctxt, Min, _, Len, AdminOnly) when Len + 1 >= Min ->
    %% We are missing the RealmUri argument, we default to the session's Realm
    %% A call can only proceed if the session's Realm matches the one passed in
    %% the arguments, unless the session's Realm is the Root Realm which allows
    %% operations on other realms
    case {AdminOnly, bondy_context:realm_uri(Ctxt)} of
        {false, Uri} ->
            [Uri | to_list(args(Msg))];
        {_, ?MASTER_REALM_URI} ->
            [?MASTER_REALM_URI | to_list(args(Msg))];
        {_, _} ->
            error(unauthorized(Msg, Ctxt))
    end.

%% @private
%% `Budget` is what makes this loop TOTAL for a pager it cannot verify.
%%
%% Measured 2026-09-01: a pager whose keyset filter was broken answered the
%% same page with `has_more => true` forever, and this loop spun the router
%% process until the test run was killed. The loop cannot prove an arbitrary
%% `Fun` terminates, so the alternative to a budget is trusting every future
%% caller to be correct — and the failure mode is a wedged router process, not
%% a wrong answer.
%%
%% Exhausting the budget is an ERROR, never a final result. A truncated page
%% marked `has_more => false` would tell the caller it had seen everything,
%% which is the one thing a bounded enumeration must not do; an error settles
%% the call and says the enumeration did not finish.
stream_pages(_M, _Ctxt, _Fun, _Cursor, 0, _Deadline) ->
    {error, stream_budget_exhausted};
stream_pages(M, Ctxt, Fun, Cursor, Budget, Deadline) ->
    case Fun(Cursor) of
        {ok, #{values := Values, has_more := false} = Page} ->
            send_chunk(M, Ctxt, Values, false, page_extras(Page));
        {ok, #{values := Values, has_more := true, next := Next} = Page} ->
            ok = send_chunk(M, Ctxt, Values, true, page_extras(Page)),
            case expired(Deadline) of
                true ->
                    %% The caller's own bound, and reported the same way the
                    %% chunk budget is: an ERROR, never a final result. The
                    %% chunk just sent said `has_more`, so settling with a
                    %% final one marked `has_more => false` would take it back
                    %% and claim the stream had finished.
                    {error, stream_deadline_exceeded};
                false ->
                    stream_pages(M, Ctxt, Fun, Next, Budget - 1, Deadline)
            end;
        {error, _} = Error ->
            Error
    end.

%% @private
%% Whether a deadline has passed. `budget/2` with a ceiling of one millisecond
%% asks the same question — "is there any time left" — and keeps the clock in
%% one function.
expired(Deadline) ->
    budget(Deadline, 1) == 0.

%% @private
%% `progress => true` on every chunk but the last. The caller is always local
%% for a `bondy.*` procedure — `bondy_dealer:apply_static_callback/3` sends its
%% own reply the same way — so the result goes straight to the caller's ref.
send_chunk(#call{request_id = ReqId}, Ctxt, Values, HasMore, Extras) ->
    Details =
        case HasMore of
            true -> #{progress => true};
            false -> #{}
        end,
    %% `values` and `has_more` are written LAST, so a pager's own keys cannot
    %% displace the two this function is responsible for.
    Payload = Extras#{~"values" => Values, ~"has_more" => HasMore},
    Result = bondy_wamp_message:result(ReqId, Details, [Payload]),
    bondy:send(
        bondy_context:realm_uri(Ctxt), bondy_context:ref(Ctxt), Result
    ).

%% @private
unauthorized(#subscribe{} = M, Ctxt) ->
    unauthorized(?SUBSCRIBE, M#subscribe.request_id, Ctxt);
unauthorized(#unsubscribe{} = M, Ctxt) ->
    unauthorized(?UNSUBSCRIBE, M#unsubscribe.request_id, Ctxt);
unauthorized(#register{} = M, Ctxt) ->
    unauthorized(?REGISTER, M#register.request_id, Ctxt);
unauthorized(#unregister{} = M, Ctxt) ->
    unauthorized(?UNREGISTER, M#unregister.request_id, Ctxt);
unauthorized(#call{} = M, Ctxt) ->
    unauthorized(?CALL, M#call.request_id, Ctxt);
unauthorized(#invocation{} = M, Ctxt) ->
    unauthorized(?INVOCATION, M#invocation.request_id, Ctxt);
unauthorized(#cancel{} = M, Ctxt) ->
    unauthorized(?CANCEL, M#cancel.request_id, Ctxt).

%% @private
unauthorized(Type, ReqId, Ctxt) ->
    Uri = bondy_context:realm_uri(Ctxt),
    Message = <<
        "You have no authorisation to perform this operation on this realm."
    >>,
    Description = <<
        "The operation you've requested is targeting a realm ",
        $\s,
        $(,
        $",
        Uri/binary,
        $",
        $),
        $,,
        " that is not your session's realm or the operation is only "
        "supported when performed by a session on the Bondy Master Realm.",
        $\s,
        $(,
        $",
        (?MASTER_REALM_URI)/binary,
        $",
        $),
        $.
    >>,
    Error = bondy_error:new(not_authorized, #{
        message => Message,
        description => Description,
        details => #{
            realm_uri => Uri,
            master_realm_uri => ?MASTER_REALM_URI
        }
    }),
    bondy_wamp_error:to_wamp(Error, Type, ReqId, #{}).

%% @private
arity_error(Msg, Description, Details) ->
    Error = bondy_error:new(invalid_argument, #{
        message => ~"Invalid number of positional arguments.",
        description => Description,
        details => Details
    }),
    bondy_wamp_error:to_wamp(
        Error, ?CALL, bondy_wamp_message:request_id(Msg), #{}
    ).

%% @private
bad_dry_run_error(Msg, Value) ->
    Error = bondy_error:new(invalid_argument, #{
        message => ~"Invalid value for `dry_run`.",
        description =>
            <<
                "`dry_run` must be a boolean. The call was neither performed "
                "nor simulated, because either reading would have been a "
                "guess about which one was meant."
            >>,
        details => #{
            value => iolist_to_binary(io_lib:format("~p", [Value]))
        }
    }),
    bondy_wamp_error:to_wamp(
        Error, ?CALL, bondy_wamp_message:request_id(Msg), #{}
    ).

%% @private
args(#call{args = Args}) -> Args;
args(#invocation{args = Args}) -> Args.

%% @private
args_len(undefined) -> 0;
args_len(L) when is_list(L) -> length(L).

%% @private
to_list(undefined) -> [];
to_list(L) when is_list(L) -> L.

do_deprecated_procedure_error(M, Uri) ->
    Error = bondy_error:new(deprecated_procedure, #{
        details => #{procedure_uri => Uri}
    }),
    bondy_wamp_error:to_wamp(Error, M).
