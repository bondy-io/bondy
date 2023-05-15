%% =============================================================================
%%  bondy_ref.erl -
%%
%%  Copyright (c) 2016-2023 Leapsight. All rights reserved.
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
%% @doc A `bondy_ref' (reference) acts as a fully qualified name for a
%% process or callback function in a Bondy network. The reference is used by
%% Bondy in the `bondy_registry' when registering procedures and subscriptions
%% so that the `bondy_router' can forward and/or relay a message to a process,
%% or callback function.
%%
%% ## Types
%% ### Internal
%%
%% ### Relay
%%
%% ### Client
%%
%% ### Callback
%%
%% @since 0.1.0
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_ref).

-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(TYPES, [relay, bridge_relay, internal, client]).

-record(bondy_ref, {
    type                ::  wildcard(ref_type()),
    nodestring          ::  wildcard(nodestring()),
    session_id          ::  wildcard(optional(bondy_session_id:t())),
    target              ::  wildcard(target())
}).

-type t()               ::  #bondy_ref{}.
% -type t_or_uri()        ::  t() | uri().
-type relay()           ::  #bondy_ref{type :: relay}.
-type bridge_relay()    ::  #bondy_ref{type :: bridge_relay}.
-type client()          ::  #bondy_ref{type :: client}.
-type internal()        ::  #bondy_ref{type :: internal}.
-type ref_type()        ::  relay | bridge_relay | internal | client.
-type target()          ::  {pid, binary()}
                            | {name, binary()}
                            | {callback, mf()}.
-type target_type()     ::  pid | name | callback.
-type name()            ::  term().
-type mf()              ::  {M :: module(), F :: atom()}.
-type wildcard(T)       ::  T | '_'.

-export_type([t/0]).
-export_type([relay/0]).
-export_type([bridge_relay/0]).
-export_type([client/0]).
-export_type([internal/0]).
-export_type([mf/0]).
-export_type([target/0]).

-export([callback/1]).
-export([from_uri/1]).
-export([is_alive/1]).
-export([is_bridge_relay/1]).
-export([is_client/1]).
-export([is_internal/1]).
-export([is_local/1]).
-export([is_local/2]).
-export([is_relay/1]).
-export([is_self/1]).
-export([is_type/1]).
-export([name/1]).
-export([new/1]).
-export([new/2]).
-export([new/3]).
-export([new/4]).
-export([node/1]).
-export([nodestring/1]).
-export([pattern/4]).
-export([pid/1]).
-export([session_id/1]).
-export([target/1]).
-export([target_type/1]).
-export([to_key/1]).
-export([to_uri/1]).
-export([type/1]).
-export([types/0]).

-compile({no_auto_import, [node/1]}).


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(Type :: ref_type()) ->
    t().

new(Type) ->
    new(Type, self()).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(Type :: ref_type(), Target :: pid() | mf() | name()) -> t().

new(Type, Target) ->
    new(Type, Target, undefined).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(
    Type :: ref_type(),
    Target :: pid() | mf() | name(),
    SessionId :: optional(bondy_session_id:t())) -> t().

new(Type, Target, SessionId) ->
    Nodestring = bondy_config:nodestring(),
    new(Type, Target, SessionId, Nodestring).


%% -----------------------------------------------------------------------------
%% @doc Creates a new reference.
%% @end
%% -----------------------------------------------------------------------------
-spec new(
    Type :: ref_type(),
    Target :: pid() | mf() | name(),
    SessionId :: optional(bondy_session_id:t()),
    Node :: node() | nodestring()) -> t() | no_return().

new(Type, Target, SessionId, Node) when is_atom(Node) ->
    new(Type, Target, SessionId, atom_to_binary(Node, utf8));

new(Type, Target0, SessionId, Nodestring) when is_binary(Nodestring) ->

    is_binary(SessionId)
        orelse (SessionId == undefined andalso Type =/= client)
        orelse error({badarg, [{type, Type}, {session_id, SessionId}]}),

    lists:member(Type, ?TYPES)
        orelse error({badarg, {type, Type}}),

    Target = validate_target(Type, Target0),


    #bondy_ref{
        type = Type,
        nodestring = Nodestring,
        session_id = SessionId,
        target = Target
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec pattern(
    Type :: wildcard(ref_type()),
    Target :: wildcard(pid() | mf() | name()),
    SessionId :: wildcard(optional(bondy_session_id:t())),
    Node :: wildcard(node() | nodestring())) -> t() | no_return().


pattern(Type, Target0, SessionId, Node) ->

    Nodestring = case Node of
        '_' ->
            Node;
        Node when is_atom(Node) ->
            atom_to_binary(Node, utf8);
        Node when is_binary(Node) ->
            Node;
        _ ->
            error({badarg, {node, Node}})
    end,

    lists:member(Type, ?TYPES ++ ['_'])
        orelse error({badarg, {type, Type}}),

    Target = validate_target(Type, Target0, _AllowPattern = true),

    is_binary(SessionId)
        orelse SessionId == '_'
        orelse error({badarg, {session_id, SessionId}}),

    #bondy_ref{
        type = Type,
        nodestring = Nodestring,
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
%% @doc Returns all the supported reference types.
%% @end
%% -----------------------------------------------------------------------------
-spec types() -> [ref_type()].

types() ->
    ?TYPES.


%% -----------------------------------------------------------------------------
%% @doc Returns the Bondy peer binary string name of the node in which the
%% target of this reference is located and/or connected to.
%%
%% See {@link target/1} for a description of the different targets and the
%% relationship with the node.
%% @end
%% -----------------------------------------------------------------------------
-spec nodestring(t()) -> nodestring().

nodestring(#bondy_ref{nodestring = Val}) ->
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

node(#bondy_ref{nodestring = Val}) ->
    binary_to_atom(Val, utf8).


%% -----------------------------------------------------------------------------
%% @doc Returns the session identifier of the reference or the atom `undefined'.
%% @end
%% -----------------------------------------------------------------------------
-spec session_id(t()) -> optional(bondy_session_id:t()).

session_id(#bondy_ref{session_id = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc Returns `false' if the ref is local and its target is a process which
%% is not alive (See `erlang:is_process_alive/1') or if the ref is remote (
%% regardless of its target type) and the remote node is disconnected (See
%% `partisan:is_connected/1). Otherwise returns `true'.
%% @end
%% -----------------------------------------------------------------------------
is_alive(#bondy_ref{} = Ref) ->
    case is_local(Ref) of
        true ->
            Pid = pid(Ref),
            Pid == undefined orelse erlang:is_process_alive(Pid);
        false ->
            partisan:is_connected(node(Ref))
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_relay(t()) -> boolean().

is_relay(Ref) ->
    relay =:= type(Ref).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_bridge_relay(t()) -> boolean().

is_bridge_relay(Ref) ->
    bridge_relay =:= type(Ref).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_client(t()) -> boolean().

is_client(Ref) ->
    client =:= type(Ref).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_internal(t()) -> boolean().

is_internal(Ref) ->
    internal =:= type(Ref).


%% -----------------------------------------------------------------------------
%% @doc Returns whether this is a reference to a local target i.e. located on
%% the caller's node.
%% @end
%% -----------------------------------------------------------------------------
-spec is_local(Ref :: t()) -> boolean().

is_local(#bondy_ref{nodestring = Val}) ->
    Val =:= bondy_config:nodestring().


%% -----------------------------------------------------------------------------
%% @doc Returns whether this is a reference to a target local to the node
%% represented by `Nodestring'.
%% @end
%% -----------------------------------------------------------------------------
-spec is_local(Ref :: t(), nodestring()) -> boolean().

is_local(#bondy_ref{nodestring = Val}, Nodestring) ->
    Val =:= Nodestring.


%% -----------------------------------------------------------------------------
%% @doc Returns whether this is a reference to the calling process.
%% @end
%% -----------------------------------------------------------------------------
-spec is_self(Ref :: t()) -> boolean().

is_self(#bondy_ref{} = Ref) ->
    (catch pid(Ref)) =:= self().


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
%% @doc Returns the target of the reference. A target is a process (`pid()') a
%% gproc registered name (`{name, GprocName}') or a callback (`mf()').
%%
%% If the reference type is `client' the target refers to the
%% session and/or process owning the network connection to the client.
%%
%% If the reference type is `internal' the target refers to an internal
%% process acting as one of the Bondy client roles e.g. an internal subscriber.
%% Messages destined to a target located on a different node are relayed by the
%% router through the cluster distribution layer (Partisan).
%%
%% If the reference type is `relay' the target refers to the session
%% and/or process owning the network connection to the edge or
%% remote cluster (See {@link bondy_bridge_relay_client} and
%% {@link bondy_bridge_relay_server} respectively). The relay acts as a proxy
%% for the actual edge or remote clients, internal and callback targets.
%%
%% @end
%% -----------------------------------------------------------------------------
-spec target(t()) -> target().

target(#bondy_ref{target = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec target_type(t()) -> wildcard(target_type()).

target_type(#bondy_ref{target = {Type, _}}) ->
    Type;

target_type(#bondy_ref{target = '_'}) ->
    '_'.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec name(t()) -> optional(binary()).

name(#bondy_ref{target = {name, Val}}) ->
    Val;

name(#bondy_ref{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc Returns a pid when target is of type `{pid, binary()}', otherwise
%% returns the atom `undefined'.
%% If the reference is not local it fails with exception `not_my_node'. This is
%% because process identifies can only be used on the node where they were
%% created (this is because we are using Partisan and not Distributed Erlang).
%% @end
%% -----------------------------------------------------------------------------
-spec pid(t()) -> optional(pid()) | no_return().

pid(#bondy_ref{target = {pid, Bin}} = Ref) ->
    %% Pids can only be used on the node where they were created (this is
    %% because we are using Partisan and not Distributed Erlang).
    is_local(Ref) orelse error(not_my_node),
    list_to_pid(binary_to_list(Bin));

pid(#bondy_ref{target = {name, Name}} = Ref) ->
    %% Pids can only be used on the node where they were created (this is
    %% because we are using Partisan and not Distributed Erlang).
    %% Also we only use gproc locally, if this ref is for another node then we
    %% do not have the session here.
    is_local(Ref) orelse error(not_my_node),
    bondy_gproc:lookup_pid(Name);

pid(#bondy_ref{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec callback(t()) -> optional(mf()).

callback(#bondy_ref{target = {callback, Val}}) ->
    Val;

callback(#bondy_ref{}) ->
    undefined.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec to_uri(t()) -> uri().

to_uri(#bondy_ref{} = Ref) ->
    Nodestring = Ref#bondy_ref.nodestring,
    SessionId =
        case Ref#bondy_ref.session_id of
            undefined ->
                <<>>;
            Val ->
                Val
        end,

    Type = atom_to_binary(Ref#bondy_ref.type),

    Target =
        case Ref#bondy_ref.target of
            {pid, PidBin} ->
                Name = binary:replace(PidBin, [<<$<>>, <<$>>>], <<>>, [global]),
                <<"p#", Name/binary>>;
            {name, Name} ->
                <<"n#", Name/binary>>;
            {callback, {M, F}} ->
                MBin = atom_to_binary(M),
                FBin = atom_to_binary(F),
                <<"c#", MBin/binary, $,, FBin/binary>>
        end,

    <<
        "bondy:",
        Nodestring/binary, $:,
        Type/binary, $:,
        SessionId/binary, $:,
        Target/binary
    >>.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec to_key(t()) -> uri().

to_key(#bondy_ref{} = Ref) ->
    Nodestring = Ref#bondy_ref.nodestring,
    SessionId = Ref#bondy_ref.session_id,
    Type = atom_to_binary(Ref#bondy_ref.type),

    Target = encode_target(Ref#bondy_ref.target),

    <<
        Nodestring/binary, $\31,
        Target/binary, $\31,
        SessionId/binary, $\31,
        Type/binary
    >>.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec from_uri(uri()) -> t().

from_uri(Uri) ->
    case binary:split(Uri, uri_pattern(), [global]) of
        [<<"bondy">>, Nodestring, Type, SessionId, Target] ->
            case SessionId of
                <<>> ->
                    undefined;
                Val ->
                    Val
            end,

            #bondy_ref{
                nodestring = Nodestring,
                type = binary_to_existing_atom(Type),
                session_id = SessionId,
                target = decode_target(Target)
            };
        _ ->
            error(badarg)
    end.


%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
validate_target(Type, Target) ->
    validate_target(Type, Target, false).


%% @private
validate_target(Type, Target, AllowPattern) ->
    case Target of
        '_'  when AllowPattern == true ->
            '_';

        '_' when AllowPattern == false ->
            badtarget(Type, Target);

        undefined ->
            badtarget(Type, Target);

        {pid, Bin} = Val ->
            is_binary(Bin) orelse badtarget(Type, Target),
            Val;

        {name, _} = Val ->
            Val;

        {callback, {M, F}} = Val ->
            (Type == internal orelse Type == '_')
                andalso is_atom(M)
                andalso is_atom(F)
                orelse badtarget(Type, Target),

            Val;

        {M, F} ->
            (Type == internal orelse Type == '_')
                andalso is_atom(M)
                andalso is_atom(F)
                orelse badtarget(Type, Target),

            {callback, Target};

        Pid when is_pid(Pid) ->
            {pid, list_to_binary(pid_to_list(Pid))};

        Term when is_binary(Term) ->
            {name, Term};

        _ ->
            badtarget(Type, Target)
    end.


badtarget(Type, Target) ->
    error({badarg, [{type, Type}, {target, Target}]}).


uri_pattern() ->
    Key = {?MODULE, uri_pattern},
    case persistent_term:get(Key, undefined) of
        undefined ->
            CP = binary:compile_pattern([<<$:>>]),
            _ = persistent_term:put(Key, CP),
            CP;
        CP ->
            CP
    end.

target_pattern() ->
    Key = {?MODULE, target_pattern},
    case persistent_term:get(Key, undefined) of
        undefined ->
            CP = binary:compile_pattern([<<$,>>]),
            _ = persistent_term:put(Key, CP),
            CP;
        CP ->
            CP
    end.


encode_target({pid, PidBin}) ->
    Name = binary:replace(PidBin, [<<$<>>, <<$>>>], <<>>, [global]),
    <<"p#", Name/binary>>;

encode_target({name, Name}) ->
    <<"n#", Name/binary>>;

encode_target({callback, {M, F}}) ->
    MBin = atom_to_binary(M),
    FBin = atom_to_binary(F),
    <<"c#", MBin/binary, $,, FBin/binary>>.


decode_target(<<"p#", Rest/binary>>) ->
    {pid, <<$<, Rest/binary, $>>>};

decode_target(<<"n#", Rest/binary>>) ->
    {name, Rest};

decode_target(<<"c#", Rest/binary>>) ->
    case binary:split(Rest, target_pattern()) of
        [BM, BF] ->
            MF = {binary_to_existing_atom(BM), binary_to_existing_atom(BF)},
            {callback, MF};
        _ ->
            error({badarg, target})
    end.
