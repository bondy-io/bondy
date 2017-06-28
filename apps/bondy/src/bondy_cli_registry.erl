-module(bondy_cli_registry).

-define(MODS, [
    bondy_cluster_cli,
    bondy_security_cli,
    bondy_api_gateway_cli
]).

-export([register_node_finder/0]).
-export([register_cli/0]).
-export([load_schema/0]).


-spec register_node_finder() -> true.
register_node_finder() ->
    F = fun() ->
        % {ok, MyRing} = riak_core_ring_manager:get_my_ring(),
        % riak_core_ring:all_members(MyRing)
        {ok, Members} = plumtree_peer_service_manager:members(),
        Members
    end,
    clique:register_node_finder(F).


-spec register_cli() -> ok.
register_cli() ->
    clique:register(?MODS).


-spec load_schema() -> ok.
load_schema() ->
    case application:get_env(bondy, schema_dirs) of
        {ok, Directories} ->
            ok = clique_config:load_schema(Directories);
        _ ->
            ok = clique_config:load_schema([code:lib_dir()])
    end.