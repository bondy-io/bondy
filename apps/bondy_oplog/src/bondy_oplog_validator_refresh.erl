%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_validator_refresh).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Refreshes an instance's in-process validator snapshot, extracted from
`bondy_oplog_applier` so both the applier (a normal instance's separate
per-cell fold process) and a fused instance (which holds its own
`validator_module`/`validator_state` directly, no separate applier) refresh
it identically.

Calls `Mod:refresh(VS)` on the current snapshot: `{ok, NewVS}` replaces it,
`{error, _}` or a raised exception keeps the previous one. Validators that
do not export `refresh/1` are a no-op (debug log only). Total — never
raises; every outcome is logged and telemetered on
`[bondy_oplog, applier, validator_refresh]` (the event name kept
unqualified by caller, since a refresh means the same thing regardless of
which process ran it).
""").

-export([refresh/4]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Refreshes `Mod`'s validator snapshot `VS`, returning the new snapshot (or
`VS` unchanged on any non-success outcome). `InstanceId` and `Reason` are
carried only for logging/telemetry.
""".
-spec refresh(
    InstanceId :: term(), Reason :: term(), Mod :: module(), VS :: term()
) -> NewVS :: term().

refresh(InstanceId, Reason, Mod, VS) ->
    case erlang:function_exported(Mod, refresh, 1) of
        false ->
            ?LOG_DEBUG(#{
                description =>
                    "bondy_oplog ignored a refresh_validator request "
                    "because the validator module does not export "
                    "refresh/1",
                instance_id => InstanceId,
                validator => Mod,
                refresh_reason => Reason
            }),
            telemetry:execute(
                [bondy_oplog, applier, validator_refresh],
                #{count => 1},
                #{
                    instance_id => InstanceId,
                    validator => Mod,
                    outcome => unsupported,
                    refresh_reason => Reason
                }
            ),
            VS;
        true ->
            try Mod:refresh(VS) of
                {ok, NewVS} ->
                    ?LOG_INFO(#{
                        description =>
                            "bondy_oplog refreshed validator snapshot",
                        instance_id => InstanceId,
                        validator => Mod,
                        refresh_reason => Reason
                    }),
                    telemetry:execute(
                        [bondy_oplog, applier, validator_refresh],
                        #{count => 1},
                        #{
                            instance_id => InstanceId,
                            validator => Mod,
                            outcome => ok,
                            refresh_reason => Reason
                        }
                    ),
                    NewVS;
                {error, RefreshReason} ->
                    ?LOG_WARNING(#{
                        description =>
                            "bondy_oplog validator refresh returned an "
                            "error; keeping the previous snapshot",
                        instance_id => InstanceId,
                        validator => Mod,
                        refresh_reason => Reason,
                        reason => RefreshReason
                    }),
                    telemetry:execute(
                        [bondy_oplog, applier, validator_refresh],
                        #{count => 1},
                        #{
                            instance_id => InstanceId,
                            validator => Mod,
                            outcome => error,
                            refresh_reason => Reason,
                            error => RefreshReason
                        }
                    ),
                    VS
            catch
                C:R:S ->
                    ?LOG_ERROR(#{
                        description =>
                            "bondy_oplog validator refresh raised; "
                            "keeping the previous snapshot",
                        instance_id => InstanceId,
                        validator => Mod,
                        refresh_reason => Reason,
                        class => C,
                        reason => R,
                        stacktrace => S
                    }),
                    telemetry:execute(
                        [bondy_oplog, applier, validator_refresh],
                        #{count => 1},
                        #{
                            instance_id => InstanceId,
                            validator => Mod,
                            outcome => crashed,
                            refresh_reason => Reason,
                            class => C,
                            error => R
                        }
                    ),
                    VS
            end
    end.
