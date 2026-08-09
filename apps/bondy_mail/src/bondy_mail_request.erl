%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_request).

-moduledoc """
The one request both surfaces build, and the authority checks applied to it.

`new/2` takes the calling realm and a caller-supplied map and answers a
validated `#bondy_mail_request{}` or an error. Both the broker bridge and the
`bondy.mail.*` API go through here, which is what stops the two from drifting
apart on what is allowed.

## The realm is not a field

The realm is the first argument, taken from the caller's session. It is not a
key a caller can set, and supplying one is rejected as an unknown key. A caller
cannot send on behalf of another realm because there is nowhere to say so.

## Sender identity is derived, not asserted

A request that names no sender gets the relay's configured `from`. A request
that names one must fall inside that relay's `allowed_from`, which is empty by
default -- so a relay whose owner has not said which domains it owns does not
let a caller choose. Validating an asserted sender against a list fails open
when the list is missing; defaulting and then narrowing cannot.

## Unknown keys are rejected

`maps_utils:validate/2` silently drops keys it does not know, which would turn
a misspelled `subjekt` into a message with no subject. The residue is diffed
and reported instead.
""".

-include_lib("kernel/include/logger.hrl").
-include("bondy_mail.hrl").

%% Encoding inflates a message: base64 costs a third on top of the raw bytes,
%% and headers and boundaries add more. The decoded budget is scaled down so
%% that a request accepted here is unlikely to be rejected by the relay for
%% size after encoding -- the encoded size is checked exactly, later.
-define(ENCODING_HEADROOM, 0.7).

%% Used only to size a routed call when the relay cannot be resolved on this
%% node. Matches the relay `timeout` default.
-define(DEFAULT_BUDGET, 30000).

-define(SPEC, #{
    ~"id" => #{
        alias => id,
        key => id,
        required => true,
        default => undefined,
        allow_null => false,
        allow_undefined => true,
        datatype => binary
    },
    ~"relay" => #{
        alias => relay,
        key => relay,
        required => true,
        default => undefined,
        allow_null => false,
        allow_undefined => true,
        datatype => binary
    },
    ~"from" => #{
        alias => from,
        key => from,
        required => true,
        default => undefined,
        allow_null => false,
        allow_undefined => true,
        datatype => binary
    },
    ~"to" => #{
        alias => to,
        key => to,
        required => true,
        allow_null => false,
        allow_undefined => false
    },
    ~"cc" => #{
        alias => cc,
        key => cc,
        required => true,
        default => [],
        allow_null => false,
        allow_undefined => false
    },
    ~"bcc" => #{
        alias => bcc,
        key => bcc,
        required => true,
        default => [],
        allow_null => false,
        allow_undefined => false
    },
    ~"reply_to" => #{
        alias => reply_to,
        key => reply_to,
        required => true,
        default => undefined,
        allow_null => false,
        allow_undefined => true,
        datatype => binary
    },
    ~"subject" => #{
        alias => subject,
        key => subject,
        required => true,
        default => ~"",
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    ~"text" => #{
        alias => text,
        key => text,
        required => true,
        default => undefined,
        allow_null => false,
        allow_undefined => true,
        datatype => binary
    },
    ~"html" => #{
        alias => html,
        key => html,
        required => true,
        default => undefined,
        allow_null => false,
        allow_undefined => true,
        datatype => binary
    },
    ~"headers" => #{
        alias => headers,
        key => headers,
        required => true,
        default => #{},
        allow_null => false,
        allow_undefined => false,
        datatype => map
    },
    ~"attachments" => #{
        alias => attachments,
        key => attachments,
        required => true,
        default => [],
        allow_null => false,
        allow_undefined => false,
        datatype => list
    },
    ~"priority" => #{
        alias => priority,
        key => priority,
        required => true,
        default => normal,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (normal) -> true;
            (low) -> true;
            (~"normal") -> {ok, normal};
            (~"low") -> {ok, low};
            (_) -> {error, ~"Expected 'normal' or 'low'."}
        end
    },
    ~"timeout" => #{
        alias => timeout,
        key => timeout,
        required => true,
        default => undefined,
        allow_null => false,
        allow_undefined => true,
        datatype => pos_integer
    }
}).

-type t() :: #bondy_mail_request{}.

-export_type([t/0]).

%% API
-export([budget/1]).
-export([deadline/1]).
-export([id/1]).
-export([idempotency_key/1]).
-export([is_realm_permitted/2]).
-export([message_id/1]).
-export([new/2]).
-export([realm/1]).
-export([recipients/1]).
-export([relay/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Validate a caller-supplied request against a realm.

`RealmUri` comes from the caller's session. `Map` may use binary or atom keys.
""".
-spec new(RealmUri :: binary(), Map :: map()) -> {ok, t()} | {error, any()}.

new(RealmUri, Map0) when is_binary(RealmUri) andalso is_map(Map0) ->
    Map = normalise_keys(Map0),
    maybe
        ok ?= reject_unknown(Map),
        {ok, Valid} ?= validate(Map),
        {ok, Relay} ?= resolve_relay(RealmUri, Valid),
        {ok, Request} ?= build(RealmUri, Relay, Valid),
        {ok, Request}
    end;
new(_, _) ->
    {error, {invalid_request, badarg}}.

-doc "Return the request's idempotency key, if it carries one.".
-spec id(Request :: t()) -> optional(binary()).

id(#bondy_mail_request{id = Id}) ->
    Id.

-doc """
Return the message id Bondy assigned.

Always present, and always naming the node holding the message's status record.
""".
-spec message_id(Request :: t()) -> binary().

message_id(#bondy_mail_request{message_id = Id}) ->
    Id.

-doc """
Return the idempotency key in a caller-supplied map, before validation.

Ownership has to be decided before a request is validated, because validation
is the owner's job -- it is the owner's relay declaration that decides whether
the request is allowed at all. So this reads one key out of the raw map and
answers `undefined` for anything that is not a non-empty binary, leaving the
real complaint to `new/2`.
""".
-spec idempotency_key(Map :: map()) -> optional(binary()).

idempotency_key(Map) when is_map(Map) ->
    case maps:get(~"id", Map, maps:get(id, Map, undefined)) of
        Key when is_binary(Key) andalso byte_size(Key) > 0 -> Key;
        _ -> undefined
    end;
idempotency_key(_) ->
    undefined.

-doc """
Return how long a request may take in total, in milliseconds.

Used to size a routed call: the owning node bounds the request -- and every
retry inside it -- by this same budget, so it is the whole of what a caller can
wait for. Read from this node's copy of the relay declaration, which is the
same file the owner reads.

Answers the relay's timeout for a request that does not ask for one, and a
default when the relay cannot be resolved here at all. Getting this wrong costs
a caller a premature timeout on a request that may still be delivered; it
cannot cause a message to be sent twice, because the owner's own deadline is
what stops the work.
""".
-spec budget(Map :: map()) -> pos_integer().

budget(Map) when is_map(Map) ->
    Requested =
        case maps:get(~"timeout", Map, maps:get(timeout, Map, undefined)) of
            N when is_integer(N) andalso N > 0 -> N;
            _ -> undefined
        end,
    case relay_timeout(Map) of
        undefined -> ?DEFAULT_BUDGET;
        Max when Requested == undefined -> Max;
        Max -> min(Requested, Max)
    end;
budget(_) ->
    ?DEFAULT_BUDGET.

-doc "Return the realm the request was made in.".
-spec realm(Request :: t()) -> binary().

realm(#bondy_mail_request{realm = Realm}) ->
    Realm.

-doc "Return the name of the relay the request will be delivered through.".
-spec relay(Request :: t()) -> binary().

relay(#bondy_mail_request{relay = Relay}) ->
    Relay.

-doc "Return the monotonic millisecond past which no attempt is made.".
-spec deadline(Request :: t()) -> integer().

deadline(#bondy_mail_request{deadline = Deadline}) ->
    Deadline.

-doc """
Return every envelope recipient: `to`, `cc` and `bcc` together.

Blind recipients are delivered to but never appear in the message, which is why
they are part of the envelope here and refused as a header in
`bondy_mail_header`.
""".
-spec recipients(Request :: t()) -> [binary()].

recipients(#bondy_mail_request{to = To, cc = Cc, bcc = Bcc}) ->
    To ++ Cc ++ Bcc.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Deliberately does not check whether the calling realm may use the relay.
%% This only sizes a wait; authority is the owner's decision and is made in
%% `authorise_relay/2` with the owner's own configuration.
relay_timeout(Map) ->
    Named =
        case maps:get(~"relay", Map, maps:get(relay, Map, undefined)) of
            Name when is_binary(Name) -> {ok, Name};
            _ -> bondy_mail_config:default_relay()
        end,
    case Named of
        {ok, Relay} ->
            case bondy_mail_config:relay(Relay) of
                {ok, #bondy_mail_relay{timeout = Timeout}} -> Timeout;
                {error, no_such_relay} -> undefined
            end;
        {error, no_such_relay} ->
            undefined
    end.

%% @private
%% Both surfaces produce binary keys -- one from JSON, the other from mops --
%% but an Erlang caller naturally writes atoms. Accept both.
normalise_keys(Map) ->
    maps:fold(
        fun
            (K, V, Acc) when is_atom(K) ->
                maps:put(atom_to_binary(K, utf8), V, Acc);
            (K, V, Acc) ->
                maps:put(K, V, Acc)
        end,
        #{},
        Map
    ).

%% @private
%% `maps_utils:validate/2` drops what it does not recognise, so a misspelled
%% key would silently become a missing value. Name them instead.
reject_unknown(Map) ->
    Known = maps:keys(?SPEC),
    case maps:keys(maps:without(Known, Map)) of
        [] -> ok;
        Unknown -> {error, {unknown_keys, lists:sort(Unknown)}}
    end.

%% @private
validate(Map) ->
    try
        {ok, maps_utils:validate(Map, ?SPEC)}
    catch
        _:Reason ->
            {error, {invalid_request, Reason}}
    end.

%% @private
%% A named relay must exist; an unnamed one falls back to the configured
%% default. Both are then checked against the calling realm.
resolve_relay(RealmUri, #{relay := undefined}) ->
    case bondy_mail_config:default_relay() of
        {ok, Name} -> authorise_relay(RealmUri, Name);
        {error, _} = Error -> Error
    end;
resolve_relay(RealmUri, #{relay := Name}) ->
    authorise_relay(RealmUri, Name).

%% @private
authorise_relay(RealmUri, Name) ->
    case bondy_mail_config:relay(Name) of
        {ok, Relay} ->
            case is_realm_permitted(RealmUri, Relay) of
                true ->
                    {ok, Relay};
                false ->
                    {error, {relay_not_permitted, Name}}
            end;
        {error, no_such_relay} ->
            {error, {no_such_relay, Name}}
    end.

-doc """
Whether `RealmUri` may send through `Relay`.

`any` opens the relay to every realm. Otherwise the realm must be listed, or
inherit from a listed prototype -- the same inheritance that governs grants, so
a family of realms can be admitted by naming the prototype once.

An empty list admits only the master realm, which is how an operator-only relay
is expressed. The master realm is not special-cased in the list itself: it is
admitted because `bondy_mail_config` treats it as always permitted.

Exported so that `bondy.mail.relay.list` shows a caller exactly the relays it
could actually use, rather than a catalogue it has to discover the hard way.
""".
-spec is_realm_permitted(
    RealmUri :: binary(),
    Relay :: #bondy_mail_relay{}
) -> boolean().

is_realm_permitted(_RealmUri, #bondy_mail_relay{realms = any}) ->
    true;
is_realm_permitted(RealmUri, #bondy_mail_relay{realms = Realms}) ->
    lists:member(RealmUri, Realms) orelse
        is_prototype_permitted(RealmUri, Realms) orelse
        bondy_mail_config:is_master_realm(RealmUri).

%% @private
is_prototype_permitted(RealmUri, Realms) ->
    case bondy_mail_config:prototype_uri(RealmUri) of
        undefined -> false;
        Prototype -> lists:member(Prototype, Realms)
    end.

%% @private
build(RealmUri, Relay, Valid) ->
    maybe
        {ok, {FromName, From}} ?= resolve_from(Relay, Valid),
        {ok, To} ?=
            bondy_mail_address:validate_many(as_list(maps:get(to, Valid))),
        ok ?= non_empty(To),
        {ok, Cc} ?=
            bondy_mail_address:validate_many(as_list(maps:get(cc, Valid))),
        {ok, Bcc} ?=
            bondy_mail_address:validate_many(as_list(maps:get(bcc, Valid))),
        ok ?= recipient_count(Relay, To ++ Cc ++ Bcc),
        {ok, {ReplyToName, ReplyTo}} ?=
            optional_mailbox(maps:get(reply_to, Valid)),
        ok ?= has_body(Valid),
        {ok, Headers} ?= bondy_mail_header:validate(maps:get(headers, Valid)),
        {ok, Attachments} ?= attachments(maps:get(attachments, Valid)),
        Size = size_bytes(Valid, Headers, Attachments),
        ok ?= within_budget(Relay, Size),
        Timeout = timeout(Relay, maps:get(timeout, Valid)),
        Key = maps:get(id, Valid),
        {ok, #bondy_mail_request{
            id = Key,
            message_id = bondy_mail_status:new_id(RealmUri, Key),
            realm = RealmUri,
            relay = Relay#bondy_mail_relay.name,
            from = From,
            from_name = FromName,
            to = To,
            cc = Cc,
            bcc = Bcc,
            reply_to = ReplyTo,
            reply_to_name = ReplyToName,
            subject = maps:get(subject, Valid),
            text = maps:get(text, Valid),
            html = maps:get(html, Valid),
            headers = Headers,
            attachments = Attachments,
            size_bytes = Size,
            priority = maps:get(priority, Valid),
            timeout = Timeout,
            deadline = erlang:monotonic_time(millisecond) + Timeout
        }}
    end.

%% @private
%% The relay's sender is the default, so a caller who says nothing cannot spoof.
%% A caller who does name one must be inside the relay's allow-list.
resolve_from(#bondy_mail_relay{from = undefined}, #{from := undefined}) ->
    {error, {invalid_request, missing_sender}};
resolve_from(#bondy_mail_relay{from = From}, #{from := undefined}) ->
    %% The relay's own sender may carry a display name too -- that is where an
    %% operator puts the brand a recipient sees. It is not checked against
    %% `allowed_from`: it IS the allowed sender.
    case bondy_mail_address:parse_mailbox(From) of
        {ok, Mailbox} -> {ok, Mailbox};
        error -> {error, {invalid_request, {relay_from, From}}}
    end;
resolve_from(Relay, #{from := From}) ->
    case bondy_mail_address:parse_mailbox(From) of
        error ->
            {error, {invalid_recipient, From}};
        {ok, {DisplayName, Address}} ->
            Allowed = Relay#bondy_mail_relay.allowed_from,
            %% Against the ADDRESS, never against what the caller supplied. A
            %% check on the whole value would admit
            %% `Trusted Sender <attacker@evil.com>` to a relay scoped to
            %% `acme.com`, which is the one property the derived-sender design
            %% exists to guarantee. `parse_mailbox/1` has already separated the
            %% two, so there is nothing here that can be got wrong by reaching
            %% for the wrong variable.
            case bondy_mail_address:is_domain_allowed(Address, Allowed) of
                true ->
                    {ok, {DisplayName, Address}};
                false ->
                    %% The relay's name travels with the refusal: which relay
                    %% refused the sender is the first thing anyone asks, and
                    %% the catalogue message says it.
                    Name = Relay#bondy_mail_relay.name,
                    {error, {sender_not_permitted, Name, Address}}
            end
    end.

%% @private
%% `Reply-To` is header-only -- it never reaches the envelope -- so a display
%% name here costs nothing beyond parsing it.
optional_mailbox(undefined) ->
    {ok, {undefined, undefined}};
optional_mailbox(Address) ->
    case bondy_mail_address:parse_mailbox(Address) of
        {ok, Mailbox} -> {ok, Mailbox};
        error -> {error, {invalid_recipient, Address}}
    end.

%% @private
as_list(L) when is_list(L) -> L;
as_list(Bin) when is_binary(Bin) -> [Bin];
as_list(Other) -> [Other].

%% @private
non_empty([]) -> {error, {invalid_request, no_recipients}};
non_empty(_) -> ok.

%% @private
%% A message with neither a text nor an HTML part has nothing to deliver.
has_body(#{text := undefined, html := undefined}) ->
    {error, {invalid_request, no_body}};
has_body(_) ->
    ok.

%% @private
timeout(#bondy_mail_relay{timeout = Max}, undefined) ->
    Max;
timeout(#bondy_mail_relay{timeout = Max}, Requested) ->
    %% A caller may ask for less than the relay allows, never more: the relay's
    %% timeout is what bounds how long a worker can be held.
    min(Requested, Max).

%% @private
%% Envelope recipients, counted together. `to`, `cc` and `bcc` all become
%% `RCPT TO` commands in one transaction, so the relay sees their sum and this
%% has to bound the same thing.
recipient_count(#bondy_mail_relay{max_recipients = Max}, Recipients) ->
    case length(Recipients) of
        N when N > Max -> {error, {too_many_recipients, N, Max}};
        _ -> ok
    end.

%% @private
%% Everything that becomes the message.
%%
%% Every field, not only the attachments: a caller cannot reason about a limit
%% whose answer depends on which field they put the megabytes in, and measuring
%% here rather than at encode time keeps an oversized message out of the queue
%% instead of refusing it once a worker has already taken it.
size_bytes(Valid, Headers, Attachments) ->
    optional_size(maps:get(subject, Valid)) +
        optional_size(maps:get(text, Valid)) +
        optional_size(maps:get(html, Valid)) +
        lists:sum([
            byte_size(N) + byte_size(V)
         || {N, V} <- Headers
        ]) +
        lists:sum([
            byte_size(A#bondy_mail_attachment.data) +
                byte_size(A#bondy_mail_attachment.filename)
         || A <- Attachments
        ]).

%% @private
optional_size(undefined) -> 0;
optional_size(Bin) when is_binary(Bin) -> byte_size(Bin).

%% @private
%% Encoding inflates a message, so the decoded budget is scaled down: a request
%% accepted here should not then be refused by the relay for size. The encoded
%% message is measured exactly, later, in `bondy_mail_mime`.
within_budget(#bondy_mail_relay{max_message_size = Limit}, Size) ->
    Max = round(Limit * ?ENCODING_HEADROOM),
    case Size > Max of
        true -> {error, {too_large_payload, Size, Max}};
        false -> ok
    end.

%% @private
attachments(L) when is_list(L) ->
    attachments(L, []);
attachments(Other) ->
    {error, {invalid_request, {attachments, Other}}}.

%% @private
attachments([], Acc) ->
    {ok, lists:reverse(Acc)};
attachments([H | T], Acc) ->
    case attachment(H) of
        {ok, #bondy_mail_attachment{} = A} -> attachments(T, [A | Acc]);
        {error, _} = Error -> Error
    end.

%% @private
attachment(Map0) when is_map(Map0) ->
    Map = normalise_keys(Map0),
    Filename = maps:get(~"filename", Map, undefined),
    ContentType = maps:get(~"content_type", Map, ~"application/octet-stream"),
    Data = maps:get(~"data", Map, undefined),

    maybe
        ok ?= valid_filename(Filename),
        ok ?= valid_content_type(ContentType),
        {ok, Decoded} ?= decode(Data),
        {ok, #bondy_mail_attachment{
            filename = Filename,
            content_type = ContentType,
            data = Decoded
        }}
    end;
attachment(Other) ->
    {error, {invalid_request, {attachment, Other}}}.

%% @private
%% A filename lands in a `Content-Disposition` header, so it is header data and
%% goes through the same control-character rule as any other header data --
%% `bondy_mail_header:has_control/1`, which is the only definition of it.
%%
%% Path separators are refused as well, which is a different concern: a
%% recipient's client decides where a file goes, and a name that looks like a
%% path invites it to decide badly.
valid_filename(Name) when is_binary(Name) andalso byte_size(Name) > 0 ->
    Bad =
        bondy_mail_header:has_control(Name) orelse
            binary:match(Name, [~"/", ~"\\"]) =/= nomatch,
    case Bad of
        true -> {error, {invalid_request, {attachment_filename, Name}}};
        false -> ok
    end;
valid_filename(Name) ->
    {error, {invalid_request, {attachment_filename, Name}}}.

%% @private
%% Also header data: it becomes a `Content-Type`.
valid_content_type(Bin) when is_binary(Bin) ->
    case binary:split(Bin, ~"/") of
        [Type, Sub] when byte_size(Type) > 0 andalso byte_size(Sub) > 0 ->
            Bad =
                bondy_mail_header:has_control(Bin) orelse
                    binary:match(Bin, ~" ") =/= nomatch,
            case Bad of
                false -> ok;
                true -> {error, {invalid_request, {content_type, Bin}}}
            end;
        _ ->
            {error, {invalid_request, {content_type, Bin}}}
    end;
valid_content_type(Other) ->
    {error, {invalid_request, {content_type, Other}}}.

%% @private
decode(Bin) when is_binary(Bin) ->
    try
        {ok, base64:decode(Bin)}
    catch
        _:_ ->
            {error, {invalid_request, attachment_not_base64}}
    end;
decode(Other) ->
    {error, {invalid_request, {attachment_data, Other}}}.
