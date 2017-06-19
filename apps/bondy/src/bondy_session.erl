%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% A Session is a transient conversation between two Peers attached to a
%% Realm and running over a Transport.
%%
%% Bondy implementation ties the lifetime of the underlying transport connection
%% for a WAMP connection to that of a WAMP Session
%% i.e. establish a new transport-layer connection as part of each new
%% session establishment.
%%
%% A Bondy Session is a not an application Session and is not a store for
%% application specific content (an application session store should be
%% implemented as a service i.e. a Callee).
%%
%% Currently sessions are not persistent i.e. if the connection closes the
%% session data will be lost.
%%
%% @end
%% =============================================================================
-module(bondy_session).
-include_lib("wamp/include/wamp.hrl").

-define(SESSION_TABLE_NAME, bondy_session).
-define(SESSION_SEQ_POS, 7).
-define(DEFAULT_RATE, #rate_window{limit = 1000, duration = 1}).
-define(DEFAULT_QUOTA, #quota_window{limit = 1000, duration = 1}).% TODO


-record(quota_window, {
    limit                           ::  pos_integer(),
    %% time when the quota resets in secs
    renews                          ::  pos_integer(),
    %% number of requests remaining in quota
    remaining                       ::  pos_integer(),
    %% time in seconds during which quota is valid e.g. 
    %% the length of the window
    duration                        ::  pos_integer()
}).
-type quota_window()                ::  #quota_window{}.

-record(rate_window, {
    %% max number of messages allowed during window 
    limit                           ::  pos_integer(), 
    %% duration of window in seconds
    duration                        ::  pos_integer()
}).
-type rate_window()                 ::  #rate_window{}.


%% -record(oauth2_token, {
%%     authid                          ::  binary(),
%%     access_token                    ::  binary(),
%%     refresh_token                   ::  binary()
%% }).

%% -record(wamp_credential, {
%%     %% The authentication ID of the session that joined
%%     authid                          ::  binary(),
%%     %% The authentication role of the session that joined
%%     authrole                        ::  binary(),
%%     %% The authentication method that was used for authentication 
%%     authmethod                      ::  binary(),
%%     %% The provider that performed the authentication of the session that joined
%%     authprovider = <<"bondy">>       ::  binary()
%% }).

%% -type credential()                  ::  #oauth2_token{} | #wamp_credential{}.

% THE NEW SESSION
% -record(session, {
%     id                              ::  id(),
%     realm_uri                       ::  uri(),
%     expires_in                      ::  pos_integer(),
%     seq = 0                         ::  non_neg_integer(),
%     rate = ?DEFAULT_RATE            ::  rate(),
%     quota = ?DEFAULT_QUOTA          ::  quota(),
%     is_active = true                ::  boolean(),
%     %% The credential used to establish the session
%     credential                      ::  credential(),
%     rate_window = ?DEFAULT_RATE     ::  rate_window(),
%     quota_window = ?DEFAULT_QUOTA   ::  quota_window(),
%     created                         ::  pos_integer(),
%     last_updated                    ::  pos_integer(),
%     resumed                         ::  boolean(),
%     resumable                       ::  boolean(),
%     resumed_token                   ::  binary(),
%     metadata = #{}                  ::  map()
% }).

-record(session, {
    id                              ::  id(),
    realm_uri                       ::  uri(),
    %% If a WS connection then we have a pid
    pid = self()                    ::  pid() | undefined,
    %% The {IP, Port} of the client
    peer                            ::  peer() | undefined,
    %% User-Agent HTTP header or WAMP equivalent
    agent                           ::  binary(),
    %% Sequence number used for ID generation
    seq = 0                         ::  non_neg_integer(),
    %% Peer WAMP Roles
    caller                          ::  map() | undefined,
    callee                          ::  map() | undefined,
    subscriber                      ::  map() | undefined,
    publisher                       ::  map() | undefined,
    %% Auth
    authid                          ::  binary() | undefined,
    %% Expiration and Limits
    created                         ::  calendar:date_time(),
    expires_in                      ::  pos_integer() | infinity,
    rate = ?DEFAULT_RATE            ::  rate_window(),
    quota = ?DEFAULT_QUOTA          ::  quota_window()
}).

-type peer()                    ::  {inet:ip_address(), inet:port_number()}.
-type session()                 ::  #session{}.
-type session_opts()            ::  #{roles => map()}.

-export_type([peer/0]).



-export([close/1]).
-export([created/1]).
-export([fetch/1]).
-export([id/1]).
-export([incr_seq/1]).
-export([lookup/1]).
-export([open/3]).
-export([open/4]).
-export([peer/1]).
-export([pid/1]).
-export([realm_uri/1]).
-export([size/0]).
-export([update/1]).
% -export([stats/0]).

%% -export([features/1]).
%% -export([subscriptions/1]).
%% -export([registrations/1]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% Creates a new session provided the RealmUri exists or can be dynamically
%% created. It assigns a new Id.
%% It calls {@link bondy_utils:get_realm/1} which will fail with an exception
%% if the realm does not exist or cannot be created
%% -----------------------------------------------------------------------------
-spec open(peer(), uri() | bondy_realm:realm(), session_opts()) -> 
    session() | no_return().

open(Peer, RealmUri, Opts) when is_binary(RealmUri) ->
    open(bondy_utils:get_id(global), Peer, bondy_realm:fetch(RealmUri), Opts);

open(Peer, Realm, Opts) when is_map(Opts) ->
    open(bondy_utils:get_id(global), Peer, Realm, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% Creates a new session provided the RealmUri exists or can be dynamically
%% created.
%% It calls {@link bondy_utils:get_realm/1} which will fail with an exception
%% if the realm does not exist or cannot be created
%% -----------------------------------------------------------------------------
-spec open(id(), peer(), uri() | bondy_realm:realm(), session_opts()) -> 
    session() | no_return().
open(Id, Peer, RealmUri, Opts) when is_binary(RealmUri) ->
    open(Id, Peer, bondy_realm:fetch(RealmUri), Opts);

open(Id, {IP, _} = Peer, Realm, Opts) when is_map(Opts) ->
    RealmUri = bondy_realm:uri(Realm),
    S0 = #session{
        id = Id,
        peer = Peer,
        realm_uri = RealmUri,
        created = calendar:local_time()
    },
    S1 = parse_details(Opts, S0),

    case ets:insert_new(table(Id), S1) of
        true ->
            ok = bondy_stats:update({session_opened, RealmUri, Id, IP}),
            S1;
        false ->
            error({integrity_constraint_violation, Id})
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(session()) -> ok.
update(#session{id = Id} = S) ->
    true = ets:insert(table(Id), S),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec close(session()) -> ok.
close(#session{id = Id} = S) ->
    {IP, _} = S#session.peer,
    Realm = S#session.realm_uri,
    Secs = calendar:datetime_to_gregorian_seconds(calendar:local_time()) - calendar:datetime_to_gregorian_seconds(S#session.created), 
    ok = bondy_stats:update(
        {session_closed, Id, Realm, IP, Secs}),
    true = ets:delete(table(Id), Id),
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec id(session()) -> id().

id(#session{id = Id}) ->
    Id.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(id() | session()) -> uri().
realm_uri(#session{realm_uri = Uri}) ->
    Uri;
realm_uri(Id) ->
    #session{realm_uri = Uri} = fetch(Id),
    Uri.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the pid of the process managing the transport that the session
%% identified by Id runs on.
%% @end
%% -----------------------------------------------------------------------------
-spec pid(session()) -> pid().

pid(Id) when is_integer(Id) ->
    pid(fetch(Id));

pid(#session{pid = Pid}) ->
    Pid.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec created(session()) -> calendar:date_time().

created(#session{created = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peer(session()) -> peer().

peer(#session{peer = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec incr_seq(id() | session()) -> map().

incr_seq(#session{id = Id}) ->
    incr_seq(Id);
    
incr_seq(SessionId) when is_integer(SessionId), SessionId >= 0 ->
    Tab = tuplespace:locate_table(?SESSION_TABLE_NAME, SessionId),
    ets:update_counter(Tab, SessionId, {?SESSION_SEQ_POS, 1, ?MAX_ID, 0}).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the number of sessions in the tuplespace.
%% @end
%% -----------------------------------------------------------------------------
-spec size() -> non_neg_integer().

size() ->
    tuplespace:size(?SESSION_TABLE_NAME).


%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the session identified by Id from the tuplespace or 'not_found'
%% if it doesn't exist.
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(id()) -> session() | not_found.

lookup(Id) ->
    case do_lookup(Id) of
        #session{} = Session ->
            Session;
        not_found ->
            not_found
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Retrieves the session identified by Id from the tuplespace. If the session
%% does not exist it fails with reason '{badarg, Id}'.
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(id()) -> session() | no_return().

fetch(Id) ->
    case lookup(Id) of
        not_found ->
            error({badarg, Id});
        Session ->
            Session
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
parse_details(Opts, Session0)  when is_map(Opts) ->
    case maps:fold(fun parse_details/3, Session0, Opts) of
        #session{
            caller = undefined,
            callee = undefined,
            subscriber = undefined,
            publisher = undefined} ->
                error({invalid_options, missing_client_role});
        Session1 ->
            Session1
    end.


%% @private

parse_details(roles, Roles, Session) when is_map(Roles) ->
    parse_details(Roles, Session);
parse_details(caller, V, Session) when is_map(V) ->
    Session#session{caller = V};
parse_details(callee, V, Session) when is_map(V) ->
    Session#session{callee = V};
parse_details(subscriber, V, Session) when is_map(V) ->
    Session#session{subscriber = V};
parse_details(publisher, V, Session) when is_map(V) ->
    Session#session{publisher = V};
parse_details(authid, V, Session) when is_binary(V) ->
    Session#session{authid = V};
parse_details(agent, V, Session) when is_binary(V) ->
    Session#session{agent = V};
parse_details(_, _, Session) ->
    Session.


%% @private
table(Id) ->
    tuplespace:locate_table(?SESSION_TABLE_NAME, Id).


%% @private
-spec do_lookup(id()) -> session() | not_found.

do_lookup(Id) ->
    Tab = table(Id),
    case ets:lookup(Tab, Id)  of
        [#session{} = Session] ->
            Session;
        [] ->
            not_found
    end.

