%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_origin_bans).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Node-shared origin ban list.

A single ETS `set` table per node, keyed by `Origin :: binary()`. All
instances on the node refuse remote events from a banned origin
without invoking `verify_event/2`.

Banning is a *per-replica trust decision*: if an origin is malicious
for one instance it is malicious for every instance, since the origin
identifies the *replica*, not a per-instance role. The library
exposes the mechanism (`ban/2,3`, `unban/1`, `is_banned/1`, `list/0`);
**policy is the consumer's** — typically driven by inspecting the
detected-equivocation rows in `bondy_oplog_quarantine` and
applying a chosen threshold.

## Retirement

`retire/1,2` records that an origin is **permanently gone** — an operator
decommissioning a node. A retirement is a ban plus three further
properties, and frontier reaping needs all three:

- **Monotone.** A retirement is never lifted; `unban/1` refuses one
  (`bondy_oplog_origin_bans_test:retire_refuses_unban/0`). Frontier
  reaping skips a retired origin's deficit on every replica, and a set
  that could shrink would make that skip a private, reversible opinion.
- **Persisted** (`retirement_path` app env). A node that forgets it
  retired an origin reads a peer's surviving frontier entry as a deficit
  and pays a catalogue rebootstrap for data it already holds — the
  `ForgetfulS1` counterexample under `do_retire/2`. With no path
  configured the set is in-memory and `is_persistent/0` answers `false`,
  which callers MUST treat as "do not reap"
  (`retire_without_path_is_refused/0`).
- **Replicated** by union (`merge_retired/1`). The union needs no
  ordering and cannot conflict because the set only grows — the model's
  `Propagate` action, exercised by `merge_retired_is_a_union/0`.

Why retirement rather than membership: membership is reversible. A
departed node returns with the disk it left with, so
`bondy_oplog_origin:load_or_create/1` hands it back the same origin and
it resumes minting under it. Reaping on "no member claims this origin"
therefore makes the survivors skip the returned node's *new* events.
Retirement is the operator asserting the node is not coming back, which
is the only statement that survives a rejoin — and the ban is what makes
it true, by refusing the events if it does.

## Concurrency

Writes (ban / unban) flow through the gen_server. Reads
(`is_banned/1`, `list/0`) go directly to ETS — created with
`read_concurrency` and `protected` access, so the hot path on every
`append_remote` is a single ETS lookup, no gen_server round-trip.
""").

-define(TABLE, bondy_oplog_origin_bans_tab).
%% Raised while a CONFIGURED retirement path cannot be written. Frontier
%% reaping is cluster-wide unanimous, so one node that cannot persist stops
%% every node from reclaiming — that is a cluster-level condition, not a
%% local one, and it must not be inferable only from a boot log line.
-define(PERSIST_ALARM_ID, bondy_oplog_retirement_not_persistent).

-record(origin_ban, {
    origin :: binary(),
    banned_at :: integer(),
    reason :: term(),
    proof :: undefined | term(),
    %% A retirement is a ban the operator declares PERMANENT. It is never
    %% lifted, it is persisted, and it licenses frontier reaping; an
    %% ordinary ban is none of those.
    retired = false :: boolean()
}).

-record(state, {
    %% `undefined` when no `retirement_path` is configured. A path that
    %% FAILED is kept: with persist-before-enforce a failed write changes
    %% nothing, so the only thing left to do is let the next attempt retry
    %% it, and dropping the path would make a transient error permanent.
    path :: undefined | binary(),
    %% Alarm episode. `alarm_handler` does not dedupe, so set and clear must
    %% each happen once per episode or `get_alarms/0` fills with duplicates.
    alarmed = false :: boolean()
}).

-type ban_entry() :: #{
    origin := binary(),
    banned_at := integer(),
    reason := term(),
    proof := undefined | term(),
    retired := boolean()
}.

-export_type([ban_entry/0]).

%% Lifecycle
-export([start_link/0]).
-export([child_spec/0]).

%% Writes
-export([ban/2]).
-export([ban/3]).
-export([unban/1]).
-export([retire/1]).
-export([retire/2]).
-export([merge_retired/1]).

%% Reads
-export([is_banned/1]).
-export([is_retired/1]).
-export([list/0]).
-export([retired/0]).
-export([retired_set/0]).
-export([has_retired/0]).
-export([is_persistent/0]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

%% =============================================================================
%% LIFECYCLE
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

%% =============================================================================
%% WRITES
%% =============================================================================

?DOC("""
Bans `Origin`. Subsequent `append_remote/2` calls for events from this
origin will be rejected with `{error, banned_origin}` without invoking
the validator.

`Reason` is opaque; useful values are e.g.
`{equivocation, ProofTerm}` or operator-supplied tags. Synchronous —
the ban is effective on return.
""").
-spec ban(Origin :: binary(), Reason :: term()) -> ok.

ban(Origin, Reason) ->
    ban(Origin, Reason, undefined).

-spec ban(Origin :: binary(), Reason :: term(), Proof :: term() | undefined) ->
    ok.

ban(Origin, Reason, Proof) when is_binary(Origin) ->
    gen_server:call(?MODULE, {ban, Origin, Reason, Proof}).

?DOC("""
Removes `Origin` from the ban list. Idempotent. Synchronous.

Returns `{error, retired}` for a RETIRED origin: retirement is monotone
by contract, because frontier reaping skips a retired origin's deficit
and un-retiring it would resurrect a deficit every peer has stopped
reporting. Lifting one is an operator error, not an operation.
""").
-spec unban(Origin :: binary()) -> ok | {error, retired}.

unban(Origin) when is_binary(Origin) ->
    gen_server:call(?MODULE, {unban, Origin}).

?DOC("""
Retires `Origin`: records that the replica it identifies is permanently
gone, bans it, and persists the decision.

This is an operator act — decommissioning a node — and deliberately not
derived from membership, which is reversible. Synchronous; the ban is
effective on return. Returns `{error, not_persistent}` when no
`retirement_path` is configured, because a retirement this node would
forget on restart is worse than no retirement at all: it licenses a reap
whose absence then reads as a deficit.

Idempotent. Retiring an origin that is already merely BANNED promotes it.
""").
-spec retire(Origin :: binary()) -> ok | {error, not_persistent}.

retire(Origin) ->
    retire(Origin, operator).

-spec retire(Origin :: binary(), Reason :: term()) ->
    ok | {error, not_persistent}.

retire(Origin, Reason) when is_binary(Origin) ->
    gen_server:call(?MODULE, {retire, Origin, Reason}).

?DOC("""
Unions `Origins` into the retirement set — the replication half of the
grow-only set. Monotone, so it needs no ordering and cannot conflict:
applying peers' sets in any order any number of times converges.

Returns `{error, not_persistent}` when no `retirement_path` is
configured, for the same reason as `retire/2`.
""").
-spec merge_retired(Origins :: [binary()]) -> ok | {error, not_persistent}.

merge_retired(Origins) when is_list(Origins) ->
    gen_server:call(?MODULE, {merge_retired, Origins}).

%% =============================================================================
%% READS
%% =============================================================================

?DOC("""
Returns `true` if `Origin` is currently banned, `false` otherwise.
Direct ETS read, no gen_server round-trip.
""").
-spec is_banned(Origin :: binary()) -> boolean().

is_banned(Origin) when is_binary(Origin) ->
    ets:member(?TABLE, Origin).

?DOC("""
Returns `true` if `Origin` has been RETIRED, `false` for an unbanned
origin and for one that is merely banned. Direct ETS read.

This is the predicate frontier reaping is allowed to act on; `is_banned/1`
is not, because an ordinary ban can be lifted.

Single-origin form, for deciding about one origin. To decide about MANY —
every pair in an apply batch, every origin in a peer frontier — take
`retired_set/0` once instead, so the match-spec compilation is paid per
batch rather than per element.
""").
-spec is_retired(Origin :: binary()) -> boolean().

is_retired(Origin) when is_binary(Origin) ->
    case ets:whereis(?TABLE) of
        undefined ->
            false;
        Tid ->
            case ets:lookup(Tid, Origin) of
                [#origin_ban{retired = Retired}] -> Retired;
                [] -> false
            end
    end.

?DOC("""
The retired origins as a map keyed by origin, for membership tests.

This is the form the per-element paths take — the applier's fold
(`bondy_oplog_cell_apply`), the frontier ceiling
(`bondy_oplog_registry:merge_frontier/2`) and the deficit skip
(`bondy_oplog_sync_session:frontier_deficit/2`) all decide about a whole
batch, so they pay one match-spec compilation and an `is_map_key/2` per
element rather than a keyed ETS call per element.

Answers `#{}` if the table is gone. That window is real — the table is owned
by this gen_server, so it dies with it, while `has_retired/0`'s
`persistent_term` does not — and one caller is the applier's fold, where
raising would kill an applier mid-batch
(`bondy_oplog_frontier_reap_test:retired_set_is_total_without_the_table/0`).

`#{}` is not uniformly conservative, and callers should know which side they
are on. The applier fold and the deficit skip degrade safely: nothing is
dropped, nothing is skipped. `merge_frontier/2`'s ceiling does not — with an
empty set a peer's advertised entry can re-enter a frontier this node had
reaped. That reverses at the next pass, which reaps again, so the window
costs a round rather than correctness.

The check is a table lookup rather than a caught exception, so a malformed
match spec still fails loudly instead of reading as "nothing retired".
""").
-spec retired_set() -> #{binary() => []}.

retired_set() ->
    case ets:whereis(?TABLE) of
        undefined ->
            #{};
        Tid ->
            maps:from_keys(
                ets:select(Tid, [
                    {
                        #origin_ban{origin = '$1', retired = true, _ = '_'},
                        [],
                        ['$1']
                    }
                ]),
                []
            )
    end.

?DOC("""
Returns all current bans as a list of maps.
""").
-spec list() -> [ban_entry()].

list() ->
    [
        #{
            origin => O,
            banned_at => BA,
            reason => R,
            proof => P,
            retired => Rt
        }
     || #origin_ban{
            origin = O,
            banned_at = BA,
            reason = R,
            proof = P,
            retired = Rt
        } <-
            ets:tab2list(?TABLE)
    ].

?DOC("""
The retired origins, as a sorted list. This is the value replicated to
peers and unioned by `merge_retired/1`.
""").
-spec retired() -> [binary()].

retired() ->
    lists:sort(maps:keys(retired_set())).

?DOC("""
Whether ANY origin is retired on this node, as a single
`persistent_term` read.

The frontier hot paths — `bondy_oplog_registry:merge_frontier/2` and
`bondy_oplog_sync_session:frontier_deficit/2` — consult the retirement
set on every round, and the set is empty in every deployment that has
never decommissioned a node. This is the guard that keeps those paths at
exactly their previous cost until an operator retires something.

The table's existence is part of the answer. A `persistent_term` outlives
the process that set it, so after a brutal kill of this gen_server the flag
would still say `true` while the table it describes is gone — and every
caller guards a table read with this
(`bondy_oplog_frontier_reap_test:retired_set_is_total_without_the_table/0`
stages exactly that stale flag).
""").
-spec has_retired() -> boolean().

has_retired() ->
    persistent_term:get({?MODULE, any_retired}, false) andalso
        ets:whereis(?TABLE) =/= undefined.

?DOC("""
Whether retirements survive a restart on this node — i.e. whether a
`retirement_path` is configured. Frontier reaping MUST refuse to run when
this is `false`.
""").
-spec is_persistent() -> boolean().

is_persistent() ->
    persistent_term:get({?MODULE, persistent}, false).

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init([]) ->
    process_flag(trap_exit, true),
    _Tab = ets:new(?TABLE, [
        named_table,
        set,
        protected,
        {keypos, #origin_ban.origin},
        {read_concurrency, true}
    ]),
    Path = configured_path(),
    State =
        case load_retired(Path) of
            ok ->
                ok = persistent_term:put(
                    {?MODULE, persistent}, Path =/= undefined
                ),
                #state{path = Path};
            {error, _Reason} ->
                %% The set on disk could not be read, so this node holds
                %% only part of it — or none. Reaping stays disabled until a
                %% write succeeds, which is also what makes the file good
                %% again. Peers re-supply the entries by union.
                ok = persistent_term:put({?MODULE, persistent}, false),
                #state{path = Path, alarmed = true}
        end,
    ok = publish_any_retired(),
    {ok,
        case State#state.alarmed of
            true -> raise_alarm(State#state{alarmed = false}, load_failed);
            false -> State
        end}.

handle_call({ban, Origin, Reason, Proof}, _From, State) ->
    Entry = #origin_ban{
        origin = Origin,
        banned_at = os:system_time(millisecond),
        reason = Reason,
        proof = Proof
    },
    true = ets:insert(?TABLE, Entry),
    ?LOG_NOTICE(#{
        description => "origin banned",
        origin => Origin,
        reason => Reason
    }),
    {reply, ok, State};
handle_call({unban, Origin}, _From, State) ->
    case is_retired(Origin) of
        true ->
            {reply, {error, retired}, State};
        false ->
            true = ets:delete(?TABLE, Origin),
            {reply, ok, State}
    end;
handle_call({retire, Origin, Reason}, _From, State) ->
    do_retire([{Origin, Reason}], State);
handle_call({merge_retired, Origins}, _From, State) ->
    do_retire([{O, replicated} || O <- Origins, is_binary(O)], State);
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% The table dies with this process, so the flags that describe it must
    %% not outlive it. `has_retired/0` re-checks the table for the brutal-kill
    %% path, which skips this callback entirely.
    _ = persistent_term:erase({?MODULE, any_retired}),
    _ = persistent_term:erase({?MODULE, persistent}),
    _ = clear_alarm(State),
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
configured_path() ->
    case application:get_env(bondy_oplog, retirement_path, undefined) of
        undefined ->
            ?LOG_INFO(#{
                description =>
                    "No origin retirement_path configured; retirements "
                    "will not survive a restart and frontier reaping "
                    "stays disabled on this node."
            }),
            undefined;
        Path ->
            unicode:characters_to_binary(Path)
    end.

%% @private
%% Applies a batch of retirements. PERSIST FIRST, enforce only on success.
%%
%% That order is not a preference. `proofs/tla/OriginRetirementSet.tla` with
%% `RetirementDurable = FALSE` — a replica may enforce a retirement it has
%% not persisted — violates `SpuriousGap` in 9 steps: mint, depart, sync,
%% depart, retire, REAP, RESTART, join. The restart forgets the retirement
%% while the reap it licensed is already gone from the frontier, so the node
%% reads a peer's surviving entry as a deficit for data it holds, on every
%% round, forever. `RetirementDurable = TRUE` is exhaustively clean
%% (2,538,102 distinct states).
%%
%% So a failed write must leave NOTHING enforced, which it does here: the
%% ETS insert is downstream of the persist
%% (`bondy_oplog_origin_bans_test:a_failed_persist_enforces_nothing/0`).
%% `persist/2` is tmp+datasync+rename+fsync_dir, so a failure also leaves
%% the previous file intact — everything already durable stays durable,
%% which is why a failure need not disable what was already reapable.
do_retire(_Pairs, #state{path = undefined} = State) ->
    {reply, {error, not_persistent}, State};
do_retire(Pairs, #state{path = Path} = State) ->
    Retired = retired_set(),
    New = [{O, R} || {O, R} <- Pairs, not is_map_key(O, Retired)],
    case New of
        [] ->
            {reply, ok, State};
        _ ->
            Wanted = lists:sort(
                maps:keys(Retired) ++ [O || {O, _} <- New]
            ),
            case persist(Path, Wanted) of
                ok ->
                    Now = os:system_time(millisecond),
                    true = ets:insert(?TABLE, [
                        #origin_ban{
                            origin = O,
                            banned_at = Now,
                            reason = R,
                            proof = undefined,
                            retired = true
                        }
                     || {O, R} <- New
                    ]),
                    ok = publish_any_retired(),
                    %% A successful write is the evidence the path works, so
                    %% it also lifts a persistence failure recorded earlier
                    %% — otherwise the alarm could clear while reaping stayed
                    %% disabled for the life of the node.
                    ok = persistent_term:put({?MODULE, persistent}, true),
                    ?LOG_NOTICE(#{
                        description => "origins retired",
                        origins => [O || {O, _} <- New],
                        retired_total => length(Wanted)
                    }),
                    {reply, ok, clear_alarm(State)};
                {error, Reason} ->
                    %% Nothing was enforced, so there is no divergence to
                    %% recover from — only an operation that did not happen.
                    ok = persistent_term:put({?MODULE, persistent}, false),
                    ?LOG_ERROR(#{
                        description =>
                            "Failed to persist the origin retirement set; "
                            "nothing was retired. Frontier reaping is "
                            "disabled on this node until a retirement "
                            "persists successfully.",
                        path => Path,
                        reason => Reason
                    }),
                    {reply, {error, not_persistent}, raise_alarm(State, Reason)}
            end
    end.

%% @private
%% The on-disk form is one length-prefixed origin after another, so a
%% truncated tail is detectable rather than silently yielding a short
%% origin. A corrupt file is refused wholesale: loading PART of a
%% retirement set is worse than loading none, because the missing entries
%% are the ones whose deficits this node would then report.
load_retired(undefined) ->
    ok;
load_retired(Path) ->
    case prim_file:read_file(Path) of
        {ok, Bin} ->
            case decode_retired(Bin, []) of
                {ok, Origins} ->
                    Now = os:system_time(millisecond),
                    true = ets:insert(?TABLE, [
                        #origin_ban{
                            origin = O,
                            banned_at = Now,
                            reason = persisted,
                            proof = undefined,
                            retired = true
                        }
                     || O <- Origins
                    ]),
                    ok;
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        description =>
                            "Corrupt origin retirement set; it has been "
                            "ignored and frontier reaping is disabled on "
                            "this node. Peers will re-supply the set, and "
                            "the next successful write repairs the file.",
                        path => Path,
                        reason => Reason
                    }),
                    {error, Reason}
            end;
        {error, enoent} ->
            %% First boot with a configured path: nothing retired yet.
            ok;
        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Failed to read the origin retirement set; frontier "
                    "reaping is disabled on this node.",
                path => Path,
                reason => Reason
            }),
            {error, Reason}
    end.

%% @private
%% Once per episode: `alarm_handler` does not dedupe, so an unguarded
%% `set_alarm` on every failed write fills `get_alarms/0` with duplicates.
raise_alarm(#state{alarmed = true} = State, _Reason) ->
    State;
raise_alarm(#state{path = Path} = State, Reason) ->
    ok = set_persist_alarm(Path, Reason),
    State#state{alarmed = true}.

%% @private
clear_alarm(#state{alarmed = false} = State) ->
    State;
clear_alarm(State) ->
    ok = clear_persist_alarm(),
    State#state{alarmed = false}.

%% @private
%% Only a CONFIGURED path that fails raises: an unconfigured one is a
%% deployment choice (embedded use, tests), announced once at INFO, and
%% alarming on it would page every operator who never wanted retirement.
set_persist_alarm(Path, Reason) ->
    Desc = iolist_to_binary(
        io_lib:format(
            "The origin retirement set at ~ts cannot be read or written "
            "(~p). Retirement and frontier reaping are disabled on this "
            "node, and because reaping requires every member to hold the "
            "retirement, no node in the cluster can reclaim a departed "
            "node's frontier entries until this is fixed.",
            [Path, Reason]
        )
    ),
    _ = catch alarm_handler:set_alarm({?PERSIST_ALARM_ID, Desc}),
    ok.

%% @private
clear_persist_alarm() ->
    _ = catch alarm_handler:clear_alarm(?PERSIST_ALARM_ID),
    ok.

%% @private
publish_any_retired() ->
    persistent_term:put({?MODULE, any_retired}, retired() =/= []).

%% @private
decode_retired(<<>>, Acc) ->
    {ok, lists:reverse(Acc)};
decode_retired(<<Len:16, Origin:Len/binary, Rest/binary>>, Acc) ->
    decode_retired(Rest, [Origin | Acc]);
decode_retired(_Trailing, _Acc) ->
    {error, truncated}.

%% @private
encode_retired(Origins) ->
    iolist_to_binary([
        <<(byte_size(O)):16, O/binary>>
     || O <- Origins
    ]).

%% @private
%% tmp + datasync + rename + fsync_dir — the same durability sequence
%% `bondy_oplog_origin:persist/2` uses for the origin file.
persist(Path, Origins) ->
    Dir = filename:dirname(Path),
    Tmp = <<Path/binary, ".tmp">>,
    case filelib:ensure_dir(Path) of
        ok ->
            case write_and_sync(Tmp, encode_retired(Origins)) of
                ok ->
                    case bondy_mst_io:rename(Tmp, Path) of
                        ok ->
                            bondy_mst_io:fsync_dir(Dir);
                        {error, _} = E ->
                            _ = prim_file:delete(Tmp),
                            E
                    end;
                {error, _} = E ->
                    _ = prim_file:delete(Tmp),
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
write_and_sync(Tmp, Bin) ->
    case prim_file:open(Tmp, [write, raw, binary]) of
        {ok, Fd} ->
            try
                case prim_file:write(Fd, Bin) of
                    ok -> bondy_mst_io:datasync(Fd);
                    {error, _} = E -> E
                end
            after
                _ = prim_file:close(Fd)
            end;
        {error, _} = E ->
            E
    end.
