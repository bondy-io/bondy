%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

-module(juno_rpc).
-include_lib("wamp/include/wamp.hrl").


-export([unregister_all/1]).
-export([register/3]).
-export([unregister/2]).
-export([registrations/1]).
-export([registrations/2]).
-export([registrations/3]).
%% -export([callees/2]).
%% -export([count_callees/2]).
%% -export([registrations/2]).
%% -export([count_registrations/2]).
%% -export([lookup_registration/2]).
%% -export([fetch_registration/2]). % wamp.registration.get
%% -export([match_registrations/2]).




%% =============================================================================
%% API
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% If the registration already exists, it fails with a
%% 'procedure_already_exists' error.
%% @end
%% -----------------------------------------------------------------------------
-spec register(uri(), map(), juno_context:context()) -> {ok, id()}.
register(ProcUri, Options, Ctxt) ->
    juno_registry:add(registration, ProcUri, Options, Ctxt).

%% -----------------------------------------------------------------------------
%% @doc
%% If the registration does not exist, it fails with a 'no_such_registration'
%% error.
%% @end
%% -----------------------------------------------------------------------------
-spec unregister(id(), juno_context:context()) -> ok.
unregister(RegId, Ctxt) ->
    juno_registry:remove(registration, RegId, Ctxt).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
unregister_all(Ctxt) ->
    juno_registry:remove_all(registration, Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the list of registrations for the active session.
%%
%% When called with a juno:context() it is equivalent to calling
%% registrations/2 with the RealmUri and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(
    ContextOrCont :: juno_context:context() | ets:continuation()) ->
    [juno_registry:entry()].
registrations(#{realm_uri := RealmUri, session_id := SessionId}) ->
    registrations(RealmUri, SessionId);
registrations(Cont) ->
    juno_registry:entries(Cont).



%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of registrations matching the RealmUri
%% and SessionId.
%%
%% Use {@link registrations/3} and {@link registrations/1} to limit the
%% number of registrations returned.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(RealmUri :: uri(), SessionId :: id()) ->
    [juno_registry:entry()].
registrations(RealmUri, SessionId) ->
    juno_registry:entries(registration, RealmUri, SessionId, infinity).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of registrations matching the RealmUri
%% and SessionId.
%%
%% Use {@link registrations/3} to limit the number of registrations returned.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(RealmUri :: uri(), SessionId :: id(), non_neg_integer()) ->
    {[juno_registry:entry()], Cont :: '$end_of_table' | term()}.
registrations(RealmUri, SessionId, Limit) ->
    juno_registry:entries(registration, RealmUri, SessionId, Limit).



%% =============================================================================
%% PRIVATE
%% =============================================================================
