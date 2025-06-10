-module(bondy_wamp_utils).
-include("bondy_wamp.hrl").


-export([rand_uniform/0]).
-export([is_valid_id/1]).
-export([validate_id/1]).
-export([validate_map/3]).
-export([validate_map/4]).





%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% Returns a random number from a _uniform distribution_ over the range [0, 2^53]
%% @end
%% -----------------------------------------------------------------------------
-spec rand_uniform() -> integer().

rand_uniform() ->
    rand:uniform(?MAX_ID).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_valid_id(id()) -> boolean().

is_valid_id(N) when is_integer(N) andalso N >= 0 andalso N =< ?MAX_ID ->
    true;
is_valid_id(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
validate_id(Id) ->
    is_valid_id(Id) == true orelse error({invalid_id, Id}),
    Id.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
validate_map(Map, Spec, Extensions) ->
    Opts = #{
        atomic => true, % Fail atomically for the whole map
        labels => atom,  % This will only turn the defined keys to atoms
        keep_unknown => false % Remove all unknown options
    },
    validate_map(Map, Spec, Extensions, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
validate_map(Map, Spec, Extensions, Opts0) ->
    Defaults = #{
        atomic => true, % Fail atomically for the whole map
        labels => atom,  % This will only turn the defined keys to atoms
        keep_unknown => false % Remove all unknown options
    },
    Opts = maps:merge(Defaults, Opts0),
    NewSpec = maybe_add_extensions(Extensions, Spec),

    try
        maps_utils:validate(Map, NewSpec, Opts)
    catch
        error:Reason when is_map(Reason) ->
            error({validation_failed, Reason})
    end.


%% private
maybe_add_extensions(Keys, Spec) when is_list(Keys) ->
    MaybeAdd = fun(Key, Acc) -> maybe_add_extension(Key, Acc) end,
    lists:foldl(MaybeAdd, Spec, Keys);

maybe_add_extensions([], Spec) ->
    Spec.



maybe_add_extension({invoke, Options}, Acc) ->
    #{datatype := {in, L}} = KeySpec = maps:get(invoke, Acc),
    NewKeySpec = KeySpec#{
        datatype => {in, lists:append(L, Options)}
    },
    maps:put(invoke, NewKeySpec, Acc);

maybe_add_extension(Key, Acc) ->
    try
        %% We add a maps_utils key specification for the known
        NewKey = to_valid_extension_key(Key),
        NewKeySpec = #{
            %% we alias it so that maps_utils:validate/2 can find the key
            %% and replace it with NewKey.
            alias => atom_to_binary(Key, utf8),
            required => false
        },
        maps:put(NewKey, NewKeySpec, Acc)
    catch
        throw:invalid_key ->
            Acc
    end.



%% @private
to_valid_extension_key(Key) when is_atom(Key) ->
    to_valid_extension_key(atom_to_binary(Key, utf8));

to_valid_extension_key(Key) when is_binary(Key) ->
    try
        {match, _} = re:run(Key, extension_key_pattern()),
        %% We add a maps_utils key specification for the known
        binary_to_existing_atom(Key, utf8)
    catch
        error:{badmatch, nomatch} ->
            throw(invalid_key);
        error:badarg ->
            throw(invalid_key)
    end.



%% @private
extension_key_pattern() ->
    CompiledPattern = persistent_term:get({?MODULE, ekey_pattern}, undefined),
    extension_key_pattern(CompiledPattern).


%% @private
extension_key_pattern(undefined) ->
    {ok, Pattern} = re:compile("_[a-z0-9_]{3,}"),
    ok = persistent_term:put({?MODULE, ekey_pattern}, Pattern),
    Pattern;

extension_key_pattern(CompiledPattern) ->
    CompiledPattern.