%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-ifndef(BONDY_CONNECT_HRL).
-define(BONDY_CONNECT_HRL, true).

-define(BONDY_CONNECT_VSN, <<"0.1.0">>).
-define(BONDY_CONNECT_AGENT, <<"bondy_connect_sdk/0.1.0">>).

%% WAMP authentication method identifiers. These mirror the constants in the
%% router's `bondy_security.hrl' but are kept local so `bondy_connect_sdk' has no
%% dependency on the `bondy' application.
-define(WAMP_ANON_AUTH, <<"anonymous">>).
-define(WAMP_CRA_AUTH, <<"wampcra">>).
-define(WAMP_CRYPTOSIGN_AUTH, <<"cryptosign">>).
-define(WAMP_TICKET_AUTH, <<"ticket">>).

%% Error URI returned to the caller when a local callee handler crashes or
%% returns an unexpected value. Kept local so `bondy_connect_sdk' has no dependency
%% on the `bondy' application; the value is the catalogued
%% `bondy_error:uri(internal_error)'. It was previously
%% `wamp.error.internal_error', which the WAMP specification does not define -
%% the `wamp.' namespace is reserved for the specification.
-define(BONDY_CONNECT_INTERNAL_ERROR, <<"bondy.error.internal_error">>).

-endif.
