%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_task_api).

-moduledoc """
The WAMP read API over `bondy_task_catalogue`: `bondy.task.catalogue` and
`bondy.task.describe`.

Master realm only, like the alarm API and for the same reason (design D4): the
catalogue names procedures that act on the node and the cluster, and the
vocabularies it publishes are what an agent's policy is written against.

Both procedures are READ-ONLY. Nothing here runs a task — the caller invokes
the task's own `id`, which goes through the ordinary dealer authorization
(`wamp.call` on that URI). That separation is the point: this API tells an
agent what is sanctioned; RBAC decides what it may actually do.

`catalogue` returns the vocabularies alongside the entries. An agent policy is
a bound on `impact`, so it needs the ORDER of that vocabulary, not just the
values it happens to see in today's rows — a catalogue that never lists a
`destructive` task must not make `destructive` unknown.
""".

-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

-export([handle_call/3]).

%% Rendering is exported for the eunit module, which pins the encodability
%% contract without standing up a session.
-export([render/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()
) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}.

handle_call(?BONDY_TASK_CATALOGUE, #call{} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 0),
    {reply, result(M, [catalogue()])};
handle_call(?BONDY_TASK_DESCRIBE, #call{} = M, Ctxt) ->
    [Uri] = bondy_wamp_api_utils:admin_call_args(M, Ctxt, 1),
    %% A miss is an empty `tasks` list rather than an error: "is this procedure
    %% a sanctioned task?" is a normal question with a normal negative answer,
    %% and the answer is NOT "no such procedure" — an uncatalogued procedure
    %% may exist and simply not be a task. Making it an error would put that
    %% question on an agent's exception path.
    {reply, result(M, [#{~"tasks" => tasks_for(Uri)}])};
handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.

-doc """
A catalogue entry as a WAMP-encodable map.
""".
-spec render(bondy_task_catalogue:entry()) -> map().

render(Entry) ->
    maps:fold(fun(K, V, Acc) -> Acc#{key(K) => encodable(V)} end, #{}, Entry).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
catalogue() ->
    #{
        ~"tasks" => [render(E) || E <- bondy_task_catalogue:list()],
        ~"vocabularies" => #{
            ~"impact" => [
                atom_to_binary(I, utf8)
             || I <- bondy_task_catalogue:impacts()
            ],
            ~"blast_radius" => [
                atom_to_binary(B, utf8)
             || B <- bondy_task_catalogue:blast_radii()
            ]
        },
        ~"out_of_scope" => bondy_task_catalogue:out_of_scope()
    }.

%% @private
tasks_for(Uri) when is_binary(Uri) ->
    case bondy_task_catalogue:lookup(Uri) of
        {ok, Entry} -> [render(Entry)];
        error -> []
    end;
tasks_for(_) ->
    [].

%% @private
result(#call{request_id = ReqId}, Args) ->
    bondy_wamp_message:result(ReqId, #{}, Args).

%% @private
key(K) when is_atom(K) -> atom_to_binary(K, utf8);
key(K) when is_binary(K) -> K.

%% @private
%% The catalogue is a literal table in this build, so every value is already
%% encodable. This is here so that stays true by construction rather than by
%% inspection: a value shape nobody anticipated renders rather than raising in
%% the encoder and killing the session of whoever asked what they may do.
encodable(V) when is_binary(V) -> V;
encodable(V) when is_boolean(V) -> V;
encodable(V) when is_number(V) -> V;
encodable(V) when is_atom(V) -> atom_to_binary(V, utf8);
encodable(V) when is_list(V) -> [encodable(E) || E <- V];
encodable(V) when is_map(V) ->
    maps:fold(fun(K, X, Acc) -> Acc#{key(K) => encodable(X)} end, #{}, V);
encodable(V) ->
    iolist_to_binary(io_lib:format("~p", [V])).
