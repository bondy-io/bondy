-module(bondy_kafka_bridge).
-behaviour(bondy_broker_bridge).
-include("bondy_broker_bridge.hrl").
-include_lib("wamp/include/wamp.hrl").

-define(PRODUCE_OPTIONS_SPEC, ?BROD_OPTIONS_SPEC#{
    %% The brod client to be used. This should have been configured through the
    %% configuration files
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
    %% Is this a sync or async produce
    <<"acknowledge">> => #{
        alias => acknowledge,
        required => true,
        default => false,
        datatype => boolean,
        allow_null => false,
        allow_undefined => false
    },
    <<"partition">> => #{
        alias => partition,
        required => false,
        datatype => integer,
        allow_null => true,
        allow_undefined => true
    },
    <<"partitioner">> => #{
        alias => partitioner,
        required => true,
        validator => ?PARTITIONER_SPEC
    },
    %% How to encode the Value
    <<"encoding">> => #{
        alias => encoding,
        required => true,
        datatype => {in, [<<"json">>, <<"msgpack">>, <<"erl">>, <<"bert">>]},
        allow_null => false,
        allow_undefined => false
    }
}).

-define(BROD_OPTIONS_SPEC, #{
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
    %% partition_buffer_limit(optional, default = 256):
    %% How many requests (per-partition) can be buffered without blocking the
    %% caller. The callers are released (by receiving the
    %% 'brod_produce_req_buffered' reply) once the request is taken into buffer
    %% and after the request has been put on wire, then the caller may expect
    %% a reply 'brod_produce_req_acked' when the request is accepted by kafka.
    <<"partition_buffer_limit">> => #{
        alias => partition_buffer_limit,
        required => false,
        datatype => integer,
        default => 256,
        allow_null => false,
        allow_undefined => false
    },
    %% partition_onwire_limit(optional, default = 1):
    %% How many message sets (per-partition) can be sent to kafka broker
    %% asynchronously before receiving ACKs from broker.
    %% NOTE: setting a number greater than 1 may cause messages being persisted
    %%       in an order different from the order they were produced.
    <<"partition_onwire_limit">> => #{
        alias => partition_onwire_limit,
        required => false,
        datatype => integer,
        default => 1,
        allow_null => false,
        allow_undefined => false
    },
    %% max_batch_size (in bytes, optional, default = 1M):
    %% In case callers are producing faster than brokers can handle (or
    %% congestion on wire), try to accumulate small requests into batches
    %% as much as possible but not exceeding max_batch_size.
    %% OBS: If compression is enabled, care should be taken when picking
    %%  the max batch size, because a compressed batch will be produced
    %%  as one message and this message might be larger than
    %%  'max.message.bytes' in kafka config (or topic config)
    <<"max_batch_size">> => #{
        alias => max_batch_size,
        required => false,
        datatype => integer,
        default => 1024,
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
    %% compression (optional, default = no_compression):
    %%'gzip' or 'snappy' to enable compression
    <<"compression">> => #{
        alias => compression,
        required => true,
        default => no_compression,
        allow_null => false,
        allow_undefined => false,
        validator => fun
            (<<"gzip">>) -> {ok, gzip};
            (<<"snappy">>) -> {ok, snappy};
            (<<"no_compression">>) -> {ok, no_compression};
            (gzip) -> true;
            (snappy) -> true;
            (no_compression) -> true;
            (_) -> false
        end
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
        allow_null => true,
        allow_undefined => true,
        default => undefined,
        validator => fun
            (null) -> {ok, undefined};
            (_) -> true
        end
    }
}).

-define(PRODUCE_ACTION_SPEC, #{
    <<"type">> => #{
        alias => type,
        required => true,
        default => <<"produce_sync">>,
        allow_null => false,
        allow_undefined => false,
        %% datatype => {in, [<<"produce">>, <<"produce_sync">>]}
        datatype => {in, [<<"produce_sync">>]}
    },
    <<"topic">> => #{
        alias => topic,
        required => true,
        datatype => binary,
        allow_null => false,
        allow_undefined => false
    },
    <<"options">> => #{
        alias => options,
        required => true,
        validator => ?PRODUCE_OPTIONS_SPEC
    },
    <<"key">> => #{
        alias => key,
        required => true,
        allow_null => true,
        allow_undefined => true,
        default => undefined,
        validator => fun
            (undefined) -> true;
            (null) -> {ok, undefined};
            (Val) when is_binary(Val) -> true;
            (_) -> false
        end
    },
    <<"value">> => #{
        alias => value,
        required => true,
        allow_null => true,
        allow_undefined => true,
        default => undefined,
        validator => fun
            (null) -> {ok, undefined};
            (_) -> true
        end
    }
}).


-export([init/1]).
-export([validate_action/1]).
-export([apply_action/1]).
-export([terminate/2]).



%% =============================================================================
%% BONDY_BROKER_BRIDGE CALLBACKS
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Initialises the Kafka clients provided by the configuration.
%% @end
%% -----------------------------------------------------------------------------
init(Config) ->
    _ = [application:set_env(brod, K, V) || {K, V} <- Config, K =:= clients],

    try application:ensure_all_started(brod) of
        {ok, _} ->
            {ok, Clients} = application:get_env(brod, clients),
            [
                begin
                    case lists:keyfind(endpoints, 1, Opts) of
                        false ->
                            error(badarg);
                        {endpoints, Endpoints} when is_list(Endpoints) ->
                            ok = brod:start_client(Endpoints, Name, Opts)
                    end
                end || {Name, Opts} <- Clients
            ],
            Topics = maps:from_list(proplists:get_value(topics, Config, [])),
            Ctxt = #{<<"kafka">> => #{<<"topics">> => Topics}},
            {ok, Ctxt};
        Error ->
            Error
    catch
        ?EXCEPTION(_, Reason, _) ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc Validates the action specification.
%% An action spec is a map containing the following keys:
%%
%% * `type :: binary()' - `<<"produce_sync">>'. Optional, the default value is `<<"produce_sync">>'.
%% * `topic :: binary()' - the Kafka topic we should produce to.
%% * `key :: binary()' - the kafka message's key
%% * `value :: any()' - the kafka message's value
%% * `options :: map()' - a map containing the following keys
%%
%% ```erlang
%% #{
%%     <<"type">> <<"produce">>,
%%     <<"topic": <<"com.magenta.wamp_events",
%%     <<"key": "\"{{event.topic}}/{{event.publication_id}}\"",
%%     <<"value": "{{event}}",
%%     <<"options" : {
%%         <<"client_id": "default",
%%         <<"acknowledge": true,
%%         <<"required_acks": "all",
%%         <<"partition": null,
%%         <<"partitioner": {
%%             "algorithm": "fnv32a",
%%             "value": "\"{{event.topic}}/{{event.publication_id}}\""
%%         },
%%         <<"encoding">>: <<"json">>
%%     }
%% }
%% '''
%% @end
%% -----------------------------------------------------------------------------
validate_action(Action0) ->
    %% maps_utils:validate(Action0, ?PRODUCE_ACTION_SPEC).
    try maps_utils:validate(Action0, ?PRODUCE_ACTION_SPEC) of
        Action1 ->
            {ok, Action1}
    catch
        ?EXCEPTION(_, Reason, _)->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc Evaluates the action specification `Action' against the context
%% `Ctxt' using `mops' and produces to Kafka.
%% @end
%% -----------------------------------------------------------------------------
apply_action(Action) ->
    try
        #{
            <<"type">> := ActionType,
            <<"topic">> := Topic,
            <<"key">> := Key,
            <<"value">> := Value,
            <<"options">> := Opts
        } = Action,
        #{
            <<"client_id">> := Client,
            <<"encoding">> := Enc,
            <<"acknowledge">> := _Ack
        } = Opts,
        Part = partition(Opts),
        Data = bondy_utils:maybe_encode(Enc, Value),

        Result = case ActionType of
            %% <<"produce">> ->
            %%     brod:produce(Client, Topic, Part, Key, Data);
            <<"produce_sync">> ->
                brod:produce_sync(Client, Topic, Part, Key, Data)
        end,

        case Result of
            ok ->
                ok;
            {ok, _Offset} ->
                ok;
            {error, client_down} ->
                {retry, client_down};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        ?EXCEPTION(_, EReason, Stacktrace) ->
            _ = lager:error(
                "Error while evaluating action; reason=~p, "
                "action=~p, stacktrace=~p",
                [EReason, Action, ?STACKTRACE(Stacktrace)]
            ),
            {error, EReason}
    end.


terminate(_Reason, _State) ->
    _  = application:stop(brod),
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================




get_client() ->
    case bondy_broker_bridge_manager:backend(?MODULE) of
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
%% @doc Returns a brod partition() or partitioner().
%% @end
%% -----------------------------------------------------------------------------
partition(#{<<"partition">> := N}) when is_integer(N) ->
    N;

partition(#{<<"partitioner">> := Map}) ->
    case maps:get(<<"algorithm">>, Map) of
        <<"random">> ->
            random;
        <<"hash">> ->
            hash;
        Other ->
            Type = list_to_atom(binary_to_list(Other)),
            PartValue = maps:get(<<"value">>, Map),

            fun(_Topic, PartCount, K, _V) ->
                Hash = case PartValue of
                    undefined ->
                        hash:Type(K);
                    PartValue ->
                        hash:Type(PartValue)
                end,
                {ok, Hash rem PartCount}
            end
    end.
