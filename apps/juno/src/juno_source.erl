%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2011 - 2016. All rights reserved.
%% =============================================================================


-module(juno_source).

-type source() :: map().

-define(INFO_KEYS, [<<"first_name">>, <<"last_name">>, <<"email">>]).

-export([lookup/1]).
% -export([add/1]).
% -export([remove/1]).
-export([fetch/1]).
% -export([list/0]).


% %% -----------------------------------------------------------------------------
% %% @doc
% %% @end
% %% -----------------------------------------------------------------------------
% -spec add(source()) -> ok.
% add(Users, ) ->
%     Info = maps:with(?INFO_KEYS, User),
%     #{
%         <<"username">> := BinName
%     } = User,
%     Username = unicode:characters_to_list(BinName, utf8),
%     Opts = [
%         {<<"info">>, Info}
%     ],
%     case juno_security:add_user(Username, Opts) of
%         ok ->
%             ok;
%         {error, role_exists} ->
%             {error, user_exists}
%     end.


% %% -----------------------------------------------------------------------------
% %% @doc
% %% @end
% %% -----------------------------------------------------------------------------
% -spec remove(list() | binary()) -> ok.
% remove(Id) when is_binary(Id) ->
%     remove(unicode:characters_to_list(Id, utf8));

% remove(Id) ->
%     case juno_security:del_user(Id) of
%         ok -> 
%             ok;
%         {error, {unknown_user, Id}} ->
%             {error, unknown_user}
%     end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(list() | binary()) -> source() | not_found.
lookup(Username) when is_binary(Username) ->
    lookup(unicode:characters_to_list(Username, utf8));

lookup(Username) ->
    case juno_security:lookup_user_source(Username) of
        not_found -> not_found;
        Obj -> to_map(Obj)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(list() | binary()) -> source() | no_return().
fetch(Id) when is_binary(Id) ->
    fetch(unicode:characters_to_list(Id, utf8));
    
fetch(Id) ->
    case lookup(Id) of
        not_found -> error(not_found);
        User -> User
    end.


% %% -----------------------------------------------------------------------------
% %% @doc
% %% @end
% %% -----------------------------------------------------------------------------
% -spec list() -> list(source()).
% list() ->
%     [to_map(User) || User <- juno_security:list(user)].




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
to_map({{_Username, _CIDR}, [{_Source, _Opts}]} = _Obj) ->
    % Map0 = proplists:get_value(<<"info">>, Opts, #{}),
    % {Addr, Mask} = CIDR,
    % CIDRStr = io_lib:format("~s/~B", [inet_parse:ntoa(Addr), Mask]).
    % Map0#{
    %     <<"cidr">> => CIDRStr
    % }.
    % TODO
    #{}.




