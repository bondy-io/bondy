%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_broker_bridge).

-moduledoc """
Behaviour for event bridge implementations.

A broker bridge consumes WAMP events via a supervised `bondy_subscriber`
process and forwards them to an external system (message broker, email
service, SMS gateway, etc.) after applying a `mops` template
transformation to the action specification.

Each bridge implementation exports four callbacks:

- `init/1` — set up connections and return a context map for `mops`
- `validate_action/1` — parse and validate an action spec before execution
- `apply_action/1` — execute the action (produce to Kafka, send email, etc.)
- `terminate/2` — tear down connections and stop dependent applications

## Shipped implementations

| Module | Sink |
|--------|------|
| `bondy_kafka_bridge` | Apache Kafka (via `brod`) |
| `bondy_aws_sns_bridge` | AWS SNS SMS (via `erlcloud`) |
| `bondy_smtp_bridge` | Email over SMTP (via `bondy_mail`) |
| `bondy_sendgrid_bridge` | SendGrid email (via `email`) |
| `bondy_mailgun_bridge` | Mailgun email (via `email`) |

`bondy_smtp_bridge` is the one to reach for. The SendGrid and Mailgun bridges
predate it and share the `email` application, which they configure through the
global application environment -- so enabling both at once is mutually
destructive, and only one provider can be used per node.

## What a callback may not do

`apply_action/1` runs inside the subscriber process that is delivering the
event. Anything slow there is slow for every subsequent event on that
subscription, so a callback must hand work to something else rather than wait
for it. `bondy_smtp_bridge` queues a message and returns; it never waits for an
SMTP conversation.
""".

%% =============================================================================
%% CALLBACKS
%% =============================================================================

-doc """
Initialise the external broker or system as an event sink.

Use this callback to set up the environment, load any plugin code, and
connect to the external system. The returned context map is merged into
the `mops` evaluation context under the bridge's namespace key so that
action templates can reference bridge-specific values.
""".
-callback init(Config :: any()) ->
    {ok, Ctxt :: #{binary() => any()}} | {error, Reason :: any()}.

-doc """
Parse and validate the action `Action`.

Called after `mops:eval/2` has expanded template expressions but before
`apply_action/1`. Use this callback to set defaults, coerce types, and
reject malformed actions early.
""".
-callback validate_action(Action :: map()) ->
    {ok, ValidAction :: map()} | {error, Reason :: any()}.

-doc """
Execute the action `Action`.

Returns `ok` on success, `{retry, Reason}` to request automatic retry
(e.g. transient connection loss), or `{error, Reason}` for permanent
failures.
""".
-callback apply_action(Action :: map()) ->
    ok
    | {retry, Reason :: any()}
    | {error, Reason :: any()}.

-doc """
Terminate the bridge and clean up resources.

Called during manager shutdown. Implementations should stop dependent
applications, close connections, and release any external resources.
""".
-callback terminate(Reason :: any(), State :: any()) -> ok.
