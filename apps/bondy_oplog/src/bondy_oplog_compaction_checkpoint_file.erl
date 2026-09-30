%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_compaction_checkpoint_file).
-behaviour(bondy_oplog_compaction_checkpoint).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
File-backed compaction checkpoint store: one file per instance, holding the
latest `{Watermark, Checkpoint}` as an Erlang External Term Format binary.

## Opts

| Key    | Required | Meaning |
|---|---|---|
| `path` | yes      | Base directory. The instance's checkpoint is stored at `<path>/<InstanceId>/checkpoint.etf`. |

## Durability (`put_checkpoint/3`)

The checkpoint, `{Watermark, Checkpoint}` as ETF, is written with
`bondy_mst_io:write_file_atomic/2`, and `put_checkpoint/3` has its error
contract.

## Corruption detection

`get_checkpoint/1` and `current_watermark/1` wrap the
`binary_to_term/1` call in a `try/catch`: a truncated or otherwise
corrupted file surfaces as `{error, {corrupted, Reason}}` rather
than a silent crash inside the instance gen_server. The instance
init treats this as fatal so the operator can restore from backup
instead of silently rebuilding from a partial state.

## On-disk envelope

The file content is `term_to_binary({checkpoint_v1, Watermark,
Checkpoint}, [{minor_version, 2}])`. The `checkpoint_v1` tag is the
versioning seam for future schema evolution.

## Why not DETS

DETS earns its keep on none of the dimensions that matter for a
single-row checkpoint store: it has no real transactional guarantees,
requires atom-named tables (an atom-table footgun with many
instances), and runs a slow repair pass on dirty restart.
`file:rename/2` is atomic on POSIX by specification, which is all this
store needs.
""").

-record(state, {
    instance_id :: instance_id(),
    path :: file:filename_all()
}).

-export([init/2]).
-export([put_checkpoint/3]).
-export([get_checkpoint/1]).
-export([current_watermark/1]).
-export([close/1]).

%% =============================================================================
%% bondy_oplog_compaction_checkpoint CALLBACKS
%% =============================================================================

init(InstanceId, Opts) when is_binary(InstanceId), is_map(Opts) ->
    case maps:find(path, Opts) of
        error ->
            {error, {missing_option, path}};
        {ok, BaseDir} ->
            %% An instance id is ONE component — `/` is refused at
            %% admission (`bondy_oplog_path:validate_instance_id/1`) — so
            %% this composes correctly with the `dirname(InstanceDir)` the
            %% caller passes as `path`. While ids nested, that pair produced
            %% a DOUBLED segment: `.../main/realm/main/realm/7/`. The pair is
            %% driven end-to-end by `bondy_oplog_path_test:
            %% checkpoint_dir_lands_inside_the_instance_dir_test_/0`.
            Dir = filename:join(BaseDir, InstanceId),
            File = filename:join(Dir, "checkpoint.etf"),
            ok = filelib:ensure_dir(File),
            case bondy_mst_io:fsync_dir(Dir) of
                ok ->
                    {ok, #state{instance_id = InstanceId, path = File}};
                {error, Reason} ->
                    {error, {dir_fsync_failed, Dir, Reason}}
            end
    end.

put_checkpoint(#state{path = Path}, Watermark, Checkpoint) ->
    Bin = erlang:term_to_binary(
        {checkpoint_v1, Watermark, Checkpoint},
        [{minor_version, 2}]
    ),
    bondy_mst_io:write_file_atomic(Path, Bin).

get_checkpoint(#state{path = Path}) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            decode(Bin);
        {error, enoent} ->
            not_found;
        {error, _} = E ->
            E
    end.

current_watermark(#state{path = Path}) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case decode(Bin) of
                {ok, W, _} -> W;
                not_found -> undefined;
                {error, _} = E -> E
            end;
        {error, enoent} ->
            undefined;
        {error, _} = E ->
            E
    end.

close(#state{}) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Decode without `[safe]`: this file holds bytes this node wrote itself, and
%% `[safe]` rejects any atom not already in the atom table. A checkpoint
%% carries atoms from modules that need not be loaded yet at the point the
%% instance reads it during boot, so `[safe]` turns a valid checkpoint into
%% `badarg` and the instance reports a corrupt file that is intact. `[safe]`
%% belongs on the peer-shipped wire path, where the bytes are untrusted; here
%% it can only produce false corruption.
%%
%% The `try` still maps a genuinely truncated or damaged file to
%% `{error, {corrupted, Reason}}` rather than killing the caller.
decode(Bin) ->
    try erlang:binary_to_term(Bin) of
        {checkpoint_v1, W, S} ->
            {ok, W, S};
        Other ->
            {error, {corrupted, {unexpected_term, Other}}}
    catch
        error:Reason ->
            {error, {corrupted, Reason}}
    end.
