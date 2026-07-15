%% =============================================================================
%% SPDX-FileCopyrightText: 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%%--------------------------------------------------------------------
%% @doc CBOR (RFC 8949) macros and constants
%% @end
%%--------------------------------------------------------------------

-ifndef(BONDY_CBOR_HRL).
-define(BONDY_CBOR_HRL, true).

%%--------------------------------------------------------------------
%% Major Types (RFC 8949 Section 3.1)
%%--------------------------------------------------------------------

% Major type 0: unsigned integer
-define(MT_UNSIGNED, 0).
% Major type 1: negative integer
-define(MT_NEGATIVE, 1).
% Major type 2: byte string
-define(MT_BYTES, 2).
% Major type 3: text string (UTF-8)
-define(MT_TEXT, 3).
% Major type 4: array of data items
-define(MT_ARRAY, 4).
% Major type 5: map of pairs
-define(MT_MAP, 5).
% Major type 6: tagged data item
-define(MT_TAG, 6).
% Major type 7: simple values and floats
-define(MT_SIMPLE, 7).

%%--------------------------------------------------------------------
%% Additional Information Values (RFC 8949 Section 3)
%%--------------------------------------------------------------------

% Following byte is uint8
-define(AI_1BYTE, 24).
% Following bytes are uint16 big-endian
-define(AI_2BYTE, 25).
% Following bytes are uint32 big-endian
-define(AI_4BYTE, 26).
% Following bytes are uint64 big-endian
-define(AI_8BYTE, 27).
% Indefinite length (for types 2-5) or break (type 7)
-define(AI_INDEFINITE, 31).

%%--------------------------------------------------------------------
%% Simple Values (RFC 8949 Section 3.3)
%%--------------------------------------------------------------------

-define(SIMPLE_FALSE, 20).
-define(SIMPLE_TRUE, 21).
-define(SIMPLE_NULL, 22).
-define(SIMPLE_UNDEFINED, 23).

%%--------------------------------------------------------------------
%% Float Additional Info (RFC 8949 Section 3.3)
%%--------------------------------------------------------------------

% IEEE 754 Half-Precision (16-bit)
-define(AI_HALF_FLOAT, 25).
% IEEE 754 Single-Precision (32-bit)
-define(AI_SINGLE_FLOAT, 26).
% IEEE 754 Double-Precision (64-bit)
-define(AI_DOUBLE_FLOAT, 27).

%%--------------------------------------------------------------------
%% Standard Tags (RFC 8949 Section 3.4)
%%--------------------------------------------------------------------

% Standard date/time string (RFC 3339)
-define(TAG_DATETIME_STRING, 0).
% Epoch-based date/time
-define(TAG_DATETIME_EPOCH, 1).
% Positive bignum
-define(TAG_POSITIVE_BIGNUM, 2).
% Negative bignum
-define(TAG_NEGATIVE_BIGNUM, 3).
% Decimal fraction
-define(TAG_DECIMAL_FRACTION, 4).
% Bigfloat
-define(TAG_BIGFLOAT, 5).
% Expected conversion to base64url
-define(TAG_EXPECTED_BASE64URL, 21).
% Expected conversion to base64
-define(TAG_EXPECTED_BASE64, 22).
% Expected conversion to base16
-define(TAG_EXPECTED_BASE16, 23).
% Encoded CBOR data item
-define(TAG_ENCODED_CBOR, 24).
% URI (RFC 3986)
-define(TAG_URI, 32).
% base64url (RFC 4648)
-define(TAG_BASE64URL, 33).
% base64 (RFC 4648)
-define(TAG_BASE64, 34).
% Regular expression (PCRE/ECMA262)
-define(TAG_REGEXP, 35).
% MIME message (RFC 2045)
-define(TAG_MIME, 36).
% Self-Described CBOR
-define(TAG_SELF_DESCRIBE, 55799).

%%--------------------------------------------------------------------
%% DAG-CBOR (IPLD) constants
%% https://ipld.io/specs/codecs/dag-cbor/spec/
%%--------------------------------------------------------------------

% CID / IPLD link tag (the only tag permitted by DAG-CBOR)
-define(TAG_CID, 42).
% Multibase identity prefix prepended to the binary CID inside tag 42
-define(MULTIBASE_IDENTITY, 16#00).

%%--------------------------------------------------------------------
%% Pre-encoded bytes for common values
%%--------------------------------------------------------------------

% Simple value 20
-define(CBOR_FALSE, <<16#F4>>).
% Simple value 21
-define(CBOR_TRUE, <<16#F5>>).
% Simple value 22
-define(CBOR_NULL, <<16#F6>>).
% Simple value 23
-define(CBOR_UNDEFINED, <<16#F7>>).
% Break stop code
-define(CBOR_BREAK, <<16#FF>>).

%%--------------------------------------------------------------------
%% Limits
%%--------------------------------------------------------------------

-define(MAX_UINT8, 255).
-define(MAX_UINT16, 65535).
-define(MAX_UINT32, 4294967295).
-define(MAX_UINT64, 18446744073709551615).

-endif.
