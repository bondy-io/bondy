-module(bondy_edge_session).
% -behaviour(gen_server).

% -include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").

-type t()             ::  #{
    %% Common to client and server
    id => id(),
    realm := uri(),
    authid := binary(),
    pubkey := binary(),
    x_authroles => [binary()],
    %% Client-side
    signer => fun((Challenge :: binary()) -> Signature :: binary()),
    %% Server-side
    auth_context => bondy_auth:context(),
    start_ts => integer(),
    subscriptions => map(),
    registrations => map()
}.

-export_type([t/0]).


