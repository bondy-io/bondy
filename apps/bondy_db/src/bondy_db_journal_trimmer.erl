%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_journal_trimmer).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Periodically reclaims journal disk for the Bookies of one
`bondy_db_leveled_sup`.

## Why this exists

Bondy opens every durable Bookie in `head_only` mode. In that mode a
write is appended to BOTH stores: the whole cell goes into the ledger as
a HEAD entry, and the same object specs go into the journal, where they
serve only to make the ledger recoverable after an unclean stop. No read
path reads them.

Nothing in leveled reclaims that journal on its own:

- `book_compactjournal/2` is refused — its handler is guarded
  `when head_only == false`.
- `book_trimjournal/1`, the head_only counterpart, is guarded
  `when head_only == true`, and leveled never calls it itself: both its
  `handle_info/2` clauses are a snapshot `'DOWN'` and a no-op catch-all.

So without this process the journal grows in step with cumulative writes
— every version of every cell ever written, forever — while the ledger
holds only the live set. Measured on a synthetic store: 4000 cells of
~620 bytes (2.5 MB live) rewritten 12 times produced a 14 MB journal
across 6 files.

## What a trim does

`book_trimjournal/1` asks the penciller for the highest SQN it has
persisted into the ledger, then drops every journal file older than the
one containing that SQN (`leveled_imanifest:find_persistedentries/2`).
Files still needed to recover the un-persisted tail are kept, so the
reclaim is safe by construction: what it deletes is exactly what a clean
restart would no longer replay.

Deletion is not synchronous. Leveled marks each file `delete_pending`
and the file process polls the inker every `?DELETE_TIMEOUT` (10s in
leveled) until no snapshot can still be reading it. Disk therefore comes
back a beat after the call returns, not during it — a trim that appears
to have done nothing has usually just not reached that poll yet.

Verified against leveled directly (`openriak-4.0`): with `persisted_sqn`
at 209 and seven rolled journal files, one `book_trimjournal/1` took the
store to a single file within ~10s.

## Scheduling

One trimmer per `bondy_db_leveled_sup`, started as that supervisor's
first child, so every topology that provisions Bookies gets one without
threading anything through the topology modules. Each tick enumerates
its siblings with `supervisor:which_children/1` and trims each live
Bookie. `db.journal_trim_interval` sets the cadence; `0` disables the
timer entirely and this process then idles.

A Bookie mid-restart is not an error: the call is wrapped, a failure is
counted and the next tick retries.
""").

-record(state, {
    sup :: pid(),
    interval :: non_neg_integer(),
    timer :: reference() | undefined
}).

-export([start_link/1]).
-export([trim_now/1]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-define(DEFAULT_INTERVAL_MS, 3600_000).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(Sup :: pid()) -> {ok, pid()} | {error, term()}.

start_link(Sup) when is_pid(Sup) ->
    gen_server:start_link(?MODULE, [Sup], []).

?DOC("""
Runs a trim pass immediately and returns the number of Bookies trimmed.
Synchronous, for operators and tests. Note that the disk is reclaimed a
beat later — see the moduledoc on `delete_pending`.
""").
-spec trim_now(pid()) -> {ok, non_neg_integer()}.

trim_now(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, trim_now, infinity).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([Sup]) ->
    Interval = interval_ms(),
    {ok, schedule(#state{sup = Sup, interval = Interval})}.

handle_call(trim_now, _From, State) ->
    {reply, {ok, trim_all(State#state.sup)}, State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, Ref, trim}, #state{timer = Ref} = State) ->
    _ = trim_all(State#state.sup),
    {noreply, schedule(State#state{timer = undefined})};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
schedule(#state{interval = 0} = State) ->
    State#state{timer = undefined};
schedule(#state{interval = I} = State) ->
    State#state{timer = erlang:start_timer(I, self(), trim)}.

%% @private
interval_ms() ->
    case application:get_env(bondy_db, journal_trim_interval_ms, undefined) of
        undefined -> ?DEFAULT_INTERVAL_MS;
        I when is_integer(I), I >= 0 -> I;
        _ -> ?DEFAULT_INTERVAL_MS
    end.

%% @private
%% Trims every live Bookie under `Sup`. The trimmer itself is a child of
%% that supervisor, so it is filtered out by module rather than by id.
trim_all(Sup) ->
    Bookies = [
        Pid
     || {_Id, Pid, _Type, Mods} <- safe_children(Sup),
        is_pid(Pid),
        Mods =:= [leveled_bookie]
    ],
    Trimmed = lists:foldl(fun trim_one/2, 0, Bookies),
    Trimmed > 0 andalso
        telemetry:execute(
            [bondy_db, journal, trim],
            #{bookies => Trimmed},
            #{}
        ),
    Trimmed.

%% @private
safe_children(Sup) ->
    try
        supervisor:which_children(Sup)
    catch
        _:_ -> []
    end.

%% @private
trim_one(Pid, Acc) ->
    try leveled_bookie:book_trimjournal(Pid) of
        ok ->
            Acc + 1;
        Other ->
            ?LOG_DEBUG(#{
                description => "Unexpected reply from book_trimjournal",
                bookie => Pid,
                reply => Other
            }),
            Acc
    catch
        Class:Reason ->
            %% A Bookie mid-restart, or one that just exited. The next
            %% tick retries; there is nothing to repair here.
            ?LOG_DEBUG(#{
                description =>
                    "Journal trim skipped for a Bookie that was unavailable",
                bookie => Pid,
                class => Class,
                reason => Reason
            }),
            Acc
    end.
