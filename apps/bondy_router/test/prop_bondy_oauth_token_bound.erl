%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% The per-user token bound (`oauth2.refresh_token.limit`), stated through the
%% PUBLIC API only (`issue/3`, `refresh/2`, `revoke/2`, `lookup/3`,
%% `cleanup/0`) so the same properties hold the store to account before and
%% after any change to how tokens are laid out in `bondy_db`.
%%
%% Two properties, deliberately different in what they claim:
%%
%% `prop_sequential_bound_and_policy` — ONE writer. After EVERY operation the
%% user holds at most MAX tokens, a scope vanishes only when that operation
%% pushed the user over the bound (and then exactly one does), and the one
%% evicted expires no later than every survivor (ties, which the policy
%% breaks arbitrarily, are allowed — the model adopts the store's choice).
%% This bound is hard for any layout that trims on its own writes with
%% read-your-writes.
%%
%% `prop_concurrent_issues_eventually_bounded` — N > MAX CONCURRENT issues of
%% distinct scopes. After every issuer has returned and ONE enforcement pass
%% (`cleanup/0`) has run: at most MAX tokens, AND exactly min(N, MAX) — every
%% accepted token is either live or was evicted by the bound, never silently
%% lost. The second half is what a whole-set read-modify-write layout fails
%% (last writer wins); the first half is what a cell-per-token layout can only
%% promise after enforcement. Neither half is asserted mid-flight: the
%% overshoot before enforcement is reported, not asserted.
%%
%% Not covered here: the cross-node case (two nodes each issuing under MAX for
%% the same user, union over MAX) — that needs a cluster suite and pins the
%% enforcement to the periodic `cleanup/0`.
%% =============================================================================

-module(prop_bondy_oauth_token_bound).

-include_lib("proper/include/proper.hrl").
-include("bondy_security.hrl").

-define(REALM_URI, <<"com.example.test.token_bound">>).
-define(PASS, <<"aWe11KeptSecret">>).
-define(MAX, 4).

-export([prop_sequential_bound_and_policy/0]).
-export([prop_concurrent_issues_eventually_bounded/0]).

%% =============================================================================
%% GENERATORS
%% =============================================================================

%% Scopes are device ids 1..2*MAX+2 — enough distinct scopes to cross the
%% bound several times over within one sequence.
device() ->
    range(1, 2 * ?MAX + 2).

command() ->
    frequency([
        {6, {issue, device()}},
        {2, {refresh, device()}},
        {2, {revoke, device()}}
    ]).

commands() ->
    non_empty(list(command())).

%% =============================================================================
%% PROPERTIES
%% =============================================================================

prop_sequential_bound_and_policy() ->
    ?SETUP(
        fun() ->
            ok = setup(),
            fun() -> ok end
        end,
        ?FORALL(
            Cmds,
            commands(),
            begin
                User = fresh_user(),
                case run_sequence(User, Cmds, #{}) of
                    ok ->
                        true;
                    {violation, Step, Reason} ->
                        ?WHENFAIL(
                            io:format(
                                "cmds=~p~nviolated at step ~p: ~p~n",
                                [Cmds, Step, Reason]
                            ),
                            false
                        )
                end
            end
        )
    ).

prop_concurrent_issues_eventually_bounded() ->
    ?SETUP(
        fun() ->
            ok = setup(),
            fun() -> ok end
        end,
        ?FORALL(
            N,
            range(?MAX + 1, 3 * ?MAX),
            begin
                User = fresh_user(),
                Results = concurrent_issues(User, lists:seq(1, N)),
                Accepted = [T || {ok, T} <- Results],
                Before = length(live_scopes(User, lists:seq(1, N))),
                _ = bondy_oauth_token:cleanup(),
                Live = live_scopes(User, lists:seq(1, N)),
                ?WHENFAIL(
                    io:format(
                        "N=~p accepted=~p live_before_cleanup=~p live_after=~p~n",
                        [N, length(Accepted), Before, length(Live)]
                    ),
                    conjunction([
                        {all_accepted, length(Accepted) =:= N},
                        {bounded, length(Live) =< ?MAX},
                        %% Eventual bound is tight: accepted tokens are live or
                        %% evicted by the bound, never silently lost.
                        {no_silent_loss, length(Live) =:= min(N, ?MAX)}
                    ])
                )
            end
        )
    ).

%% =============================================================================
%% MODEL RUN
%% =============================================================================

%% The model is `#{Device => ExpiresAt}` for the scopes the store should hold
%% after the previous step — at most MAX of them. Every step re-derives what
%% the store actually holds (through `lookup/3`) and checks it against the
%% model:
%%
%% - `bounded`: never more than MAX live;
%% - `no_silent_loss`: a scope vanishes ONLY when this step pushed the model
%%   over the bound, and then exactly one does;
%% - `policy`: the one evicted expires no later than every survivor.
%%
%% The model then adopts the store's choice of victim, so it never has to
%% reproduce the implementation's tie-break among tokens that expire in the
%% same second — it only has to agree that the choice was lawful.
run_sequence(_User, [], _Model) ->
    ok;
run_sequence(User, [{issue, D} = Step | Rest], Model0) ->
    {ok, T} = issue_token(User, D),
    Model1 = Model0#{D => bondy_oauth_token:expires_at(T)},
    Expected = max(0, map_size(Model1) - ?MAX),
    check_then_continue(User, Step, Rest, Model1, Expected);
run_sequence(User, [{refresh, D} = Step | Rest], Model0) ->
    case bondy_oauth_token:lookup(?REALM_URI, User, scope(D)) of
        {ok, T0} ->
            RT = bondy_oauth_token:to_refresh_token(T0),
            case bondy_oauth_token:refresh(?REALM_URI, RT) of
                {ok, T} ->
                    Model1 = Model0#{D => bondy_oauth_token:expires_at(T)},
                    %% A refresh replaces in place: nothing may vanish.
                    check_then_continue(User, Step, Rest, Model1, 0);
                {error, oauth2_invalid_grant} ->
                    %% Sequentially, a token we just looked up must refresh.
                    {violation, Step, refresh_refused}
            end;
        {error, _} ->
            run_sequence(User, Rest, Model0)
    end;
run_sequence(User, [{revoke, D} = Step | Rest], Model0) ->
    case bondy_oauth_token:lookup(?REALM_URI, User, scope(D)) of
        {ok, T} ->
            RT = bondy_oauth_token:to_refresh_token(T),
            ok = bondy_oauth_token:revoke(?REALM_URI, RT),
            check_then_continue(User, Step, Rest, maps:remove(D, Model0), 0);
        {error, _} ->
            run_sequence(User, Rest, Model0)
    end.

%% @private
%% Compare the store with `Model` after `Step`; `ExpectedGone` is how many of
%% the model's scopes the bound had to evict at this step (0 or 1).
check_then_continue(User, Step, Rest, Model, ExpectedGone) ->
    Live = live_scopes(User, maps:keys(Model)),
    Gone = maps:keys(Model) -- Live,
    LiveExp = [maps:get(D, Model) || D <- Live],
    GoneExp = [maps:get(D, Model) || D <- Gone],
    Checks = [
        {bounded, length(Live) =< ?MAX},
        {no_silent_loss, length(Gone) =:= ExpectedGone},
        {policy, Gone =:= [] orelse lists:min(LiveExp) >= lists:max(GoneExp)}
    ],
    case [Name || {Name, false} <- Checks] of
        [] ->
            run_sequence(User, Rest, maps:without(Gone, Model));
        Failed ->
            {violation, Step, #{
                failed => Failed,
                model => Model,
                live => Live,
                gone => Gone
            }}
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

setup() ->
    bondy_ct:start_bondy(),
    ok = bondy_config:set([oauth2, max_tokens_per_user], ?MAX),
    case bondy_realm:lookup(?REALM_URI) of
        {ok, _} ->
            ok;
        {error, not_found} ->
            _ = bondy_realm:create(#{
                uri => ?REALM_URI,
                authmethods => [?WAMP_OAUTH2_AUTH, ?PASSWORD_AUTH],
                security_enabled => true,
                groups => [#{name => <<"g">>}],
                users => [],
                grants => [
                    #{
                        permissions => [<<"wamp.call">>],
                        uri => <<"">>,
                        match => <<"prefix">>,
                        roles => <<"all">>
                    }
                ]
            }),
            ok
    end.

%% A fresh user per test case so cases never share a token set. Random, not a
%% VM counter: the durable store outlives the VM between runs.
fresh_user() ->
    Name = <<"bound_", (base16:encode(crypto:strong_rand_bytes(8)))/binary>>,
    User = bondy_rbac_user:new(#{
        username => Name,
        password => ?PASS,
        groups => [<<"g">>]
    }),
    {ok, _} = bondy_rbac_user:add(?REALM_URI, User),
    Name.

issue_token(User, D) ->
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(
        SessionId, ?REALM_URI, User, [<<"g">>], {127, 0, 0, 1}
    ),
    bondy_oauth_token:issue(password, Ctxt, #{device_id => device_id(D)}).

concurrent_issues(User, Ds) ->
    Parent = self(),
    Pids = [
        spawn_link(fun() -> Parent ! {self(), issue_token(User, D)} end)
     || D <- Ds
    ],
    [
        receive
            {Pid, R} -> R
        after 30000 -> exit({timeout_waiting_for, Pid})
        end
     || Pid <- Pids
    ].

%% Which of `Ds` the store currently holds for `User`, through the public API.
live_scopes(User, Ds) ->
    [
        D
     || D <- Ds,
        case bondy_oauth_token:lookup(?REALM_URI, User, scope(D)) of
            {ok, _} -> true;
            {error, _} -> false
        end
    ].

scope(D) ->
    bondy_auth_scope:new(?REALM_URI, all, device_id(D)).

device_id(D) ->
    <<"device_", (integer_to_binary(D))/binary>>.
