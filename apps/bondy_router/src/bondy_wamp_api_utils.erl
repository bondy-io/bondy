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
-export([admin_call_args/3]).
-export([admin_call_args/4]).
-export([call_args/3]).
-export([call_args/4]).
-export([validate_admin_call_args/3]).
-export([validate_admin_call_args/4]).
-export([validate_call_args/3]).
-export([validate_call_args/4]).

-compile({no_auto_import, [error/2]}).

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

dry_run(#call{kwargs = KWArgs} = M) when is_map(KWArgs) ->
    case maps:get(dry_run, KWArgs, maps:get(~"dry_run", KWArgs, false)) of
        V when V == true; V == ~"true" ->
            true;
        V when V == false; V == ~"false" ->
            false;
        Other ->
            error(bad_dry_run_error(M, Other))
    end;
dry_run(#call{}) ->
    false.

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
