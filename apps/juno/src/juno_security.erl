%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
% -module(juno_security).
-module(juno_security).



%% printing functions
-export([print_users/1, print_sources/1, print_user/2,
         print_groups/1, print_group/2, print_grants/2]).

%% type exports
-export_type([context/0]).

%% API
-export([add_grant/4]).
-export([add_group/3]).
-export([add_revoke/4]).
-export([add_source/5]).
-export([add_user/3]).
-export([alter_group/3]).
-export([alter_user/3]).
-export([authenticate/4]).
-export([check_permission/2]).
-export([check_permissions/2]).
-export([del_group/2]).
-export([del_source/3]).
-export([del_user/2]).
-export([disable/1]).
-export([enable/1]).
-export([find_user/2]).
-export([find_one_user_by_metadata/3]).
-export([find_unique_user_by_metadata/3]).
-export([find_bucket_grants/3]).
-export([get_ciphers/1]).
-export([get_username/1]).
-export([get_realm_uri/1]).
-export([get_grants/1]).
-export([is_enabled/1]).
-export([print_ciphers/1]).
-export([set_ciphers/2]).
-export([status/1]).
-export([context_to_map/1]).

%% =============================================================================
%% ADDED BY US
%% =============================================================================

%% Note that Buckets are not buckets, 
%% these are the "resources" or assets being protected

-define(FULL_PREFIX(RealmUri, A, B), 
    {<<RealmUri/binary, $., A/binary>>, B}
).
-define(USERS_PREFIX(RealmUri), 
    ?FULL_PREFIX(RealmUri, <<"security">>, <<"users">>)
).
-define(GROUPS_PREFIX(RealmUri), 
    ?FULL_PREFIX(RealmUri, <<"security">>, <<"groups">>)
).
-define(SOURCES_PREFIX(RealmUri), 
    ?FULL_PREFIX(RealmUri, <<"security">>, <<"sources">>)
).
-define(USER_GRANTS_PREFIX(RealmUri), 
    ?FULL_PREFIX(RealmUri, <<"security">>, <<"usergrants">>)
).
-define(GROUP_GRANTS_PREFIX(RealmUri), 
    ?FULL_PREFIX(RealmUri, <<"security">>, <<"groupgrants">>)
).
-define(STATUS_PREFIX(RealmUri), 
    ?FULL_PREFIX(RealmUri, <<"security">>, <<"status">>)
).
-define(CONFIG_PREFIX(RealmUri), 
    ?FULL_PREFIX(RealmUri, <<"security">>, <<"config">>)
).

-type uri() :: binary() | string().
-type cidr() :: {inet:ip_address(), non_neg_integer()}.

-export_type([cidr/0]).

-export([user_grants/2]).
-export([group_grants/2]).
-export([lookup_user/2]).
-export([lookup_group/2]).
-export([lookup_user_sources/2]).
-export([user_groups/2]).
-export([list/2]).


%% =============================================================================





-define(DEFAULT_CIPHER_LIST,
"ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256"
":ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384"
":DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256"
":DHE-DSS-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384"
":ADH-AES256-GCM-SHA384:ADH-AES128-GCM-SHA256"
":ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256"
":ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384"
":ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA"
":DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256"
":DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA"
":AES128-GCM-SHA256:AES256-GCM-SHA384:ECDHE-RSA-RC4-SHA:ECDHE-ECDSA-RC4-SHA"
":SRP-DSS-AES-128-CBC-SHA:SRP-RSA-AES-128-CBC-SHA:DHE-DSS-AES128-SHA"
":AECDH-AES128-SHA:SRP-AES-128-CBC-SHA:ADH-AES128-SHA256:ADH-AES128-SHA"
":ECDH-RSA-AES128-GCM-SHA256:ECDH-ECDSA-AES128-GCM-SHA256"
":ECDH-RSA-AES128-SHA256:ECDH-ECDSA-AES128-SHA256:ECDH-RSA-AES128-SHA"
":ECDH-ECDSA-AES128-SHA:AES128-SHA256:AES128-SHA:SRP-DSS-AES-256-CBC-SHA"
":SRP-RSA-AES-256-CBC-SHA:DHE-DSS-AES256-SHA256:AECDH-AES256-SHA"
":SRP-AES-256-CBC-SHA:ADH-AES256-SHA256:ADH-AES256-SHA"
":ECDH-RSA-AES256-GCM-SHA384:ECDH-ECDSA-AES256-GCM-SHA384"
":ECDH-RSA-AES256-SHA384:ECDH-ECDSA-AES256-SHA384:ECDH-RSA-AES256-SHA"
":ECDH-ECDSA-AES256-SHA:AES256-SHA256:AES256-SHA:RC4-SHA"
":DHE-RSA-CAMELLIA256-SHA:DHE-DSS-CAMELLIA256-SHA:ADH-CAMELLIA256-SHA"
":CAMELLIA256-SHA:DHE-RSA-CAMELLIA128-SHA:DHE-DSS-CAMELLIA128-SHA"
":ADH-CAMELLIA128-SHA:CAMELLIA128-SHA").

-define(TOMBSTONE, '$deleted').

%% Avoid whitespace, control characters, comma, semi-colon,
%% non-standard Windows-only characters, other misc
-define(ILLEGAL, lists:seq(0, 44) ++ lists:seq(58, 63) ++
            lists:seq(127, 191)).

-ifdef(TEST).
-define(REFRESH_TIME, 1).
-else.
-define(REFRESH_TIME, 1000).
-endif.

-record(context, {
    realm_uri   ::  binary(), 
    username    ::  binary(),
    grants      ::  [{any(), any()}],
    epoch       ::  erlang:timestamp()
}).

-type context() :: #context{}.
-type bucket() :: {binary(), binary()} | binary().
-type permission() :: {string()} | {string(), bucket()}.
-type userlist() :: all | [string()].
-type metadata_key() :: string().
-type metadata_value() :: term().
-type options() :: [{metadata_key(), metadata_value()}].



-spec find_user(Realm :: binary(), Username :: string()) -> options() | {error, not_found}.
find_user(Realm, Username) ->
    case user_details(Realm, name2bin(Username)) of
        undefined ->
            {error, not_found};
        Options ->
            Options
    end.

-spec find_one_user_by_metadata(binary(), metadata_key(), metadata_value()) -> {Username :: string(), options()} | {error, not_found}.
find_one_user_by_metadata(Realm, Key, Value) ->
    plumtree_metadata:fold(
      fun(User, _Acc) -> return_if_user_matches_metadata(Key, Value, User) end,
      {error, not_found},
      ?USERS_PREFIX(Realm),
      [{resolver, lww}, {default, []}]).

return_if_user_matches_metadata(Key, Value, {_Username, Options} = User) ->
    case lists:member({Key, Value}, Options) of
        true ->
            throw({break, User});
        false ->
            {error, not_found}
    end.

-spec find_unique_user_by_metadata(binary(), metadata_key(), metadata_value()) ->
    {Username :: string(), options()} | {error, not_found | not_unique}.
find_unique_user_by_metadata(Realm, Key, Value) ->
    plumtree_metadata:fold(fun (User, Acc) -> accumulate_matching_user(Key, Value, User, Acc) end,
                            {error, not_found},
                            ?USERS_PREFIX(Realm),
                            [{resolver, lww}, {default, []}]).

accumulate_matching_user(Key, Value, {_Username, Options} = User, Acc) ->
    accumulate_matching_user(lists:member({Key, Value}, Options), User, Acc).

accumulate_matching_user(true, User, {error, not_found}) ->
    User;
accumulate_matching_user(true, _User, _Acc) ->
    throw({break, {error, not_unique}});
accumulate_matching_user(false, _, Acc) ->
    Acc.

-spec find_bucket_grants(binary(), bucket(), user | group) -> [{RoleName :: string(), [permission()]}].
find_bucket_grants(Realm, Bucket, Type) ->
    Grants = match_grants(Realm, {'_', Bucket}, Type),
    lists:map(fun ({{Role, _Bucket}, Permissions}) ->
                      {bin2name(Role), Permissions}
              end, Grants).



prettyprint_users([all], _) ->
    "all";
prettyprint_users(Users0, Width) ->
    %% my kingdom for an iolist join...
    Users = [unicode:characters_to_list(U, utf8) || U <- Users0],
    prettyprint_permissions(Users, Width).

print_sources(RealmUri) ->
    Uri = name2bin(RealmUri),
    Sources = plumtree_metadata:fold(fun({{Username, CIDR}, [{Source, Options}]}, Acc) ->
                                              [{Username, CIDR, Source, Options}|Acc];
                                         ({{_, _}, [?TOMBSTONE]}, Acc) ->
                                              Acc
                                      end, [], ?SOURCES_PREFIX(Uri)),

    do_print_sources(Sources).

%% @private
do_print_sources(Sources) ->
    GS = group_sources(Sources),
    juno_console_table:print([{users, 20}, {cidr, 10}, {source, 10}, {options, 10}],
                [[prettyprint_users(Users, 20), prettyprint_cidr(CIDR),
                  atom_to_list(Source), io_lib:format("~p", [Options])] ||
            {Users, CIDR, Source, Options} <- GS]).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec print_user(RealmUri :: uri(), Username :: string()) ->
    ok | {error, term()}.
print_user(RealmUri, User) ->
    Uri = name2bin(RealmUri),
    Name = name2bin(User),
    Details = user_details(Uri, Name),
    case Details of
        undefined ->
            {error, {unknown_user, Name}};
        _ ->
            print_users([{Name, [Details]}])
    end.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
print_users(RealmUri) ->
    Uri = name2bin(RealmUri),
    Users = plumtree_metadata:fold(fun({_Username, [?TOMBSTONE]}, Acc) ->
                                            Acc;
                                        ({Username, Options}, Acc) ->
                                    [{Username, Options}|Acc]
                            end, [], ?USERS_PREFIX(Uri)),
    do_print_users(Uri, Users).

%% @private
do_print_users(RealmUri, Users) ->
    juno_console_table:print([{username, 10}, {'member of', 15}, {password, 40}, {options, 30}],
                [begin
                     Groups = case proplists:get_value("groups", Options) of
                                 undefined ->
                                     "";
                                 List ->
                                     prettyprint_permissions([unicode:characters_to_list(R, utf8)
                                                              || R <- List,
                                                                 group_exists(RealmUri, R)], 20)
                             end,
                     Password = case proplists:get_value("password", Options) of
                                    undefined ->
                                        "";
                                    Pw ->
                                        proplists:get_value(hash_pass, Pw)
                                end,
                     OtherOptions = lists:keydelete("password", 1,
                                                    lists:keydelete("groups", 1,
                                                                    Options)),
                     [Username, Groups, Password,
                      lists:flatten(io_lib:format("~p", [OtherOptions]))]
                 end ||
            {Username, [Options]} <- Users]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec print_group(RealmUri :: uri(), Group :: string()) ->
    ok | {error, term()}.
print_group(RealmUri, Group) ->
    Name = name2bin(Group),
    Details = group_details(RealmUri, Name),
    case Details of
        undefined ->
            {error, {unknown_group, Name}};
        _ ->
            do_print_groups(RealmUri, [{Name, [Details]}])
    end.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
print_groups(RealmUri) ->
    Uri = name2bin(RealmUri),
    Groups = plumtree_metadata:fold(fun({_Groupname, [?TOMBSTONE]}, Acc) ->
                                             Acc;
                                        ({Groupname, Options}, Acc) ->
                                    [{Groupname, Options}|Acc]
                            end, [], ?GROUPS_PREFIX(Uri)),
    do_print_groups(RealmUri, Groups).

%% @private
do_print_groups(RealmUri, Groups) ->
    juno_console_table:print([{group, 10}, {'member of', 15}, {options, 30}],
                [begin
                     GroupOptions = case proplists:get_value("groups", Options) of
                                 undefined ->
                                     "";
                                 List ->
                                     prettyprint_permissions([unicode:characters_to_list(R, utf8)
                                                              || R <- List,
                                                                 group_exists(RealmUri, R)], 20)
                             end,
                     OtherOptions = lists:keydelete("groups", 1, Options),
                     [Groupname, GroupOptions,
                      lists:flatten(io_lib:format("~p", [OtherOptions]))]
                 end ||
            {Groupname, [Options]} <- Groups]).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec print_grants(RealmUri :: uri(), Rolename :: string()) ->
    ok | {error, term()}.
print_grants(RealmUri, RoleName) ->
    Uri = name2bin(RealmUri),
    Name = name2bin(RoleName),
    case is_prefixed(Name) of
        true ->
            print_grants(Uri, chop_name(Name), role_type(Uri, Name));
        false ->
            case { print_grants(Uri, Name, user), print_grants(Uri, Name, group) } of
                {{error, _}, {error, _}} ->
                    {error, {unknown_role, Name}};
                _ ->
                    ok
            end
    end.

print_grants(_, User, unknown) ->
    {error, {unknown_role, User}};
print_grants(RealmUri, User, user) ->
    case user_details(RealmUri, User) of
        undefined ->
            {error, {unknown_user, User}};
        _U ->
            Grants = accumulate_grants(RealmUri, User, user),

            juno_console_table:print(
              io_lib:format("Inherited permissions (user/~ts)", [User]),
              [{group, 20}, {type, 10}, {bucket, 10}, {grants, 40}],
                        [begin
                             case Bucket of
                                 any ->
                                     [chop_name(Username), "*", "*",
                                      prettyprint_permissions(Permissions, 40)];
                                 {T, B} ->
                                     [chop_name(Username), T, B,
                                      prettyprint_permissions(Permissions, 40)];
                                 T ->
                                     [chop_name(Username), T, "*",
                                      prettyprint_permissions(Permissions, 40)]
                             end
                         end ||
                         {{Username, Bucket}, Permissions} <- Grants, Username /= <<"user/", User/binary>>]),

            juno_console_table:print(
              io_lib:format("Dedicated permissions (user/~ts)", [User]),
              [{type, 10}, {bucket, 10}, {grants, 40}],
                        [begin
                             case Bucket of
                                 any ->
                                     ["*", "*",
                                      prettyprint_permissions(Permissions, 40)];
                                 {T, B} ->
                                     [T, B,
                                      prettyprint_permissions(Permissions, 40)];
                                 T ->
                                     [T, "*",
                                      prettyprint_permissions(Permissions, 40)]
                             end
                         end ||
                         {{Username, Bucket}, Permissions} <- Grants, Username == <<"user/", User/binary>>]),
            GroupedGrants = group_grants(Grants),

            juno_console_table:print(
              io_lib:format("Cumulative permissions (user/~ts)", [User]),
              [{type, 10}, {bucket, 10}, {grants, 40}],
                        [begin
                             case Bucket of
                                 any ->
                                     ["*", "*",
                                      prettyprint_permissions(Permissions, 40)];
                                 {T, B} ->
                                     [T, B,
                                      prettyprint_permissions(Permissions, 40)];
                                 T ->
                                     [T, "*",
                                      prettyprint_permissions(Permissions, 40)]
                             end
                         end ||
                         {Bucket, Permissions} <- GroupedGrants]),
            ok
    end;
print_grants(RealmUri, Group, group) ->
    case group_details(RealmUri, Group) of
        undefined ->
            {error, {unknown_group, Group}};
        _U ->
            Grants = accumulate_grants(RealmUri, Group, group),

            juno_console_table:print(
              io_lib:format("Inherited permissions (group/~ts)", [Group]),
              [{group, 20}, {type, 10}, {bucket, 10}, {grants, 40}],
                        [begin
                             case Bucket of
                                 any ->
                                     [chop_name(Groupname), "*", "*",
                                      prettyprint_permissions(Permissions, 40)];
                                 {T, B} ->
                                     [chop_name(Groupname), T, B,
                                      prettyprint_permissions(Permissions, 40)];
                                 T ->
                                     [chop_name(Groupname), T, "*",
                                      prettyprint_permissions(Permissions, 40)]
                             end
                         end ||
                         {{Groupname, Bucket}, Permissions} <- Grants, chop_name(Groupname) /= Group]),

            juno_console_table:print(
              io_lib:format("Dedicated permissions (group/~ts)", [Group]),
              [{type, 10}, {bucket, 10}, {grants, 40}],
                        [begin
                             case Bucket of
                                 any ->
                                     ["*", "*",
                                      prettyprint_permissions(Permissions, 40)];
                                 {T, B} ->
                                     [T, B,
                                      prettyprint_permissions(Permissions, 40)];
                                 T ->
                                     [T, "*",
                                      prettyprint_permissions(Permissions, 40)]
                             end
                         end ||
                         {{Groupname, Bucket}, Permissions} <- Grants, chop_name(Groupname) == Group]),
            GroupedGrants = group_grants(Grants),

            juno_console_table:print(
              io_lib:format("Cumulative permissions (group/~ts)", [Group]),
              [{type, 10}, {bucket, 10}, {grants, 40}],
                        [begin
                             case Bucket of
                                 any ->
                                     ["*", "*",
                                      prettyprint_permissions(Permissions, 40)];
                                 {T, B} ->
                                     [T, B,
                                      prettyprint_permissions(Permissions, 40)];
                                 T ->
                                     [T, "*",
                                      prettyprint_permissions(Permissions, 40)]
                             end
                         end ||
                         {Bucket, Permissions} <- GroupedGrants]),
            ok
    end.

prettyprint_permissions(Permissions, Width) ->
    prettyprint_permissions(lists:sort(Permissions), Width, []).

prettyprint_permissions([], _Width, Acc) ->
    string:join([string:join(Line, ", ") || Line <- lists:reverse(Acc)], ",\n");
prettyprint_permissions([Permission|Rest], Width, [H|T] =Acc) ->
    case length(Permission) + lists:flatlength(H) + 2 + (2 * length(H)) > Width of
        true ->
            prettyprint_permissions(Rest, Width, [[Permission] | Acc]);
        false ->
            prettyprint_permissions(Rest, Width, [[Permission|H]|T])
    end;
prettyprint_permissions([Permission|Rest], Width, Acc) ->
    prettyprint_permissions(Rest, Width, [[Permission] | Acc]).

-spec check_permission(Permission :: permission(), Context :: context()) ->
    {true, context()} | {false, binary(), context()}.
check_permission({Permission}, #context{realm_uri = Uri} = Context0) ->
    Context = maybe_refresh_context(Uri, Context0),
    %% The user needs to have this permission applied *globally*
    %% This is for things like mapreduce with undetermined inputs or
    %% permissions that don't tie to a particular bucket, like 'ping' and
    %% 'stats'.
    MatchG = match_grant(any, Context#context.grants),
    case lists:member(Permission, MatchG) of
        true ->
            {true, Context};
        false ->
            %% no applicable grant
            {false, unicode:characters_to_binary(
                      ["Permission denied: User '",
                       Context#context.username, "' does not have '",
                       Permission, "' on any"], utf8, utf8), Context}
    end;
check_permission({Permission, Bucket}, #context{realm_uri = Uri} = Context0) ->
    Context = maybe_refresh_context(Uri, Context0),
    MatchG = match_grant(Bucket, Context#context.grants),
    case lists:member(Permission, MatchG) of
        true ->
            {true, Context};
        false ->
            %% no applicable grant
            {false, unicode:characters_to_binary(
                      ["Permission denied: User '",
                       Context#context.username, "' does not have '",
                       Permission, "' on ",
                       bucket2iolist(Bucket)], utf8, utf8), Context}
    end.

check_permissions(Permission, Ctx) when is_tuple(Permission) ->
    %% single permission
    check_permission(Permission, Ctx);
check_permissions([], Ctx) ->
    {true, Ctx};
check_permissions([Permission|Rest], Ctx) ->
    case check_permission(Permission, Ctx) of
        {true, NewCtx} ->
            check_permissions(Rest, NewCtx);
        Other ->
            %% return non-standard result
            Other
    end.

get_username(#context{username=Username}) ->
    Username.

get_realm_uri(#context{realm_uri=Uri}) ->
    Uri.


get_grants(#context{grants=Val}) ->
    Val.


% -spec authenticate(
%     RealmUri :: uri(), 
%     Username::binary(), 
%     Password::binary(), 
%     ConnInfo :: [{atom(), any()}]) -> {ok, context()} | {error, term()}.
% authenticate(RealmUri, Username, Password, ConnInfo) ->
%     Uri = name2bin(RealmUri),
%     case user_details(RealmUri, Username) of
%         undefined ->
%             {error, unknown_user};
%         UserData ->
%             Sources0 = plumtree_metadata:fold(fun({{Un, CIDR}, [{Source, Options}]}, Acc) ->
%                                                       [{Un, CIDR, Source, Options}|Acc];
%                                                   ({{_, _}, [?TOMBSTONE]}, Acc) ->
%                                                        Acc
%                                               end, [], ?SOURCES_PREFIX(Uri)),
%             Sources = sort_sources(Sources0),
%             case match_source(Sources, Username,
%                               proplists:get_value(ip, ConnInfo)) of
%                 {ok, Source, SourceOptions} ->
%                     case Source of
%                         trust ->
%                             %% trust always authenticates
%                             {ok, get_context(Uri, Username)};
%                         password ->
%                             %% pull the password out of the userdata
%                             case lookup("password", UserData) of
%                                 undefined ->
%                                     lager:warning("User ~p is configured for "
%                                                   "password authentication, but has "
%                                                   "no password", [Username]),
%                                     {error, missing_password};
%                                 PasswordData ->
%                                     HashedPass = lookup(hash_pass, PasswordData),
%                                     HashFunction = lookup(hash_func, PasswordData),
%                                     Salt = lookup(salt, PasswordData),
%                                     Iterations = lookup(iterations, PasswordData),
%                                     case juno_pw_auth:check_password(Password,
%                                                                           HashedPass,
%                                                                           HashFunction,
%                                                                           Salt,
%                                                                           Iterations) of
%                                         true ->
%                                             {ok, get_context(Uri, Username)};
%                                         false ->
%                                             {error, bad_password}
%                                     end
%                             end;
%                         certificate ->
%                             case proplists:get_value(common_name, ConnInfo) of
%                                 undefined ->
%                                     {error, no_common_name};
%                                 CN ->
%                                     %% TODO postgres support a map from
%                                     %% common-name to username, should we?
%                                     case name2bin(CN) == Username of
%                                         true ->
%                                             {ok, get_context(Uri, Username)};
%                                         false ->
%                                             {error, common_name_mismatch}
%                                     end
%                             end;
%                         Source ->
%                             %% check for a dynamically registered auth module
%                             AuthMods = app_helper:get_env(juno,
%                                                           auth_mods, []),
%                             case proplists:get_value(Source, AuthMods) of
%                                 undefined ->
%                                     lager:warning("User ~p is configured with unknown "
%                                                   "authentication source ~p",
%                                                   [Username, Source]),
%                                     {error, unknown_source};
%                                 AuthMod ->
%                                     case AuthMod:auth(Username, Password,
%                                                       UserData, SourceOptions) of
%                                         ok ->
%                                             {ok, get_context(Uri, Username)};
%                                         error ->
%                                             {error, bad_password}
%                                     end
%                             end
%                     end;
%                 {error, Reason} ->
%                     {error, Reason}
%             end
%     end.


-spec authenticate(
    RealmUri :: uri(), 
    Username::binary(), 
    Password::binary() | {hash, binary()}, 
    ConnInfo :: [{atom(), any()}]) -> {ok, context()} | {error, term()}.

authenticate(RealmUri, Username, Password, ConnInfo) ->
    case user_details(RealmUri, Username) of
        undefined ->
            {error, unknown_user};
        Data ->
            M = #{
                username => name2bin(Username),
                password => Password,
                realm_uri => name2bin(RealmUri),
                conn_info => ConnInfo 
            },
            auth_with_data(Data, M)
    end.


%% @private
auth_with_data(UserData, M0) ->
    Uri = maps:get(realm_uri, M0),
    F = fun
        ({{Un, CIDR}, [{Source, Options}]}, Acc) ->
            [{Un, CIDR, Source, Options}|Acc];
        ({{_, _}, [?TOMBSTONE]}, Acc) ->
            Acc
    end,
    Sources0 = plumtree_metadata:fold(F, [], ?SOURCES_PREFIX(Uri)),
    Sources = sort_sources(Sources0),
    IP = proplists:get_value(ip, maps:get(conn_info, M0)),
    case match_source(Sources, maps:get(username, M0), IP) of
        {ok, Source, Opts} ->
            M1 = M0#{source_options => Opts},
            auth_with_source(Source, UserData, M1);
        {error, _} = Error ->
            Error
    end.


%% @private
auth_with_source(trust, _, M) ->
    %% trust always authenticates
    {ok, get_context(M)};

auth_with_source(password, UserData, M) ->
    % pull the password out of the userdata
    case lookup("password", UserData) of
        undefined ->
            lager:warning("User ~p is configured for "
                            "password authentication, but has "
                            "no password", [maps:get(username, M)]),
            {error, missing_password};
        PasswordData ->
            HashedPass = lookup(hash_pass, PasswordData),
            HashFunction = lookup(hash_func, PasswordData),
            Salt = lookup(salt, PasswordData),
            Iterations = lookup(iterations, PasswordData),
            case 
                juno_pw_auth:check_password(
                    maps:get(password, M),
                    HashedPass,
                    HashFunction,
                    Salt,
                    Iterations) 
            of
                true ->
                    {ok, get_context(M)};
                false ->
                    {error, bad_password}
            end
    end;

auth_with_source(certificate, _, M) ->
    case proplists:get_value(common_name, maps:get(conn_info, M)) of
        undefined ->
            {error, no_common_name};
        CN ->
            %% TODO postgres support a map from
            %% common-name to username, should we?
            case name2bin(CN) == maps:get(username, M) of
                true ->
                    {ok, get_context(M)};
                false ->
                    {error, common_name_mismatch}
            end
    end;

auth_with_source(Source, UserData, M) ->
    %% check for a dynamically registered auth module
    Opts = maps:get(source_options, M),
    AuthMods = app_helper:get_env(juno, auth_mods, []),
    Username = maps:get(username, M),
    case proplists:get_value(Source, AuthMods) of
        undefined ->
            lager:warning(
                "User ~p is configured with unknown "
                "authentication source ~p",
                [Username, Source]),
            {error, unknown_source};
        AuthMod ->
            Password = maps:get(password, M),
            case AuthMod:auth(Username, Password, UserData, Opts) of
                ok ->
                    {ok, get_context(M)};
                error ->
                    {error, bad_password}
            end
    end.




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add_user(
    RealmUri :: binary(), 
    Username :: string(), 
    Options :: [{string(), term()}]) ->
    ok | {error, term()}.
add_user(RealmUri, Username, Options) ->
    Uri = name2bin(RealmUri),
    FP = ?USERS_PREFIX(Uri),
    add_role(
        Uri, name2bin(Username), Options, fun user_exists/2, FP).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add_group(
    binary(), Groupname :: string(), Options :: [{string(), term()}]) ->
    ok | {error, term()}.
add_group(RealmUri, Groupname, Options) ->
    Uri = name2bin(RealmUri),
    add_role(Uri, name2bin(Groupname), Options, fun group_exists/2,
             ?GROUPS_PREFIX(Uri)).

%% @private
add_role(_, <<"all">>, _Options, _Fun, _Prefix) ->
    {error, reserved_name};
add_role(_, <<"on">>, _Options, _Fun, _Prefix) ->
    {error, reserved_name};
add_role(_, <<"to">>, _Options, _Fun, _Prefix) ->
    {error, reserved_name};
add_role(_, <<"from">>, _Options, _Fun, _Prefix) ->
    {error, reserved_name};
add_role(_, <<"any">>, _Options, _Fun, _Prefix) ->
    {error, reserved_name};
add_role(RealmUri, Name, Options, ExistenceFun, Prefix) ->
    Uri = name2bin(RealmUri),
    case illegal_name_chars(unicode:characters_to_list(Name, utf8)) of
        false ->
            case ExistenceFun(Uri, unicode:characters_to_list(Name, utf8)) of
                false ->
                    case validate_options(RealmUri, Options) of
                        {ok, NewOptions} ->
                            plumtree_metadata:put(Prefix, Name, NewOptions),
                            ok;
                        Error ->
                            Error
                    end;
                true ->
                    {error, role_exists}
            end;
        true ->
            {error, illegal_name_char}
    end.


-spec alter_user(
    RealmUri :: binary(), 
    Username :: string(), 
    Options :: [{string(), term()}]) ->
    ok | {error, term()}.
alter_user(_, "all", _Options) ->
    {error, reserved_name};
alter_user(RealmUri, Username, Options) ->
    Uri = name2bin(RealmUri),
    Name = name2bin(Username),
    case user_details(Uri, Name) of
        undefined ->
            {error, {unknown_user, Name}};
        UserData ->
            case validate_options(RealmUri, Options) of
                {ok, NewOptions} ->
                    MergedOptions = lists:ukeymerge(1, lists:sort(NewOptions),
                                                    lists:sort(UserData)),

                    plumtree_metadata:put(
                        ?USERS_PREFIX(Uri),Name, MergedOptions),
                    ok;
                Error ->
                    Error
            end
    end.

-spec alter_group(
    RealmUri :: binary(), 
    Groupname :: string(), 
    Options :: [{string(), term()}]) ->
    ok | {error, term()}.
alter_group(_, "all", _Options) ->
    {error, reserved_name};
alter_group(RealmUri, Groupname, Options) ->
    Uri = name2bin(RealmUri),
    Name = name2bin(Groupname),
    case group_details(Uri, Groupname) of
        undefined ->
            {error, {unknown_group, Name}};
        GroupData ->
            case validate_groups_option(Uri, Options) of
                {ok, NewOptions} ->
                    MergedOptions = lists:ukeymerge(1, lists:sort(NewOptions),
                                                    lists:sort(GroupData)),

                    plumtree_metadata:put(
                        ?GROUPS_PREFIX(Uri), Name, MergedOptions),
                    ok;
                Error ->
                    Error
            end
    end.

-spec del_user(RealmUri :: binary(), Username :: string()) ->
    ok | {error, term()}.
del_user(_, "all") ->
    {error, reserved_name};
del_user(RealmUri, Username) ->
    Uri = name2bin(RealmUri),
    Name = name2bin(Username),
    case user_exists(Uri, Name) of
        false ->
            {error, {unknown_user, Name}};
        true ->
            plumtree_metadata:delete(?USERS_PREFIX(RealmUri), Name),
            %% delete any associated grants, so if a user with the same name
            %% is added again, they don't pick up these grants
            Prefix = ?USER_GRANTS_PREFIX(Uri),
            plumtree_metadata:fold(fun({Key, _Value}, Acc) ->
                                            %% apparently destructive
                                            %% iteration is allowed
                                            plumtree_metadata:delete(Prefix, Key),
                                            Acc
                                    end, undefined,
                                    Prefix,
                                    [{match, {Name, '_'}}]),
            delete_user_from_sources(Uri, Name),
            ok
    end.

-spec del_group(RealmUri :: binary(), Groupname :: string()) ->
    ok | {error, term()}.
del_group(_, "all") ->
    {error, reserved_name};
del_group(RealmUri, Groupname) ->
    Uri = name2bin(RealmUri),
    Name = name2bin(Groupname),
    case group_exists(RealmUri, Name) of
        false ->
            {error, {unknown_group, Name}};
        true ->
            plumtree_metadata:delete(?GROUPS_PREFIX(Uri),
                                      Name),
            %% delete any associated grants, so if a user with the same name
            %% is added again, they don't pick up these grants
            Prefix = ?GROUP_GRANTS_PREFIX(Uri),
            plumtree_metadata:fold(fun({Key, _Value}, Acc) ->
                                            %% apparently destructive
                                            %% iteration is allowed
                                            plumtree_metadata:delete(Prefix, Key),
                                            Acc
                                    end, undefined,
                                    Prefix,
                                    [{match, {Name, '_'}}]),
            delete_group_from_roles(Uri, Name),
            ok
    end.

-spec add_grant(
    binary(), userlist(), bucket() | any, [string()]) -> ok | {error, term()}.
add_grant(RealmUri, all, Bucket, Grants) ->
    %% all is always valid
    case validate_permissions(Grants) of
        ok ->
            add_grant_int([{all, group}], RealmUri, bucket2bin(Bucket), Grants);
        Error ->
            Error
    end;
add_grant(RealmUri, RoleList, Bucket, Grants) ->
    RoleTypes = lists:map(
                  fun(Name) -> {chop_name(name2bin(Name)),
                                role_type(RealmUri, name2bin(Name))} end,
                  RoleList
                 ),

    UnknownRoles = lists:foldl(
                     fun({Name, unknown}, Accum) ->
                             Accum ++ [Name];
                        ({_Name, _Type}, Accum) ->
                             Accum
                     end,
                     [], RoleTypes),

    NameOverlaps = lists:foldl(
                     fun({Name, both}, Accum) ->
                             Accum ++ [Name];
                        ({_Name, _Type}, Accum) ->
                             Accum
                     end,
                     [], RoleTypes),

    case check_grant_blockers(UnknownRoles, NameOverlaps,
                              validate_permissions(Grants)) of
        none ->
            add_grant_int(RoleTypes, RealmUri, bucket2bin(Bucket), Grants);
        Error ->
            Error
    end.


-spec add_revoke(
    binary(), userlist(), bucket() | any, [string()]) -> ok | {error, term()}.
add_revoke(RealmUri, all, Bucket, Revokes) ->
    %% all is always valid
    case validate_permissions(Revokes) of
        ok ->
            add_revoke_int([{all, group}], RealmUri, bucket2bin(Bucket), Revokes);
        Error ->
            Error
    end;
add_revoke(RealmUri, RoleList, Bucket, Revokes) ->
    RoleTypes = lists:map(
                   fun(Name) -> {chop_name(name2bin(Name)),
                                 role_type(RealmUri, name2bin(Name))} end,
                   RoleList
                 ),

    UnknownRoles = lists:foldl(
                     fun({Name, unknown}, Accum) ->
                             Accum ++ [Name];
                        ({_Name, _Type}, Accum) ->
                             Accum
                     end,
                     [], RoleTypes),

    NameOverlaps = lists:foldl(
                     fun({Name, both}, Accum) ->
                             Accum ++ [Name];
                        ({_Name, _Type}, Accum) ->
                             Accum
                     end,
                     [], RoleTypes),

    case check_grant_blockers(UnknownRoles, NameOverlaps,
                              validate_permissions(Revokes)) of
        none ->
            add_revoke_int(RoleTypes, RealmUri, bucket2bin(Bucket), Revokes);
        Error ->
            Error
    end.

-spec add_source(
    RealmUri :: binary(), 
    userlist(), 
    CIDR :: {inet:ip_address(), non_neg_integer()},
    Source :: atom(),
    Options :: [{string(), term()}]) -> ok | {error, term()}.
add_source(RealmUri, all, CIDR, Source, Options) ->
    Uri = name2bin(RealmUri),
    %% all is always valid

    %% TODO check if there are already 'user' sources for this CIDR
    %% with the same source
    plumtree_metadata:put(
        ?SOURCES_PREFIX(Uri), {all, anchor_mask(CIDR)}, {Source, Options}),
    ok;

add_source(RealmUri, Users, CIDR, Source, Options) ->
    Uri = name2bin(RealmUri),
    UserList = lists:map(fun name2bin/1, Users),

    %% We only allow sources to be assigned to users, so don't check
    %% for valid group names
    UnknownUsers = unknown_roles(Uri, UserList, user),

    Valid = case UnknownUsers of
                [] ->
                    %% TODO check if there is already an 'all' source for this CIDR
                    %% with the same source
                    ok;
                _ ->
                    {error, {unknown_users, UnknownUsers}}
            end,

    case Valid of
        ok ->
            %% add a source for each user
            add_source_int(
                UserList, RealmUri, anchor_mask(CIDR), Source, Options),
            ok;
        Error ->
            Error
    end.

del_source(RealmUri, all, CIDR) ->
    Uri = name2bin(RealmUri),
    %% all is always valid
    plumtree_metadata:delete(?SOURCES_PREFIX(Uri), {all, anchor_mask(CIDR)}),
    ok;

del_source(RealmUri, Users, CIDR) ->
    Uri = name2bin(RealmUri),
    UserList = lists:map(fun name2bin/1, Users),
    _ = [plumtree_metadata:delete(
            ?SOURCES_PREFIX(Uri), {User, anchor_mask(CIDR)}) 
            || User <- UserList],
    ok.


is_enabled(RealmUri) ->
    Uri = name2bin(RealmUri),
    case plumtree_metadata:get(?STATUS_PREFIX(Uri), enabled) of
    true -> true;
    _ -> false
    end.


enable(RealmUri) ->
    Uri = name2bin(RealmUri),
    plumtree_metadata:put(?STATUS_PREFIX(Uri), enabled, true).


get_ciphers(RealmUri) ->
    Uri = name2bin(RealmUri),
    case plumtree_metadata:get(?CONFIG_PREFIX(Uri), ciphers) of
        undefined ->
            ?DEFAULT_CIPHER_LIST;
        Result ->
            Result
    end.

print_ciphers(RealmUri) ->
    Ciphers = get_ciphers(RealmUri),
    {Good, Bad} = parse_ciphers(Ciphers),
    io:format("Configured ciphers~n~n~s~n~n", [Ciphers]),
    io:format("Valid ciphers(~b)~n~n~s~n~n",
              [length(Good), do_print_ciphers(Good)]),
    case Bad of
        [] ->
            ok;
        _ ->
            io:format("Unknown/Unsupported ciphers(~b)~n~n~s~n~n",
                      [length(Bad), string:join(Bad, ":")])
    end.

set_ciphers(RealmUri, CipherList) ->
    Uri = name2bin(RealmUri),
    case parse_ciphers(CipherList) of
        {[], _} ->
            %% no valid ciphers
            io:format("No known or supported ciphers in list.~n"),
            error;
        _ ->
            plumtree_metadata:put(?CONFIG_PREFIX(Uri), ciphers,
                                   CipherList),
            ok
    end.

disable(RealmUri) ->
    Uri = name2bin(RealmUri),
    plumtree_metadata:put(?STATUS_PREFIX(Uri), enabled, false).

status(RealmUri) ->
    Uri = name2bin(RealmUri),
    Enabled = plumtree_metadata:get(
        ?STATUS_PREFIX(Uri), enabled, [{default, false}]),
    case Enabled of
        true ->
            enabled;
        _ ->
            disabled
    end.

%% ============
%% INTERNAL
%% ============

match_grants(Realm, Match, Type) ->
    Grants = plumtree_metadata:to_list(metadata_grant_prefix(Realm, Type),
                                        [{match, Match}]),
    [{Key, Val} || {Key, [Val]} <- Grants, Val /= ?TOMBSTONE].

metadata_grant_prefix(RealmUri, user) ->
    Uri = name2bin(RealmUri),
    ?USER_GRANTS_PREFIX(Uri);

metadata_grant_prefix(RealmUri, group) ->
    Uri = name2bin(RealmUri),
    ?GROUP_GRANTS_PREFIX(Uri).


add_revoke_int([], _, _, _) ->
    ok;
add_revoke_int([{Name, RoleType}|Roles], RealmUri, Bucket, Permissions) ->
    Prefix = metadata_grant_prefix(RealmUri, RoleType),
    RoleGrants = plumtree_metadata:get(Prefix, {Name, Bucket}),

    %% check if there is currently a GRANT we can revoke
    case RoleGrants of
        undefined ->
            %% can't REVOKE what wasn't GRANTED
            add_revoke_int(Roles, RealmUri, Bucket, Permissions);
        GrantedPermissions ->
            NewPerms = [X || X <- GrantedPermissions, not lists:member(X,
                                                                       Permissions)],

            %% TODO - do deletes here, once cluster metadata supports it for
            %% real, if NewPerms == []

            case NewPerms of
                [] ->
                    plumtree_metadata:delete(Prefix, {Name, Bucket});
                _ ->
                    plumtree_metadata:put(Prefix, {Name, Bucket}, NewPerms)
            end,
            add_revoke_int(Roles, RealmUri, Bucket, Permissions)
    end.

add_source_int([], _, _, _, _) ->
    ok;
add_source_int(Users, RealmUri, CIDR, Source, Options) when is_list(RealmUri) ->
    add_source_int(Users, name2bin(RealmUri), CIDR, Source, Options);

add_source_int([User|Users], Uri, CIDR, Source, Options) ->
    plumtree_metadata:put(
        ?SOURCES_PREFIX(Uri), {User, CIDR}, {Source, Options}),
    add_source_int(Users, Uri, CIDR, Source, Options).

add_grant_int([], _, _, _) ->
    ok;
add_grant_int([{Name, RoleType}|Roles], RealmUri, Bucket, Permissions) ->
    Prefix = metadata_grant_prefix(RealmUri, RoleType),
    BucketPermissions = case plumtree_metadata:get(Prefix, {Name, Bucket}) of
                            undefined ->
                                [];
                            Perms ->
                                Perms
                        end,
    NewPerms = lists:umerge(lists:sort(BucketPermissions),
                            lists:sort(Permissions)),
    plumtree_metadata:put(Prefix, {Name, Bucket}, NewPerms),
    add_grant_int(Roles, RealmUri, Bucket, Permissions).

match_grant(Bucket, Grants) ->
    AnyGrants = proplists:get_value(any, Grants, []),
    %% find the first grant that matches the bucket name and then merge in the
    %% 'any' grants, if any
    lists:umerge(lists:sort(lists:foldl(fun({B, P}, Acc) when Bucket == B ->
                        P ++ Acc;
                   ({B, P}, Acc) when element(1, Bucket) == B ->
                        %% wildcard match against bucket type
                        P ++ Acc;
                   (_, Acc) ->
                        Acc
                end, [], Grants)), lists:sort(AnyGrants)).

maybe_refresh_context(RealmUri, Context) ->
    %% TODO replace this with a cluster metadata hash check, or something
    Epoch = os:timestamp(),
    case timer:now_diff(Epoch, Context#context.epoch) < ?REFRESH_TIME of
        false ->
            %% context has expired
            get_context(RealmUri, Context#context.username);
        _ ->
            Context
    end.

concat_role(user, Name) ->
    <<"user/", Name/binary>>;
concat_role(group, Name) ->
    <<"group/", Name/binary>>.


%% Contexts are only valid until the GRANT epoch changes, and it will change
%% whenever a GRANT or a REVOKE is performed. This is a little coarse grained
%% right now, but it'll do for the moment.
get_context(RealmUri, Username) when is_binary(Username) ->
    Grants = group_grants(accumulate_grants(RealmUri, Username, user)),
    #context{
        realm_uri = name2bin(RealmUri), 
        username=Username, 
        grants=Grants, 
        epoch=os:timestamp()}.


get_context(#{username := U, realm_uri := R}) ->
    get_context(R, U).


accumulate_grants(RealmUri, Role, Type) ->
    %% The 'all' grants always apply
    All = lists:map(fun ({{_Role, Bucket}, Permissions}) ->
                            {{<<"group/all">>, Bucket}, Permissions}
                    end, match_grants(RealmUri, {all, '_'}, group)),
    {Grants, _Seen} = accumulate_grants([Role], [], All, Type, RealmUri),
    lists:flatten(Grants).


accumulate_grants([], Seen, Acc, _Type, _) ->
    {Acc, Seen};
accumulate_grants([Role|Roles], Seen, Acc, Type, RealmUri) ->
    Options = role_details(RealmUri, Role, Type),
    Groups = [G || G <- lookup("groups", Options, []),
                        not lists:member(G,Seen),
                        group_exists(RealmUri, G)],
    {NewAcc, NewSeen} = accumulate_grants(
        Groups, [Role|Seen], Acc, group, RealmUri),

    Grants = lists:map(fun ({{_Role, Bucket}, Permissions}) ->
                               {{concat_role(Type, Role), Bucket}, Permissions}
                       end, match_grants(RealmUri, {Role, '_'}, Type)),
    accumulate_grants(Roles, NewSeen, [Grants|NewAcc], Type, RealmUri).


%% lookup a key in a list of key/value tuples. Like proplists:get_value but
%% faster.
lookup(Key, List, Default) ->
    case lists:keyfind(Key, 1, List) of
        false ->
            Default;
        {Key, Value} ->
            Value
    end.

lookup(Key, List) ->
    lookup(Key, List, undefined).

stash(Key, Value, List) ->
    lists:keystore(Key, 1, List, Value).

%% @doc Get the subnet mask as an integer, stolen from an old post on
%%      erlang-questions.
mask_address(Addr={_, _, _, _}, Maskbits) ->
    B = list_to_binary(tuple_to_list(Addr)),
    <<Subnet:Maskbits, _Host/bitstring>> = B,
    Subnet;
mask_address({A, B, C, D, E, F, G, H}, Maskbits) ->
    <<Subnet:Maskbits, _Host/bitstring>> = <<A:16, B:16, C:16, D:16, E:16,
                                             F:16, G:16, H:16>>,
    Subnet.

%% @doc returns the real bottom of a netmask. Eg if 192.168.1.1/16 is
%% provided, return 192.168.0.0/16
anchor_mask(Addr={_, _, _, _}, Maskbits) ->
    M = mask_address(Addr, Maskbits),
    Rem = 32 - Maskbits,
    <<A:8, B:8, C:8, D:8>> = <<M:Maskbits, 0:Rem>>,
    {{A, B, C, D}, Maskbits};
anchor_mask(Addr={_, _, _, _, _, _, _, _}, Maskbits) ->
    M = mask_address(Addr, Maskbits),
    Rem = 128 - Maskbits,
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>> = <<M:Maskbits, 0:Rem>>,
    {{A, B, C, D, E, F, G, H}, Maskbits}.

anchor_mask({Addr, Mask}) ->
    anchor_mask(Addr, Mask).

prettyprint_cidr({Addr, Mask}) ->
    io_lib:format("~s/~B", [inet_parse:ntoa(Addr), Mask]).



validate_options(RealmUri, Options) ->
    %% Check if password is an option
    case lookup("password", Options) of
        undefined ->
            validate_groups_option(RealmUri, Options);
        Pass ->
            {ok, NewOptions} = validate_password_option(Pass, Options),
            validate_groups_option(RealmUri, NewOptions)
    end.

validate_groups_option(RealmUri, Options) ->
    case lookup("groups", Options) of
        undefined ->
            {ok, Options};
        GroupStr ->
            %% Don't let the admin assign "all" as a container
            Groups= [name2bin(G) ||
                        G <- string:tokens(GroupStr, ","), G /= "all"],

            case unknown_roles(RealmUri, Groups, group) of
                [] ->
                    {ok, stash("groups", {"groups", Groups},
                               Options)};
                UnknownGroups ->
                    {error, {unknown_groups, UnknownGroups}}
            end
    end.

%% Handle 'password' option if given
validate_password_option(Pass, Options) ->
    {ok, HashedPass, AuthName, HashFunction, Salt, Iterations} =
        juno_pw_auth:hash_password(list_to_binary(Pass)),
    NewOptions = stash("password", {"password",
                                    [{hash_pass, HashedPass},
                                     {auth_name, AuthName},
                                     {hash_func, HashFunction},
                                     {salt, Salt},
                                     {iterations, Iterations}]},
                       Options),
    {ok, NewOptions}.


validate_permissions(Perms) ->
    KnownPermissions = app_helper:get_env(juno, permissions, []),
    validate_permissions(Perms, KnownPermissions).

validate_permissions([], _) ->
    ok;
validate_permissions([Perm|T], Known) ->
    case string:tokens(Perm, ".") of
        [App, P] ->
            try {list_to_existing_atom(App), list_to_existing_atom(P)} of
                {AppAtom, PAtom} ->
                    case lists:member(PAtom, lookup(AppAtom, Known, [])) of
                        true ->
                            validate_permissions(T, Known);
                        false ->
                            {error, {unknown_permission, Perm}}
                    end
            catch
                error:badarg ->
                    {error, {unknown_permission, Perm}}
            end;
        _ ->
            {error, {unknown_permission, Perm}}
    end.

match_source([], _User, _PeerIP) ->
    {error, no_matching_sources};
match_source([{UserName, {IP,Mask}, Source, Options}|Tail], User, PeerIP) ->
    case (UserName == all orelse
          UserName == User) andalso
        mask_address(IP, Mask) == mask_address(PeerIP, Mask) of
        true ->
            {ok, Source, Options};
        false ->
            match_source(Tail, User, PeerIP)
    end.

sort_sources(Sources) ->
    %% sort sources first by userlist, so that 'all' matches come last
    %% and then by CIDR, so that most sprcific masks come first
    Sources1 = lists:sort(fun({UserA, _, _, _}, {UserB, _, _, _}) ->
                    case {UserA, UserB} of
                        {all, all} ->
                            true;
                        {all, _} ->
                            %% anything is greater than 'all'
                            true;
                        {_, all} ->
                            false;
                        {_, _} ->
                            true
                    end
            end, Sources),
    lists:sort(fun({_, {_, MaskA}, _, _}, {_, {_, MaskB}, _, _}) ->
                MaskA > MaskB
        end, Sources1).

%% group users sharing the same CIDR/Source/Options
group_sources(Sources) ->
    D = lists:foldl(fun({User, CIDR, Source, Options}, Acc) ->
                dict:append({CIDR, Source, Options}, User, Acc)
        end, dict:new(), Sources),
    R1 = [{Users, CIDR, Source, Options} || {{CIDR, Source, Options}, Users} <-
                                       dict:to_list(D)],
    %% Split any entries where the user list contains (but is not
    %% exclusively) 'all' so that 'all' has its own entry. We could
    %% actually elide any user sources that overlap with an 'all'
    %% source, but that may be more confusing because deleting the all
    %% source would then 'resurrect' the user sources.
    R2 = lists:foldl(fun({Users, CIDR, Source, Options}=E, Acc) ->
                    case Users =/= [all] andalso lists:member(all, Users) of
                        true ->
                            [{[all], CIDR, Source, Options},
                             {Users -- [all], CIDR, Source, Options}|Acc];
                        false ->
                            [E|Acc]
                    end
            end, [], R1),
    %% sort the result by the same criteria that sort_sources uses
    R3 = lists:sort(fun({UserA, _, _, _}, {UserB, _, _, _}) ->
                    case {UserA, UserB} of
                        {[all], [all]} ->
                            true;
                        {[all], _} ->
                            %% anything is greater than 'all'
                            true;
                        {_, [all]} ->
                            false;
                        {_, _} ->
                            true
                    end
            end, R2),
    lists:sort(fun({_, {_, MaskA}, _, _}, {_, {_, MaskB}, _, _}) ->
                MaskA > MaskB
        end, R3).

group_grants(Grants) ->
    D = lists:foldl(fun({{_Role, Bucket}, G}, Acc) ->
                dict:append(Bucket, G, Acc)
        end, dict:new(), Grants),
    [{Bucket, lists:usort(flatten_once(P))} || {Bucket, P} <- dict:to_list(D)].

flatten_once(List) ->
    lists:foldl(fun(A, Acc) ->
                        A ++ Acc
                end, [], List).

check_grant_blockers([], [], ok) ->
    none;
check_grant_blockers([], [], {error, Error}) ->
    {error, Error};
check_grant_blockers(UnknownRoles, [], ok) ->
    {error, {unknown_roles, UnknownRoles}};
check_grant_blockers([], NameOverlaps, ok) ->
    {error, {duplicate_roles, NameOverlaps}};
check_grant_blockers(UnknownRoles, NameOverlaps, ok) ->
    {errors, [{unknown_roles, UnknownRoles},
             {duplicate_roles, NameOverlaps}]};
check_grant_blockers(UnknownRoles, [], {error, Error}) ->
    {errors, [{unknown_roles, UnknownRoles}, Error]};
check_grant_blockers([], NameOverlaps, {error, Error}) ->
    {errors, [{duplicate_roles, NameOverlaps},
              Error]};
check_grant_blockers(UnknownRoles, NameOverlaps, {error, Error}) ->
    {errors, [{unknown_roles, UnknownRoles},
             {duplicate_roles, NameOverlaps},
              Error]}.



delete_group_from_roles(RealmUri, Groupname) ->
    %% delete the group out of any user or group's 'roles' option
    %% this is kind of a pain, as we have to iterate ALL roles
    delete_group_from_roles(RealmUri, Groupname, <<"users">>),
    delete_group_from_roles(RealmUri, Groupname, <<"groups">>).

delete_group_from_roles(RealmUri, Groupname, RoleType) ->
    Uri = name2bin(RealmUri),
    FP  = ?FULL_PREFIX(Uri, <<"security">>, RoleType),
    plumtree_metadata:fold(fun({_, [?TOMBSTONE]}, Acc) ->
                                    Acc;
                               ({Rolename, [Options]}, Acc) ->
                                    case proplists:get_value("groups", Options) of
                                        undefined ->
                                            Acc;
                                        Groups ->
                                            case lists:member(Groupname,
                                                              Groups) of
                                                true ->
                                                    NewGroups = lists:keystore("groups", 1, Options, {"groups", Groups -- [Groupname]}),
                                                    plumtree_metadata:put(
                                                        FP, Rolename, NewGroups),
                                                    Acc;
                                                false ->
                                                    Acc
                                            end
                                    end
                            end, undefined,
                            FP).


delete_user_from_sources(RealmUri, Username) ->
    Uri = name2bin(RealmUri),
    FP  = ?SOURCES_PREFIX(Uri),
    plumtree_metadata:fold(fun({{User, _CIDR}=Key, _}, Acc)
                                  when User == Username ->
                                    plumtree_metadata:delete(FP, Key),
                                    Acc;
                               ({{_, _}, _}, Acc) ->
                                    Acc
                            end, [], FP).

%%%% Role identification functions

%% Take a list of roles (users or groups) and return any that can't
%% be found.
unknown_roles(RealmUri, RoleList, user) ->
    unknown_roles(RealmUri, RoleList, <<"users">>);

unknown_roles(RealmUri, RoleList, group) ->
    unknown_roles(RealmUri, RoleList, <<"groups">>);

unknown_roles(RealmUri, RoleList, RoleType) ->
    Uri = name2bin(RealmUri),
    FP = ?FULL_PREFIX(Uri, <<"security">>, RoleType),
    plumtree_metadata:fold(fun({Rolename, _}, Acc) ->
                                    Acc -- [Rolename]
                            end, RoleList, FP).

user_details(RealmUri, U) ->
    role_details(RealmUri, U, user).

group_details(RealmUri, G) ->
    role_details(RealmUri, G, group).

is_prefixed(<<"user/", _Name/binary>>) ->
    true;
is_prefixed(<<"group/", _Name/binary>>) ->
    true;
is_prefixed(_) ->
    false.

chop_name(<<"user/", Name/binary>>) ->
    Name;
chop_name(<<"group/", Name/binary>>) ->
    Name;
chop_name(Name) ->
    Name.

%% When we need to know whether a role name is a group or user (or
%% both), use this
role_type(RealmUri, <<"user/", Name/binary>>) ->
    do_role_type(role_details(RealmUri, Name, user),
              undefined);
role_type(RealmUri, <<"group/", Name/binary>>) ->
    do_role_type(undefined,
              role_details(RealmUri, Name, group));
role_type(RealmUri, Name) ->
    do_role_type(role_details(RealmUri, Name, user),
              role_details(RealmUri, Name, group)).

%% @private
do_role_type(undefined, undefined) ->
    unknown;
do_role_type(_UserDetails, undefined) ->
    user;
do_role_type(undefined, _GroupDetails) ->
    group;
do_role_type(_UserDetails, _GroupDetails) ->
    both.


role_details(RealmUri, Rolename, user) ->
    role_details(RealmUri, Rolename, <<"users">>);
role_details(RealmUri, Rolename, group) ->
    role_details(RealmUri, Rolename, <<"groups">>);
role_details(RealmUri, Rolename, RoleType) ->
    Uri = name2bin(RealmUri),
    FullPrefix = ?FULL_PREFIX(Uri, <<"security">>, RoleType),
    plumtree_metadata:get(FullPrefix, name2bin(Rolename)).

user_exists(RealmUri, Username) ->
    role_exists(RealmUri, Username, user).

group_exists(RealmUri, Groupname) ->
    role_exists(RealmUri, Groupname, group).

role_exists(RealmUri, Rolename, user) ->
    role_exists(RealmUri, Rolename, <<"users">>);
role_exists(RealmUri, Rolename, group) ->
    role_exists(RealmUri, Rolename, <<"groups">>);
role_exists(RealmUri, Rolename, RoleType) ->
    case role_details(RealmUri, Rolename, RoleType) of
        undefined ->
            false;
        _ -> true
    end.

illegal_name_chars(Name) ->
    [Name] =/= string:tokens(Name, ?ILLEGAL).

bin2name(Bin) when is_binary(Bin) ->
    unicode:characters_to_list(Bin, utf8);
%% 'all' can be stored in a grant instead of a binary name
bin2name(Name) when is_atom(Name) ->
    Name.

%% Rather than introduce yet another dependency to Riak this late in
%% the 2.0 cycle, we'll live with string:to_lower/1. It will lowercase
%% any latin1 characters. We can look at a better library to handle
%% more of the unicode space later.
name2bin(Name) when is_binary(Name) ->
    Name;
name2bin(Name) ->
    unicode:characters_to_binary(string:to_lower(Name), utf8, utf8).

bucket2bin(any) ->
    any;
bucket2bin({Type, Bucket}) ->
    { unicode:characters_to_binary(Type, utf8, utf8),
      unicode:characters_to_binary(Bucket, utf8, utf8)};
bucket2bin(Name) ->
    unicode:characters_to_binary(Name, utf8, utf8).

bucket2iolist({Type, Bucket}) ->
    [unicode:characters_to_binary(Type, utf8, utf8), "/",
     unicode:characters_to_binary(Bucket, utf8, utf8)];
bucket2iolist(Bucket) ->
     unicode:characters_to_binary(Bucket, utf8, utf8).





%% =============================================================================
%% THE FOLLOWING IS EXTRACTED FROM 
%% https://github.com/basho/riak_core/blob/develop/src/riak_core_ssl_util.erl
%% =============================================================================




%% Takes a list of openssl style cipher names and converts them to erlang
%% cipher names. Returns a 2-tuple of the supported and unknown/unsupported
%% suites.
parse_ciphers(CipherList) ->
    {Good, Bad} = lists:foldl(fun(Cipher, {Acc, Unknown}) ->
                        try ssl_cipher:openssl_suite(Cipher) of
                            C ->
                                {[C|Acc], Unknown}
                        catch
                            _:_ ->
                                %% function will function_clause on
                                %% unsupported/unknown ciphers
                                {Acc, [Cipher|Unknown]}
                        end
                end, {[], []},  string:tokens(CipherList, ":")),
    {lists:reverse(Good), lists:reverse(Bad)}.

%% print the OpenSSL name for ciphers
do_print_ciphers(CipherList) ->
    string:join([ssl_cipher:openssl_suite_name(Cipher) || Cipher <-
                                                          CipherList], ":").




%% =============================================================================
%% ADDED BY US
%% =============================================================================

-spec lookup_user(binary(), binary()) -> tuple() | not_found.
lookup_user(RealmUri, Username) when is_binary(RealmUri), is_binary(Username) ->
    case plumtree_metadata:get(?USERS_PREFIX(RealmUri), Username) of
        undefined -> not_found;
        Val -> {Username, Val}
    end.

-spec lookup_group(binary(), binary()) -> tuple() | not_found.
lookup_group(RealmUri, Name) when is_binary(Name) ->
    case plumtree_metadata:get(?GROUPS_PREFIX(RealmUri), Name) of
        undefined -> not_found;
        Val -> {Name, Val}
    end.


-spec list(binary(), user | group) -> list().
list(RealmUri, user) when is_binary(RealmUri) ->
    plumtree_metadata:fold(
        fun
            ({_Username, [?TOMBSTONE]}, Acc) ->
                Acc;
            ({Username, Options}, Acc) ->
                [{Username, Options}|Acc]
        end, 
        [], 
        ?USERS_PREFIX(RealmUri)
    );

list(RealmUri, group) when is_binary(RealmUri) ->
    plumtree_metadata:fold(
        fun
            ({_Groupname, [?TOMBSTONE]}, Acc) ->
                Acc;
            ({Groupname, Options}, Acc) ->
            [{Groupname, Options}|Acc]
        end, 
        [], 
        ?GROUPS_PREFIX(RealmUri)
    );

list(RealmUri, source) when is_binary(RealmUri) ->
    plumtree_metadata:fold(
        fun
            ({{Username, CIDR}, [{Source, Options}]}, Acc) ->
                [{Username, CIDR, Source, Options}|Acc];
            ({{_, _}, [?TOMBSTONE]}, Acc) ->
                Acc
        end, 
        [], 
        ?SOURCES_PREFIX(RealmUri)
    ).


lookup_user_sources(RealmUri, Username) when is_binary(RealmUri) ->
    L = plumtree_metadata:to_list(
        ?SOURCES_PREFIX(RealmUri), [{match, {name2bin(Username), '_'}}]),
    Pred = fun({_, [?TOMBSTONE]}) -> false; (_) -> true end,
    case lists:filter(Pred, L) of
        L -> 
            [{BinName, CIDR, Source, Options} || 
                {{BinName, CIDR}, [{Source, Options}]} <- L];
        [] -> 
            not_found
    end.

%% @private
user_groups(RealmUri, {_, Opts}) ->
    [R || 
        R <- proplists:get_value("groups", Opts, []), 
        group_exists(RealmUri, R)].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
user_grants(RealmUri, Username) ->
    accumulate_grants(RealmUri, Username, user).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
group_grants(RealmUri, Group) ->
    accumulate_grants(RealmUri, Group, group).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
context_to_map(#context{} = Ctxt) ->
    #context{
        realm_uri = Uri, 
        username = Username, 
        grants = Grants, 
        epoch = E
    } = Ctxt,
    #{
        realm_uri => Uri, 
        username => Username, 
        grants => Grants,
        timestamp => E
    }.



