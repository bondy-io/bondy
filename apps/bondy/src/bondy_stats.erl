%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2016. All rights reserved.
%% =============================================================================


-module(bondy_stats).

-export([update/1]).
-export([update/2]).
-export([get_stats/0]).
-export([create_metrics/0]).



%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec create_metrics() -> ok.

create_metrics() ->
    %% TODO Process aliases
    lists:foreach(
        fun({Name, Type , Opts, _Aliases}) ->
            exometer:new(Name, Type, Opts)
        end,
        static_specs()
    ).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec get_stats() -> any().

get_stats() ->
    exometer:get_values([bondy]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(tuple()) -> ok.

update(Event) ->
    do_update(Event).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(wamp_message:message(), bondy_context:context()) -> ok.

update(M, #{peer := {IP, _}} = Ctxt) ->
    Type = element(1, M),
    Size = erts_debug:flat_size(M) * 8,
    case Ctxt of
        #{realm_uri := Uri, session := S} ->
            Id = bondy_session:id(S),
            do_update({message, Id, Uri, IP, Type, Size});
        #{realm_uri := Uri} ->
            do_update({message, Uri, IP, Type, Size});
        _ ->
            do_update({message, IP, Type, Size})
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
baddress(T) when is_tuple(T), (tuple_size(T) == 4 orelse tuple_size(T) == 8) ->
  list_to_binary(inet_parse:ntoa(T));
baddress(T) when is_list(T) ->
  list_to_binary(T);
baddress(T) when is_binary(T) ->
  T.

%% @private
do_update({session_opened, Realm, _SessionId, IP}) ->
    BIP = baddress(IP),
    exometer:update([bondy, sessions], 1),
    exometer:update([bondy, sessions, active], 1),

    exometer:update_or_create(
        [bondy, realm, sessions, Realm], 1, spiral, []),
    exometer:update_or_create(
        [bondy, realm, sessions, active, Realm], 1, counter, []),
    
    exometer:update_or_create(
        [bondy, ip, sessions, BIP], 1, spiral, []),
    exometer:update_or_create(
        [bondy, ip, sessions, active, BIP], 1, counter, []);

do_update({session_closed, SessionId, Realm, IP, Secs}) ->
    BIP = baddress(IP),
    exometer:update([bondy, sessions, active], -1),
    exometer:update([bondy, sessions, duration], Secs),

    exometer:update_or_create(
        [bondy, realm, sessions, active, Realm], -1, []),
    exometer:update_or_create(
        [bondy, realm, sessions, duration, Realm], Secs, []),
    
    exometer:update_or_create(
        [bondy, ip, sessions, active, BIP], -1, []),
    exometer:update_or_create(
        [bondy, ip, sessions, duration, BIP], Secs, []),
    
    %% Cleanup
    exometer:delete([bondy, session, messages, SessionId]),
    lists:foreach(
        fun({Name, _, _}) ->
            exometer:delete(Name)
        end,
        exometer:find_entries([bondy, session, messages, '_', SessionId])
    ), 
    ok;

do_update({message, IP, Type, Sz}) ->
    BIP = baddress(IP),
    exometer:update([bondy, messages], 1),
    exometer:update([bondy, messages, size], Sz),
    exometer:update_or_create([bondy, messages, Type], 1, spiral, []),

    exometer:update_or_create(
        [bondy, ip, messages, BIP], 1, counter, []),
    exometer:update_or_create(
        [bondy, ip, messages, size, BIP], Sz, histogram, []),
    exometer:update_or_create(
        [bondy, ip, messages, Type, BIP], 1, spiral, []);


do_update({message, Realm, IP, Type, Sz}) ->
    BIP = baddress(IP),
    exometer:update([bondy, messages], 1),
    exometer:update([bondy, messages, size], Sz),
    exometer:update_or_create([bondy, messages, Type], 1, spiral, []),

    exometer:update_or_create(
        [bondy, ip, messages, BIP], 1, counter, []),
    exometer:update_or_create(
        [bondy, ip, messages, size, BIP], Sz, histogram, []),
    exometer:update_or_create(
        [bondy, ip, messages, Type, BIP], 1, spiral, []),

    exometer:update_or_create(
        [bondy, realm, messages, Realm], 1, counter, []),
    exometer:update_or_create(
        [bondy, realm, messages, size, Realm], Sz, histogram, []),
    exometer:update_or_create(
        [bondy, realm, messages, Type, Realm], 1, spiral, []);

do_update({message, Session, Realm, IP, Type, Sz}) ->
    BIP = baddress(IP),
    exometer:update([bondy, messages], 1),
    exometer:update([bondy, messages, size], Sz),
    exometer:update_or_create([bondy, messages, Type], 1, spiral, []),

    exometer:update_or_create(
        [bondy, ip, messages, BIP], 1, counter, []),
    exometer:update_or_create(
        [bondy, ip, messages, size, BIP], Sz, histogram, []),
    exometer:update_or_create(
        [bondy, ip, messages, Type, BIP], 1, spiral, []),

    exometer:update_or_create(
        [bondy, realm, messages, Realm], 1, counter, []),
    exometer:update_or_create(
        [bondy, realm, messages, size, Realm], Sz, histogram, []),
    exometer:update_or_create(
        [bondy, realm, messages, Type, Realm], 1, spiral, []),

    exometer:update_or_create(
        [bondy, session, messages, Session], 1, counter, []),
    exometer:update_or_create(
        [bondy, session, messages, size, Session], Sz, histogram, []),
    exometer:update_or_create(
        [bondy, session, messages, Type, Session], 1, spiral, []).




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
static_specs() ->
    [
        {[bondy, sessions], 
            spiral, [], [
                {one, sessions}, 
                {count, sessions_total}]},
        {[bondy, messages], 
            spiral, [], [
                {one, messages}, 
                {count, messages_total}]},
        {[bondy, sessions, active], 
            counter, [], [
                {value, sessions_active}]},
        {[bondy, sessions, duration], 
            histogram, [], [
                {mean, sessions_duration_mean},
                {median, sessions_duration_median},
                {95, sessions_duration_95},
                {99, sessions_duration_99},
                {max, sessions_duration_100}]}
    ].


