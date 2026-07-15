%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_secondary_sup).

-behaviour(supervisor).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
`simple_one_for_one` supervisor for `bondy_oplog_secondary_writer`
workers — one per `writer_key` (the set of index shards a single writer
drives). Sibling of `bondy_oplog_instance_dyn_sup` under `bondy_oplog_sup`.

`bondy_db` provisioning starts one writer per distinct `writer_key` via
`start_writer/1` — found once and joined by every later index shard that
shares the key — and stops it on the last shard's teardown via
`stop_writer/1`. Workers are `transient`: an abnormal crash is restarted
(the restarted writer re-adopts its streams from the registry — re-stamping
its pid and requesting any needed rebuild — and re-resolves its handles on
the next flush, so it self-heals), while an orderly `stop_writer/1` does not
restart. The index is a deterministic function of the primary, so the
bounded ops lost across a crash window are recoverable by the rebuild.
""").

-export([start_link/0]).
-export([start_writer/1]).
-export([stop_writer/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-doc """
Start a writer for one `writer_key`. `Args` is the
`bondy_oplog_secondary_writer:init/1` map
(`#{writer_key, shard}`, optional `coalesce_ms`).
""".
-spec start_writer(map()) -> {ok, pid()} | {error, term()}.

start_writer(Args) when is_map(Args) ->
    supervisor:start_child(?SERVER, [Args]).

-doc "Stop a writer started by `start_writer/1`.".
-spec stop_writer(pid()) -> ok.

stop_writer(Pid) when is_pid(Pid) ->
    case supervisor:terminate_child(?SERVER, Pid) of
        ok -> ok;
        {error, not_found} -> ok
    end.

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 10
    },
    ChildSpec = #{
        id => bondy_oplog_secondary_writer,
        start => {bondy_oplog_secondary_writer, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [bondy_oplog_secondary_writer]
    },
    {ok, {SupFlags, [ChildSpec]}}.
