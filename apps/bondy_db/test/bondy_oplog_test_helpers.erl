%% =============================================================================
%% Shared test helpers for bondy_mst eunit suites.
%%
%% Centralises the boilerplate for fabricating projection cell frames
%% (V2 wire format with optional value column) and projecting fold
%% states to the user-facing values that the substrate now returns from
%% `bondy_oplog_core:read/3..5`.
%% =============================================================================

-module(bondy_oplog_test_helpers).

-export([frame/3]).
-export([frame/4]).
-export([value_of/2]).

%% Build a V2 cell frame for the given fold state. Equivalent to what
%% the applier writes through `bondy_oplog_cell_apply` —
%% state bytes + `term_to_binary(to_value(State))` value bytes.
%%
%% Callers that want to inject an explicit HLC distinct from the
%% state's intrinsic HLC use `frame/4`.
-spec frame(
    Strategy :: atom(),
    State :: term(),
    Hlc :: non_neg_integer()
) -> binary().

frame(Strategy, State, Hlc) ->
    Mod = crdt_mod(Strategy),
    frame(Strategy, State, Hlc, Mod:value_equals_state()).

frame(Strategy, State, Hlc, true) ->
    Mod = crdt_mod(Strategy),
    StateBytes = Mod:encode_state(State),
    bondy_oplog_cell_frame:encode(Hlc, StateBytes, undefined, true);
frame(Strategy, State, Hlc, false) ->
    Mod = crdt_mod(Strategy),
    StateBytes = Mod:encode_state(State),
    ValueBytes = term_to_binary(Mod:to_value(State)),
    bondy_oplog_cell_frame:encode(Hlc, StateBytes, ValueBytes, false).

%% Convenience: the value that `bondy_oplog_core:read/3` is expected to
%% return for `State`.
-spec value_of(Strategy :: atom(), State :: term()) -> term().

value_of(Strategy, State) ->
    (crdt_mod(Strategy)):to_value(State).

%% Resolve a `fold_module` label to its native CRDT twin (PR-Z).
crdt_mod(Strategy) ->
    {crdt, Mod} = bondy_oplog_cell_kernel:from_modules(Strategy, undefined),
    Mod.
