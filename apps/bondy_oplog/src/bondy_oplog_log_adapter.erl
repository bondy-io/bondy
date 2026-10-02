%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_log_adapter).

-behaviour(bondy_log_record).
-behaviour(bondy_log_identity).
-behaviour(bondy_log_directory).

-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").
-include_lib("bondy_log/include/bondy_log.hrl").

-moduledoc """
The oplog's log adapter: the `bondy_log_record`, `bondy_log_identity` and
`bondy_log_directory` behaviours that make a `bondy_log` writer an oplog
WAL.

Records: a frame body is `term_to_binary([#bondy_oplog_event{}, ...],
[{minor_version, 2}, deterministic])`, the record key is the event's HLC,
and the batch maximum is the largest event seq. The frame magic is `BDOP`.

Identity: the context is `#{instance_id, origin}`; the segment header's
8-byte field is the first 8 bytes of `sha256(InstanceId)` and the 16-byte
field is the origin. `encode_identity/1` is where the oplog validates its
origin (`bondy_oplog_origin:validate/1`), so `{missing_opt, origin}` and
`{invalid_origin, _}` are the errors a WAL opened without a usable origin
reports. `verify_identity/2` checks the origin first, then the hash, and
names the first mismatch (`origin_mismatch`, `instance_id_hash_mismatch`).

Directory: the writer's pid is the `wal_pid` field of the instance's
`bondy_oplog_registry` row, where `bondy_oplog_instance` and the
per-instance supervisor expect it.

The record and identity bytes are the bytes the WAL wrote before the
seams existed; the byte-identity probe pins them, and
`bondy_log_frame_test` pins the frame envelope.

`decode_body/1` is deliberately NOT `[safe]`: it decodes frames THIS node
wrote. Under `[safe]` an event carrying an atom absent from the VM's atom
table at replay time raises `badarg` and would be misattributed to frame
corruption — dropped by the reader, and read as TRUNCATION by strict
recovery, discarding every frame after it. `binary_to_term/1` still
raises `badarg` on malformed bytes, so real framing errors are caught
exactly as before. Peer-shipped bytes are decoded under `[safe]` at the
wire boundary (`C-2`), where that control belongs.
""".

-export([frame_magic/0]).
-export([is_valid/1]).
-export([key/1]).
-export([max_seq/1]).
-export([encode_body/1]).
-export([decode_body/1]).

-export([encode_identity/1]).
-export([verify_identity/2]).

-export([register/2]).
-export([lookup_pid/1]).

-export([instance_id_hash/1]).

%% =============================================================================
%% bondy_log_record CALLBACKS
%% =============================================================================

-spec frame_magic() -> bondy_log_frame:magic().

frame_magic() ->
    ?BONDY_OPLOG_WAL_FRAME_MAGIC.

-spec is_valid(term()) -> boolean().

is_valid(#bondy_oplog_event{}) -> true;
is_valid(_) -> false.

-spec key(bondy_oplog_event:t()) -> bondy_connect_hlc:hlc().

key(Event) ->
    bondy_oplog_event:key_hlc(bondy_oplog_event:key(Event)).

-spec max_seq([bondy_oplog_event:t(), ...]) -> non_neg_integer().

max_seq(Events) ->
    lists:max([
        bondy_oplog_event:key_seq(bondy_oplog_event:key(E))
     || E <- Events
    ]).

-spec encode_body([bondy_oplog_event:t(), ...]) -> binary().

encode_body(Events) ->
    term_to_binary(Events, [{minor_version, 2}, deterministic]).

-spec decode_body(binary()) ->
    {ok, [bondy_oplog_event:t(), ...]} | {error, term()}.

decode_body(Body) ->
    try binary_to_term(Body) of
        [_ | _] = Batch ->
            case lists:all(fun is_valid/1, Batch) of
                true -> {ok, Batch};
                false -> {error, non_event}
            end;
        [] ->
            {error, empty};
        Other ->
            {error, {non_list, Other}}
    catch
        error:badarg ->
            {error, badarg}
    end.

%% =============================================================================
%% bondy_log_identity CALLBACKS
%% =============================================================================

-spec encode_identity(bondy_log_identity:ctx()) ->
    {ok, bondy_log_identity:identity()} | {error, term()}.

encode_identity(#{instance_id := InstanceId} = Ctx) ->
    case maps:find(origin, Ctx) of
        {ok, Origin} ->
            case bondy_oplog_origin:validate(Origin) of
                ok ->
                    {ok, #{
                        hash8 => instance_id_hash(InstanceId),
                        id16 => Origin
                    }};
                {error, R} ->
                    {error, {invalid_origin, R}}
            end;
        error ->
            {error, {missing_opt, origin}}
    end.

-spec verify_identity(bondy_log_identity:identity(), bondy_log_identity:ctx()) ->
    ok | {error, origin_mismatch | instance_id_hash_mismatch}.

verify_identity(#{hash8 := Hash8, id16 := Origin}, #{
    instance_id := InstanceId, origin := Origin
}) ->
    case instance_id_hash(InstanceId) of
        Hash8 -> ok;
        _ -> {error, instance_id_hash_mismatch}
    end;
verify_identity(#{hash8 := _, id16 := _}, #{instance_id := _, origin := _}) ->
    {error, origin_mismatch}.

%% =============================================================================
%% bondy_log_directory CALLBACKS
%% =============================================================================

-spec register(instance_id(), pid()) -> ok.

register(InstanceId, Pid) ->
    bondy_oplog_registry:set_wal_pid(InstanceId, Pid).

-spec lookup_pid(instance_id()) -> pid() | undefined.

lookup_pid(InstanceId) ->
    bondy_oplog_registry:wal_pid(InstanceId).

-doc """
The 8-byte instance id hash stamped in the oplog's segment headers: the
leading 8 bytes of `crypto:hash(sha256, InstanceId)`.
""".
-spec instance_id_hash(instance_id()) -> <<_:64>>.

instance_id_hash(InstanceId) when
    is_binary(InstanceId), byte_size(InstanceId) > 0
->
    Full = crypto:hash(sha256, InstanceId),
    binary:part(Full, 0, ?BONDY_LOG_SEGMENT_HASH8_BYTES).
