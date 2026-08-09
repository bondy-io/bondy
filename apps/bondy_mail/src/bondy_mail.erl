%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail).

-moduledoc """
Outbound email for Bondy.

This is the whole send path. The two surfaces on top of it -- the
`bondy_smtp_bridge` broker bridge and the `bondy.mail.*` WAMP API -- are thin
translations onto this module, and neither carries transport, MIME, retry or
authority logic of its own.

Nothing here knows about WAMP.

## Relays

A relay is operator-owned infrastructure: host, credentials, TLS settings and
sending policy, declared in `bondy.conf` under `mail.relay.$name.*`. Callers
reference a relay by name. Credentials never appear in a bridge specification,
an RPC argument, a log line or an error payload.

Which realms may use a relay, and which sender identities they may claim, are
part of that declaration and are enforced here rather than in either surface --
this is the only layer both of them pass through.

## Idempotency

A request may carry an `id`, which is a caller's idempotency key: send the same
key twice and the second one reports the first message rather than sending
another. The check is cluster-wide, so a client that retries a timed-out
request against a different node still gets one email. See `bondy_mail_status`
for how that is located and what it costs.

Without a key there is nothing to deduplicate and no hop to pay.

## Dormancy

With no relay configured the application starts and does nothing:
`is_configured/0` answers `false`, and sending answers
`{error, not_configured}`. Configuring email is an operator's choice, and a
node that has not made it must still boot.
""".

-include_lib("kernel/include/logger.hrl").
-include("bondy_mail.hrl").

%% How much longer than the request's own budget a routed call may take. Covers
%% the hop itself, not the delivery attempt.
-define(ROUTE_OVERHEAD, 5000).

%% API
-export([default_relay/0]).
-export([is_configured/0]).
-export([relay_names/0]).
-export([relays/1]).
-export([send/2]).
-export([send/3]).
-export([send_async/2]).
-export([send_async/3]).
-export([status/2]).
-export([to_error/1]).

%% REMOTE CALLBACKS
-export([accept/3]).
-export([accept/4]).

-type opts() :: #{surface => atom()}.

-export_type([opts/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Send a message and wait for the relay to accept it.

`RealmUri` is the calling realm, taken from the session. It is an argument
rather than a field so a caller has nowhere to claim another realm.

Answers `{ok, #{id, status, receipt, attempts}}` once the relay has taken
responsibility for the message, or `{error, Reason}`. Blocking ends at the
request's deadline, which is bounded by the relay's `timeout` -- a caller may
ask for less, never more.

A request whose idempotency key has already been used answers
`{ok, #{id, status, duplicate := true}}` without sending anything, reporting
what became of the first message.

A receipt is not a delivery guarantee. It means the relay accepted the message;
what happens after that is between the relay and the recipient, and Bondy does
not process bounces.
""".
-spec send(RealmUri :: binary(), Request :: map()) ->
    {ok, map()} | {error, any()}.

send(RealmUri, Map) ->
    send(RealmUri, Map, #{}).

-doc """
Send a message, naming the surface it came from.

`Opts` carries `surface => rpc | bridge`, which reaches telemetry and nothing
else. It is attribution, not authority: neither surface is granted anything the
other is not, and it is set by the calling code inside Bondy rather than by
anything a peer sends.
""".
-spec send(RealmUri :: binary(), Request :: map(), Opts :: opts()) ->
    {ok, map()} | {error, any()}.

send(RealmUri, Map, Opts) ->
    dispatch(RealmUri, Map, send, Opts).

-doc """
Queue a message and return without waiting.

Answers `{ok, #{id, status := queued}}`. The id is what `status/2` takes.

**What a successful return does not mean.** It does not mean the relay accepted
the message, or saw it. It does not mean the message will be delivered. And it
does not survive a restart: the queue is in memory, so a node that stops loses
whatever it was holding. Bondy is not a mail spool, and building one would put
per-message writes into the replicated state plane for data that is
ephemeral by nature.

What it does mean is that the message passed validation and authority, and was
accepted into a bounded queue on this node. A relay whose queue is full refuses
here rather than blocking, and says so with a transient error.
""".
-spec send_async(RealmUri :: binary(), Request :: map()) ->
    {ok, map()} | {error, any()}.

send_async(RealmUri, Map) ->
    send_async(RealmUri, Map, #{}).

-doc "As `send_async/2`, naming the surface the request came from.".
-spec send_async(RealmUri :: binary(), Request :: map(), Opts :: opts()) ->
    {ok, map()} | {error, any()}.

send_async(RealmUri, Map, Opts) ->
    dispatch(RealmUri, Map, send_async, Opts).

-doc """
Return what is known about a message.

`status` is one of:

- `queued` -- accepted into a relay's queue on the owning node.
- `sent` -- a relay took responsibility for it. Not a delivery guarantee.
- `failed` -- a relay was shown the message and it will not be delivered.
- `shed` -- it was dropped from the queue before any relay saw it, because it
  outlived `queue.ttl` or the worker holding it stopped. An idempotency key
  whose message was shed may be used again; one whose message `failed` may not.
- `unknown` -- see below.

`#{status := unknown}` when this cluster cannot say -- an id that never
existed, a record that has been swept, a message belonging to another realm, or
an owning node that is unreachable. Answering the same way for all four is
deliberate: a caller cannot use this to learn whether another realm's message
exists, and an unreachable node genuinely has an unknown answer, since its
queue was in memory.
""".
-spec status(RealmUri :: binary(), Id :: binary()) ->
    {ok, bondy_mail_status:info()}.

status(RealmUri, Id) when is_binary(RealmUri) andalso is_binary(Id) ->
    {ok, bondy_mail_status:get(RealmUri, Id)}.

-doc """
Translate a send failure into a catalogue error.

Both surfaces call this rather than mapping for themselves, because two
translations of the same failure drift and callers then see one URI from the
bridge and another from the RPC for identical causes.

## What a caller is told

The `M001`-`M009` entries of `bondy_error` carry the relay's configured *name*
and nothing else about it. A relay's hostname, its username, its credential and
the text of its SMTP replies stay in the log. A relay banner is written by
someone other than us and may say anything at all, so only the three-digit
reply code survives translation -- that is the part a caller can act on.

Anything unrecognised becomes `internal_error`, which carries a trace id and no
detail. A failure Bondy cannot describe safely is one it does not describe.
""".
-spec to_error(Reason :: any()) -> bondy_error:t().

to_error(not_configured) ->
    bondy_error:new(mail_not_configured);
%% Declared but unusable. Same audience, same remedy, same absence of anything
%% a caller can do -- but saying "not configured" of a relay that is plainly
%% configured would send an operator looking in the wrong place.
to_error({permanent, Class, _}) when
    Class == configuration orelse Class == missing_requirement
->
    bondy_error:new(mail_not_configured, #{
        message =>
            ~"The mail relay is declared but cannot be used as configured."
    });
to_error(no_such_relay) ->
    bondy_error:new(no_such_relay, #{
        message =>
            <<
                "No mail relay was named, and no default relay is configured."
            >>
    });
to_error({no_such_relay, Name}) ->
    relay_error(no_such_relay, Name);
to_error({permanent, no_such_relay, Name}) ->
    relay_error(no_such_relay, Name);
to_error({relay_not_permitted, Name}) ->
    relay_error(relay_not_permitted, Name);
to_error({sender_not_permitted, Name, Address}) ->
    bondy_error:new(sender_not_permitted, #{
        details => #{relay => Name, address => Address}
    });
to_error({invalid_recipient, Address}) ->
    bondy_error:new(invalid_recipient, #{details => #{address => Address}});
to_error({unknown_keys, Keys}) ->
    bondy_error:new(invalid_request, #{
        message => ~"The request contains keys that are not recognised.",
        details => #{keys => Keys}
    });
to_error({header_injection, Name}) ->
    bondy_error:new(invalid_request, #{
        message =>
            <<
                "The header '%{key}' contains a line break and was refused."
            >>,
        description =>
            <<
                "A line break in a header would let a value become further "
                "headers, or a message body. The header is refused rather than "
                "stripped: silently removing the break would change what the "
                "message means without saying so."
            >>,
        details => #{key => Name}
    });
to_error({reserved_header, Name}) ->
    bondy_error:new(invalid_request, #{
        message => ~"The header '%{key}' may not be set by a caller.",
        description =>
            <<
                "Envelope and authentication headers are Bondy's or the relay's "
                "to set. A caller-supplied 'Bcc', for instance, would publish "
                "exactly what the field exists to hide."
            >>,
        details => #{key => Name}
    });
to_error({invalid_header, Name}) ->
    bondy_error:new(invalid_request, #{
        message => ~"The header '%{key}' is malformed.",
        details => #{key => Name}
    });
to_error({too_large_payload, Size, Max}) ->
    bondy_error:new(too_large_payload, #{
        details => #{value => Size, limit => Max}
    });
to_error({too_many_recipients, Count, Max}) ->
    bondy_error:new(too_large_payload, #{
        message =>
            ~"The message names %{value} recipients; at most %{limit} are allowed.",
        details => #{value => Count, limit => Max}
    });
%% The worker wraps the same failure once it has encoded the message. Unwrapped
%% rather than answered bare, so a caller is told the limit whichever of the two
%% checks refused them -- being told only "too large" by one of them and the
%% actual number by the other is the kind of difference that sends someone
%% looking for a second bug.
to_error({permanent, too_large_payload, {too_large_payload, Size, Max}}) ->
    to_error({too_large_payload, Size, Max});
to_error({permanent, too_large_payload, _}) ->
    bondy_error:new(too_large_payload);
to_error({invalid_request, Reason}) ->
    bondy_error:new(invalid_request, #{details => #{reason => Reason}});
to_error({transient, rate_limited, Name}) ->
    relay_error(rate_limit_exceeded, Name);
to_error({transient, queue_full, Name}) ->
    relay_error(mail_queue_full, Name);
to_error({transient, queue_unavailable, _}) ->
    bondy_error:new(relay_unavailable);
%% The owner is a Bondy node, not a relay: S004 says exactly this, and saying
%% the relay is unavailable would send an operator to inspect a healthy one.
to_error({transient, owner_unavailable, _}) ->
    bondy_error:new(unavailable);
to_error({transient, status_unavailable, _}) ->
    bondy_error:new(unavailable);
to_error({transient, Class, _}) when
    Class == timeout orelse Class == deadline
->
    bondy_error:new(request_timeout);
to_error({transient, network, _}) ->
    bondy_error:new(relay_unavailable);
to_error({permanent, rejected, Code}) ->
    bondy_error:new(mail_rejected, #{details => reply_code(Code)});
to_error({transient, deferred, Code}) ->
    bondy_error:new(mail_delivery_failed, #{details => reply_code(Code)});
%% A message Bondy could not encode is Bondy's defect, not the caller's, and
%% the catalogue's contract for those is a trace id and nothing else.
to_error({permanent, encoding_failed, _} = Reason) ->
    bondy_error:internal(Reason);
to_error({permanent, _, _}) ->
    bondy_error:new(mail_rejected);
to_error({transient, _, _}) ->
    bondy_error:new(mail_delivery_failed);
to_error(Other) ->
    bondy_error:internal(Other).

%% =============================================================================
%% REMOTE CALLBACKS
%% =============================================================================

-doc """
Accept a request on this node, without routing it anywhere else.

This is the far end of a routed send, exported because a peer calls it by name.
It never routes: ownership was decided by the node that called it, and letting
this re-route would let two nodes with slightly different views of membership
bounce a request between them indefinitely.

Everything else is identical to `send/2` and `send_async/2`, including
validation and authority, which are re-run here against this node's own relay
declaration.
""".
-spec accept(
    RealmUri :: binary(),
    Request :: map(),
    Kind :: send | send_async
) -> {ok, map()} | {error, any()}.

accept(RealmUri, Map, Kind) ->
    accept(RealmUri, Map, Kind, #{}).

-doc "As `accept/3`, naming the surface the request came from.".
-spec accept(
    RealmUri :: binary(),
    Request :: map(),
    Kind :: send | send_async,
    Opts :: opts()
) -> {ok, map()} | {error, any()}.

accept(RealmUri, Map, Kind, Opts) when
    is_binary(RealmUri) andalso
        is_map(Map) andalso
        is_map(Opts) andalso
        (Kind == send orelse Kind == send_async)
->
    case is_configured() of
        false ->
            {error, not_configured};
        true ->
            do_accept(RealmUri, Map, Kind, Opts)
    end;
accept(_, _, _, _) ->
    {error, {invalid_request, badarg}}.

-doc """
Return `true` when at least one relay is configured and usable.

A relay whose credential could not be resolved is not counted: it was dropped
at startup with an error naming it, because attempting delivery
unauthenticated is worse than not attempting it.
""".
-spec is_configured() -> boolean().

is_configured() ->
    bondy_mail_config:is_configured().

-doc """
Return the name of the relay used when a request does not name one.

`mail.default_relay` when set, otherwise the only configured relay when there
is exactly one. With several relays and no default, `undefined`: naming one is
then the caller's job, and guessing on their behalf is how mail goes out
through the wrong relay.
""".
-spec default_relay() -> optional(binary()).

default_relay() ->
    case bondy_mail_config:default_relay() of
        {ok, Name} -> Name;
        {error, no_such_relay} -> undefined
    end.

-doc "Return the names of every usable relay, sorted.".
-spec relay_names() -> [binary()].

relay_names() ->
    bondy_mail_config:relay_names().

-doc """
Return what is safe to report about every relay `RealmUri` may use.

Name, transport, status and default sender only -- never the host, the username
or the credential.

Filtered, not annotated: a realm is not shown a relay it would be refused,
because a list of things you cannot have is an invitation to try them. There is
deliberately no unfiltered form of this: an authority-sensitive list with a
realm-scoped variant beside it is two functions where the wrong one is easy to
reach for.
""".
-spec relays(RealmUri :: binary()) -> [bondy_mail_relay:info()].

relays(RealmUri) when is_binary(RealmUri) ->
    lists:filtermap(
        fun(Name) ->
            case permitted_relay(RealmUri, Name) of
                true -> info_or_false(Name);
                false -> false
            end
        end,
        relay_names()
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Dormancy is answered before anything else, so an unconfigured node gives the
%% same clear reason whatever the request looked like.
dispatch(RealmUri, Map, Kind, Opts) when
    is_binary(RealmUri) andalso is_map(Map)
->
    case is_configured() of
        false ->
            {error, not_configured};
        true ->
            Key = bondy_mail_request:idempotency_key(Map),
            case bondy_mail_status:owner(RealmUri, Key) of
                local ->
                    accept(RealmUri, Map, Kind, Opts);
                {remote, Node} ->
                    route(Node, RealmUri, Map, Kind, Opts)
            end
    end;
dispatch(_, _, _, _) ->
    {error, {invalid_request, badarg}}.

%% @private
%% Rejections are counted here rather than at each `?=`, because there are five
%% ways to be refused and one place that knows what happened to all of them.
do_accept(RealmUri, Map, Kind, Opts) ->
    case bondy_mail_request:new(RealmUri, Map) of
        {ok, Request} ->
            Relay = bondy_mail_request:relay(Request),
            case rate_limit(Request) of
                ok ->
                    Surface = maps:get(surface, Opts, rpc),
                    ok = bondy_mail_telemetry:accepted(
                        Relay, RealmUri, Surface
                    ),
                    run(Request, Kind);
                {error, {transient, rate_limited, _}} = Error ->
                    ok = bondy_mail_telemetry:rate_limited(Relay, RealmUri),
                    Error;
                {error, _} = Error ->
                    Error
            end;
        {error, Reason} = Error ->
            ok = report_rejection(Map, Reason),
            Error
    end.

%% @private
%% Only the refusals that say something about pressure or authority are
%% counted. A malformed request is a caller's mistake and belongs in the
%% caller's error, not in a relay's rejection rate -- mixing them makes the
%% metric useless for the thing it is watched for.
report_rejection(_Map, {relay_not_permitted, Relay}) ->
    bondy_mail_telemetry:rejected(Relay, not_permitted);
report_rejection(_Map, {sender_not_permitted, Relay, _Address}) ->
    bondy_mail_telemetry:rejected(Relay, not_permitted);
report_rejection(Map, {too_large_payload, _Size, _Max}) ->
    bondy_mail_telemetry:rejected(named_relay(Map), oversized);
report_rejection(_Map, _Reason) ->
    ok.

%% @private
%% What the request asked for, which may be nothing and may be nonsense -- the
%% name is a label, and this is reached only on paths where the relay was never
%% resolved.
named_relay(Map) when is_map(Map) ->
    case maps:get(~"relay", Map, undefined) of
        Name when is_binary(Name) -> Name;
        _ -> undefined
    end;
named_relay(_) ->
    undefined.

%% @private
%% An owner that cannot be reached is a transient failure, not a reason to send
%% locally: falling back would defeat the deduplication the caller asked for by
%% supplying a key. A retry re-selects an owner from whatever membership has
%% settled to.
route(Node, RealmUri, Map, Kind, Opts) ->
    Args = [RealmUri, Map, Kind, Opts],
    Timeout = route_timeout(Map, Kind),
    try partisan_rpc:call(Node, ?MODULE, accept, Args, Timeout) of
        {badrpc, Reason} ->
            ok = log_route_failure(Node, RealmUri, Reason),
            {error, {transient, owner_unavailable, Node}};
        Result ->
            Result
    catch
        Class:Reason ->
            ok = log_route_failure(Node, RealmUri, {Class, Reason}),
            {error, {transient, owner_unavailable, Node}}
    end.

%% @private
%% A routed `send_async` returns as soon as the owner has queued the message,
%% so it needs no more than the hop. A routed `send` waits for delivery, which
%% the owner bounds by the request's own budget.
route_timeout(_Map, send_async) ->
    ?ROUTE_OVERHEAD;
route_timeout(Map, send) ->
    bondy_mail_request:budget(Map) + ?ROUTE_OVERHEAD.

%% @private
run(Request, Kind) ->
    case bondy_mail_status:claim(Request) of
        {ok, claimed} ->
            deliver(Request, Kind);
        {ok, {duplicate, Info}} ->
            {ok, Info#{duplicate => true}};
        {error, _} = Error ->
            Error
    end.

%% @private
%% A claim is given back only when no relay was ever shown the message. Here
%% that means only when enqueueing itself failed; a worker that sheds a message
%% gives the claim back for itself, through `bondy_mail_status:shed/2`. Once a
%% relay has been shown the message the claim stands whatever the outcome,
%% including a timeout: Bondy cannot tell a relay that never saw a message from
%% one that accepted it and then dropped the connection, so a failure is not
%% licence to send it twice. A caller who wants another attempt uses another key.
%%
%% Releasing on any error instead would leave exactly one hole -- a send whose
%% await expired while its worker was still delivering -- through which the same
%% key could be sent twice.
deliver(Request, send) ->
    Id = bondy_mail_request:message_id(Request),
    %% An alias rather than a reference: see await/2.
    Ref = alias([reply]),
    case bondy_mail_worker:enqueue(Request, {self(), Ref}) of
        ok ->
            case await(Request, Ref) of
                {ok, Result} -> {ok, Result#{id => Id, status => sent}};
                {error, _} = Error -> Error
            end;
        {error, Reason} = Error ->
            _ = unalias(Ref),
            ok = bondy_mail_status:release(Request),
            ok = report_enqueue_failure(Request, Reason),
            Error
    end;
deliver(Request, send_async) ->
    Id = bondy_mail_request:message_id(Request),
    case bondy_mail_worker:enqueue(Request, undefined) of
        ok ->
            {ok, #{id => Id, status => queued}};
        {error, Reason} = Error ->
            ok = bondy_mail_status:release(Request),
            ok = report_enqueue_failure(Request, Reason),
            Error
    end.

%% @private
report_enqueue_failure(_Request, {transient, queue_full, Name}) ->
    bondy_mail_telemetry:rejected(Name, queue_full);
report_enqueue_failure(_Request, _Reason) ->
    ok.

%% @private
info_or_false(Name) ->
    case bondy_mail_relay:info(Name) of
        {ok, Info} -> {true, Info};
        {error, _} -> false
    end.

%% @private
permitted_relay(RealmUri, Name) ->
    case bondy_mail_config:relay(Name) of
        {ok, Relay} -> bondy_mail_request:is_realm_permitted(RealmUri, Relay);
        {error, no_such_relay} -> false
    end.

%% @private
relay_error(Type, Name) when is_binary(Name) ->
    bondy_error:new(Type, #{details => #{relay => Name}});
relay_error(Type, _) ->
    bondy_error:new(Type).

%% @private
%% Only a three-digit reply code survives. The rest of a relay's rejection text
%% can echo the recipient, the subject, or whatever else that relay's operator
%% decided to put in a banner.
%%
%% The transport already truncates to the code, so this checks the shape rather
%% than trusting it: this is the last thing between a relay's own words and a
%% caller, and a second cheap check here is worth more than the line it costs.
%% The predicate itself lives in `bondy_mail_transport` -- checking twice is the
%% point, defining twice is not.
reply_code(Code) ->
    case bondy_mail_transport:is_reply_code(Code) of
        true -> #{code => Code};
        false -> #{}
    end.

%% @private
log_route_failure(Node, RealmUri, Reason) ->
    ?LOG_WARNING(#{
        description => "Could not route mail request to its owning node",
        node => Node,
        realm_uri => RealmUri,
        reason => Reason
    }),
    ok.

%% @private
%% The worker answers past the deadline only if it overran; the timeout here is
%% a backstop so a caller is never held indefinitely by a worker that died
%% between accepting the message and replying.
%%
%% `Ref` is a process alias, not a bare reference, and that is what makes the
%% timeout safe. A worker that answers after this has given up sends to a dead
%% alias and the runtime drops the message; a plain `Pid ! {_, Ref, _}` would
%% leave it in the caller's mailbox for ever. Callers here are router pool
%% processes, and whether that leaked depended on `load_regulation.router.pool.
%% type`: transient workers die and take it with them, permanent ones do not.
%% Correctness that depends on someone else's pool setting is not correctness.
await(Request, Ref) ->
    Timeout =
        max(
            0,
            bondy_mail_request:deadline(Request) -
                erlang:monotonic_time(millisecond)
        ) + 1000,
    receive
        {bondy_mail, Ref, Result} ->
            %% `alias([reply])` deactivates itself once a message sent through
            %% it is received, so there is nothing to release here.
            Result
    after Timeout ->
        _ = unalias(Ref),
        %% Deactivated above, but a reply may already have been sent before
        %% that took effect. One non-blocking check clears it.
        ok = flush(Ref),
        {error, {transient, timeout, Timeout}}
    end.

%% @private
flush(Ref) ->
    receive
        {bondy_mail, Ref, _} -> ok
    after 0 ->
        ok
    end.

%% @private
%% Keyed per relay, so one busy realm cannot spend another relay's budget. The
%% limiter fails open if its own subsystem is unavailable, which is the right
%% trade: a rate limit protects a relay, and losing the limiter should not stop
%% mail.
rate_limit(Request) ->
    Name = bondy_mail_request:relay(Request),
    case bondy_mail_config:relay(Name) of
        {ok, #bondy_mail_relay{rate_limit_rate = 0}} ->
            ok;
        {ok, Relay} ->
            Opts = #{
                rate => Relay#bondy_mail_relay.rate_limit_rate,
                capacity => Relay#bondy_mail_relay.rate_limit_burst
            },
            case bondy_rate_limiter:allow({bondy_mail, Name}, Opts) of
                true -> ok;
                false -> {error, {transient, rate_limited, Name}}
            end;
        {error, no_such_relay} ->
            {error, {permanent, no_such_relay, Name}}
    end.
