-module(ls_map_utils).

-type datatype()                ::  {enum, Enum :: [{atom()|string(), term()}]}
                                    | boolean
                                    | integer
                                    | float
                                    | atom
                                    | string
                                    | binary
                                    | pid | reference | port.

-type validator()               ::  fun((term()) -> boolean()).
-type value_spec()              ::  #{
                                        required => boolean(),
                                        default => term(),
                                        datatype => datatype(),
                                        validator => validator()
                                    }.
-type map_spec()                ::  #{term() => value_spec()}.


-export_type([datatype/0]).
-export_type([validator/0]).
-export_type([value_spec/0]).
-export_type([map_spec/0]).

-export([append/3]).
-export([append_list/3]).
-export([collect/2]).
-export([validate/2]).


%% =============================================================================
%% API
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% This function appends a new Value to the current list of values associated
%% with Key.
%% @end
%% -----------------------------------------------------------------------------
append(Key, Value, Map) ->
    case maps:get(Key, Map, []) of
        Values when is_list(Values) ->
            maps:update(Key, [Value|Values], Map);
        Prev ->
            maps:put(Key, [Value, Prev], Map)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% This function appends a list of values Values to the current list of values
%% associated with Key. An exception is generated if the initial value
%% associated with Key is not a list of values.
%% @end
%% -----------------------------------------------------------------------------
append_list(Key, Values, Map) when is_list(Values) ->
    case maps:get(Key, Map, []) of
        OldValues when is_list(OldValues) ->
            maps:update(Key, lists:append(OldValues, Values), Map);
        _ ->
            error(badarg)
    end.


%% @doc Collects the values for Keys preserving its order
-spec collect(Keys :: list(), Map :: map()) -> list().
collect(Keys, Map) ->
    L = [begin
        case maps:find(K, Map) of
            {ok, V} -> V;
            error -> not_found
        end
    end || K <- Keys],
    lists:filter(fun(not_found) -> false; (_) -> true end, L).


%% Throws
%% * {missing_required_key, Key :: term()}
%% * {invalid_datatype, Key :: term(), Value :: term()}
%% * {invalid, Key :: term(), Value :: term()}
-spec validate(Map :: map(), Spec :: map_spec()) -> ValidMap :: map().
validate(Map, Spec) when is_map(Spec) ->
    {Map, Validated} = maps:fold(fun validate_fold_fun/3, {Map, #{}}, Spec),
    Validated.




%% =============================================================================
%% PRIVATE : MAP VALIDATION
%% =============================================================================



%% @private
validate_fold_fun(K, Spec, {In, Out}) when is_map(Spec) ->
    case maps:find(K, In) of
        {ok, Val} ->
            {In, Out#{K => validate(K, Val, Spec)}};
        error ->
            IsReq = is_required(Spec),
            Default = default(Spec),
            {In, maybe_add_key(Out, K, IsReq, Default)}
    end;
validate_fold_fun(K, V, _) ->
    error({invalid_value_spec, {K, V}}).



%% @private
maybe_add_key(_, K, true, no_default) ->
    error({missing_required_key, K});
maybe_add_key(Map, K, true, Default) ->
    Map#{K => Default};
maybe_add_key(Map, _, _, _) ->
    Map.


%% @private
is_required(#{required := V}) -> V;
is_required(_) -> false.


%% @private
default(#{default := V}) -> V;
default(_) -> no_default.


%% @private
maybe_eval(K, V, #{validator := Fun}) ->
    maybe_eval(K, V, Fun(V));
maybe_eval(K, V, false) ->
    error({invalid, {K, V}});
maybe_eval(_, V, _) ->
    V.


%% @private
validate(K, V, #{datatype := boolean} = Spec) when is_boolean(V) ->
    maybe_eval(K, V, Spec);
validate(K, V, #{datatype := atom} = Spec) when is_atom(V) ->
    maybe_eval(K, V, Spec);
validate(K, V, #{datatype := integer} = Spec) when is_integer(V) ->
    maybe_eval(K, V, Spec);
validate(K, V, #{datatype := float} = Spec) when is_float(V) ->
    maybe_eval(K, V, Spec);
validate(K, V, #{datatype := pid} = Spec) when is_pid(V) ->
    maybe_eval(K, V, Spec);
validate(K, V, #{datatype := port} = Spec) when is_port(V) ->
    maybe_eval(K, V, Spec);
validate(K, V, #{datatype := list} = Spec) when is_list(V) ->
    maybe_eval(K, V, Spec);
validate(K, V, #{datatype := string} = Spec) when is_list(V) ->
    maybe_eval(K, V, Spec);
validate(K, V, #{datatype := binary} = Spec) when is_binary(V) ->
    maybe_eval(K, V, Spec);
validate(K, V, #{datatype := map} = Spec) when is_map(V) ->
    maybe_eval(K, V, Spec);
validate(K, V, #{datatype := {enum, L}} = Spec) ->
    case lists:member(V, L) of
        true ->
            maybe_eval(K, V, Spec);
        false ->
            error({invalid_datatype, {K, V}})
    end;
validate(K, V, #{datatype := _}) ->
    error({invalid_datatype, {K, V}});
validate(K, V, Spec) ->
    maybe_eval(K, V, Spec).
