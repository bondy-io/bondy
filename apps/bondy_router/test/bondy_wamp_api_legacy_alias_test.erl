%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% `bondy_wamp_api:resolve/1` rewrites a legacy procedure URI to its current
%% name before dispatch. A mapping whose TARGET has no handler is worse than no
%% mapping at all: the call reaches the target API's catch-all and is answered
%% `wamp.error.no_such_procedure`, which is true of the resolved URI and false
%% of the one the caller sent — so the caller is told their own procedure does
%% not exist when the real answer is that it was withdrawn.
%%
%% Four oauth2 aliases resolve to procedures never implemented on this line
%% (`bondy.oauth2.{client,resource_owner}.{get,list}`: declared in
%% `bondy_uris.hrl`, absent from `bondy_admin_api.json`, and named by nothing
%% else in the tree). They answer `bondy.error.deprecated_procedure` instead.
%%
%% The set is DECLARED here rather than scanned out of `resolve/1`: a scanner
%% over the same clauses agrees with them by construction, including when both
%% are wrong.
-module(bondy_wamp_api_legacy_alias_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(DEPRECATED, ~"bondy.error.deprecated_procedure").
-define(NO_SUCH, ~"wamp.error.no_such_procedure").

withdrawn_aliases() ->
    [
        {~"bondy.api_gateway.fetch_client", ~"bondy.oauth2.client.get"},
        {~"bondy.api_gateway.list_clients", ~"bondy.oauth2.client.list"},
        {
            ~"bondy.api_gateway.fetch_resource_owner",
            ~"bondy.oauth2.resource_owner.get"
        },
        {
            ~"bondy.api_gateway.list_resource_owners",
            ~"bondy.oauth2.resource_owners.list"
        }
    ].

withdrawn_alias_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_wamp),
            ok
        end,
        fun(_) -> ok end, [
            {"each alias still resolves to its withdrawn target",
                fun each_alias_still_resolves/0},
            {"deprecated, not no_such_procedure",
                fun answers_deprecated_not_no_such/0},
            {"the error names the alias, not the target",
                fun names_the_alias/0},
            {"a live alias is unaffected", fun live_alias_unaffected/0}
        ]}.

%% The mapping itself still holds — this is what makes the next case a
%% statement about the HANDLER rather than about a mapping that quietly went
%% away.
each_alias_still_resolves() ->
    _ = [
        ?assertEqual(Target, bondy_wamp_api:resolve(Alias))
     || {Alias, Target} <- withdrawn_aliases()
    ].

%% The falsifier for the four `bondy_oauth2_api` clauses: delete any one and
%% its alias falls to that module's catch-all and answers ?NO_SUCH.
answers_deprecated_not_no_such() ->
    _ = [
        begin
            {reply, #error{} = E} = call(Alias),
            ?assertNotEqual(?NO_SUCH, E#error.error_uri),
            ?assertEqual(?DEPRECATED, E#error.error_uri)
        end
     || {Alias, _} <- withdrawn_aliases()
    ].

%% The answer must carry the URI the CALLER sent. Reporting the resolved name
%% would send an operator looking for a procedure they never called.
names_the_alias() ->
    _ = [
        ?assert(mentions(Alias, call(Alias)))
     || {Alias, _} <- withdrawn_aliases()
    ].

%% An alias whose target IS implemented must be untouched — the clauses above
%% must not have been written so broadly that a live procedure reports itself
%% withdrawn. `client.add` reaches argument validation and fails there; that it
%% RAISES rather than replying is incidental to this case, so the assertion is
%% only that the outcome is not the deprecation error.
live_alias_unaffected() ->
    Got =
        try call(~"bondy.api_gateway.add_client") of
            {reply, #error{error_uri = Uri}} -> Uri;
            Other -> Other
        catch
            _:_ -> raised
        end,
    ?assertNotEqual(?DEPRECATED, Got).

%% @private
%% The URI may travel in `details`, `kwargs` or `args` depending on how the
%% error is rendered, and this case is about WHICH URI is reported, not where.
mentions(Uri, {reply, #error{details = D, kwargs = K, args = A}}) ->
    Rendered = iolist_to_binary(io_lib:format("~0tp", [{D, K, A}])),
    binary:match(Rendered, Uri) =/= nomatch.

%% @private
%% `handle_call/2` resolves, checks `dry_run`, then dispatches; it reads
%% nothing else from the context, and none of the clauses under test read it
%% either, so `undefined` is enough and keeps the case free of a realm fixture.
call(Uri) ->
    M = #call{
        request_id = 1,
        options = #{},
        procedure_uri = Uri,
        args = [],
        kwargs = #{}
    },
    bondy_wamp_api:handle_call(M, undefined).
