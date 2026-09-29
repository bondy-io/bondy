%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_secondary_sup).

-behaviour(supervisor).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Supervisor of the `bondy_oplog_secondary_writer` workers, one child per
`writer_key` (the set of index shards a single writer drives), with the
`writer_key` as the child id. Sibling of `bondy_oplog_instance_dyn_sup` under
`bondy_oplog_sup`.

`bondy_db` provisioning calls `start_writer/1` for every index shard it
registers; a key that already has a writer returns that writer, so shards
sharing a key share one process. The last shard's teardown calls
`stop_writer/1`.

The registry, not this supervisor, records which writers must run: `init/1`
starts one writer per `writer_key` in
`bondy_oplog_core_registry:index_writers/0`. A restart of this supervisor,
including one forced by exhausting its restart intensity, therefore brings back
every writer, and each re-adopts its streams and requests the rebuild that
recovers the ops dispatched while it was down
(`bondy_db_shared_writer_test:secondary_sup_restart_keeps_writers/1`).
Writers that keep crashing exhaust this supervisor's intensity, and each of its
restarts counts against `bondy_oplog_sup`'s.
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
Start the writer for one `writer_key`, or return the one already running.
`Args` is the `bondy_oplog_secondary_writer:init/1` map
`#{writer_key, shard}`.
""".
-spec start_writer(map()) -> {ok, pid()} | {error, term()}.

start_writer(#{writer_key := _} = Args) ->
    case supervisor:start_child(?SERVER, child_spec(Args)) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, _} = Err -> Err
    end.

-doc """
Stop the writer for `WriterKey` started by `start_writer/1`. The caller has
already unregistered every index shard of `WriterKey`, so when this supervisor
is not running the writer died with it and its restart will not re-create it
(`bondy_db_index_lag_test:close_while_writer_sup_down/1`).
""".
-spec stop_writer(WriterKey :: binary()) -> ok.

stop_writer(WriterKey) when is_binary(WriterKey) ->
    try
        _ = supervisor:terminate_child(?SERVER, WriterKey),
        _ = supervisor:delete_child(?SERVER, WriterKey),
        ok
    catch
        exit:{noproc, _} -> ok
    end.

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10
    },
    {ok, {SupFlags, [child_spec(Args) || Args <- registered_writers()]}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

child_spec(#{writer_key := WriterKey} = Args) ->
    #{
        id => WriterKey,
        start => {bondy_oplog_secondary_writer, start_link, [Args]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [bondy_oplog_secondary_writer]
    }.

registered_writers() ->
    [
        #{writer_key => WriterKey, shard => Shard}
     || {WriterKey, Shard} <- bondy_oplog_core_registry:index_writers()
    ].
