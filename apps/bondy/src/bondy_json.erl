-module(bondy_json).

-export([setup/0]).
-export([decode/1]).
-export([encode/1]).


setup() ->
    jose:json_module(?MODULE).



encode(Bin) ->
    jsone:encode(Bin, [undefined_as_null, {object_key_type, string}]).


decode(Bin) ->
    jsone:decode(Bin, [undefined_as_null]).