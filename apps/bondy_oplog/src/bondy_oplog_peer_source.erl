%% =============================================================================
%%  bondy_oplog_peer_source.erl -
%%
%%  Copyright (c) 2023-2026 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%% =============================================================================

-module(bondy_oplog_peer_source).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Behaviour for peer discovery used by the sync scheduler.

The default sync scheduler invokes `peers_for/2` once per tick per
running instance to obtain the peers it should consider for that
round. The behaviour abstracts:

- Closed clusters where peers are statically configured.
- Open networks where peers are sampled from a churning pool.
- Domain-specific topologies (service mesh, gossip, peer-discovery
  services) — consumers implement their own module.

The library ships three built-ins:
- `bondy_oplog_peer_source_static`
- `bondy_oplog_peer_source_sample`
- `bondy_oplog_peer_source_partisan`
""").

-callback peers_for(InstanceId :: instance_id(), Opts :: map()) ->
    [peer_id()].
