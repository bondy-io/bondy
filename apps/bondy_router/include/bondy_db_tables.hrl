%% =============================================================================
%% BONDY DB TABLE NAMES + MARKERS
%% =============================================================================
%%
%% These atoms are the bondy_db logical table names (and the `?EOT'/`?TOMBSTONE'
%% markers). Historically this header named plum_db prefixes and was called
%% `bondy_plum_db.hrl'; the data now lives in bondy_db (design §11.4) and plum_db
%% is no longer a dependency, so the header was renamed, the `?PLUM_DB_*' macros
%% renamed to `?BONDY_DB_*', and it is now self-contained (no longer includes
%% `plum_db/include/plum_db.hrl').

%% End-of-table / tombstone markers (were provided by plum_db.hrl).
-define(EOT, '$end_of_table').
-define(TOMBSTONE, '$deleted').

%% These atoms are the bondy_db logical table names. They are persisted as part
%% of the on-disk layout, so changing them requires migrating existing data.
-define(BONDY_DB_REALM_TAB, bondy_realm).
%% The realm's signing/encryption key material, stored OUT of the realm
%% identity cell (see `bondy_realm`): the realm's bondy_db identity/digest is its
%% Uri + config, never the volatile random key bytes.
-define(BONDY_DB_REALM_KEYS_TAB, bondy_realm_keys).
-define(BONDY_DB_USER_TAB, security_users).
-define(BONDY_DB_GROUP_TAB, security_groups).
-define(BONDY_DB_GROUP_MEMBERS_TAB, security_group_members).
-define(BONDY_DB_GROUP_GRANT_TAB, security_group_grants).
-define(BONDY_DB_USER_GRANT_TAB, security_user_grants).
-define(BONDY_DB_SOURCE_TAB, security_sources).
-define(BONDY_DB_TICKET_TAB, bondy_ticket).
-define(BONDY_DB_OAUTH_TOKEN_TAB, bondy_oauth_token).
-define(BONDY_DB_REGISTRY_ACTOR, '$bondy_registry').

%% REGISTRY
-define(BONDY_DB_REGISTRATION_TAB, bondy_registration).
-define(BONDY_DB_SUBSCRIPTION_TAB, bondy_subscription).
-define(BONDY_DB_REGISTRATION_PREFIX(RealmUri),
    {?BONDY_DB_REGISTRATION_TAB, RealmUri}
).
-define(BONDY_DB_SUBSCRIPTION_PREFIX(RealmUri),
    {?BONDY_DB_SUBSCRIPTION_TAB, RealmUri}
).

-define(BONDY_DB_PREFIXES, [
    %% ram
    %% ------------------------------------------
    %% Cut over to the ephemeral bondy_db `registry` DB (design §11.4 / D-7):
    %% registrations / subscriptions are no longer written to plum_db, so the
    %% net-split merge-veto callbacks (will_merge / on_merge + the per-node
    %% merge-status table) are gone. The presence-FSM SUSPEND/RESUME/EVICT that
    %% replaces them lands with oplog.aae. These empty prefixes are retained
    %% (like the other migrated tables) but never written.
    {?BONDY_DB_REGISTRATION_TAB, #{
        type => ram,
        shard_by => prefix,
        callbacks => #{}
    }},
    {?BONDY_DB_SUBSCRIPTION_TAB, #{
        type => ram,
        shard_by => prefix,
        callbacks => #{}
    }},

    %% ram_disk
    %% ------------------------------------------
    {?BONDY_DB_REALM_TAB, #{
        type => ram_disk,
        shard_by => prefix,
        %% Cut over to bondy_db (design §11.4): realms are no longer written to
        %% plum_db, so the prefix callbacks are gone. The local lifecycle
        %% notifications fire inline in bondy_realm (on_create/on_update/
        %% on_delete); the remote on_merge (close sessions on a peer's delete)
        %% is deferred to the oplog.aae phase. The LOCAL plum_db callbacks were
        %% already no-ops.
        callbacks => #{}
    }},
    {?BONDY_DB_USER_TAB, #{
        type => ram_disk,
        shard_by => prefix,
        %% Cut over to bondy_db (design §11.4): users are no longer written to
        %% plum_db, so the prefix callbacks are gone. The local lifecycle
        %% side-effects fire inline in bondy_rbac_user; the remote on_merge
        %% side-effect is deferred to the oplog.aae phase.
        callbacks => #{}
    }},
    {?BONDY_DB_GROUP_TAB, #{
        type => ram_disk,
        shard_by => prefix,
        %% Cut over to bondy_db (design §11.4): groups are no longer written to
        %% plum_db, so the prefix callbacks are gone. The local lifecycle events
        %% fire inline in bondy_rbac_group (on_merge was already a no-op).
        callbacks => #{}
    }},
    {?BONDY_DB_GROUP_GRANT_TAB, #{
        type => ram_disk,
        shard_by => prefix,
        callbacks => #{}
    }},
    {?BONDY_DB_USER_GRANT_TAB, #{
        type => ram_disk,
        shard_by => prefix,
        callbacks => #{}
    }},
    {?BONDY_DB_SOURCE_TAB, #{
        type => ram_disk,
        shard_by => prefix,
        callbacks => #{}
    }},

    %% disk
    %% ------------------------------------------
    {api_gateway, #{
        type => disk,
        shard_by => prefix,
        callbacks => #{}
    }},
    {?BONDY_DB_TICKET_TAB, #{
        type => disk,
        %% We shard by key as we prioritise ticket creation and lookup over
        %% listing and range operations.
        shard_by => key,
        callbacks => #{}
    }},
    {?BONDY_DB_OAUTH_TOKEN_TAB, #{
        type => disk,
        %% We shard by key as we prioritise token creation and lookup over
        %% listing and range operations.
        shard_by => key,
        callbacks => #{}
    }},
    {bondy_bridge_relay, #{
        type => disk,
        shard_by => prefix,
        callbacks => #{}
    }}
]).
