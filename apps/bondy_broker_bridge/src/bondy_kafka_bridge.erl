-module(bondy_kafka_bridge).
-behaviour(bondy_broker_bridge).
-include("bondy_broker_bridge.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(OPTIONS_SPEC, #{
    %% How many acknowledgements the kafka broker should receive from the
    %% clustered replicas before acking producer.
    %%  0: the broker will not send any response
    %%     (this is the only case where the broker will not reply to a request)
    %%  1: The leader will wait the data is written to the local log before
    %%     sending a response.
    %% -1: If it is -1 the broker will block until the message is
    %%     committed by all in sync replicas before acking.
    <<"required_acks">> => #{
        alias => required_acks,
        required => true,
        default => -1,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (<<"leader">>) -> {ok, -1};
            (<<"none">>) -> {ok, 0};
            (<<"all">>) -> {ok, 1};
            (Val) when Val >= -1 andalso Val =< 1 -> true;
            (_) -> false
        end
    },
    %% Maximum time in milliseconds the broker can await the receipt of the
    %% number of acknowledgements in RequiredAcks. The timeout is not an exact
    %% limit on the request time for a few reasons: (1) it does not include
    %% network latency, (2) the timer begins at the beginning of the processing
    %% of this request so if many requests are queued due to broker overload
    %% that wait time will not be included, (3) kafka leader will not terminate
    %% a local write so if the local write time exceeds this timeout it will
    %% not be respected.
    <<"ack_timeout">> => #{
        alias => ack_timeout,
        required => true,
        datatype => timeout,
        default => 10000,
        allow_null => false,
        allow_undefined => false
    },
    %% max_retries (optional, default = 3):
    %% If {max_retries, N} is given, the producer retry produce request for
    %% N times before crashing in case of failures like connection being
    %% shutdown by remote or exceptions received in produce response from kafka.
    %% The special value N = -1 means 'retry indefinitely'
    <<"max_retries">> => #{
        alias => max_retries,
        required => true,
        default => 3,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (Val) when is_integer(Val) andalso Val >= -1 -> true;
            (_) -> false
        end
    },
    %% retry_backoff_ms (optional, default = 500);
    %% Time in milli-seconds to sleep before retry the failed produce request.
    <<"retry_backoff_ms">> => #{
        alias => retry_backoff_ms,
        required => true,
        datatype => timeout,
        default => 500,
        allow_null => false,
        allow_undefined => false
    },
    %% max_linger_ms (optional, default = 0):
    %% Messages are allowed to 'linger' in buffer for this amount of
    %% milli-seconds before being sent.
    %% Definition of 'linger': A message is in 'linger' state when it is allowed
    %% to be sent on-wire, but chosen not to (for better batching).
    %% The default value is 0 for 2 reasons:
    %% 1. Backward compatibility (for 2.x releases)
    %% 2. Not to surprise `brod:produce_sync' callers
    <<"max_linger_ms">> => #{
        alias => max_linger_ms,
        required => true,
        datatype => timeout,
        default => 0,
        allow_null => false,
        allow_undefined => false
    },
    %% max_linger_count (optional, default = 0):
    %% At most this amount (count not size) of messages are allowed to 'linger'
    %% in buffer. Messages will be sent regardless of 'linger' age when this
    %% threshold is hit.
    %% NOTE: It does not make sense to have this value set larger than
    %%     `partition_buffer_limit'
    <<"max_linger_count">> => #{
        alias => max_linger_count,
        required => true,
        datatype => pos_integer,
        default => 0,
        allow_null => false,
        allow_undefined => false
    }
}).

-define(PARTITIONER_SPEC, #{
    <<"algorithm">> => #{
        alias => algorithm,
        required => true,
        default => <<"fnv32a">>,
        datatype => {in, [
            <<"random">>, <<"hash">>,
            <<"fnv32">>, <<"fnv32a">>, <<"fnv32m">>,
            <<"fnv64">>, <<"fnv64a">>,
            <<"fnv128">>, <<"fnv128a">>
        ]}
    },
    <<"value">> => #{
        alias => value,
        required => true,
        allow_null => false,
        allow_undefined => true,
        default => undefined,
        validator => fun
            (undefined) -> true;
            (Val) when is_binary(Val) -> true;
            (_) -> false
        end
    }
}).

-define(ACTION_SPEC, #{
    <<"client_id">> => #{
        alias => client_id,
        required => true,
        default => undefined,
        allow_null => false,
        validator => fun
            (undefined) ->
                get_client();
            (Val) when is_atom(Val) ->
                {ok, Val};
            (Val) when is_binary(Val) ->
                {ok, list_to_atom(binary_to_list(Val))}
        end
    },
    <<"topic">> => #{
        alias => topic,
        required => true,
        datatype => binary,
        allow_null => false,
        allow_undefined => false
    },
    <<"partition">> => #{
        alias => partition,
        required => false,
        datatype => integer,
        allow_null => false,
        allow_undefined => false
    },
    <<"partitioner">> => #{
        alias => partitioner,
        required => true,
        validator => ?PARTITIONER_SPEC
    },
    <<"options">> => #{
        alias => options,
        required => true,
        validator => ?OPTIONS_SPEC
    },
    <<"key">> => #{
        alias => key,
        required => true,
        allow_null => false,
        allow_undefined => true,
        default => undefined,
        validator => fun
            (undefined) -> true;
            (Val) when is_binary(Val) -> true;
            (_) -> false
        end
    },
    <<"value">> => #{
        alias => value,
        required => true,
        datatype => [binary, list]
    },
    <<"acknowledge">> => #{
        alias => acknowledge,
        required => true,
        default => false,
        datatype => boolean,
        allow_null => false,
        allow_undefined => false
    },
    <<"encoding">> => #{
        alias => encoding,
        required => true,
        datatype => {in, [<<"json">>, <<"msgpack">>, <<"erl">>, <<"bert">>]},
        allow_null => false,
        allow_undefined => false
    }
}).


-export([init/1]).
-export([validate_action/1]).
-export([apply_action/2]).
-export([terminate/2]).



%% =============================================================================
%% BONDY_BROKER_BRIDGE CALLBACKS
%% =============================================================================



init(Config) ->
    _ = [application:set_env(brod, K, V) || {K, V} <- Config],

    try application:ensure_all_started(brod) of
        {ok, _} ->
            {ok, Clients} = application:get_env(brod, clients),
            [
                begin
                    case lists:keyfind(endpoints, 1, Opts) of
                        false ->
                            error(badarg);
                        {endpoints, Endpoints} ->
                            ok = brod:start_client(Endpoints, Name, Opts)
                    end
                end || {Name, Opts} <- Clients
            ],
            ok;
        Error ->
            Error
    catch
        _:Reason ->
            {error, Reason}
    end.


validate_action(Action0) ->
    try maps_utils:validate(Action0, ?ACTION_SPEC) of
        Action1 ->
            {ok, Action1}
    catch
        error:Reason ->
            {error, Reason}
    end.


apply_action(Action0, Ctxt) ->
    try mops:eval(Action0, Ctxt) of
        #{
            <<"client_id">> := Client,
            <<"topic">> := Topic,
            <<"key">> := Key,
            <<"value">> := Value,
            <<"acknowledge">> := Ack,
            <<"encoding">> := Enc
        } = Action1 ->
            Part = part(Action1),
            Data = bondy_utils:maybe_encode(Enc, Value),

            Res = case Ack of
                true ->
                    brod:produce_sync(Client, Topic, Part, Key, Data);
                false ->
                    brod:produce(Client, Topic, Part, Key, Data)
            end,

            case Res of
                ok ->
                    ok;
                {ok, _} ->
                    ok;
                {error, client_down} ->
                    {retry, client_down};
                {error, Reason} ->
                    {error, Reason}
            end
    catch
        ?EXCEPTION(_, Reason, Stacktrace) ->
            _ = lager:error(
                "Error while evaluating action; reason=~p, "
                "action=~p, stacktrace=~p",
                [Reason, Action0, ?STACKTRACE(Stacktrace)]
            ),
            {error, Reason}
    end.


terminate(_Reason, _State) ->
    _  = application:stop(brod),
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================




get_client() ->
    case bondy_broker_bridge:backend(?MODULE) of
        undefined ->
            {error, not_found};
        PL ->
            case lists:keyfind(clients, 1, PL) of
                {clients, [H|_]} ->
                    {ok, H};
                false ->
                    {error, not_found}
            end
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Returns a brod partition() or partitioner()
%% @end
%% -----------------------------------------------------------------------------
part(#{<<"partition">> := N}) ->
    N;
part(#{<<"partitioner">> := Map}) ->
    case maps:get(<<"algorithm">>, Map) of
        <<"random">> ->
            random;
        <<"hash">> ->
            hash;
        Other ->
            Type = list_to_atom(binary_to_list(Other)),
            Value = maps:get(<<"value">>, Map),
            Hash = hash:Type(Value),
            fun(_Topic, PartCount, _K, _V) ->
                Partition = Hash rem PartCount,
                {ok, Partition}
            end
    end.
