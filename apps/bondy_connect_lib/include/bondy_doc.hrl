%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Shared documentation-attribute macros. On OTP >= 27 these expand to the
%% native `-moduledoc`/`-doc` attributes; on older releases they are no-ops.
%% Kept in a standalone header (rather than buried in a layer-private header)
%% so both the `bondy_mst` replication-structure library and the
%% `bondy_oplog`/`bondy_db` layer can use them without sharing private state.

-ifndef(BONDY_DOC_HRL).
-define(BONDY_DOC_HRL, true).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-endif.
