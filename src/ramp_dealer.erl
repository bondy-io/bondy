-module(ramp_dealer).
-behaviour(gen_server).
-include("ramp.hrl").

-define(POOL_NAME, ramp_dealer_pool).


-record(state, {
    pool_type = permanent       :: permanent | transient,
    event                       :: term()
}).

%% API
-export([handle_message/2]).
-export([unregister_all/1]).
-export([cast/2]).

%% GEN_SERVER API
-export([start_pool/0]).
-export([pool_name/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).


%% =============================================================================
%% API
%% =============================================================================



-spec handle_message(M :: message(), Ctxt :: map()) ->
    {ok, NewCtxt :: ramp_context:context()}
    | {stop, NewCtxt :: ramp_context:context()}
    | {reply, Reply :: message(), NewCtxt :: ramp_context:context()}
    | {stop, Reply :: message(), NewCtxt :: ramp_context:context()}.
handle_message(#register{} = _M, Ctxt) ->
    {ok, Ctxt};

handle_message(#unregister{} = _M, Ctxt) ->
    {ok, Ctxt};

handle_message(#call{} = _M, Ctxt) ->
    {ok, Ctxt}.




unregister_all(_) ->
    ok.



%% =============================================================================
%% API : GEN_SERVER
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec pool_name() -> atom().
pool_name() -> ?POOL_NAME.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_pool() -> ok.
start_pool() ->
    case do_start_pool() of
        {ok, _Child} -> ok;
        {ok, _Child, _Info} -> ok;
        {error, already_present} -> ok;
        {error, {already_started, _Child}} -> ok;
        {error, Reason} -> error(Reason)
    end.



%% =============================================================================
%% API : GEN_SERVER CALLBACKS
%% =============================================================================



init([?POOL_NAME]) ->
    %% We've been called by sidejob_worker
    %% TODO send metaevent
    {ok, #state{pool_type = permanent}};

init([Event]) ->
    %% We've been called by sidejob_supervisor
    %% We immediately timeout so that we find ourselfs in handle_info.
    %% TODO send metaevent

    State = #state{
        pool_type = transient,
        event = Event
    },
    {ok, State, 0}.


handle_call(Event, _From, State) ->
    try
        Reply = handle_event(Event, State),
        {reply, {ok, Reply}, State}
    catch
        throw:abort ->
            %% TODO send metaevent
            {reply, abort, State};
        _:Reason ->
            %% TODO send metaevent
            error_logger:error_report([
                {reason, Reason},
                {stacktrace, erlang:get_stacktrace()}
            ]),
            {reply, {error, Reason}, State}
    end.


handle_cast(Event, State) ->
    try
        handle_event(Event, State),
        {noreply, State}
    catch
        throw:abort ->
            %% TODO send metaevent
            {noreply, State};
        _:Reason ->
            %% TODO send metaevent
            error_logger:error_report([
                {reason, Reason},
                {stacktrace, erlang:get_stacktrace()}
            ]),
            {noreply, State}
    end.


handle_info(timeout, #state{pool_type = transient} = State) ->
    ok = handle_event(State#state.event, State),
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.


terminate(normal, _State) ->
    ok;
terminate(shutdown, _State) ->
    ok;
terminate({shutdown, _}, _State) ->
    ok;
terminate(_Reason, _State) ->
    %% TODO send metaevent
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE : GEN_SERVER
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec cast(#call{}, ramp_context:context()) -> ok | {error, any()}.
cast(#call{} = M, Ctxt) ->
    PoolName = pool_name(),
    Resp = case ramp_config:pool_type(PoolName) of
        permanent ->
            %% We send a request to an existing permanent worker
            %% using sidejob_worker
            sidejob:cast(PoolName, {M, Ctxt});
        transient ->
            %% We spawn a transient process with sidejob_supervisor
            sidejob_supervisor:start_child(
                PoolName,
                gen_server,
                start_link,
                [ramp_dealer, [{M, Ctxt}], []]
            )
    end,
    return(Resp, PoolName, false).


%% @private
do_start_pool() ->
    Size = ramp_config:pool_size(?POOL_NAME),
    Capacity = ramp_config:pool_capacity(?POOL_NAME),
    case ramp_config:pool_type(?POOL_NAME) of
        permanent ->
            sidejob:new_resource(?POOL_NAME, ?MODULE, Capacity, Size);
        transient ->
            sidejob:new_resource(?POOL_NAME, sidejob_supervisor, Capacity, Size)
    end.


%% @private
handle_event({#call{} = _M, _Ctxt}, _State) ->
    %% ReqId = M#call.request_id,
    %% Opts = M#call.options,
    %% TopicUri = M#call.topic_uri,
    %% Args = M#call.arguments,
    %% Payload = M#call.payload,

    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
return(ok, _, _) ->
    ok;
return(overload, PoolName, _) ->
    error_logger:info_report([
        {reason, overload},
        {pool, PoolName}
    ]),
    %% TODO send metaevent
    overload;
return({ok, _}, _, _) ->
    ok;
return({error, overload}, PoolName, _) ->
    error_logger:info_report([
        {reason, overload},
        {pool, PoolName}
    ]),
    overload;
return({error, Reason}, _, true) ->
    error(Reason);
return({error, _} = Error, _, false) ->
    Error.
