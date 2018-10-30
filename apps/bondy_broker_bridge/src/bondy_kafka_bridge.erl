-module(bondy_kafka_bridge).
-behaviour(bondy_broker_bridge).
-include("bondy_broker_bridge.hrl").
-include_lib("wamp/include/wamp.hrl").


-define(ACTION_SPEC, #{
    <<"client_id">> => #{
        alias => topic,
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
        alias => topic,
        required => false,
        datatype => integer,
        allow_null => false,
        allow_undefined => false
    },
    <<"partitioner">> => #{
        alias => topic,
        required => true,
        default => <<"fnv32a">>,
        datatype => {in, [
            <<"random">>, <<"hash">>,
            <<"fnv32">>, <<"fnv32a">>, <<"fnv32m">>,
            <<"fnv64">>, <<"fnv64a">>,
            <<"fnv128">>, <<"fnv128a">>
        ]}
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
part(#{<<"partition">> := N}) -> N;
part(#{<<"partitioner">> := <<"random">>}) -> random;
part(#{<<"partitioner">> := <<"hash">>}) -> hash;
part(#{<<"partitioner">> := Val, <<"key">> := Key}) ->
    Type = list_to_atom(binary_to_list(Val)),
    part_fun(hash:Type(Key)).


%% @private
part_fun(Hash) ->
    fun(_Topic, PartCount, _Key, _Value) ->
        Partition = Hash rem PartCount,
        {ok, Partition}
    end.