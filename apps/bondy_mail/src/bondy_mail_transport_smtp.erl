%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_transport_smtp).

-moduledoc """
Delivery over SMTP, using `gen_smtp_client`.

Runs only inside a `bondy_mail_worker`. Nothing on this path may be called from
a router process: it blocks for as long as a relay takes to answer.

## Two things are deliberately switched off

**MX lookups.** A relay is a host an operator named, not a domain to be
resolved. Looking up MX records for `smtp.example.com` would send mail
somewhere other than where the operator pointed.

**`gen_smtp`'s own retries.** They are set to zero, because `bondy_mail_worker`
retries with a jittered budget bounded by the request's deadline. Leaving both
enabled multiplies the attempts a relay sees by a factor nothing reports, and
the deadline stops meaning anything.

## Classification

`gen_smtp` already separates a 4xx from a 5xx, which is the distinction that
matters and the one only something speaking the protocol can make. This module
maps its vocabulary onto `permanent | transient`:

| gen_smtp | Nature | Why |
| --- | --- | --- |
| `permanent_failure` | permanent | A 5xx. The relay will say the same thing next time. |
| `temporary_failure` | transient | A 4xx, including greylisting and a failed TLS handshake. |
| `network_failure` | transient | Timeout, refused, unreachable. |
| `unexpected_response` | transient | The relay is not making sense; it may later. |
| `missing_requirement` | permanent | We require AUTH or TLS and the relay does not offer it. A configuration mismatch, and retrying only repeats it. |
| option errors | permanent | The relay is misconfigured. |
""".

-behaviour(bondy_mail_transport).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mail.hrl").

%% BONDY_MAIL_TRANSPORT CALLBACKS
-export([send/3]).

%% =============================================================================
%% BONDY_MAIL_TRANSPORT CALLBACKS
%% =============================================================================

-doc "Deliver one encoded message, classifying any failure.".
-spec send(
    Request :: #bondy_mail_request{},
    Message :: binary(),
    Relay :: #bondy_mail_relay{}
) ->
    {ok, binary()} | {error, bondy_mail_transport:reason()}.

send(#bondy_mail_request{} = Request, Message, #bondy_mail_relay{} = Relay) ->
    From = binary_to_list(Request#bondy_mail_request.from),
    To = [binary_to_list(R) || R <- bondy_mail_request:recipients(Request)],
    Email = {From, To, Message},

    try gen_smtp_client:send_blocking(Email, options(Relay)) of
        Receipt when is_binary(Receipt) ->
            {ok, Receipt};
        Receipts when is_list(Receipts) ->
            %% LMTP answers per recipient. Not a protocol we speak today, but
            %% answering something coherent beats crashing if one appears.
            {ok, iolist_to_binary(io_lib:format("~p", [Receipts]))};
        {error, _, _} = Error ->
            {error, classify(Error)};
        {error, _} = Error ->
            {error, classify(Error)}
    catch
        Class:Reason:Stacktrace ->
            %% `send_blocking/2` links to a worker process that exits on
            %% failure, so some failures arrive as exits rather than returns.
            ?LOG_DEBUG(#{
                description => "SMTP delivery raised",
                relay => Relay#bondy_mail_relay.name,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, classify_exception(Reason)}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
options(#bondy_mail_relay{} = Relay) ->
    #bondy_mail_relay{
        host = Host,
        port = Port,
        transport = Transport,
        auth = Auth,
        timeout = Timeout
    } = Relay,

    Base = [
        {relay, binary_to_list(Host)},
        {port, Port},
        {timeout, Timeout},
        %% A relay is a host, not a domain to resolve.
        {no_mx_lookups, true},
        %% Retry policy lives in bondy_mail_worker. See the module docs.
        {retries, 0},
        {auth, Auth}
    ],

    Base ++ transport_options(Transport, Relay) ++ credentials(Relay).

%% @private
%% `starttls` requires the upgrade and fails if the relay will not offer it --
%% `if_available` would silently fall back to plaintext, which is not what
%% asking for STARTTLS means.
transport_options(plain, _Relay) ->
    [{ssl, false}, {tls, never}];
transport_options(starttls, Relay) ->
    [{ssl, false}, {tls, always}, {tls_options, tls_options(Relay)}];
transport_options(tls, Relay) ->
    %% `sockopts`, not `tls_options`. gen_smtp reads `tls_options` only when it
    %% upgrades an established plaintext connection; the options for a
    %% connection that is encrypted from the first byte come from `sockopts`,
    %% which it passes to `smtp_socket:connect/5`
    %% (`gen_smtp_client.erl:849-875`).
    %%
    %% Putting them in `tls_options` therefore does not fail -- it is silently
    %% ignored, and `ssl:connect/4` runs on its own defaults. A relay declared
    %% `transport = tls` with `tls.verify = verify_peer` would have connected
    %% with whatever the runtime defaults to rather than with the verification
    %% the operator asked for. Caught by `bondy_mail_mailpit_SUITE`, which is
    %% the first test to speak implicit TLS to anything.
    [{ssl, true}, {tls, never}, {sockopts, tls_options(Relay)}].

%% @private
tls_options(#bondy_mail_relay{tls_verify = verify_none}) ->
    [{verify, verify_none}];
tls_options(#bondy_mail_relay{} = Relay) ->
    Host = binary_to_list(Relay#bondy_mail_relay.host),
    Base = [
        {verify, verify_peer},
        {depth, 5},
        %% Without this a certificate valid for any host is accepted, which
        %% makes verification close to worthless against an active attacker.
        {server_name_indication, Host},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ],
    Base ++ cacerts(Relay).

%% @private
cacerts(#bondy_mail_relay{tls_cacertfile = undefined}) ->
    %% The OS trust store, which is what a public relay is signed against.
    [{cacerts, public_key:cacerts_get()}];
cacerts(#bondy_mail_relay{tls_cacertfile = File}) ->
    [{cacertfile, binary_to_list(File)}].

%% @private
%% The credential is exposed here and nowhere else, as an argument, and is not
%% bound into anything that outlives the call.
credentials(#bondy_mail_relay{username = undefined}) ->
    [];
credentials(#bondy_mail_relay{secret = undefined}) ->
    [];
credentials(#bondy_mail_relay{username = Username, secret = Secret}) ->
    [
        {username, binary_to_list(Username)},
        {password, binary_to_list(bondy_mail_secret:expose(Secret))}
    ].

%% @private
classify({error, _Stage, {permanent_failure, _Host, Reason}}) ->
    {permanent, rejected, detail(Reason)};
classify({error, _Stage, {temporary_failure, _Host, Reason}}) ->
    {transient, deferred, detail(Reason)};
classify({error, _Stage, {network_failure, _Host, {error, timeout}}}) ->
    {transient, timeout, timeout};
classify({error, _Stage, {network_failure, _Host, {error, Posix}}}) ->
    {transient, network, Posix};
classify({error, _Stage, {missing_requirement, _Host, What}}) ->
    {permanent, missing_requirement, What};
classify({error, _Stage, {unexpected_response, _Host, _Responses}}) ->
    %% The responses can quote the conversation, including anything the relay
    %% chose to echo. Kept out of the reason so it cannot reach a caller.
    {transient, unexpected_response, unexpected_response};
classify({error, Reason}) when
    Reason == no_relay orelse Reason == invalid_port orelse
        Reason == no_credentials
->
    {permanent, configuration, Reason};
classify(Other) ->
    ?LOG_DEBUG(#{
        description => "Unclassified SMTP failure",
        reason => Other
    }),
    {transient, unknown, unknown}.

%% @private
%% An exit carrying a classified failure keeps its classification.
classify_exception({error, _, _} = Error) ->
    classify(Error);
classify_exception({no_more_hosts, {permanent_failure, _Host, Reason}}) ->
    {permanent, rejected, detail(Reason)};
classify_exception(timeout) ->
    {transient, timeout, timeout};
classify_exception(_Other) ->
    {transient, unknown, unknown}.

%% @private
%% A relay's rejection text can echo the recipient or the message. Keep only
%% the reply code, which is what a caller can act on, and let the log hold the
%% rest -- the error catalogue's contract is that a peer never receives
%% anything the server could not vouch for.
detail(Bin) when is_binary(Bin) ->
    case Bin of
        <<Code:3/binary, _/binary>> ->
            case bondy_mail_transport:is_reply_code(Code) of
                true -> Code;
                false -> unspecified
            end;
        _ ->
            unspecified
    end;
detail(Atom) when is_atom(Atom) ->
    Atom;
detail(_) ->
    unspecified.
