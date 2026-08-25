%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mcp_spec_parser).

-moduledoc """
Validator for MCP overlay documents (design §18.4) — the operator-authored
layer that names WAMP procedures for MCP, carries what has no WAMP meaning
(the MCP `name`, annotations, `wamp_options`) and declares resource
templates.

`parse/1` is PURE: it validates one document as a whole — the first invalid
entry rejects the document — and returns the entries in a normalized,
atom-keyed form. It does not touch storage and does not check the world
(realm existence, cross-document name ownership); those checks belong to
`bondy_mcp_gateway:load/1`, which runs them against the store at load time.

Validated here, per entry:

- `name` — the §17 rules: 1..256 bytes, printable ASCII, no whitespace.
- `kind` — the closed set `tool` | `resource_template`.
- `wamp_procedure` — a valid exact-match WAMP URI.
- For a `resource_template` (§16.3): the RFC 6570 `uri_template`'s variable
  set must equal `uri_vars_schema`'s key set; every `{{var}}` reference in
  `wamp_args` / `wamp_kwargs` / `update_topic` must be a template variable;
  and the entry must declare `result_args_schema` and/or
  `result_kwargs_schema`.
- Two entries claiming one `(realm, name)` reject the document (§17).
""".

-type kind() :: tool | resource_template.
-type entry() :: #{
    realm := binary(),
    name := binary(),
    kind := kind(),
    wamp_procedure := binary(),
    description => binary(),
    annotations => map(),
    wamp_options => map(),
    args_schema => map(),
    kwargs_schema => map(),
    result_args_schema => map(),
    result_kwargs_schema => map(),
    version => binary(),
    %% resource_template only
    uri_template => binary(),
    uri_vars_schema => map(),
    wamp_args => list(),
    wamp_kwargs => map(),
    update_topic => binary()
}.
-type document() :: #{
    id := binary(),
    version => binary(),
    entries := [entry()]
}.

-export_type([document/0]).
-export_type([entry/0]).

-export([parse/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Validates `Map` — a decoded §18.4 overlay document — as a whole and returns
its normalized form, or `{error, Reason}` naming the first violation.
""".
-spec parse(map()) -> {ok, document()} | {error, any()}.

parse(#{<<"id">> := Id, <<"entries">> := Entries} = Map) when
    is_binary(Id), Id =/= <<>>, is_list(Entries), Entries =/= []
->
    try
        Parsed = [entry(E) || E <- Entries],
        ok = assert_unique_names(Parsed),
        Doc0 = #{id => Id, entries => Parsed},
        {ok, with_version(Doc0, Map)}
    catch
        throw:Reason -> {error, Reason}
    end;
parse(#{<<"id">> := Id}) when not is_binary(Id) orelse Id == <<>> ->
    {error, {invalid_value, <<"id">>}};
parse(#{<<"id">> := _, <<"entries">> := Entries}) when
    not is_list(Entries) orelse Entries == []
->
    %% A document declaring nothing is not a load; removal is `delete/1`.
    {error, {invalid_value, <<"entries">>}};
parse(Map) when is_map(Map) ->
    Missing =
        case maps:is_key(<<"id">>, Map) of
            true -> <<"entries">>;
            false -> <<"id">>
        end,
    {error, {missing_required_value, Missing}};
parse(_) ->
    {error, invalid_document}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
with_version(Doc, Map) ->
    case maps:get(<<"version">>, Map, undefined) of
        undefined -> Doc;
        V when is_binary(V) -> Doc#{version => V};
        Other -> throw({invalid_value, {<<"version">>, Other}})
    end.

%% @private
entry(Data) when is_map(Data) ->
    Realm = required_binary(<<"realm">>, Data),
    Name = name(required_binary(<<"name">>, Data)),
    Kind = kind(required_binary(<<"kind">>, Data)),
    Procedure = procedure_uri(required_binary(<<"wamp_procedure">>, Data)),
    E0 = #{
        realm => Realm,
        name => Name,
        kind => Kind,
        wamp_procedure => Procedure
    },
    E1 = optional_fields(E0, Data),
    case Kind of
        tool -> E1;
        resource_template -> template_fields(E1, Data)
    end;
entry(Data) ->
    throw({invalid_entry, Data}).

%% @private
optional_fields(E, Data) ->
    Fields = [
        {<<"description">>, description, fun is_binary/1},
        {<<"annotations">>, annotations, fun is_map/1},
        {<<"wamp_options">>, wamp_options, fun is_map/1},
        {<<"args_schema">>, args_schema, fun is_map/1},
        {<<"kwargs_schema">>, kwargs_schema, fun is_map/1},
        {<<"result_args_schema">>, result_args_schema, fun is_map/1},
        {<<"result_kwargs_schema">>, result_kwargs_schema, fun is_map/1},
        {<<"version">>, version, fun is_binary/1}
    ],
    lists:foldl(
        fun({BinKey, AtomKey, Valid}, Acc) ->
            case maps:get(BinKey, Data, undefined) of
                undefined ->
                    Acc;
                Value ->
                    Valid(Value) orelse
                        throw({invalid_value, {BinKey, Value}}),
                    Acc#{AtomKey => Value}
            end
        end,
        E,
        Fields
    ).

%% @private
%% The §16.3 resource-template consistency checks.
template_fields(E0, Data) ->
    UriTemplate = required_binary(<<"uri_template">>, Data),
    Vars = uri_template_vars(UriTemplate),
    VarsSchema = maps:get(<<"uri_vars_schema">>, Data, #{}),
    is_map(VarsSchema) orelse
        throw({invalid_value, {<<"uri_vars_schema">>, VarsSchema}}),
    lists:foreach(
        fun
            ({K, V}) when is_binary(K), is_map(V) -> ok;
            (KV) -> throw({invalid_value, {<<"uri_vars_schema">>, KV}})
        end,
        maps:to_list(VarsSchema)
    ),
    %% The template's variable set and the declared schemas must coincide:
    %% a schema for an absent variable is dead, a variable without a schema
    %% is unvalidated input at the gateway edge.
    Declared = lists:sort(maps:keys(VarsSchema)),
    Declared == Vars orelse
        throw({uri_vars_mismatch, #{template => Vars, declared => Declared}}),

    Args = maps:get(<<"wamp_args">>, Data, []),
    is_list(Args) orelse throw({invalid_value, {<<"wamp_args">>, Args}}),
    Kwargs = maps:get(<<"wamp_kwargs">>, Data, #{}),
    is_map(Kwargs) orelse throw({invalid_value, {<<"wamp_kwargs">>, Kwargs}}),
    E1 = E0#{
        uri_template => UriTemplate,
        uri_vars_schema => VarsSchema,
        wamp_args => Args,
        wamp_kwargs => Kwargs
    },
    E2 =
        case maps:get(<<"update_topic">>, Data, undefined) of
            undefined ->
                E1;
            Topic when is_binary(Topic), Topic =/= <<>> ->
                E1#{update_topic => Topic};
            Topic ->
                throw({invalid_value, {<<"update_topic">>, Topic}})
        end,

    %% Every {{var}} reference in the bindings must be a template variable.
    Refs = lists:usort(
        lists:flatmap(fun binding_refs/1, Args) ++
            lists:flatmap(fun binding_refs/1, maps:values(Kwargs)) ++
            binding_refs(maps:get(update_topic, E2, <<>>))
    ),
    case Refs -- Vars of
        [] -> ok;
        Unknown -> throw({unknown_template_vars, Unknown})
    end,

    %% §16.3: every resource template declares its result shape.
    (maps:is_key(result_args_schema, E2) orelse
        maps:is_key(result_kwargs_schema, E2)) orelse
        throw(missing_result_schema),
    E2.

%% @private
assert_unique_names(Entries) ->
    Keys = [{maps:get(realm, E), maps:get(name, E)} || E <- Entries],
    case Keys -- lists:usort(Keys) of
        [] -> ok;
        Dups -> throw({duplicate_names, lists:usort(Dups)})
    end.

%% @private
required_binary(Key, Data) ->
    case maps:get(Key, Data, undefined) of
        V when is_binary(V), V =/= <<>> -> V;
        undefined -> throw({missing_required_value, Key});
        V -> throw({invalid_value, {Key, V}})
    end.

%% @private
%% §17: 1..256 bytes, printable ASCII, no whitespace. Case-sensitive as-is.
name(Name) when byte_size(Name) >= 1, byte_size(Name) =< 256 ->
    Printable = lists:all(
        fun(C) -> C >= 33 andalso C =< 126 end,
        binary_to_list(Name)
    ),
    Printable orelse throw({invalid_name, Name}),
    Name;
name(Name) ->
    throw({invalid_name, Name}).

%% @private
kind(<<"tool">>) -> tool;
kind(<<"resource_template">>) -> resource_template;
kind(Kind) -> throw({invalid_kind, Kind}).

%% @private
procedure_uri(Uri) ->
    bondy_wamp_uri:is_valid(Uri, <<"exact">>) orelse
        throw({invalid_uri, Uri}),
    Uri.

%% @private
%% The variable names of an RFC 6570 level-1 template (`{var}`), sorted.
%% Unbalanced braces or an empty / non-alphanumeric variable name reject the
%% template; nesting cannot arise because a `{` inside an expression is
%% itself an invalid variable character.
uri_template_vars(Template) ->
    lists:sort(template_vars(Template, <<"{">>, <<"}">>, [])).

%% @private
%% The `{{var}}` references inside one binding value (§16.3). Non-binary
%% values (a JSON number, a nested literal) carry no references.
binding_refs(Value) when is_binary(Value) ->
    template_vars(Value, <<"{{">>, <<"}}">>, []);
binding_refs(_) ->
    [].

%% @private
%% Scans `Bin` for `Open Var Close` occurrences, validating each variable
%% name. `Open` of `{` (URI templates) treats a dangling or empty expression
%% as an error; the `{{` form does too, so a typo like `{{id}` fails the
%% load instead of silently interpolating nothing.
template_vars(Bin, Open, Close, Acc) ->
    case binary:split(Bin, Open) of
        [_] ->
            lists:reverse(Acc);
        [_, Rest] ->
            case binary:split(Rest, Close) of
                [Var, Tail] ->
                    ok = validate_var(Var),
                    template_vars(Tail, Open, Close, [Var | Acc]);
                [_] ->
                    throw({invalid_template, Bin})
            end
    end.

%% @private
validate_var(Var) when byte_size(Var) >= 1 ->
    Valid = lists:all(
        fun(C) ->
            (C >= $a andalso C =< $z) orelse
                (C >= $A andalso C =< $Z) orelse
                (C >= $0 andalso C =< $9) orelse
                C == $_
        end,
        binary_to_list(Var)
    ),
    Valid orelse throw({invalid_template_var, Var}),
    ok;
validate_var(Var) ->
    throw({invalid_template_var, Var}).
