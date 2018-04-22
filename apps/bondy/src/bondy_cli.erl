%% =============================================================================
%%  bondy_cli.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================



-module(bondy_cli).
-behaviour(clique_handler).

%% API
-export([command/1]).
-export([load_schema/0]).
-export([register/0]).
-export([register_node_finder/0]).
-export([status/3]).

%% API SECURITY
-export([add_group/1]).
-export([add_source/1]).
-export([add_user/1]).
-export([alter_group/1]).
-export([alter_user/1]).
-export([ciphers/1]).
-export([del_group/1]).
-export([del_source/1]).
-export([del_user/1]).
-export([grant/1]).
-export([parse_cidr/1]).
-export([print_grants/1]).
-export([print_group/1]).
-export([print_groups/1]).
-export([print_sources/1]).
-export([print_user/1]).
-export([print_users/1]).
-export([revoke/1]).
-export([security_disable/1]).
-export([security_enable/1]).
-export([security_status/1]).


%% API
-export([load_api/3]).

%% CLIQUE CALLBACKS
-export([register_cli/0]).




%% =============================================================================
%% API
%% =============================================================================


command(Cmd) ->
    clique:run(Cmd).


register() ->
    clique:register([?MODULE]).


-spec load_schema() -> ok.

load_schema() ->
    case application:get_env(bondy, schema_dirs) of
        {ok, Directories} ->
            ok = clique_config:load_schema(Directories);
        _ ->
            ok = clique_config:load_schema([code:lib_dir()])
    end.


status(_Command, [], []) ->
    JSON = sampler_server:get_status(),
    [clique_status:text(jsx:encode(JSON))];

status(_Command, [], [{status, Status}]) ->
    sampler_server:set_status([{status, list_to_binary(Status)}]),
    JSON = sampler_server:get_status(),
    [clique_status:text(mochijson2:encode(JSON))].



-spec register_node_finder() -> true.

register_node_finder() ->
    F = fun() ->
        {ok, Members} = bondy_peer_service_manager:members(),
        Members
    end,
    clique:register_node_finder(F).




%% =============================================================================
%% CLIQUE CALLBACKS
%% =============================================================================



-spec register_cli() -> ok.
register_cli() ->
    %% clique:register(?MODULE).
    register_all_usage(),
    register_all_commands().


%%%===================================================================
%%% Private
%%%===================================================================

register_all_usage() ->
    %% clique:register_usage(["cluster"], cluster_usage()),
    %% clique:register_usage(["cluster", "status"], status_usage()),
    %% clique:register_usage(["cluster", "partition"], partition_usage()),
    %% clique:register_usage(["cluster", "partitions"], partitions_usage()),
    %% clique:register_usage(["cluster", "partition_count"], partition_count_usage()).
    [].


register_all_commands() ->
    lists:foreach(
        fun
            ({Cmd, _, _, undefined, UsageCB}) ->
                apply(clique, register_usage, [Cmd, UsageCB]);
            ({Cmd, KeySpecs, FlagSpecs, CB, UsageCB}) ->
                apply(clique, register_command, [Cmd, KeySpecs, FlagSpecs, CB]),
                apply(clique, register_usage, [Cmd, UsageCB])
        end,
        lists:append([
            cluster_commands(),
            %% router_register(),
            security_commands(),
            api_gateway_commands()
        ])
    ).


cluster_commands() ->
    %% [ {Cmd, KeySpecs, FlagSpecs, CmdCallback, UsageCallback} ]
    [
        {
            ["cluster"],
            [],
            [],
            undefined,
            fun cluster_usage/0
        },
        {
            ["cluster", "join"],
            [
                {node, [
                    {shortname, "n"},
                    {longname, "node"},
                    {typecast, fun to_node/1}
                ]}
            ],
            [],
            fun join/3,
            fun join_usage/0
        },
        {
            ["cluster", "leave"],
            [],
            [],
            fun leave/3,
            fun leave_usage/0
        },
        {
            ["cluster", "kick-out"],
            [
                {node, [
                    {shortname, "n"},
                    {longname, "node"},
                    {typecast, fun to_node/1}
                ]}
            ],
            [],
            fun kick_out/3,
            fun kick_out_usage/0
        },
        {
            ["cluster", "members"],
            [],
            [],
            fun members/3,
            fun members_usage/0
        }
    ].


security_commands() ->
    %% [ {Cmd, KeySpecs, FlagSpecs, CmdCallback, UsageCallback} ]
    [
        {
            ["security", "add-user"],
            [],
            [],
            fun status/3,
            fun status_usage/0
        }
    ].


api_gateway_commands() ->
    %% [Cmd, KeySpecs, FlagSpecs, Callback]
    [
        {
            ["gateway"],
            [],
            [],
            undefined,
            fun gateway_usage/0
        },
        {
            ["gateway", "load-api"],
            [{filename, []}],
            [],
            fun load_api/3,
            fun load_api_usage/0
        }
    ].

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
members(["cluster", "members"], [], []) ->
    {ok, L} = bondy_peer_service:members(),
    Table = [ [{name, E}] || E <- L ],
    [
        clique_status:table(Table)
    ].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
join(["cluster", "join"], [], []) ->
    clique_status:usage();

join(["cluster", "join"], [{node, Node}], []) ->
    ok = bondy_peer_service:join(Node),
    {ok, L} = bondy_peer_service:members(),
    Mssg = io_lib:format(
        "Node succesfully joined the cluster.~n"
        "The cluster has ~p members.~n",
        [length(L)]
    ),
    Table = [ [{name, E}] || E <- L ],
    [
        clique_status:text(Mssg),
        clique_status:table(Table)
    ].


kick_out(["cluster", "kick-out"], [{node, Node}], []) ->
    ok = bondy_peer_service:leave(Node),
    {ok, L} = bondy_peer_service:members(),
    Table = [ [{name, E}] || E <- L ],
    [
        clique_status:text("Node was kicked out from the cluster."),
        clique_status:table(Table)
    ].


leave(["cluster", "leave"], [], []) ->
    ok = bondy_peer_service:leave(),
    [clique_status:text("ok")].



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
load_api(["gateway", "load-api"], [{filename, FName}], []) ->
    case bondy_api_gateway:load(FName) of
        ok ->
            Text = io_lib:format("The API Gateway Specification was succesfully loaded."),
            %% TODO Also Print table of resulting API/Versions
            [clique_status:text(Text)];
        {error, invalid_specification_format} ->
            Text = clique_status:text("ERROR: Failed to load API Gateway Specification from file '~p'. The file does not contain a valid API Gateway Specification format.", [FName]),
            [clique_status:alert([Text])];
        {error, badarg} ->
            Text = clique_status:text("ERROR: Failed to load API Gateway Specification from file '~p'. The file was either not found or had the wrong permissions.", [FName]),
            [clique_status:alert([Text])]
    end;

load_api(["gateway", "load-api"], [{Op, Value}], []) ->
    [make_alert(["ERROR: The given value ", integer_to_list(Value),
                " for ", atom_to_list(Op), " is invalid."])];
load_api(_, [], []) ->
    clique_status:usage().


cluster_usage() ->
    [
     "bondy-admin cluster <sub-command>\n\n",
     "  Interact with a the peer service.\n\n",
     "  Sub-commands:\n",
     "    join    join cluster by providing another node.\n",
     "    leave   leave the cluster.\n",
     "    kick-out   make another node leave the cluster.\n",
     "    members list the cluster members.\n",
     "  Use --help after a sub-command for more details.\n"
    ].

members_usage() ->
    ["tbd\n"].

join_usage() ->
    ["tbd\n"].

leave_usage() ->
    ["tbd\n"].

kick_out_usage() ->
    ["tbd\n"].


gateway_usage() ->
    [
     "bondy-admin gateway <sub-command>\n\n",
     "  Interact with a the API Gateway application.\n\n",
     "  Sub-commands:\n",
     "    load-api    Load and deploy the API endpoints found in the provided Bondy API Gateway Specification format.\n",
     "  Use --help after a sub-command for more details.\n"
    ].

load_api_usage() ->
    [
     "bondy-admin gateway load-api filename='my_spec.json'\n\n",
     "  Load and deploy the API endpoints found in the provided filename. The file needs to be a valid Bondy API Gateway Specification format.\n"
    ].

status_usage() ->
    [
     "bondy-admin cluster status'\n\n",
     "  TBD\n"
    ].

%% =============================================================================
%% SECURITY (FROM RIAK CORE)
%% =============================================================================


security_error_xlate({errors, Errors}) ->
    string:join(
      lists:map(fun(X) -> security_error_xlate({error, X}) end,
                Errors),
      "~n");
security_error_xlate({error, unknown_user}) ->
    "User not recognized";
security_error_xlate({error, unknown_group}) ->
    "Group not recognized";
security_error_xlate({error, {unknown_permission, Name}}) ->
    io_lib:format("Permission not recognized: ~ts", [Name]);
security_error_xlate({error, {unknown_role, Name}}) ->
    io_lib:format("Name not recognized: ~ts", [Name]);
security_error_xlate({error, {unknown_user, Name}}) ->
    io_lib:format("User not recognized: ~ts", [Name]);
security_error_xlate({error, {unknown_group, Name}}) ->
    io_lib:format("Group not recognized: ~ts", [Name]);
security_error_xlate({error, {unknown_users, Names}}) ->
    io_lib:format("User(s) not recognized: ~ts",
                  [
                   string:join(
                     lists:map(fun(X) -> unicode:characters_to_list(X, utf8) end, Names),
                     ", ")
                  ]);
security_error_xlate({error, {unknown_groups, Names}}) ->
    io_lib:format("Group(s) not recognized: ~ts",
                  [
                   string:join(
                     lists:map(fun(X) -> unicode:characters_to_list(X, utf8) end, Names),
                     ", ")
                  ]);
security_error_xlate({error, {unknown_roles, Names}}) ->
    io_lib:format("Name(s) not recognized: ~ts",
                  [
                   string:join(
                    lists:map(fun(X) -> unicode:characters_to_list(X, utf8) end, Names),
                    ", ")
                  ]);
security_error_xlate({error, {duplicate_roles, Names}}) ->
    io_lib:format("Ambiguous names need to be prefixed with 'user/' or 'group/': ~ts",
                  [
                   string:join(
                     lists:map(fun(X) -> unicode:characters_to_list(X, utf8) end, Names),
                     ", ")
                  ]);
security_error_xlate({error, reserved_name}) ->
    "This name is reserved for system use";
security_error_xlate({error, no_matching_sources}) ->
    "No matching source";
security_error_xlate({error, illegal_name_char}) ->
    "Illegal character(s) in name";
security_error_xlate({error, role_exists}) ->
    "This name is already in use";

%% If we get something we hadn't planned on, better an ugly error
%% message than an ugly RPC call failure
security_error_xlate(Error) ->
    io_lib:format("~p", [Error]).

add_user([Username|Options]) ->
    add_role(Username, Options, fun bondy_security:add_user/2).

add_group([Groupname|Options]) ->
    add_role(Groupname, Options, fun bondy_security:add_group/2).

add_role(Name, Options, Fun) ->
    try Fun(Name, parse_options(Options)) of
        ok ->
            ok;
        Error ->
            io:format(security_error_xlate(Error)),
            io:format("~n"),
            Error
    catch
        throw:{error, {invalid_option, Option}} ->
            io:format("Invalid option ~p, options are of the form key=value~n",
                      [Option]),
            error
    end.

alter_user([Username|Options]) ->
    alter_role(Username, Options, fun bondy_security:alter_user/2).

alter_group([Groupname|Options]) ->
    alter_role(Groupname, Options, fun bondy_security:alter_group/2).

alter_role(Name, Options, Fun) ->
    try Fun(Name, parse_options(Options)) of
        ok ->
            ok;
        Error ->
            io:format(security_error_xlate(Error)),
            io:format("~n"),
            Error
    catch
        throw:{error, {invalid_option, Option}} ->
            io:format("Invalid option ~p, options are of the form key=value~n",
                      [Option]),
            error
    end.

del_user([Username]) ->
    del_role(Username, fun bondy_security:del_user/1).

del_group([Groupname]) ->
    del_role(Groupname, fun bondy_security:del_group/1).

del_role(Name, Fun) ->
    case Fun(Name) of
        ok ->
            io:format("Successfully deleted ~ts~n", [Name]),
            ok;
        Error ->
            io:format(security_error_xlate(Error)),
            io:format("~n"),
            Error
    end.

add_source([Users, CIDR, Source | Options]) ->
    Unames = case string:tokens(Users, ",") of
        ["all"] ->
            all;
        Other ->
            Other
    end,
    %% Unicode note: atoms are constrained to latin1 until R18, so our
    %% sources are as well
    try bondy_security:add_source(Unames, parse_cidr(CIDR),
                                  list_to_atom(string:to_lower(Source)),
                                  parse_options(Options)) of
        ok ->
            io:format("Successfully added source~n"),
            ok;
        Error ->
            io:format(security_error_xlate(Error)),
            io:format("~n"),
            Error
    catch
        throw:{error, {invalid_option, Option}} ->
            io:format("Invalid option ~p, options are of the form key=value~n",
                      [Option]);
        error:badarg ->
            io:format("Invalid source ~ts, must be latin1, sorry~n",
                      [Source])
    end.

del_source([Users, CIDR]) ->
    Unames = case string:tokens(Users, ",") of
        ["all"] ->
            all;
        Other ->
            Other
    end,
    bondy_security:del_source(Unames, parse_cidr(CIDR)),
    io:format("Deleted source~n").


parse_roles(Roles) ->
    case string:tokens(Roles, ",") of
        ["all"] ->
            all;
        Other ->
            Other
    end.

parse_grants(Grants) ->
    string:tokens(Grants, ",").

grant_int(Permissions, Bucket, Roles) ->
    case bondy_security:add_grant(Roles, Bucket, Permissions) of
        ok ->
            io:format("Successfully granted~n"),
            ok;
        Error ->
            io:format(security_error_xlate(Error)),
            io:format("~n"),
            Error
    end.


grant([Grants, "on", "any", "to", Users]) ->
    grant_int(parse_grants(Grants),
              any,
              parse_roles(Users));
grant([Grants, "on", Type, Bucket, "to", Users]) ->
    grant_int(parse_grants(Grants),
              { Type, Bucket },
              parse_roles(Users));
grant([Grants, "on", Type, "to", Users]) ->
    grant_int(parse_grants(Grants),
              Type,
              parse_roles(Users));
grant(_) ->
    io:format("Usage: grant <permissions> on (<type> [bucket]|any) to <users>~n"),
    error.

revoke_int(Permissions, Bucket, Roles) ->
    case bondy_security:add_revoke(Roles, Bucket, Permissions) of
        ok ->
            io:format("Successfully revoked~n"),
            ok;
        Error ->
            io:format(security_error_xlate(Error)),
            io:format("~n"),
            Error
    end.

revoke([Grants, "on", "any", "from", Users]) ->
    revoke_int(parse_grants(Grants),
               any,
               parse_roles(Users));
revoke([Grants, "on", Type, Bucket, "from", Users]) ->
    revoke_int(parse_grants(Grants),
               { Type, Bucket },
               parse_roles(Users));
revoke([Grants, "on", Type, "from", Users]) ->
    revoke_int(parse_grants(Grants),
               Type,
               parse_roles(Users));
revoke(_) ->
    io:format("Usage: revoke <permissions> on <type> [bucket] from <users>~n"),
    error.

print_grants([Name]) ->
    case bondy_security:print_grants(Name) of
        ok ->
            ok;
        Error ->
            io:format(security_error_xlate(Error)),
            io:format("~n"),
            Error
    end.

print_users([]) ->
    bondy_security:print_users().

print_user([User]) ->
    case bondy_security:print_user(User) of
        ok ->
            ok;
        Error ->
            io:format(security_error_xlate(Error)),
            io:format("~n"),
            Error
    end.


print_groups([]) ->
    bondy_security:print_groups().

print_group([Group]) ->
    case bondy_security:print_group(Group) of
        ok ->
            ok;
        Error ->
            io:format(security_error_xlate(Error)),
            io:format("~n"),
            Error
    end.

print_sources([]) ->
    bondy_security:print_sources().

ciphers([]) ->
    bondy_security:print_ciphers();

ciphers([CipherList]) ->
    case bondy_security:set_ciphers(CipherList) of
        ok ->
            bondy_security:print_ciphers(),
            ok;
        error ->
            error
    end.

security_enable([]) ->
    bondy_security:enable().

security_disable([]) ->
    bondy_security:disable().

security_status([]) ->
    case bondy_security:status() of
        enabled ->
            io:format("Enabled~n");
        disabled ->
            io:format("Disabled~n");
        enabled_but_no_capability ->
            io:format("WARNING: Configured to be enabled, but not supported "
                      "on all nodes so it is disabled!~n")
    end.

parse_options(Options) ->
    parse_options(Options, []).

parse_options([], Acc) ->
    Acc;
parse_options([H|T], Acc) ->
    case re:split(H, "=", [{parts, 2}, {return, list}]) of
        [Key, Value] when is_list(Key), is_list(Value) ->
            parse_options(T, [{string:to_lower(Key), Value}|Acc]);
        _Other ->
            throw({error, {invalid_option, H}})
    end.

-spec parse_cidr(string()) -> {inet:ip_address(), non_neg_integer()}.
parse_cidr(CIDR) ->
    [IP, Mask] = string:tokens(CIDR, "/"),
    {ok, Addr} = inet_parse:address(IP),
    {Addr, list_to_integer(Mask)}.





%% =============================================================================
%% PRIVATE
%% =============================================================================



make_alert(Iolist) ->
    clique_status:alert([clique_status:text(Iolist)]).

-spec to_node(string()) -> node() | {error, bad_node}.
to_node(Str) ->
    try
        list_to_atom(Str)
    catch error:badarg ->
        {error, bad_node}
    end.