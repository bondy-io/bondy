-module(bondy_security_ldap_auth).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-export([authenticate/5]).


%% =============================================================================
%% API
%% =============================================================================



-spec authenticate(
    RealmUri    ::  uri(),
    Username    ::  binary(),
    Password    ::  binary(),
    UserData    ::  [{atom(), any()}],
    Opts        ::  [{atom(), any()}]) ->
    ok | {error, unknown_user | missing_password | no_matching_sources}.

authenticate(_Realm, _Username, _Password, _UserData, _Opts) ->
    {error, not_implemented}.

