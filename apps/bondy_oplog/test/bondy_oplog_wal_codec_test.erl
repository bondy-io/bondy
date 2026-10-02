%% =============================================================================
%% End-to-end tests for the WAL writer + reader using `bondy_log_codec`:
%% a body is compressed and / or encrypted on write and reversed on read
%% transparently. The pure codec tests live with the codec in
%% `bondy_log_codec_test`.
%% =============================================================================

-module(bondy_oplog_wal_codec_test).

-behaviour(bondy_log_key_registry).

-include_lib("eunit/include/eunit.hrl").

%% In-process key registry used by this suite. Static current key
%% derived from `static_key/0`; one extra retired key surfaces via
%% `key_id = 7` for the "old key still resolvable" case.
-export([current_key/0]).
-export([lookup_key/1]).

current_key() ->
    {1, static_key(1)}.

lookup_key(1) -> {ok, static_key(1)};
lookup_key(7) -> {ok, static_key(7)};
lookup_key(_) -> {error, missing}.

static_key(Salt) ->
    crypto:hash(sha256, <<"codec-test-key-", Salt:32>>).

%% =============================================================================
%% End-to-end: writer compresses, reader decompresses
%% =============================================================================

end_to_end_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(telemetry),
            ok
        end,
        fun(_) -> ok end, [
            {timeout, 15, fun writer_with_compression_roundtrips/0},
            {timeout, 15, fun writer_without_compression_still_works/0}
        ]}.

writer_with_compression_roundtrips() ->
    Id = instance_id(),
    Dir = mktemp_dir(),
    Opts = #{
        dir => Dir,
        origin => origin(),
        body_compression => zlib,
        body_compression_min_bytes => 1,
        retention_sweep_interval => 24 * 60 * 60 * 1000
    },
    {ok, Wal} = bondy_oplog_wal:start_link(Id, Opts),
    HLC = bondy_connect_hlc:new(),
    %% Append a very compressible batch — bodies should shrink after
    %% the codec runs.
    Events = [
        mk_event(bondy_connect_hlc:now(HLC), Seq)
     || Seq <- lists:seq(0, 9)
    ],
    {ok, _Acks} = bondy_oplog_wal:append_batch(Wal, Events),
    %% Open a reader and read the batch back. It must be byte-for-byte
    %% identical to what we appended — i.e. decompression actually
    %% restores the original term encoding.
    {ok, Iter0} = bondy_log_reader:open(Wal, beginning),
    {ok, Batch, _Hlcs, _Pos, _Iter1} = bondy_log_reader:next(Iter0),
    ?assertEqual(Events, Batch),
    ok = bondy_oplog_wal:close(Wal),
    rmrf(Dir).

writer_without_compression_still_works() ->
    Id = instance_id(),
    Dir = mktemp_dir(),
    Opts = #{
        dir => Dir,
        origin => origin(),
        body_compression => none,
        retention_sweep_interval => 24 * 60 * 60 * 1000
    },
    {ok, Wal} = bondy_oplog_wal:start_link(Id, Opts),
    HLC = bondy_connect_hlc:new(),
    Events = [
        mk_event(bondy_connect_hlc:now(HLC), Seq)
     || Seq <- lists:seq(0, 4)
    ],
    {ok, _Acks} = bondy_oplog_wal:append_batch(Wal, Events),
    {ok, Iter0} = bondy_log_reader:open(Wal, beginning),
    {ok, Batch, _Hlcs, _Pos, _Iter1} = bondy_log_reader:next(Iter0),
    ?assertEqual(Events, Batch),
    ok = bondy_oplog_wal:close(Wal),
    rmrf(Dir).

%% =============================================================================
%% End-to-end with WAL — encryption + compression
%% =============================================================================

end_to_end_encryption_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(telemetry),
            ok
        end,
        fun(_) -> ok end, [
            {timeout, 15, fun encrypted_writer_roundtrips/0},
            {timeout, 15, fun encrypted_compressed_writer_roundtrips/0}
        ]}.

encrypted_writer_roundtrips() ->
    Id = instance_id(),
    Dir = mktemp_dir(),
    Opts = #{
        dir => Dir,
        origin => origin(),
        body_encryption => {enabled, ?MODULE},
        retention_sweep_interval => 24 * 60 * 60 * 1000
    },
    {ok, Wal} = bondy_oplog_wal:start_link(Id, Opts),
    HLC = bondy_connect_hlc:new(),
    Events = [
        mk_event(bondy_connect_hlc:now(HLC), Seq)
     || Seq <- lists:seq(0, 4)
    ],
    {ok, _Acks} = bondy_oplog_wal:append_batch(Wal, Events),
    {ok, Iter0} = bondy_log_reader:open(Wal, beginning),
    {ok, Batch, _Hlcs, _Pos, _Iter1} = bondy_log_reader:next(Iter0),
    ?assertEqual(Events, Batch),
    ok = bondy_oplog_wal:close(Wal),
    rmrf(Dir).

encrypted_compressed_writer_roundtrips() ->
    Id = instance_id(),
    Dir = mktemp_dir(),
    Opts = #{
        dir => Dir,
        origin => origin(),
        body_compression => zlib,
        body_compression_min_bytes => 1,
        body_encryption => {enabled, ?MODULE},
        retention_sweep_interval => 24 * 60 * 60 * 1000
    },
    {ok, Wal} = bondy_oplog_wal:start_link(Id, Opts),
    HLC = bondy_connect_hlc:new(),
    Events = [
        mk_event(bondy_connect_hlc:now(HLC), Seq)
     || Seq <- lists:seq(0, 9)
    ],
    {ok, _Acks} = bondy_oplog_wal:append_batch(Wal, Events),
    {ok, Iter0} = bondy_log_reader:open(Wal, beginning),
    {ok, Batch, _Hlcs, _Pos, _Iter1} = bondy_log_reader:next(Iter0),
    ?assertEqual(Events, Batch),
    ok = bondy_oplog_wal:close(Wal),
    rmrf(Dir).

%% =============================================================================
%% Helpers
%% =============================================================================

instance_id() ->
    list_to_binary(
        io_lib:format(
            "codec-test-~p-~p",
            [
                erlang:system_time(microsecond),
                erlang:unique_integer([positive])
            ]
        )
    ).

origin() ->
    <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>.

mk_event(Hlc, Seq) ->
    Key = bondy_oplog_event:key(Hlc, origin(), Seq),
    bondy_oplog_event:new(Key, {op, Seq}, undefined).

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_oplog_wal_codec_test_~p_~p",
                [
                    erlang:system_time(microsecond),
                    erlang:unique_integer([positive])
                ]
            )
        ]
    ),
    Dir = lists:flatten(Base),
    ok = filelib:ensure_path(Dir),
    Dir.

rmrf(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.
