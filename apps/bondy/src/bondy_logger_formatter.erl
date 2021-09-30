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

-type template() :: [metakey() | {metakey(), template(), template()} | string()].
-type metakey() :: atom() | [atom()].

%%====================================================================
%% API functions
%%====================================================================
-spec format(LogEvent, Config) -> unicode:chardata() when
      LogEvent :: logger:log_event(),
      Config :: logger:formatter_config().
format(Map = #{msg := {report, #{label := {error_logger, _}, format := Format, args := Terms}}}, UsrConfig) ->
    format(Map#{msg := {report,
                        #{unstructured_log =>
                              unicode:characters_to_binary(io_lib:format(Format, Terms))}}},
           UsrConfig);
format(#{level:=Level, msg:={report, Msg}, meta:=Meta}, UsrConfig) when is_map(Msg) ->
    Config = apply_defaults(UsrConfig),
    NewMeta = maps:merge(Meta, #{level => Level
                                ,colored_start => Level
                                ,colored_end => "\e[0m"
                                }),
    format_log(maps:get(template, Config), Config, Msg, NewMeta);
format(Map = #{msg := {report, KeyVal}}, UsrConfig) when is_list(KeyVal) ->
    format(Map#{msg := {report, maps:from_list(KeyVal)}}, UsrConfig);
format(Map = #{msg := {string, String}}, UsrConfig) ->
    format(Map#{msg := {report,
                        #{unstructured_log =>
                          unicode:characters_to_binary(String)}}}, UsrConfig);
format(Map = #{msg := {Format, Terms}}, UsrConfig) ->
    format(Map#{msg := {report,
                        #{unstructured_log =>
                          unicode:characters_to_binary(io_lib:format(Format, Terms))}}},
           UsrConfig).

%%====================================================================
%% Internal functions
%%====================================================================
apply_defaults(Map) ->
    maps:merge(
      #{term_depth => undefined,
        map_depth => -1,
        time_offset => 0,
        time_designator => $T,
        colored => false,
        colored_debug =>     "\e[0;38m",
        colored_info =>      "\e[1;37m",
        colored_notice =>    "\e[1;36m",
        colored_warning =>   "\e[1;33m",
        colored_error =>     "\e[1;31m",
        colored_critical =>  "\e[1;35m",
        colored_alert =>     "\e[1;44m",
        colored_emergency => "\e[1;41m",
        template => [colored_start, "when=", time, " level=", level,
                     {id, [" id=", id], ""}, {parent_id, [" parent_id=", parent_id], ""},
                     {correlation_id, [" correlation_id=", correlation_id], ""},
                     {pid, [" pid=", pid], ""}, " at=", mfa, ":", line, colored_end, " ", msg, "\n"]
       },
      Map
    ).


-spec format_log(template(), Config, Msg, Meta) -> unicode:chardata() when
      Config :: logger:formatter_config(),
      Msg :: Data,
      Meta :: Data,
      Data :: #{string() | binary() | atom() => term()}.
format_log(Tpl, Config, Msg, Meta) -> format_log(Tpl, Config, Msg, Meta, []).

format_log([], _Config, _Msg, _Meta, Acc) ->
    lists:reverse(Acc);

format_log([msg | Rest], Config, Msg, Meta, Acc) ->
    format_log(Rest, Config, Msg, Meta, [format_msg(Msg, Config) | Acc]);

format_log([{msg, Key} | Rest], Config, Msg, Meta, Acc) when is_atom(Key) ->
    case maps:take(Key, Msg) of
        error ->
            format_log(Rest, Config, Msg, Meta, Acc);
        {Val, NewMsg} ->
            format_log(Rest, Config, NewMsg, Meta, [format_val(Key, Val, Config) | Acc])
    end;

format_log([Key | Rest], Config, Msg, Meta, Acc) when is_atom(Key)
                                                 orelse is_atom(hd(Key)) -> % from OTP
    case maps:find(Key, Meta) of
        error ->
            format_log(Rest, Config, Msg, Meta, Acc);
        {ok, Val} ->
            format_log(Rest, Config, Msg, Meta, [format_val(Key, Val, Config) | Acc])
    end;

format_log([{{msg, Key}, IfExists, Else} | Rest], Config, Msg, Meta, Acc)
when is_atom(Key) ->
    case maps:take(Key, Msg) of
        error ->
            format_log(Rest, Config, Msg, Meta, [Else | Acc]);
        {Val, NewMsg} ->
            format_log(Rest, Config, NewMsg, Meta,
                       [format_log(IfExists, Config, NewMsg, #{Key => Val}, []) | Acc])
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

format_msg(Data, Config) -> format_msg("", Data, Config).

format_msg(Parents, Data, Config=#{map_depth := 0}) when is_map(Data) ->
    to_string(truncate_key(Parents), Config)++"=... ";
format_msg(Parents, Data, Config = #{map_depth := Depth}) when is_map(Data) ->
    maps:fold(
      fun(K, V, Acc) when is_map(V) ->
        [format_msg(Parents ++ to_string(K, Config) ++ "_",
                    V,
                    Config#{map_depth := Depth-1}) | Acc]
      ;  (K, V, Acc) ->
        [Parents ++ to_string(K, Config), $=,
         to_string(V, Config), $\s | Acc]
      end,
      [],
      Data
    ).


format_val(time, Time, Config) ->
    format_time(Time, Config);
format_val(mfa, MFA, Config) ->
    escape(format_mfa(MFA, Config));
format_val(colored_end, _EOC, #{colored := false}) -> "";
format_val(colored_end, EOC,  #{colored := true}) -> EOC;
format_val(colored_start, _Level,    #{colored := false}) -> "";
format_val(colored_start, debug,     #{colored := true, colored_debug     := BOC}) -> BOC;
format_val(colored_start, info,      #{colored := true, colored_info      := BOC}) -> BOC;
format_val(colored_start, notice,    #{colored := true, colored_notice    := BOC}) -> BOC;
format_val(colored_start, warning,   #{colored := true, colored_warning   := BOC}) -> BOC;
format_val(colored_start, error,     #{colored := true, colored_error     := BOC}) -> BOC;
format_val(colored_start, critical,  #{colored := true, colored_critical  := BOC}) -> BOC;
format_val(colored_start, alert,     #{colored := true, colored_alert     := BOC}) -> BOC;
format_val(colored_start, emergency, #{colored := true, colored_emergency := BOC}) -> BOC;
format_val(_Key, Val, Config) ->
    to_string(Val, Config).


format_time(N, #{time_offset := O, time_designator := D}) when is_integer(N) ->
    calendar:system_time_to_rfc3339(N, [{unit, microsecond},
                                        {offset, O},
                                        {time_designator, D}]).

format_mfa({M, F, A}, _) when is_atom(M), is_atom(F), is_integer(A) ->
   [atom_to_list(M), $:, atom_to_list(F), $/, integer_to_list(A)];
format_mfa({M, F, A}, Config) when is_atom(M), is_atom(F), is_list(A) ->
    %% arguments are passed as a literal list ({mod, fun, [a, b, c]})
    format_mfa({M, F, length(A)}, Config);
format_mfa(MFAStr, Config) -> % passing in a pre-formatted string value
    to_string(MFAStr,Config).

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

format_str(#{term_depth := undefined}, T) ->
    io_lib:format("~0tp", [T]);
format_str(#{term_depth := D}, T) ->
    io_lib:format("~0tP", [T, D]).

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

needs_quoting(Str) ->
    string:find(Str, " ") =/= nomatch orelse
    string:find(Str, "=") =/= nomatch.

needs_escape(Str) ->
    string:find(Str, "\"") =/= nomatch orelse
    string:find(Str, "\\") =/= nomatch orelse
    string:find(Str, "\n") =/= nomatch.

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

truncate_key([]) -> [];
truncate_key("_") -> "";
truncate_key([H|T]) -> [H | truncate_key(T)].