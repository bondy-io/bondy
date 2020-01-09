%% From https://github.com/ferd/flatlog
%% https://ferd.ca/erlang-otp-21-s-new-logger.html

%%% @doc
%%% This is the main module that exposes custom formatting to the OTP
%%% logger library (part of the `kernel' application since OTP-21).
%%%
%%% The module honors the standard configuration of the kernel's default
%%% logger formatter regarding: max depth, templates.
%%% @end
-module(bondy_logger_formatter).

%% API exports
-export([format/2]).

-ifdef(TEST).
-export([format_msg/2, to_string/2]).
-endif.

-type template() :: [
    metakey() | {metakey(), template(), template()} | string()
].
-type metakey() :: atom() | [atom()].




%% =============================================================================
%% API
%% =============================================================================



-spec format(LogEvent, Config) -> unicode:chardata() when
      LogEvent :: logger:log_event(),
      Config :: logger:formatter_config().

format(#{level := Level, meta := Meta, msg := {report, Msg}}, UsrConfig)
when is_map(Msg) ->
    Config = apply_defaults(UsrConfig),
    NewMeta = maps:put(level, Level, Meta),
    format_log(maps:get(template, Config), Config, Msg, NewMeta);

format(#{msg := {report, KeyVal}} = Map, UsrConfig) when is_list(KeyVal) ->
    format(Map#{msg := {report, maps:from_list(KeyVal)}}, UsrConfig);

format(#{msg := {string, String}} = Map, UsrConfig) ->
    Msg = #{message => unicode:characters_to_binary(String)},
    format(Map#{msg := {report, Msg}}, UsrConfig);

format(Map = #{msg := {Format, Terms}}, UsrConfig) ->
    String = unicode:characters_to_binary(io_lib:format(Format, Terms)),
    format(Map#{msg := {report, String}}, UsrConfig).




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
apply_defaults(Map) ->
    maps:merge(
      #{
            term_depth => undefined,
            map_depth => -1,
            %% time_offset => 0,
            %% time_designator => $T,
            time_offset => "Z",
            time_designator => $\s,
            template => [
                time, " [", level, "] ",
                "[", {pid, [pid], " "}, " ", mfa, ":", line, "]",
                {id, [" id=", id], ""},
                {parent_id, [" parent_id=", parent_id], ""},
                {correlation_id, [" correlation_id=", correlation_id], ""},
                " ", msg, "\n"
            ]
       },
      Map
    ).


%% @private
-spec format_log(template(), Config, Msg, Meta) -> unicode:chardata() when
      Config :: logger:formatter_config(),
      Msg :: Data,
      Meta :: Data,
      Data :: #{string() | binary() | atom() => term()}.

format_log(Tpl, Config, Msg, Meta) ->
    format_log(Tpl, Config, Msg, Meta, []).


format_log([], _Config, _Msg, _Meta, Acc) ->
    lists:reverse(Acc);

format_log([msg | Rest], Config, Msg, Meta, Acc) ->
    format_log(Rest, Config, Msg, Meta, [format_msg(Msg, Config) | Acc]);

format_log([Key | Rest], Config, Msg, Meta, Acc)
when is_atom(Key) orelse is_atom(hd(Key)) -> % from OTP
    case maps:find(Key, Meta) of
        error ->
            format_log(Rest, Config, Msg, Meta, Acc);
        {ok, Val} ->
            format_log(
                Rest, Config, Msg, Meta, [format_val(Key, Val, Config) | Acc])
    end;

format_log([{Key, IfExists, Else} | Rest], Config, Msg, Meta, Acc) ->
    case maps:find(Key, Meta) of
        error ->
            format_log(Rest, Config, Msg, Meta, [Else | Acc]);
        {ok, Val} ->
            format_log(Rest, Config, Msg, Meta,
                       [format_log(IfExists, Config, Msg, #{Key => Val}, []) | Acc])
    end;
format_log([Term | Rest], Config, Msg, Meta, Acc) when is_list(Term) ->
    format_log(Rest, Config, Msg, Meta, [Term | Acc]).


%% @private
format_msg(Data0, Config) ->
    %% message is a special key in our formatter that goes at the beginning of
    %% the remaining content followed by $;
    {Message, Data} = case maps:take(message, Data0) of
        {Value0, Data1} ->
            Value1 = io_lib:format("~s", [unicode:characters_to_list(Value0)]),
            {Value1, Data1};
        error ->
            {undefined, Data0}
    end,

    case format_msg("", Data, Config) of
        [] ->
            [Message];
        IOList when Message =/= undefined->
            [Message, $;, $\s | IOList];
        IOList ->
            IOList
    end.


format_msg(Parents, Data, #{map_depth := 0} = Config) when is_map(Data) ->
    to_string(truncate_key(Parents), Config) ++ "=... ";

format_msg(Parents, Data, #{map_depth := Depth} = Config) when is_map(Data) ->
    maps:fold(fun
        (K, V, Acc) when is_map(V) ->
            Formatted = format_msg(
                Parents ++ to_string(K, Config) ++ "_",
                V,
                Config#{map_depth := Depth-1}
            ),
            [Formatted | Acc];
        (K, V, Acc) ->
            [
                Parents ++ to_string(K, Config), $=,
                to_string(V, Config), $\s
                | Acc
            ]
      end,
      [],
      Data
    ).


%% @private
format_val(time, Time, Config) ->
    format_time(Time, Config);

format_val(mfa, MFA, Config) ->
    escape(format_mfa(MFA, Config));

format_val(_Key, Val, Config) ->
    to_string(Val, Config).



%% @private
format_time(N, #{time_offset := O, time_designator := D})
when is_integer(N) ->
    Millis = erlang:convert_time_unit(N, microsecond, millisecond),
    Opts = [
        {unit, millisecond},
        {offset, O},
        {time_designator, D}
    ],
    calendar:system_time_to_rfc3339(Millis, Opts).


%% @private
format_mfa({M, F, A}, _) when is_atom(M), is_atom(F), is_integer(A) ->
   [atom_to_list(M), $:, atom_to_list(F), $/, integer_to_list(A)];

format_mfa({M, F, A}, Config) when is_atom(M), is_atom(F), is_list(A) ->
    %% arguments are passed as a literal list ({mod, fun, [a, b, c]})
    format_mfa({M, F, length(A)}, Config);

format_mfa(MFAStr, Config) -> % passing in a pre-formatted string value
    to_string(MFAStr, Config).


%% @private
to_string(X, _) when is_atom(X) ->
    escape(atom_to_list(X));

to_string(X, _) when is_integer(X) ->
    integer_to_list(X);

to_string(X, _) when is_pid(X) ->
    pid_to_list(X);

to_string(X, _) when is_reference(X) ->
    ref_to_list(X);

to_string(X, C) when is_binary(X) ->
    case unicode:characters_to_list(X) of
        {_, _, _} -> % error or incomplete
            escape(format_str(C, X));
        List ->
            case io_lib:printable_list(List) of
                true -> escape(List);
                _ -> escape(format_str(C, X))
            end
    end;

to_string(X, C) when is_list(X) ->
    case io_lib:printable_list(X) of
        true -> escape(X);
        _ -> escape(format_str(C, X))
    end;

to_string(X, C) ->
    escape(format_str(C, X)).


%% @private
format_str(#{term_depth := undefined}, T) ->
    io_lib:format("~0tp", [T]);

format_str(#{term_depth := D}, T) ->
    io_lib:format("~0tP", [T, D]).



%% @private
escape(Str) ->
    case needs_escape(Str) of
        false ->
            case needs_quoting(Str) of
                true -> [$", Str, $"];
                false -> Str
            end;
        true ->
            [$", do_escape(Str), $"]
    end.


%% @private
needs_quoting(Str) ->
    string:find(Str, " ") =/= nomatch orelse
    string:find(Str, "=") =/= nomatch.


%% @private
needs_escape(Str) ->
    string:find(Str, "\"") =/= nomatch orelse
    string:find(Str, "\\") =/= nomatch orelse
    string:find(Str, "\n") =/= nomatch.


%% @private
do_escape([]) ->
    [];

do_escape(Str) ->
    case string:next_grapheme(Str) of
        [$\n | Rest] -> [$\\, $\n | do_escape(Rest)];
        ["\r\n" | Rest] -> [$\\, $\r, $\\, $\n | do_escape(Rest)];
        [$" | Rest] -> [$\\, $" | do_escape(Rest)];
        [$\\ | Rest] -> [$\\, $\\ | do_escape(Rest)];
        [Grapheme | Rest] -> [Grapheme | do_escape(Rest)]
    end.


%% @private
truncate_key([]) -> [];
truncate_key("_") -> "";
truncate_key([H|T]) -> [H | truncate_key(T)].
