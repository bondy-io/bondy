-module(bondy_log_recovery_test).

-include_lib("eunit/include/eunit.hrl").

%% Index entries are `{FirstKey, LastKey, ByteOffset}`. The clamp anchor
%% is the largest indexed offset at or below the target; a target below
%% every entry yields the same anchor as an empty index.
seek_byte_offset_test() ->
    Entries = [{k1, k1, 100}, {k2, k2, 300}, {k3, k3, 500}],
    ?assertEqual(300, bondy_log_recovery:seek_byte_offset(Entries, 350)),
    ?assertEqual(300, bondy_log_recovery:seek_byte_offset(Entries, 300)),
    ?assertEqual(500, bondy_log_recovery:seek_byte_offset(Entries, 9000)),
    ?assertEqual(
        bondy_log_recovery:seek_byte_offset([], 50),
        bondy_log_recovery:seek_byte_offset(Entries, 50)
    ).
