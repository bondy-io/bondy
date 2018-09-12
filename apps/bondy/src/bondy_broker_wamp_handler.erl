-module(bondy_broker_wamp_handler).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-export([handle_call/2]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Handles the following META API wamp calls:
%%
%% * "wamp.subscription.list": Retrieves subscription IDs listed according to match policies.
%% * "wamp.subscription.lookup": Obtains the subscription (if any) managing a topic, according to some match policy.
%% * "wamp.subscription.match": Retrieves a list of IDs of subscriptions matching a topic URI, irrespective of match policy.
%% * "wamp.subscription.get": Retrieves information on a particular subscription.
%% * "wamp.subscription.list_subscribers": Retrieves a list of session IDs for sessions currently attached to the subscription.
%% * "wamp.subscription.count_subscribers": Obtains the number of sessions currently attached to the subscription.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_call(wamp_call(), bondy_context:t()) -> ok | no_return().

handle_call(#call{procedure_uri = <<"wamp.subscription.list">>} = M, Ctxt) ->
    %% TODO, BUT This call might be too big, dos not make any sense as it is a dump of the whole database
    Res = #{
        ?EXACT_MATCH => [],
        ?PREFIX_MATCH=> [],
        ?WILDCARD_MATCH => []
    },
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy_wamp_peer:send(bondy_context:peer(Ctxt), M);

handle_call(#call{procedure_uri = <<"wamp.subscription.lookup">>} = M, Ctxt) ->
    % #{<<"topic">> := TopicUri} = Args = M#call.arguments,
    % Opts = maps:get(<<"options">>, Args, #{}),
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy_wamp_peer:send(bondy_context:peer(Ctxt), M);

handle_call(#call{procedure_uri = <<"wamp.subscription.match">>} = M, Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy_wamp_peer:send(bondy_context:peer(Ctxt), M);

handle_call(#call{procedure_uri = <<"wamp.subscription.get">>} = M, Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy_wamp_peer:send(bondy_context:peer(Ctxt), M);

handle_call(
    #call{procedure_uri = <<"wamp.subscription.list_subscribers">>} = M,
    Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy_wamp_peer:send(bondy_context:peer(Ctxt), M);

handle_call(
    #call{procedure_uri = <<"wamp.subscription.count_subscribers">>} = M,
    Ctxt) ->
    Res = #{},
    M = wamp_message:result(M#call.request_id, #{}, [], Res),
    bondy_wamp_peer:send(bondy_context:peer(Ctxt), M);

handle_call(#call{} = M, Ctxt) ->
    Error = bondy_wamp_utils:no_such_procedure_error(M),
    bondy_wamp_peer:send(bondy_context:peer(Ctxt), Error).