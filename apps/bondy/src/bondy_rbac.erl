%% =============================================================================
%%  bondy_rbac.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
%%  Copyright (c) 2013 Basho Technologies, Inc.
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

%% -----------------------------------------------------------------------------
%% @doc
%% ### WAMP Permissions:
%%
%% * "wamp.register"
%% * "wamp.unregister"
%% * "wamp.call"
%% * "wamp.cancel"
%% * "wamp.subscribe"
%% * "wamp.unsubscribe"
%% * "wamp.publish"
%% * "wamp.disclose_caller"
%% * "wamp.disclose_publisher"
%%
%% ### Reserved Names
%% Reserved names are role (user or group) or resource names that act as
%% keywords in RBAC in either binary or atom forms and thus cannot be used.
%%
%% The following is the list of all reserved names.
%%
%% * all - group
%% * anonymous - the anonymous user and group
%% * any - use to denote a resource
%% * from - use to denote a resource
%% * on - not used
%% * to - use to denote a resource
%%
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_rbac).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-ifdef(TEST).
-define(REFRESH_TIME, 1).
-else.
-define(REFRESH_TIME, 1000).
-endif.

-record(bondy_rbac_context, {
    realm_uri               ::  binary(),
    username                ::  binary(),
    permissions             ::  [bondy_rbac_policy:permission()],
    epoch                   ::  erlang:timestamp(),
    is_anonymous = false    ::  boolean()
}).

-type context() :: #bondy_rbac_context{}.

%% type exports
-export_type([context/0]).

-export([authorize/3]).
-export([get_anonymous_context/1]).
-export([get_anonymous_context/2]).
-export([get_context/1]).
-export([get_context/2]).
-export([is_reserved_name/1]).
-export([normalize_name/1]).



%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc Returns 'ok' or an exception.
%% @end
%% -----------------------------------------------------------------------------
-spec authorize(binary(), binary(), bondy_context:t()) ->
    ok | no_return().

authorize(Permission, Resource, Ctxt) ->
    case bondy_context:is_security_enabled(Ctxt) of
        true ->
            %% TODO We need to cache the RBAC Context in the Bondy Context
            SecurityCtxt = get_context(Ctxt),
            do_authorize(Permission, Resource, SecurityCtxt);
        false ->
            ok
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_context(Ctxt :: bondy_context:t()) -> context().

get_context(Ctxt) ->
    case bondy_context:is_anonymous(Ctxt) of
        true ->
            get_anonymous_context(Ctxt);
        false ->
            AuthId = bondy_context:authid(Ctxt),
            RealmUri = bondy_context:realm_uri(Ctxt),
            get_context(RealmUri, AuthId)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_anonymous_context(Ctxt :: bondy_context:t()) -> context().

get_anonymous_context(Ctxt) ->
    case bondy_config:get([security, allow_anonymous_user], true) of
        true ->
            AuthId = bondy_context:authid(Ctxt),
            RealmUri = bondy_context:realm_uri(Ctxt),
            get_anonymous_context(RealmUri, AuthId);
        false ->
            error({not_authorized, <<"Anonymous user not allowed.">>})
    end.


%% -----------------------------------------------------------------------------
%% @doc Contexts are only valid until the GRANT epoch changes, and it will
%% change whenever a GRANT or a REVOKE is performed. This is a little coarse
%% grained right now, but it'll do for the moment.
%% @end
%% -----------------------------------------------------------------------------

get_context(RealmUri, Username)
when is_binary(Username) orelse Username == anonymous ->
    #bondy_rbac_context{
        realm_uri = RealmUri,
        username = Username,
        permissions = bondy_rbac_policy:permissions(RealmUri, Username, user),
        epoch = erlang:timestamp(),
        is_anonymous = Username == anonymous
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
get_anonymous_context(RealmUri, Username) ->
    #bondy_rbac_context{
        realm_uri = RealmUri,
        username = Username,
        permissions = bondy_rbac_policy:permissions(RealmUri, anonymous, group),
        epoch = erlang:timestamp(),
        is_anonymous = true
    }.


%% -----------------------------------------------------------------------------
%% @doc Returns true if term is a reserved name in binary or atom form.
%%
%% **Reserved names:**
%%
%% * all
%% * anonymous
%% * any
%% * from
%% * on
%% * to
%%
%% @end
%% -----------------------------------------------------------------------------
-spec is_reserved_name(Term :: binary() | atom()) -> boolean() | no_return().

is_reserved_name(Term) when is_binary(Term) ->
    try binary_to_existing_atom(Term, utf8) of
        Atom -> is_reserved_name(Atom)
    catch
        _:_ ->
            false
    end;

is_reserved_name(anonymous) ->
    true;

is_reserved_name(all) ->
    true;

is_reserved_name(on) ->
    true;

is_reserved_name(to) ->
    true;

is_reserved_name(from) ->
    true;

is_reserved_name(any) ->
    true;

is_reserved_name(Term) when is_atom(Term) ->
    false;

is_reserved_name(_) ->
    error(invalid_name).


%% -----------------------------------------------------------------------------
%% @doc Normalizes the utf8 binary `Bin' into a Normalized Form of compatibly
%% equivalent Decomposed characters according to the Unicode standard and
%% converts it to a case-agnostic comparable string.
%%
%% @end
%% -----------------------------------------------------------------------------
-spec normalize_name(Term :: binary() | atom()) -> boolean() | no_return().

normalize_name(Bin) when is_binary(Bin) ->
    string:casefold(unicode:characters_to_nfkd_binary(Bin)).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_authorize(Permission, Resource, SecCtxt) ->
    %% We could be cashing the security ctxt,
    %% the data is in ets so it should be pretty fast.
    case check_permission({Permission, Resource}, SecCtxt) of
        {true, _SecCtxt1} ->
            ok;
        {false, Mssg, _SecCtxt1} ->
            error({not_authorized, Mssg})
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec check_permission(
    Permission :: bondy_rbac_policy:permission(), Context :: context()) ->
    {true, context()} | {false, binary(), context()}.

check_permission({Permission}, #bondy_rbac_context{realm_uri = Uri} = Context0) ->
    Context = maybe_refresh_context(Uri, Context0),
    %% The user needs to have this permission applied *globally*
    %% This is for things with undetermined inputs or
    %% permissions that don't tie to a particular resource, like 'ping' and
    %% 'stats'.
    MatchG = match_grants(any, Context#bondy_rbac_context.permissions),
    case lists:member(Permission, MatchG) of
        true ->
            {true, Context};
        false ->
            %% no applicable grant
            Mssg = permission_denied_message(Permission, any, Context),
            {false, Mssg, Context}
    end;

check_permission(
    {Permission, Resource}, #bondy_rbac_context{realm_uri = Uri} = Ctxt0) ->
    Ctxt = maybe_refresh_context(Uri, Ctxt0),
    MatchG = match_grants(Resource, Ctxt#bondy_rbac_context.permissions),
    case lists:member(Permission, MatchG) of
        true ->
            {true, Ctxt};
        false ->
            %% no applicable grant
            Mssg = permission_denied_message(Permission, Resource, Ctxt),
            {false, Mssg, Ctxt}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
% check_permissions(Permission, Ctx) when is_tuple(Permission) ->
%     %% single permission
%     check_permission(Permission, Ctx);

% check_permissions([], Ctx) ->
%     {true, Ctx};

% check_permissions([Permission|Rest], Ctx) ->
%     case check_permission(Permission, Ctx) of
%         {true, NewCtx} ->
%             check_permissions(Rest, NewCtx);
%         Other ->
%             %% return non-standard result
%             Other
%     end.


%% @private
maybe_refresh_context(RealmUri, Context) ->
    %% TODO replace this with a cluster metadata hash check, or something
    Epoch = erlang:timestamp(),
    Diff = timer:now_diff(Epoch, Context#bondy_rbac_context.epoch),

    case Diff < ?REFRESH_TIME of
        false when Context#bondy_rbac_context.is_anonymous ->
            %% context has expired
            get_anonymous_context(
                RealmUri, Context#bondy_rbac_context.username
            );
        false ->
            %% context has expired
            get_context(RealmUri, Context#bondy_rbac_context.username);
        _ ->
            Context
    end.


%% @private
match_grants(Resource, Grants) ->
    match_grants(Resource, Grants, []).


%% @private
match_grants(any, Grants, Acc) ->
    case lists:keyfind(any, 1, Grants) of
        {any, Permissions} ->
            Acc ++ Permissions;
        false ->
            Acc
    end;

match_grants(Resource, Grants, Acc) ->
    %% find the first grant that matches the resource name
    %% and then merge in the 'any' grants, if any
    Fun = fun
        ({{Uri, Strategy}, Permissions}, IAcc) ->
            case wamp_uri:match(Resource, Uri, Strategy) of
                true ->
                    Permissions ++ IAcc;
                false ->
                    IAcc
            end;
        (_, IAcc) ->
            IAcc
    end,
    lists:umerge(
        lists:sort(lists:foldl(Fun, Acc, Grants)),
        lists:sort(match_grants(any, Grants))
    ).


%% @private
to_bin(anonymous) -> <<"anonymous">>;
to_bin(Bin) when is_binary(Bin) -> Bin.



%% @private
resource_to_iolist({Type, Bucket}) ->
    [Type, "/", Bucket];
resource_to_iolist(any) ->
    "any";
resource_to_iolist(Bucket) ->
    Bucket.


%% @private
permission_denied_message(
    Permission, Resource, #bondy_rbac_context{is_anonymous = false} = Ctxt) ->
    Username = to_bin(Ctxt#bondy_rbac_context.username),
    unicode:characters_to_binary(
        [
            "Permission denied. ",
            "User '", Username,
            "' does not have permission '",
            Permission, "' on '", resource_to_iolist(Resource), "'"
        ],
        utf8,
        utf8
    );

permission_denied_message(
    Permission, Resource, #bondy_rbac_context{is_anonymous = true} = Ctxt) ->
    Username = to_bin(Ctxt#bondy_rbac_context.username),
    unicode:characters_to_binary(
        [
            "Permission denied. ",
            "Anonymous user '", Username,
            "' does not have permission '",
            Permission, "' on '", resource_to_iolist(Resource), "'"
        ],
        utf8,
        utf8
    ).
