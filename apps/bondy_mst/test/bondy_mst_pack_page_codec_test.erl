%% =============================================================================
%% EUnit suite for `bondy_mst_pack_store`'s PAGE codec — `serialise/1` and
%% `deserialise/1`, the durability contract with the on-disk pack format.
%%
%% The property under test is that a page this node wrote is a page this node
%% can read back, INDEPENDENT of which modules happen to be loaded at read
%% time. Decoding with `[safe]` resolves atoms against the VM's atom table AT
%% READ TIME, so a page carrying an atom whose defining module has not loaded
%% yet raises `badarg` — killing the boot fold in
%% `bondy_oplog_instance:init/1` and leaving the node unable to open a store it
%% wrote perfectly well.
%%
%% That hazard is unreachable through the public API — a page holding an atom
%% this VM does not know cannot be constructed from inside this VM — so the
%% bytes are built by name-substitution on a real `serialise/1` output, which
%% keeps the external term format exactly valid while naming an atom that has
%% never existed here.
%%
%% NOTE on the atom names: they are assembled at RUNTIME. Written as literals,
%% `binary_to_atom(<<"...">>, utf8)` is constant-folded by the compiler and the
%% atom lands in this module's atom chunk, so it exists the moment the module
%% loads — which silently defeats the whole suite.
%% =============================================================================

-module(bondy_mst_pack_page_codec_test).

-include_lib("eunit/include/eunit.hrl").

%% Its name length is what the substituted names must match, so that every ETF
%% length prefix in the encoded page stays correct.
-define(PLACEHOLDER, 'mst_codec_placeholder_atom_0001').

%% =============================================================================
%% TESTS
%% =============================================================================

round_trip_preserves_page_test() ->
    Page = bondy_mst_page:new(0, undefined, [{k, v}]),
    Bytes = bondy_mst_pack_store:serialise(Page),
    ?assertEqual(Page, bondy_mst_pack_store:deserialise(Bytes)).

%% The regression lock. Before the fix this raised `badarg`.
deserialise_accepts_an_atom_absent_from_the_atom_table_test() ->
    Name = never_loaded_name(1),
    Bytes = page_bytes_naming(Name),

    %% Precondition: the substitution really does name an atom this VM has
    %% never created. Without this the assertion below proves nothing.
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)),

    Page = bondy_mst_pack_store:deserialise(Bytes),
    ?assertEqual([binary_to_atom(Name, utf8)], bondy_mst_page:list(Page)).

%% Guard the guard: those bytes are only interesting if `[safe]` is what
%% rejects them. Uses its own name, since the test above creates its atom on
%% the way out.
safe_decoding_is_what_rejects_those_bytes_test() ->
    Name = never_loaded_name(2),
    Bytes = page_bytes_naming(Name),
    ?assertError(badarg, binary_to_term(Bytes, [safe])),
    ?assertMatch({0, undefined, [_]}, binary_to_term(Bytes)).

%% Genuinely malformed bytes must still be rejected — dropping `[safe]` must
%% not weaken the corruption detection the pack reader relies on.
deserialise_still_rejects_malformed_bytes_test() ->
    Page = bondy_mst_page:new(0, undefined, [{k, v}]),
    Bytes = bondy_mst_pack_store:serialise(Page),
    Truncated = binary:part(Bytes, 0, byte_size(Bytes) - 3),
    ?assertError(badarg, bondy_mst_pack_store:deserialise(Truncated)),
    ?assertError(badarg, bondy_mst_pack_store:deserialise(<<"not a term">>)).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Built from a variable so the compiler cannot fold it into an atom literal.
never_loaded_name(N) when is_integer(N) ->
    <<"mst_codec_neverloaded_atom_000", (integer_to_binary(N))/binary>>.

%% @private
%% Serialise a page whose only element is `?PLACEHOLDER`, then rename that atom
%% in the encoded bytes. Equal name lengths keep the ETF valid.
page_bytes_naming(Name) ->
    Placeholder = atom_to_binary(?PLACEHOLDER, utf8),
    byte_size(Name) == byte_size(Placeholder) orelse
        error({name_length_mismatch, Name, Placeholder}),
    Page = bondy_mst_page:new(0, undefined, [?PLACEHOLDER]),
    Bytes = bondy_mst_pack_store:serialise(Page),
    binary:replace(Bytes, Placeholder, Name).
