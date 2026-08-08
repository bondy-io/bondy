%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_transport).

-moduledoc """
How a message actually leaves the node.

There is one implementation, `bondy_mail_transport_smtp`. The behaviour exists
so that a provider API -- SES, SendGrid, Postmark -- can be added later without
disturbing anything above it: the worker, the retry budget, the rate limiter
and both surfaces all sit on this contract rather than on SMTP.

## The contract that matters

`send/3` classifies its own failures, because only the transport can. A `4xx`
and a `5xx` are both "the relay said no", and only something that speaks the
protocol knows that the first is worth retrying and the second never will be.
Returning an unclassified error would push that judgement up to a layer with
less information, which is how systems end up retrying a rejected recipient
forever.

`permanent` means no amount of retrying changes the answer: the address is
malformed, the message is too large, the credentials are wrong. `transient`
means the condition is in the relay, the network or the moment: a 4xx, a
timeout, a TLS handshake that failed. This is the same axis as
`bondy_error`'s `nature` field, so a classification here maps onto the error
catalogue without translation.
""".

-include("bondy_mail.hrl").

-type nature() :: permanent | transient.
-type reason() :: {nature(), Class :: atom(), Detail :: any()}.

-export_type([nature/0]).
-export_type([reason/0]).

%% =============================================================================
%% CALLBACKS
%% =============================================================================

-doc """
Deliver one encoded message.

`Receipt` is whatever the relay returned to identify the message, for the log
and for `bondy.mail.status.get`. It is not a delivery guarantee: it means the
relay accepted responsibility, nothing more.
""".
-callback send(
    Request :: #bondy_mail_request{},
    Message :: binary(),
    Relay :: #bondy_mail_relay{}
) ->
    {ok, Receipt :: binary()} | {error, reason()}.
