%% -----------------------------------------------------------------------------
%% @doc A `bondy_ref' (reference) acts as a fully qualified name for a
%% process or callback function in a Bondy network. The reference is used by
%% Bondy in the `bondy_registry' when registering procedures and subscriptions
%% so that the `bondy_router' can forward and/or relay a message to a process,
%% or callback function.
%%
%% ## Types
%% ### Internal
%%
%% ### Bridge
%%
%% ### Client
%%
%% ### Callback
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_ref).

-include_lib("wamp/include/wamp.hrl").
-include_lib("bondy.hrl").

%% The order of the record fields is defined so that the ref can be used as a
%% key in an ordered_set store supporting prefix mapping, so do not change it
%% unless you know exactly what you are doing.
%% Changing this order might affect the following modules:
%% - bondy_registry_entry
%% - bondy_registry
%% - bondy_rpc_promise
%% - bondy_session
-record(bondy_ref, {
    realm_uri           ::  uri(),
    node                ::  wildcard(node()),
    target              ::  wildcard(target()),
    session_id          ::  wildcard(maybe(id())),
    type                ::  wildcard(ref_type())
}).

-type t()               ::  #bondy_ref{}.
-type bridge_ref()      ::  #bondy_ref{type :: bridge}.
-type client_ref()      ::  #bondy_ref{type :: client}.
-type internal_ref()    ::  #bondy_ref{type :: internal}.
-type ref_type()        ::  internal | bridge | client.
-type target()          ::  {pid, binary()}
                            | {callback, mfargs()}
                            | {name, term()}.
-type name()            ::  term().
-type mfargs()          ::  {M :: module(), F :: atom(), A :: maybe([term()])}.
-type wildcard(T)       ::  T | '_'.

-export_type([t/0]).
-export_type([bridge_ref/0]).
-export_type([client_ref/0]).
-export_type([internal_ref/0]).
-export_type([target/0]).

-export([callback/1]).
-export([is_bridge/1]).
-export([is_callback/1]).
-export([is_client/1]).
-export([is_internal/1]).
-export([is_local/1]).
-export([is_self/1]).
-export([is_type/1]).
-export([name/1]).
-export([new/3]).
-export([new/4]).
-export([new/5]).
-export([node/1]).
-export([pattern/5]).
-export([pid/1]).
-export([realm_uri/1]).
-export([session_id/1]).
-export([target/1]).
-export([type/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(
    Type :: ref_type(),
    RealmUri :: uri(),
    Target :: pid() | mfargs() | name()) ->
    t().

new(Type, RealmUri, Target) ->
    SessionId = undefined,
    Node = bondy_peer_service:mynode(),
    new(Type, RealmUri, Target, SessionId, Node).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(
    Type :: ref_type(),
    RealmUri :: uri(),
    Target :: pid() | mfargs() | name(),
    SessionId :: maybe(bondy_session:id())) -> t().

new(Type, RealmUri, Target, SessionId) ->
    Node = bondy_peer_service:mynode(),
    new(Type, RealmUri, Target, SessionId, Node).


%% -----------------------------------------------------------------------------
%% @doc Creates a new reference.
%% @end
%% -----------------------------------------------------------------------------
-spec new(
    Type :: ref_type(),
    RealmUri :: uri(),
    Target :: pid() | mfargs() | name(),
    SessionId :: maybe(bondy_session:id()),
    Node :: node()) -> t().

new(Type, RealmUri, Target0, SessionId, Node)
when is_binary(RealmUri), is_atom(Node) ->

    is_integer(SessionId)
        orelse SessionId == undefined
        orelse error({badarg, {session_id, SessionId}}),

    lists:member(Type, [client, internal, bridge])
        orelse error({badarg, {type, Type}}),

    Target = validate_target(Target0),

    #bondy_ref{
        type = Type,
        realm_uri = RealmUri,
        node = Node,
        session_id = SessionId,
        target = Target
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec pattern(
    Type :: wildcard(ref_type()),
    RealmUri :: uri(),
    Target :: wildcard(pid() | mfargs() | name()),
    SessionId :: wildcard(maybe(bondy_session:id())),
    Node :: wildcard(node())) -> t().

pattern(Type, RealmUri, Target0, SessionId, Node)
when is_binary(RealmUri), is_atom(Node) ->

    lists:member(Type, ['_', client, internal, bridge])
        orelse error({badarg, {type, Type}}),

    Target = validate_target(Target0, _AllowPattern = true),

    is_integer(SessionId)
        orelse SessionId == '_'
        orelse error({badarg, {session_id, SessionId}}),

    #bondy_ref{
        type = Type,
        realm_uri = RealmUri,
        node = Node,
        session_id = SessionId,
        target = Target
    }.


%% -----------------------------------------------------------------------------
%% @doc Returns the reference type.
%% @end
%% -----------------------------------------------------------------------------
-spec type(Term :: term()) -> ref_type().

type(#bondy_ref{type = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns `true' if term `Term' is a reference. Otherwise returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec is_type(t()) -> boolean().

is_type(#bondy_ref{}) ->
    true;

is_type(_) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc Returns the realm URI of the reference.
%% @end
%% -----------------------------------------------------------------------------
-spec realm_uri(t()) -> uri().

realm_uri(#bondy_ref{realm_uri = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the Bondy peer node in which the target of this reference is
%% located and/or connected to.
%%
%% See {@link target/1} for a description of the different targets and the
%% relationship with the node.
%% @end
%% -----------------------------------------------------------------------------
-spec node(t()) -> node().

node(#bondy_ref{node = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the session identifier of the reference or the atom `undefined'.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(t()) -> maybe(id()).

session_id(#bondy_ref{session_id = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the target of the reference. A target is a process (`pid()') a
%% gproc registered name (`{name, GprocName}') or a callback (`mfargs()').
%%
%% If the reference type is `client' the target refers to the
%% session and/or process owning the network connection to the client.
%%
%% If the reference type is `internal' the target refers to an internal
%% process acting as one of the Bondy client roles e.g. an internal subscriber.
%% Messages destined to a target located on a different node are relayed by the
%% router through the cluster distribution layer (Partisan).
%%
%% If the reference type is `bridge' the target refers to the session
%% and/or process owning the network connection to the edge or
%% remote cluster (See {@link bondy_edge_uplink_client} and
%% {@link bondy_edge_uplink_server} respectively). The bridge acts as a proxy
%% for the actual edge or remote clients, internal and callback targets.
%%
%% @end
%% -----------------------------------------------------------------------------
-spec target(t()) -> target().

target(#bondy_ref{target = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns whether this is a reference to a local target i.e. located on
%% the caller's node.
%% @end
%% -----------------------------------------------------------------------------
-spec is_local(Ref :: t()) -> boolean().

is_local(#bondy_ref{node = Node}) ->
    Node =:= bondy_peer_service:mynode().


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_callback(t()) -> boolean().

is_callback(#bondy_ref{target = {callback, _}}) ->
    true;

is_callback(#bondy_ref{}) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_bridge(t()) -> boolean().

is_bridge(Ref) ->
    bridge =:= type(Ref).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_internal(t()) -> boolean().

is_internal(Ref) ->
    internal =:= type(Ref).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_client(t()) -> boolean().

is_client(Ref) ->
    client =:= type(Ref).


%% -----------------------------------------------------------------------------
%% @doc Returns whether this is a reference to the calling process.
%% @end
%% -----------------------------------------------------------------------------
-spec is_self(Ref :: t()) -> boolean().

is_self(#bondy_ref{target = {pid, Val}} = Ref) ->
    %% Pids can only be used on the node where they were created (this is
    %% because we are using Partisan and not Distributed Erlang)
    is_local(Ref) andalso Val =:= bondy_utils:pid_to_bin(self());

is_self(#bondy_ref{target = {name, Name}} = Ref) ->
    %% Pids can only be used on the node where they were created (this is
    %% because we are using Partisan and not Distributed Erlang).
    %% Also we only use gproc locally, if this ref is for another node then we
    %% do not have the session here.
    is_local(Ref) andalso gproc:lookup_pid({n, l, Name}) =:= self();

is_self(#bondy_ref{}) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec name(t()) -> maybe(term()).

name(#bondy_ref{target = {name, Val}}) ->
    Val;

name(#bondy_ref{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec pid(t()) -> maybe(pid()).

pid(#bondy_ref{target = {pid, Bin}}) ->
    bondy_utils:bin_to_pid(Bin);

pid(#bondy_ref{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec callback(t()) -> maybe(mfargs()).

callback(#bondy_ref{target = {callback, Val}}) ->
    Val;

callback(#bondy_ref{}) ->
    undefined.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
validate_target(Target) ->
    validate_target(Target, false).


%% @private
validate_target(Target, AllowPattern) ->
    case Target of
        undefined ->
            error({badarg, {target, Target}});

        {M, F, undefined} when is_atom(M), is_atom(F) ->
            {callback, Target};

        {M, F, A} when is_atom(M), is_atom(F), is_list(A) ->
            {callback, Target};

        Pid when is_pid(Pid) ->
            {pid, bondy_utils:pid_to_bin(Pid)};

        '_'  ->
            AllowPattern == true
                orelse error({badarg, {target, Target}}),
            '_';

        Term ->
            {name, Term}
    end.