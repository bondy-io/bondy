%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-include_lib("bondy_stdlib/include/bondy_stdlib.hrl").

-ifndef(BONDY_MAIL_HRL).
-define(BONDY_MAIL_HRL, true).

%% A relay is operator-owned infrastructure: it is declared in `bondy.conf` and
%% never in a bridge specification or an RPC argument. `realms` and
%% `allowed_from` are the two authority fields -- which realms may send through
%% it, and which sender identities they may claim -- and both default to closed.
-record(bondy_mail_relay, {
    name :: binary(),
    host :: binary(),
    port :: inet:port_number(),
    transport :: plain | starttls | tls,
    username :: optional(binary()),
    %% Opaque. See bondy_mail_secret: it cannot be printed by accident.
    secret :: optional(bondy_mail_secret:t()),
    auth :: always | if_available | never,
    tls_verify :: verify_peer | verify_none,
    tls_cacertfile :: optional(binary()),
    %% The default envelope and header From. A request that does not name a
    %% sender gets this one, which is why a caller cannot spoof by default.
    from :: optional(binary()),
    %% Domains a caller may claim in `from`. `[]` means callers cannot set it;
    %% `any` disables spoofing protection for this relay.
    allowed_from :: [binary()] | any,
    %% Realm URIs, or prototype URIs, permitted to use this relay. `any` means
    %% every realm; `[]` means the master realm only.
    realms :: [binary()] | any,
    %% The module delivering for this relay. One implementation today,
    %% `bondy_mail_transport_smtp`; the worker dispatches on this value rather
    %% than naming a module, so a provider transport is a new module and a
    %% configuration value rather than an edit to the delivery path.
    transport_mod :: module(),
    pool_size :: pos_integer(),
    %% Round-robin cursor over the relay's workers, held here so that picking
    %% one is a wait-free atomic increment off the relay's own record rather
    %% than a call to anything. See bondy_mail_worker:pick_worker/2.
    pool_cursor :: atomics:atomics_ref(),
    %% Two counters: messages queued for this relay, and the bytes they hold.
    %% Both are reserved before a message is handed to a worker and released
    %% when one takes it, so the pair IS the admission bound rather than a
    %% description of it. See bondy_mail_worker:reserve/2.
    queue_counters :: atomics:atomics_ref(),
    queue_max_size :: pos_integer(),
    %% The same bound expressed in bytes. A bound in messages alone bounds
    %% nothing: one message may be a hundred bytes or twenty megabytes, and a
    %% queue that holds a thousand of the latter is not bounded in any sense an
    %% operator cares about.
    queue_max_bytes :: pos_integer(),
    queue_ttl :: pos_integer(),
    timeout :: pos_integer(),
    retry_max_attempts :: non_neg_integer(),
    retry_backoff_min :: pos_integer(),
    retry_backoff_max :: pos_integer(),
    %% Messages per second. 0 disables the limit.
    rate_limit_rate :: number(),
    rate_limit_burst :: pos_integer(),
    max_message_size :: pos_integer(),
    %% Envelope recipients allowed in one message. RFC 5321 obliges a server to
    %% accept 100, so that is the default; a single request naming thousands is
    %% one SMTP transaction a relay will refuse anyway, and refusing it here
    %% costs the relay nothing.
    max_recipients :: pos_integer(),
    %% Consecutive TRANSIENT failures that mark the relay down, and consecutive
    %% successes that clear the alarm again. Traffic recovers on the first
    %% success regardless; only the alarm waits. See bondy_mail_relay.
    health_failure_threshold :: pos_integer(),
    health_success_threshold :: pos_integer()
}).

%% One decoded attachment. `data` is raw bytes: the base64 a caller sends on the
%% wire is decoded during validation, so size limits apply to what actually goes
%% into the message rather than to its encoding.
-record(bondy_mail_attachment, {
    filename :: binary(),
    content_type :: binary(),
    data :: binary()
}).

%% The one request both surfaces build. `realm` is filled from the caller's
%% session and is not a field a caller can set -- see bondy_mail_request:new/2.
-record(bondy_mail_request, {
    %% Caller-supplied idempotency key. Also decides which node owns the
    %% message, so that a retry landing on another node still deduplicates.
    id :: optional(binary()),
    %% Bondy-assigned and always present. Carries the owning node, so that any
    %% node can route a status query from the id alone. Derived from `id` when
    %% there is one, which is what makes a retry find the original message
    %% rather than mint a second.
    message_id :: binary(),
    realm :: binary(),
    relay :: binary(),
    %% ALWAYS a bare address, never `Name <addr>`. It feeds the SMTP envelope
    %% and the `allowed_from` domain check, and neither may see a display name:
    %% `MAIL FROM:<...>` cannot carry one, and a domain check against a string
    %% with a name in it would let `Trusted <x@evil.com>` past an allow-list.
    %% The display name lives beside it and is used only to build the header.
    from :: binary(),
    from_name :: optional(binary()),
    to :: [binary()],
    cc :: [binary()],
    bcc :: [binary()],
    reply_to :: optional(binary()),
    reply_to_name :: optional(binary()),
    subject :: binary(),
    text :: optional(binary()),
    html :: optional(binary()),
    headers :: [{binary(), binary()}],
    attachments :: [#bondy_mail_attachment{}],
    %% Everything that becomes the message: subject, bodies, headers and
    %% decoded attachments. Measured once, at validation, and used twice --
    %% to refuse an oversized request before it is queued, and to reserve the
    %% queue's byte budget. The encoded message is measured again exactly, in
    %% bondy_mail_mime; this is the estimate that keeps the oversized ones out
    %% of the queue in the first place.
    size_bytes :: non_neg_integer(),
    %% Selects the worker's lane. `normal` is served before `low`, and within a
    %% lane the order is the order of arrival.
    priority :: normal | low,
    timeout :: pos_integer(),
    %% `erlang:monotonic_time(millisecond)` past which no further attempt is
    %% made. Carried rather than recomputed so retries share one budget.
    deadline :: integer()
}).

-endif.
