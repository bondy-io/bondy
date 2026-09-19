%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_logger_formatter_test).
-moduledoc """
The formatter renders text as text whatever the VM's `+pc` range is.

A structured report's `description` is prose, and the prose in this codebase
uses characters outside Latin-1 (the em dash, U+2014, above all). Under the
VM's default `+pc latin1` such a string is not `io_lib:printable_list/1`, and
a formatter that relied on that predicate printed it through the depth-limited
term printer: the operator read `[82,101,99,108,97,...|...]` where the text
told them which cluster member to revive. Six production log sites carry such
a character today; the customer logs of 2026-09-17 show every stall warning
of `bondy_oplog_gc_scheduler` rendered that way.

These cases run under whatever range `rebar3 eunit` starts the VM with — the
default, `latin1` — and that is the only range under which they can fail: a
VM started with `+pc unicode` passes them with the old predicate too. Each
case names the range it ran under on failure.
""".

-include_lib("eunit/include/eunit.hrl").

-define(EM_DASH, "\x{2014}").

%% The description `bondy_oplog_gc_scheduler:maybe_log_stall/3` logs,
%% shortened, with its em dash.
-define(STALL,
    "Reclamation stalled " ?EM_DASH " a stalled member never ages out"
).

non_latin1_charlist_renders_as_text_test() ->
    Out = render(#{description => ?STALL}),
    ?assertEqual(
        quoted(?STALL),
        Out,
        #{printable_range => io:printable_range()}
    ).

non_latin1_binary_renders_as_text_test() ->
    Out = render(#{description => unicode:characters_to_binary(?STALL)}),
    ?assertEqual(
        quoted(?STALL),
        Out,
        #{printable_range => io:printable_range()}
    ).

%% Not covered by the two cases above and asserted here: recognising Unicode
%% text must not turn a list that is NOT text into one.
integer_list_is_not_text_test() ->
    ?assertEqual(<<"[1,2,3]">>, render(#{description => [1, 2, 3]})).

latin1_charlist_still_renders_as_text_test() ->
    ?assertEqual(
        quoted("GC worker exited abnormally"),
        render(#{description => "GC worker exited abnormally"})
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% What the operator sees for the `description` of `Report`, as UTF-8 — the
%% same encoding the OTP handler applies to the formatter's chardata
%% (`logger_h_common:string_to_binary/1`, OTP 29). The template is the one
%% the shipped `logger.schema` builds for `description`: a `{msg, Key}`
%% conditional.
render(Report) ->
    Config = #{
        template => [{{msg, description}, [description], []}],
        map_depth => 3,
        term_depth => 50,
        colored => false
    },
    Event = #{level => warning, msg => {report, Report}, meta => #{}},
    unicode:characters_to_binary(bondy_logger_formatter:format(Event, Config)).

%% @private
%% A value with spaces is quoted by the formatter.
quoted(Str) ->
    unicode:characters_to_binary([$", Str, $"]).
