%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Falsifiers for `bondy_mcp_spec_parser:parse/1` — the pure overlay-document
%% validator. Each rejection case aims at one specific §17 / §16.3 rule; the
%% acceptance cases pin the normalized shape the compiler consumes.
-module(bondy_mcp_spec_parser_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% FIXTURES
%% =============================================================================

setup() ->
    %% `wamp_procedure` validation runs through `bondy_wamp_uri`, which
    %% reads the wamp app config.
    {ok, _} = application:ensure_all_started(bondy_wamp),
    ok.

parser_test_() ->
    {setup, fun setup/0, [
        fun valid_tool_document/0,
        fun valid_resource_template_document/0,
        fun document_shape_is_enforced/0,
        fun name_rules/0,
        fun kind_is_a_closed_set/0,
        fun wamp_procedure_must_be_a_valid_exact_uri/0,
        fun duplicate_names_reject_the_document/0,
        fun one_invalid_entry_rejects_the_document/0,
        fun template_consistency/0
    ]}.

%% =============================================================================
%% HELPERS
%% =============================================================================

doc(Entries) ->
    #{<<"id">> => <<"doc_1">>, <<"entries">> => Entries}.

tool() ->
    tool(#{}).

tool(Extra) ->
    maps:merge(
        #{
            <<"realm">> => <<"com.acme.app1">>,
            <<"name">> => <<"create_invoice">>,
            <<"kind">> => <<"tool">>,
            <<"wamp_procedure">> => <<"com.acme.billing.create_invoice">>
        },
        Extra
    ).

template() ->
    template(#{}).

template(Extra) ->
    maps:merge(
        #{
            <<"realm">> => <<"com.acme.app1">>,
            <<"name">> => <<"user">>,
            <<"kind">> => <<"resource_template">>,
            <<"wamp_procedure">> => <<"com.acme.users.get">>,
            <<"uri_template">> => <<"users:///{id}">>,
            <<"uri_vars_schema">> => #{
                <<"id">> => #{<<"type">> => <<"integer">>}
            },
            <<"wamp_args">> => [],
            <<"wamp_kwargs">> => #{<<"id">> => <<"{{id}}">>},
            <<"update_topic">> => <<"com.acme.users.{{id}}.changed">>,
            <<"result_kwargs_schema">> => #{<<"type">> => <<"object">>}
        },
        Extra
    ).

parse(Doc) ->
    bondy_mcp_spec_parser:parse(Doc).

%% =============================================================================
%% CASES
%% =============================================================================

valid_tool_document() ->
    Entry = tool(#{
        <<"description">> => <<"Create a draft invoice">>,
        <<"annotations">> => #{<<"destructive_hint">> => true},
        <<"wamp_options">> => #{<<"timeout">> => 60000},
        <<"kwargs_schema">> => #{<<"type">> => <<"object">>}
    }),
    {ok, #{id := <<"doc_1">>, entries := [E]}} = parse(doc([Entry])),
    ?assertMatch(
        #{
            realm := <<"com.acme.app1">>,
            name := <<"create_invoice">>,
            kind := tool,
            wamp_procedure := <<"com.acme.billing.create_invoice">>,
            description := <<"Create a draft invoice">>,
            annotations := #{<<"destructive_hint">> := true},
            wamp_options := #{<<"timeout">> := 60000},
            kwargs_schema := #{<<"type">> := <<"object">>}
        },
        E
    ),
    %% The document version rides along when present.
    ?assertMatch(
        {ok, #{version := <<"1.0">>}},
        parse((doc([tool()]))#{<<"version">> => <<"1.0">>})
    ).

valid_resource_template_document() ->
    {ok, #{entries := [E]}} = parse(doc([template()])),
    ?assertMatch(
        #{
            kind := resource_template,
            uri_template := <<"users:///{id}">>,
            uri_vars_schema := #{<<"id">> := _},
            wamp_args := [],
            wamp_kwargs := #{<<"id">> := <<"{{id}}">>},
            update_topic := <<"com.acme.users.{{id}}.changed">>
        },
        E
    ).

document_shape_is_enforced() ->
    ?assertMatch({error, {missing_required_value, <<"id">>}}, parse(#{})),
    ?assertMatch(
        {error, {missing_required_value, <<"entries">>}},
        parse(#{<<"id">> => <<"d">>})
    ),
    ?assertMatch(
        {error, {invalid_value, <<"id">>}},
        parse(#{<<"id">> => <<>>, <<"entries">> => [tool()]})
    ),
    ?assertMatch(
        {error, {invalid_value, <<"entries">>}},
        parse(#{<<"id">> => <<"d">>, <<"entries">> => []})
    ),
    ?assertMatch(
        {error, {invalid_value, {<<"version">>, 2}}},
        parse((doc([tool()]))#{<<"version">> => 2})
    ),
    ?assertMatch({error, invalid_document}, parse([])).

name_rules() ->
    Reject = fun(Name) ->
        ?assertMatch(
            {error, {invalid_name, _}},
            parse(doc([tool(#{<<"name">> => Name})]))
        )
    end,
    %% §17: 1..256 bytes, printable ASCII, no whitespace.
    Reject(<<"has space">>),
    Reject(<<"tab\there">>),
    Reject(<<"caf", 16#C3, 16#A9>>),
    %% The empty name falls to the required-value check, one step earlier.
    ?assertMatch(
        {error, {invalid_value, {<<"name">>, <<>>}}},
        parse(doc([tool(#{<<"name">> => <<>>})]))
    ),
    Reject(binary:copy(<<"x">>, 257)),
    Max = binary:copy(<<"x">>, 256),
    ?assertMatch({ok, _}, parse(doc([tool(#{<<"name">> => Max})]))).

kind_is_a_closed_set() ->
    ?assertMatch(
        {error, {invalid_kind, <<"prompt">>}},
        parse(doc([tool(#{<<"kind">> => <<"prompt">>})]))
    ).

wamp_procedure_must_be_a_valid_exact_uri() ->
    ?assertMatch(
        {error, {invalid_uri, _}},
        parse(doc([tool(#{<<"wamp_procedure">> => <<"com..broken">>})]))
    ),
    ?assertMatch(
        {error, {missing_required_value, <<"wamp_procedure">>}},
        parse(doc([maps:remove(<<"wamp_procedure">>, tool())]))
    ).

duplicate_names_reject_the_document() ->
    ?assertMatch(
        {error,
            {duplicate_names, [{<<"com.acme.app1">>, <<"create_invoice">>}]}},
        parse(
            doc([
                tool(),
                tool(#{<<"wamp_procedure">> => <<"com.acme.billing.other">>})
            ])
        )
    ),
    %% Same name in DIFFERENT realms is not a duplicate.
    ?assertMatch(
        {ok, _},
        parse(doc([tool(), tool(#{<<"realm">> => <<"com.acme.app2">>})]))
    ).

one_invalid_entry_rejects_the_document() ->
    ?assertMatch(
        {error, {invalid_name, _}},
        parse(doc([tool(), tool(#{<<"name">> => <<"bad name">>})]))
    ).

template_consistency() ->
    %% A schema for an absent variable, or a variable without a schema.
    ?assertMatch(
        {error, {uri_vars_mismatch, _}},
        parse(
            doc([
                template(#{
                    <<"uri_vars_schema">> => #{
                        <<"id">> => #{},
                        <<"extra">> => #{}
                    }
                })
            ])
        )
    ),
    ?assertMatch(
        {error, {uri_vars_mismatch, _}},
        parse(doc([template(#{<<"uri_vars_schema">> => #{}})]))
    ),
    %% A binding referencing a variable the template does not declare.
    ?assertMatch(
        {error, {unknown_template_vars, [<<"nope">>]}},
        parse(
            doc([
                template(#{
                    <<"wamp_kwargs">> => #{<<"id">> => <<"{{nope}}">>}
                })
            ])
        )
    ),
    ?assertMatch(
        {error, {unknown_template_vars, [<<"nope">>]}},
        parse(doc([template(#{<<"wamp_args">> => [<<"{{nope}}">>]})]))
    ),
    ?assertMatch(
        {error, {unknown_template_vars, [<<"nope">>]}},
        parse(
            doc([template(#{<<"update_topic">> => <<"t.{{nope}}.changed">>})])
        )
    ),
    %% Malformed templates fail rather than silently interpolate nothing.
    ?assertMatch(
        {error, {invalid_template, _}},
        parse(doc([template(#{<<"uri_template">> => <<"users:///{id">>})]))
    ),
    ?assertMatch(
        {error, {invalid_template, _}},
        parse(
            doc([
                template(#{<<"wamp_kwargs">> => #{<<"id">> => <<"{{id}">>}})
            ])
        )
    ),
    ?assertMatch(
        {error, {invalid_template_var, <<"a-b">>}},
        parse(doc([template(#{<<"uri_template">> => <<"users:///{a-b}">>})]))
    ),
    %% §16.3: every resource template declares its result shape.
    ?assertMatch(
        {error, missing_result_schema},
        parse(doc([maps:remove(<<"result_kwargs_schema">>, template())]))
    ).
