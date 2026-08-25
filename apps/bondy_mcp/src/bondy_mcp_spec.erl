%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_spec).

-moduledoc """
The compiled MCP manifest entry: the projection of one realm's interface
metadata (`bondy_interface`, the base layer) joined with the MCP overlay
documents (`bondy_mcp_spec_parser`, the naming/annotation layer) — design
§7.2's "one way out".

`compile/2` derives the manifest of one realm:

- every EXACT-match `procedure` interface entry becomes a `tool` named by
  its WAMP URI (§17's default), unless an overlay tool entry claims that
  procedure — a claim REPLACES the URI-named base entry, which is what
  makes an overlay rename a rename rather than an added alias;
- every exact-match `topic` interface entry becomes a `resource` at the
  default URI `wamp:<realm>:<topic>` (§17);
- overlay entries stand on their own, joining the interface entry of their
  `wamp_procedure` (when one exists) field by field: an overlay field wins,
  an absent one falls through to the interface layer;
- two surviving entries claiming one name with DIFFERENT underlying WAMP
  bindings are BOTH skipped and reported in `collisions` (§17) — the
  caller raises the critical alarm; identical bindings from two documents
  keep the entry from the lexicographically first document, so the result
  is deterministic.

Each compiled entry carries `hash`: a SHA-256 over its NORMATIVE content —
name, kind, the flattened schemas, the WAMP binding and the annotations
(§7.5) — so drift is visible and an operator can pin a tool to the exact
content a security review saw. `description`, `version` and provenance are
deliberately outside the hash: prose can be corrected without re-approving
the tool. The canonical byte form is `term_to_binary/2` with
`deterministic` (the `bondy_db_manifest:fingerprint/1` precedent): stable
for one OTP release; an OTP major upgrade may re-key hashes, which surfaces
as visible drift, never as silent acceptance.

Schemas are flattened per §16.1, symmetrically for input and output: a
kwargs-only shape passes through, an args-only shape wraps under the
reserved `@args` key, a mixed shape merges `@args` into the kwargs
properties.
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

%% The §7.5 normative content: what `hash/1` covers. Everything else on a
%% compiled entry (realm, description, version, source) may change without
%% changing the hash.
-define(NORMATIVE_KEYS, [
    name,
    kind,
    procedure,
    topic,
    uri,
    uri_template,
    uri_vars_schema,
    wamp_args,
    wamp_kwargs,
    update_topic,
    wamp_options,
    annotations,
    input_schema,
    output_schema
]).

-type kind() :: tool | resource | resource_template.
-type t() :: #{
    realm := uri(),
    name := binary(),
    kind := kind(),
    hash := binary(),
    annotations := map(),
    wamp_options := map(),
    source := #{interface => binary(), overlay => binary()},
    procedure => uri(),
    topic => uri(),
    uri => binary(),
    uri_template => binary(),
    uri_vars_schema => map(),
    wamp_args => list(),
    wamp_kwargs => map(),
    update_topic => binary(),
    description => binary(),
    version => binary(),
    input_schema => map(),
    output_schema => map()
}.
-type collision() :: #{
    realm := uri(),
    name := binary(),
    bindings := [uri()]
}.

-export_type([t/0]).
-export_type([collision/0]).

-export([compile/2]).
-export([hash/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Compiles the manifest of `RealmUri` from the interface store joined with
`OverlayEntries` — the parsed entries of every loaded overlay document that
name this realm, each annotated by the caller with `overlay_source` (its
document id). Reads `bondy_db` only; contacts no peer (§7.10).
""".
-spec compile(RealmUri :: uri(), OverlayEntries :: [map()]) ->
    #{entries := #{binary() => t()}, collisions := [collision()]}.

compile(RealmUri, OverlayEntries) ->
    Procedures = interface_entries(RealmUri, procedure),
    Topics = interface_entries(RealmUri, topic),

    %% An overlay tool entry claiming a procedure replaces the URI-named
    %% base entry compiled from that procedure's interface entry.
    Claimed = [
        maps:get(wamp_procedure, O)
     || O <- OverlayEntries, maps:get(kind, O) == tool
    ],
    BaseTools = [
        base_tool(RealmUri, E)
     || {Uri, E} <- maps:to_list(Procedures),
        not lists:member(Uri, Claimed)
    ],
    BaseResources = [
        base_resource(RealmUri, E)
     || {_, E} <- maps:to_list(Topics)
    ],
    Overlaid = [
        overlay_entry(RealmUri, O, Procedures)
     || O <- OverlayEntries
    ],
    {Entries, Collisions} = resolve_names(
        BaseTools ++ BaseResources ++ Overlaid
    ),
    #{
        entries => maps:from_list([
            {maps:get(name, E), with_hash(E)}
         || E <- Entries
        ]),
        collisions => Collisions
    }.

-doc """
The content-addressed hash of a compiled entry (§7.5): `<<"sha256:...">>`
(lowercase hex) over the entry's normative fields.
""".
-spec hash(t() | map()) -> binary().

hash(Entry) when is_map(Entry) ->
    Normative = maps:with(?NORMATIVE_KEYS, Entry),
    Digest = crypto:hash(
        sha256, term_to_binary(Normative, [deterministic])
    ),
    <<"sha256:", (binary:encode_hex(Digest, lowercase))/binary>>.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The realm's exact-match interface entries of `Kind`, as `Uri => Entry`.
%% Prefix / wildcard entries describe pattern registrations; MCP's surface
%% is callable-by-exact-URI, so they do not project.
interface_entries(RealmUri, Kind) ->
    maps:from_list([
        {maps:get(uri, E), E}
     || E <- bondy_interface:list(RealmUri, Kind),
        maps:get(match_policy, E) == ?EXACT_MATCH
    ]).

%% @private
base_tool(RealmUri, Iface) ->
    Uri = maps:get(uri, Iface),
    finish(
        RealmUri,
        #{
            name => Uri,
            kind => tool,
            procedure => Uri,
            annotations => #{},
            wamp_options => #{},
            source => #{interface => maps:get(source, Iface)}
        },
        Iface,
        #{}
    ).

%% @private
base_resource(RealmUri, Iface) ->
    Uri = maps:get(uri, Iface),
    E = #{
        realm => RealmUri,
        name => Uri,
        kind => resource,
        topic => Uri,
        uri => <<"wamp:", RealmUri/binary, ":", Uri/binary>>,
        annotations => #{},
        wamp_options => #{},
        source => #{interface => maps:get(source, Iface)}
    },
    %% A topic's payload schemas describe what a subscriber RECEIVES, so
    %% they flatten into the resource's output shape.
    E1 = maybe_put(description, maps:get(description, Iface, undefined), E),
    E2 = maybe_put(version, maps:get(version, Iface, undefined), E1),
    E3 = maybe_put(
        output_schema,
        flatten(
            maps:get(args_schema, Iface, undefined),
            maps:get(kwargs_schema, Iface, undefined)
        ),
        E2
    ),
    E3.

%% @private
%% One overlay entry joined with the interface entry of its procedure:
%% overlay fields win, absent ones fall through (§7.2 layering).
overlay_entry(RealmUri, O, Procedures) ->
    Procedure = maps:get(wamp_procedure, O),
    Iface = maps:get(Procedure, Procedures, #{}),
    E0 = #{
        name => maps:get(name, O),
        kind => maps:get(kind, O),
        procedure => Procedure,
        annotations => maps:get(annotations, O, #{}),
        wamp_options => maps:get(wamp_options, O, #{}),
        source => maybe_put(
            interface,
            maps:get(source, Iface, undefined),
            #{overlay => maps:get(overlay_source, O)}
        )
    },
    E1 =
        case maps:get(kind, O) of
            tool ->
                E0;
            resource_template ->
                E2 = E0#{
                    uri_template => maps:get(uri_template, O),
                    uri_vars_schema => maps:get(uri_vars_schema, O),
                    wamp_args => maps:get(wamp_args, O),
                    wamp_kwargs => maps:get(wamp_kwargs, O)
                },
                maybe_put(
                    update_topic, maps:get(update_topic, O, undefined), E2
                )
        end,
    finish(RealmUri, E1, Iface, O).

%% @private
%% Layered fields plus the flattened schemas. `Over` (the overlay entry)
%% wins per field; `Iface` (the interface entry) supplies the rest.
finish(RealmUri, E0, Iface, Over) ->
    Layered = fun(Key) ->
        case maps:get(Key, Over, undefined) of
            undefined -> maps:get(Key, Iface, undefined);
            Value -> Value
        end
    end,
    E1 = maybe_put(description, Layered(description), E0),
    E2 = maybe_put(version, Layered(version), E1),
    E3 = maybe_put(
        input_schema,
        flatten(Layered(args_schema), Layered(kwargs_schema)),
        E2
    ),
    E4 = maybe_put(
        output_schema,
        flatten(Layered(result_args_schema), Layered(result_kwargs_schema)),
        E3
    ),
    E4#{realm => RealmUri}.

%% @private
%% §16.1: kwargs-only passes through; args-only wraps under `@args`;
%% mixed merges `@args` into the kwargs properties.
flatten(undefined, undefined) ->
    undefined;
flatten(undefined, KwargsSchema) ->
    KwargsSchema;
flatten(ArgsSchema, undefined) ->
    #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{<<"@args">> => ArgsSchema},
        <<"required">> => [<<"@args">>]
    };
flatten(ArgsSchema, KwargsSchema) ->
    Props = maps:get(<<"properties">>, KwargsSchema, #{}),
    KwargsSchema#{
        <<"properties">> => Props#{<<"@args">> => ArgsSchema}
    }.

%% @private
maybe_put(_, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

%% @private
%% §17: one name, several entries. Different underlying bindings — the
%% collision an agent must never be exposed to — skips them ALL and reports;
%% identical bindings from two documents keep the first by document id.
resolve_names(Candidates) ->
    ByName = lists:foldl(
        fun(E, Acc) ->
            maps:update_with(
                maps:get(name, E), fun(L) -> [E | L] end, [E], Acc
            )
        end,
        #{},
        Candidates
    ),
    maps:fold(
        fun
            (_, [E], {Es, Cs}) ->
                {[E | Es], Cs};
            (Name, Es0, {Es, Cs}) ->
                case lists:usort([binding(E) || E <- Es0]) of
                    [_] ->
                        Sorted = lists:sort(
                            fun(A, B) -> doc_of(A) =< doc_of(B) end, Es0
                        ),
                        {[hd(Sorted) | Es], Cs};
                    Bindings ->
                        Collision = #{
                            realm => maps:get(realm, hd(Es0)),
                            name => Name,
                            bindings => Bindings
                        },
                        {Es, [Collision | Cs]}
                end
        end,
        {[], []},
        ByName
    ).

%% @private
%% The underlying WAMP binding a name resolves to — what §17's collision
%% rule compares.
binding(#{procedure := P}) -> P;
binding(#{topic := T}) -> T.

%% @private
doc_of(#{source := #{overlay := Id}}) -> Id;
doc_of(_) -> <<>>.

%% @private
with_hash(E) ->
    E#{hash => hash(E)}.
