-module(bondy_session_info).

-include_lib("wamp/include/wamp.hrl").
-include_lib("bondy.hrl").

-record(bondy_session_info, {
    role            ::  bridge | client,
    %% Node in which the client is located or connected to
    %% This used for cluster-wide routing.
    %% In the case of a bridge this is the node where the bridge is connected
    node            ::  node(),
    %% Session identifier for
    session_id      ::  id(),
    %% If brige, external client (TCP or Websockets) or an internal process,
    %% we will have a pid. In the case of bridge and external client the pid is
    %% the socket owner
    pid             ::  maybe(pid()),
    %% For internal callback-implemented clients we do not have the pid but a
    %% module
    callback_mod    ::  maybe(module())

}).

-type t()           ::  #bondy_session_info{}.

-export_type([t/0]).





%% =============================================================================
%% API
%% =============================================================================



