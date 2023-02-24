-module(bondy_sysmon_handler).

-behaviour(gen_event).

-include_lib("kernel/include/logger.hrl").

-record(state, {
}).

%% API
-export([add_handler/0]).

%% GEN_EVENT CALLBACKS
-export([init/1]).
-export([handle_event/2]).
-export([handle_call/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
add_handler() ->
    Handlers = gen_event:which_handlers(riak_sysmon_handler),
    case lists:member(?MODULE, Handlers) of
        true ->
            ok;
        false ->
            riak_sysmon_filter:add_custom_handler(?MODULE, [])
    end.



%% =============================================================================
%% GEN_EVENT CALLBACKS
%% =============================================================================



%%--------------------------------------------------------------------
%% @doc
%% Whenever a new event handler is added to an event manager,
%% this function is called to initialize the event handler.
%%
%% @end
%%--------------------------------------------------------------------
init([]) ->
    State = #state{},
    {ok, State, hibernate}.


%%--------------------------------------------------------------------
%% @doc
%% Whenever an event manager receives an event sent using
%% gen_event:notify/2 or gen_event:sync_notify/2, this function is
%% called for each installed event handler to handle the event.
%% @end
%%--------------------------------------------------------------------
handle_event({monitor, Pid, Type, Info}, #state{} = State)
when Type == long_gc; Type == large_heap; Type == long_schedule ->
    PInfo = process_info(Pid, [
        registered_name,
        current_function,
        heap_size,
        message_queue_len,
        status
    ]),

    ?LOG_INFO(#{
        description => "System event received.",
        pid => Pid,
        type => Type,
        info => Info,
        process_info => PInfo
    }),
    {ok, State};

handle_event({monitor, Pid, Type, Info}, #state{} = State) ->
    ?LOG_INFO(#{
        description => "System event received.",
        pid => Pid,
        type => Type,
        info => Info
    }),
    {ok, State};

handle_event(_Event, #state{} = State) ->
    {ok, State}.


%%--------------------------------------------------------------------
%% @doc
%% Whenever an event manager receives a request sent using
%% gen_event:call/3,4, this function is called for the specified
%% event handler to handle the request.
%%
%% @end
%%--------------------------------------------------------------------
handle_call(_Msg, State) ->
    {ok, {error, unknown_call}, State}.


%%--------------------------------------------------------------------
%% @doc
%% This function is called for each installed event handler when
%% an event manager receives any other message than an event or a
%% synchronous request (or a system message).
%%
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {ok, State}.


%%--------------------------------------------------------------------
%% @doc
%% Whenever an event handler is deleted from an event manager, this
%% function is called. It should be the opposite of Module:init/1 and
%% do any necessary cleaning up.
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.


%%--------------------------------------------------------------------
%% @doc
%% Convert process state when code is changed
%%
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.