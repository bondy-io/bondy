%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_error).
-moduledoc """
Projects a `bondy_error:t()` onto the WAMP wire, and back.

This is the only place a WAMP `ERROR` or `ABORT` payload is derived from an
error value, so every peer sees the same shape whatever produced the error.

## The standard WAMP error payload

- `ErrorUri` is the error's `uri`, which is its normative identity.
- `Args` is `[Message]`, a single human-readable sentence.
- `KWArgs` is `bondy_error:to_map/1`: binary keys, JSON-encodable values.

`KWArgs` is backwards compatible with the payload Bondy has always emitted. The
keys `code`, `message` and `description` keep their historical values; `uri`,
`handle`, `nature`, `details`, `causes`, `doc_uri` and `trace_id` are additions.
New clients should key off `uri` rather than `code`.
""".

-include("bondy_wamp.hrl").

%% API
-export([from_wamp/1]).
-export([to_abort/1]).
-export([to_wamp/2]).
-export([to_wamp/3]).
-export([to_wamp/4]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Builds a WAMP `ERROR` in reply to `Source`.
""".
-spec to_wamp(
    Error :: bondy_error:t() | any(),
    Source :: bondy_wamp_message:error_source()
) -> wamp_error() | no_return().

to_wamp(Error, Source) ->
    to_wamp(Error, Source, #{}).

-doc """
Builds a WAMP `ERROR` in reply to `Source`, merging `Details` into the message
details.
""".
-spec to_wamp(
    Error :: bondy_error:t() | any(),
    Source :: bondy_wamp_message:error_source(),
    Details :: map()
) -> wamp_error() | no_return().

to_wamp(Error0, Source, Details) when is_map(Details) ->
    #{uri := Uri, message := Message} = Error = coerce(Error0),
    bondy_wamp_message:error_from(
        Source, Details, Uri, [Message], bondy_error:to_map(Error)
    ).

-doc """
Builds a WAMP `ERROR` for a request identified by its type and id.

Use this when the originating message is not available, e.g. when replying to a
request that has already been consumed.
""".
-spec to_wamp(
    Error :: bondy_error:t() | any(),
    RequestType :: pos_integer(),
    RequestId :: id(),
    Details :: map()
) -> wamp_error() | no_return().

to_wamp(Error0, RequestType, RequestId, Details) when is_map(Details) ->
    #{uri := Uri, message := Message} = Error = coerce(Error0),
    bondy_wamp_message:error(
        RequestType,
        RequestId,
        Details,
        Uri,
        [Message],
        bondy_error:to_map(Error)
    ).

-doc """
Builds a WAMP `ABORT` from an error.

`ABORT` has no payload, only details, so the projection is folded into the
details map under the same keys a peer would find in an `ERROR`'s `KWArgs`.
""".
-spec to_abort(Error :: bondy_error:t() | any()) ->
    wamp_abort() | no_return().

to_abort(Error0) ->
    #{uri := Uri} = Error = coerce(Error0),
    bondy_wamp_message:abort(bondy_error:to_map(Error), Uri).

-doc """
Rebuilds an error value from a WAMP `ERROR` received from a peer.

The peer's `KWArgs` is untrusted: it is fed through `bondy_error:from_term/1`,
which sanitises it. Only the error URI is taken at face value, because it is the
one part of the message the protocol requires to be a URI.
""".
-spec from_wamp(Message :: wamp_error()) -> bondy_error:t().

from_wamp(#error{error_uri = Uri, args = Args, kwargs = KWArgs}) ->
    Base =
        case KWArgs of
            #{} when map_size(KWArgs) > 0 -> bondy_error:from_term(KWArgs);
            _ -> bondy_error:from_term(Uri)
        end,

    %% The URI on the wire wins over anything reconstructed from the payload.
    Error = Base#{uri => Uri},

    case message_of(Args) of
        undefined -> Error;
        Message -> Error#{message => Message}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
coerce(Error) ->
    case bondy_error:is_type(Error) of
        true -> Error;
        false -> bondy_error:from_term(Error)
    end.

%% @private
message_of([Message | _]) when is_binary(Message) ->
    Message;
message_of(_) ->
    undefined.
