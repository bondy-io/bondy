%% =============================================================================
%%  bondy_retained_message_SUITE.erl -
%%
%%  Copyright (c) 2016-2019 Ngineo Limited. All rights reserved.
%%  Copyright (c) 2020 Leapsight Holdings Limited. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

-module(bondy_retained_message_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-compile([nowarn_export_all, export_all]).



all() ->
    [
        {group, crud}
    ].

groups() ->
    [
        {crud, [sequence], [
            put,
            prefix_match,
            wildcard_match
        ]}
    ].



init_per_suite(Config) ->
    common:start_bondy(),
    Config.

end_per_suite(Config) ->
    %% common:stop_bondy(),
    {save_config, Config}.



put(Config0) ->
    R = <<"com.leapsight.test">>,
    T = <<"com.foo.bar.1">>,
    Event = wamp_message:event(1, 1, #{}),
    ok = bondy_retained_message:put(R, T, Event, #{}),
    ?assertEqual(
        bondy_retained_message,
        element(1, bondy_retained_message:get(R, T))
    ),
    ok = bondy_retained_message:put(R, <<"com.foo.bar.1.1">>, Event, #{}),
    ok = bondy_retained_message:put(R, <<"com.foo.bar.1.2">>, Event, #{}),
    _ = [
        begin
            Topic = <<"com.foo.bar.2.", (integer_to_binary(X))/binary>>,
            bondy_retained_message:put(R, Topic, Event, #{})
        end || X <- lists:seq(1, 500)
    ],
    Config = [{realm, R}, {topic, T} | Config0],
    {save_config, Config}.


exact_match(Config) ->
    SavedConfig = element(2, ?config(saved_config, Config)),
    R = ?config(realm, SavedConfig),
    T = ?config(topic, SavedConfig),
    {Result, _} = bondy_retained_message:match(R, T, 1, <<"exact">>),
    ?assertEqual(1, length(Result)),
    {save_config, SavedConfig}.


prefix_match(Config) ->
    SavedConfig = element(2, ?config(saved_config, Config)),
    R = ?config(realm, SavedConfig),
    T = ?config(topic, SavedConfig),
    {Result, _}  = bondy_retained_message:match(R, T, 1, <<"prefix">>),
    ?assertEqual(3, length(Result)),
    {save_config, SavedConfig}.


wildcard_match(Config) ->
    SavedConfig = element(2, ?config(saved_config, Config)),
    R = ?config(realm, SavedConfig),
    {Result, _} = bondy_retained_message:match(
        R, <<"com...">>, 1, <<"wildcard">>),
    ?assertEqual(1, length(Result)),
    {L1, C1} = bondy_retained_message:match(R, <<"com....">>, 1, <<"wildcard">>),
    ?assertEqual(100, length(L1)),
    {L2, C2} = bondy_retained_message:match(C1),
    ?assertEqual(100, length(L2)),
    ?assertNotEqual(C1, C2).