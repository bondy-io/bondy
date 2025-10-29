%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2025 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================


-module(bondy_itc).

-moduledoc """
Interval Tree Clocks (ITC) implementation based on the paper [Interval Tree Clocks: A Logical Clock for Dynamic Systems
by Paulo Sérgio Almeida, Carlos Baquero, and Victor Fonte (2008)](http://gsd.di.uminho.pt/members/cbm/ps/itc2008.pdf)

ITC provides a causality tracking mechanism for dynamic distributed systems
where processes/replicas can be created or retired in a decentralized fashion.
""".

%% Type definitions
-type id_tree() :: 0 | 1 | {id_tree(), id_tree()}.
-type event_tree() ::
    non_neg_integer()
    | {non_neg_integer(), event_tree(), event_tree()}.
-type stamp() :: {id_tree(), event_tree()}.



%% API exports - Core operations
-export([seed/0]).
-export([fork/1]).
-export([event/1]).
-export([join/2]).
-export([peek/1]).
-export([leq/2]).

%% API exports - Utility functions
-export([is_valid/1]).
-export([encode/1]).
-export([decode/1]).




%% =============================================================================
%% API
%% =============================================================================



-doc """
Create the seed stamp (1,0) from which all stamps derive
""".
-spec seed() -> stamp().

seed() ->
    {1, 0}.

-doc """
Fork operation - splits a stamp into two stamps with identical event components
but disjoint id components
""".
-spec fork(stamp()) -> {stamp(), stamp()}.

fork({Id, Event}) ->
    {Id1, Id2} = split_id(Id),
    {{Id1, Event}, {Id2, Event}}.

-doc """
Event operation - registers a new event by inflating the event component
Precondition: Id must be non-null (not 0)
""".
-spec event(stamp()) -> stamp().

event({0, _Event}) ->
    error(anonymous_stamp_cannot_register_events);

event({Id, Event}) ->
    case fill(Id, Event) of
        Event ->  %% No change from fill, use grow
            {Event1, _Cost} = grow(Id, Event),
            {Id, Event1};
        Event1 ->  %% Fill succeeded
            {Id, Event1}
    end.

-doc """
Join operation - merges two stamps by summing their ids and joining events
""".
-spec join(stamp(), stamp()) -> stamp().

join({Id1, Event1}, {Id2, Event2}) ->
    {sum_id(Id1, Id2), join_event(Event1, Event2)}.

-doc """
Peek operation - creates an anonymous stamp for message passing
""".
-spec peek(stamp()) -> {stamp(), stamp()}.

peek({Id, Event}) ->
    {{0, Event}, {Id, Event}}.

-doc """
Compare stamps using the partial order (less than or equal)
""".
-spec leq(stamp(), stamp()) -> boolean().

leq({_Id1, Event1}, {_Id2, Event2}) ->
    leq_event(Event1, Event2).

-doc """
Check if a stamp is valid (normalized)
""".
-spec is_valid(stamp()) -> boolean().

is_valid({Id, Event}) ->
    Id =:= norm_id(Id) andalso Event =:= norm_event(Event).




%% =============================================================================
%% API ID Tree Operations
%% =============================================================================



%% Normalize an ID tree
norm_id({0, 0}) -> 0;
norm_id({1, 1}) -> 1;
norm_id(Id) -> Id.

%% Split an ID tree for forking
split_id(0) -> {0, 0};
split_id(1) -> {{1, 0}, {0, 1}};
split_id({0, I}) ->
    {I1, I2} = split_id(I),
    {{0, I1}, {0, I2}};
split_id({I, 0}) ->
    {I1, I2} = split_id(I),
    {{I1, 0}, {I2, 0}};
split_id({I1, I2}) ->
    {{I1, 0}, {0, I2}}.

%% Sum two ID trees
sum_id(0, Id) -> Id;
sum_id(Id, 0) -> Id;
sum_id({L1, R1}, {L2, R2}) ->
    norm_id({sum_id(L1, L2), sum_id(R1, R2)}).




%% =============================================================================
%% Event Tree Operations
%% =============================================================================



%% Normalize an event tree
norm_event(N) when is_integer(N) -> N;
norm_event({N, M, M}) when is_integer(M) -> N + M;
norm_event({N, E1, E2}) ->
    M = min(min_event(E1), min_event(E2)),
    {N + M, lift_event(E1, -M), lift_event(E2, -M)}.

%% Get minimum value in an event tree (for normalized trees)
min_event(N) when is_integer(N) -> N;
min_event({N, _E1, _E2}) -> N.

%% Get maximum value in an event tree
max_event(N) when is_integer(N) -> N;
max_event({N, E1, E2}) ->
    N + max(max_event(E1), max_event(E2)).

%% Lift an event tree by an offset
lift_event(N, Offset) when is_integer(N) -> N + Offset;
lift_event({N, E1, E2}, Offset) -> {N + Offset, E1, E2}.

%% Join two event trees
join_event(N1, N2) when is_integer(N1), is_integer(N2) ->
    max(N1, N2);
join_event(N1, {N2, L2, R2}) when is_integer(N1) ->
    join_event({N1, 0, 0}, {N2, L2, R2});
join_event({N1, L1, R1}, N2) when is_integer(N2) ->
    join_event({N1, L1, R1}, {N2, 0, 0});
join_event({N1, L1, R1}, {N2, L2, R2}) when N1 > N2 ->
    join_event({N2, L2, R2}, {N1, L1, R1});
join_event({N1, L1, R1}, {N2, L2, R2}) ->
    Diff = N2 - N1,
    norm_event({N1, 
                join_event(L1, lift_event(L2, Diff)),
                join_event(R1, lift_event(R2, Diff))}).

%% Compare event trees for less-than-or-equal
leq_event(N1, N2) when is_integer(N1), is_integer(N2) ->
    N1 =< N2;
leq_event(N1, {N2, _L2, _R2}) when is_integer(N1) ->
    N1 =< N2;
leq_event({N1, L1, R1}, N2) when is_integer(N2) ->
    N1 =< N2 andalso
    leq_event(lift_event(L1, N1), N2) andalso
    leq_event(lift_event(R1, N1), N2);
leq_event({N1, L1, R1}, {N2, L2, R2}) ->
    N1 =< N2 andalso
    leq_event(lift_event(L1, N1), lift_event(L2, N2)) andalso
    leq_event(lift_event(R1, N1), lift_event(R2, N2)).




%% =============================================================================
%% Event Registration Functions (fill and grow)
%% =============================================================================



%% Fill operation - tries to simplify the event tree using available ID
fill(0, E) -> E;
fill(1, E) -> max_event(E);
fill(_Id, N) when is_integer(N) -> N;
fill({1, Ir}, {N, El, Er}) ->
    Er1 = fill(Ir, Er),
    norm_event({N, max(max_event(El), min_event(Er1)), Er1});
fill({Il, 1}, {N, El, Er}) ->
    El1 = fill(Il, El),
    norm_event({N, El1, max(max_event(Er), min_event(El1))});
fill({Il, Ir}, {N, El, Er}) ->
    norm_event({N, fill(Il, El), fill(Ir, Er)}).

%% Grow operation - inflates event tree minimizing growth cost
%% Large constant for cost calculation
-define(GROW_COST_CONSTANT, 1000000).

grow(1, N) when is_integer(N) ->
    {N + 1, 0};
grow(Id, N) when is_integer(N) ->
    {E1, Cost} = grow(Id, {N, 0, 0}),
    {E1, Cost + ?GROW_COST_CONSTANT};
grow({0, Ir}, {N, El, Er}) ->
    {Er1, Cr} = grow(Ir, Er),
    {{N, El, Er1}, Cr + 1};
grow({Il, 0}, {N, El, Er}) ->
    {El1, Cl} = grow(Il, El),
    {{N, El1, Er}, Cl + 1};
grow({Il, Ir}, {N, El, Er}) ->
    {El1, Cl} = grow(Il, El),
    {Er1, Cr} = grow(Ir, Er),
    if
        Cl < Cr -> {{N, El1, Er}, Cl + 1};
        true -> {{N, El, Er1}, Cr + 1}
    end.



%% =============================================================================
%% Encoding/Decoding Functions
%% =============================================================================



-doc """
Encode a stamp to binary format
""".
-spec encode(stamp()) -> binary().

encode({Id, Event}) ->
    IdBits = encode_id(Id),
    EventBits = encode_event(Event),
    <<IdBits/bitstring, EventBits/bitstring>>.

encode_id(0) ->
    <<0:2, 0:1>>;

encode_id(1) ->
    <<0:2, 1:1>>;

encode_id({0, I}) ->
    IBits = encode_id(I),
    <<1:2, IBits/bitstring>>;

encode_id({I, 0}) ->
    IBits = encode_id(I),
    <<2:2, IBits/bitstring>>;

encode_id({Il, Ir}) ->
    IlBits = encode_id(Il),
    IrBits = encode_id(Ir),
    <<3:2, IlBits/bitstring, IrBits/bitstring>>.

encode_event({0, 0, Er}) ->
    ErBits = encode_event(Er),
    <<0:1, 0:2, ErBits/bitstring>>;

encode_event({0, El, 0}) ->
    ElBits = encode_event(El),
    <<0:1, 1:2, ElBits/bitstring>>;

encode_event({0, El, Er}) ->
    ElBits = encode_event(El),
    ErBits = encode_event(Er),
    <<0:1, 2:2, ElBits/bitstring, ErBits/bitstring>>;

encode_event({N, 0, Er}) ->
    NBits = encode_event(N),
    ErBits = encode_event(Er),
    <<0:1, 3:2, 0:1, 0:1, NBits/bitstring, ErBits/bitstring>>;

encode_event({N, El, 0}) ->
    NBits = encode_event(N),
    ElBits = encode_event(El),
    <<0:1, 3:2, 0:1, 1:1, NBits/bitstring, ElBits/bitstring>>;

encode_event({N, El, Er}) ->
    NBits = encode_event(N),
    ElBits = encode_event(El),
    ErBits = encode_event(Er),
    <<0:1, 3:2, 1:1, NBits/bitstring, ElBits/bitstring, ErBits/bitstring>>;

encode_event(N) when is_integer(N) ->
    <<1:1, (encode_number(N, 2))/bitstring>>.

encode_number(N, B) when N < (1 bsl B) ->
    <<0:1, N:B>>;

encode_number(N, B) ->
    <<1:1, (encode_number(N - (1 bsl B), B + 1))/bitstring>>.


-doc """
Decode a binary to a stamp
""".
-spec decode(binary()) -> stamp().

decode(Bits) ->
    {Id, Rest1} = decode_id(Bits),
    {Event, _Rest2} = decode_event(Rest1),
    {Id, Event}.

decode_id(<<0:2, 0:1, Rest/bitstring>>) ->
    {0, Rest};

decode_id(<<0:2, 1:1, Rest/bitstring>>) ->
    {1, Rest};

decode_id(<<1:2, Rest/bitstring>>) ->
    {I, Rest1} = decode_id(Rest),
    {{0, I}, Rest1};

decode_id(<<2:2, Rest/bitstring>>) ->
    {I, Rest1} = decode_id(Rest),
    {{I, 0}, Rest1};

decode_id(<<3:2, Rest/bitstring>>) ->
    {Il, Rest1} = decode_id(Rest),
    {Ir, Rest2} = decode_id(Rest1),
    {{Il, Ir}, Rest2}.

decode_event(<<1:1, Rest/bitstring>>) ->
    decode_number(Rest, 2);

decode_event(<<0:1, Type:2, Rest/bitstring>>) ->
    case Type of
        0 ->
            %% {0, 0, Er}
            {Er, Rest1} = decode_event(Rest),
            {{0, 0, Er}, Rest1};

        1 ->
            %% {0, El, 0}
            {El, Rest1} = decode_event(Rest),
            {{0, El, 0}, Rest1};

        2 ->
            %% {0, El, Er}
            {El, Rest1} = decode_event(Rest),
            {Er, Rest2} = decode_event(Rest1),
            {{0, El, Er}, Rest2};

        3 ->
            %% Extended format
            decode_event_extended(Rest)
    end.

decode_event_extended(<<0:1, SubType:1, Rest/bitstring>>) ->
    {N, Rest1} = decode_event(Rest),
    case SubType of
        0 ->  %% {N, 0, Er}
            {Er, Rest2} = decode_event(Rest1),
            {{N, 0, Er}, Rest2};
        1 ->  %% {N, El, 0}
            {El, Rest2} = decode_event(Rest1),
            {{N, El, 0}, Rest2}
    end;

decode_event_extended(<<1:1, Rest/bitstring>>) ->
    {N, Rest1} = decode_event(Rest),
    {El, Rest2} = decode_event(Rest1),
    {Er, Rest3} = decode_event(Rest2),
    {{N, El, Er}, Rest3}.

decode_number(Bin, B) when is_integer(B) ->
    case Bin of
        <<0:1, N:B, Rest/bitstring>>->
            {N, Rest};
        <<1:1, Rest/bitstring>> ->
            {N, Rest1} = decode_number(Rest, B + 1),
            {N + (1 bsl B), Rest1}
    end.
