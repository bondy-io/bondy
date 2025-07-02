%% =============================================================================
%% PLUM_DB
%% =============================================================================

%% These values MUST not be changed as they impact the layout of the data
%% on PlumDB.
%% Changing them requires the migration of any existing on-disk data.
%% Check PLUM_DB_PREFIXES below.
-define(PLUM_DB_REALM_TAB, bondy_realm).
-define(PLUM_DB_USER_TAB, security_users).
-define(PLUM_DB_GROUP_TAB, security_groups).
-define(PLUM_DB_GROUP_GRANT_TAB, security_group_grants).
-define(PLUM_DB_USER_GRANT_TAB, security_user_grants).
-define(PLUM_DB_SOURCE_TAB, security_sources).
-define(PLUM_DB_TICKET_TAB, bondy_ticket).
-define(PLUM_DB_OAUTH_TOKEN_TAB, bondy_oauth_token).
-define(PLUM_DB_REGISTRY_ACTOR, '$bondy_registry').

%% REGISTRY
-define(PLUM_DB_REGISTRATION_TAB, bondy_registration).
-define(PLUM_DB_SUBSCRIPTION_TAB, bondy_subscription).
-define(PLUM_DB_REGISTRATION_PREFIX(RealmUri),
    {?PLUM_DB_REGISTRATION_TAB, RealmUri}
).
-define(PLUM_DB_SUBSCRIPTION_PREFIX(RealmUri),
    {?PLUM_DB_SUBSCRIPTION_TAB, RealmUri}
).

-define(PLUM_DB_PREFIXES, [
    %% ram
    %% ------------------------------------------
    %% used by bondy_registry.erl
    {?PLUM_DB_REGISTRATION_TAB, #{
        type => ram,
        shard_by => prefix,
        callbacks => #{
            will_merge => {bondy_registry, will_merge},
            on_merge => {bondy_registry, on_merge},
            on_update => {bondy_registry, on_update},
            on_delete => {bondy_registry, on_delete},
            on_erase => {bondy_registry, on_erase}
        }
    }},
    {?PLUM_DB_SUBSCRIPTION_TAB, #{
        type => ram,
        shard_by => prefix,
        callbacks => #{
            will_merge => {bondy_registry, will_merge},
            on_merge => {bondy_registry, on_merge},
            on_update => {bondy_registry, on_update},
            on_delete => {bondy_registry, on_delete},
            on_erase => {bondy_registry, on_erase}
        }
    }},

    %% ram_disk
    %% ------------------------------------------
    {?PLUM_DB_REALM_TAB, #{
        type => ram_disk,
        shard_by => prefix,
        callbacks => #{
            will_merge => {bondy_realm, will_merge},
            on_merge => {bondy_realm, on_merge},
            on_update => {bondy_realm, on_update},
            on_delete => {bondy_realm, on_delete},
            on_erase => {bondy_realm, on_erase}
        }
    }},
    {?PLUM_DB_USER_TAB, #{
        type => ram_disk,
        shard_by => prefix,
        callbacks => #{
            will_merge => {bondy_rbac_user, will_merge},
            on_merge => {bondy_rbac_user, on_merge},
            on_update => {bondy_rbac_user, on_update},
            on_delete => {bondy_rbac_user, on_delete},
            on_erase => {bondy_rbac_user, on_erase}
        }
    }},
    {?PLUM_DB_GROUP_TAB, #{
        type => ram_disk,
        shard_by => prefix,
        callbacks => #{
            will_merge => {bondy_rbac_group, will_merge},
            on_merge => {bondy_rbac_group, on_merge},
            on_update => {bondy_rbac_group, on_update},
            on_delete => {bondy_rbac_group, on_delete},
            on_erase => {bondy_rbac_group, on_erase}
        }
    }},
    {?PLUM_DB_GROUP_GRANT_TAB, #{
        type => ram_disk,
        shard_by => prefix,
        callbacks => #{}
    }},
    {?PLUM_DB_USER_GRANT_TAB, #{
        type => ram_disk,
        shard_by => prefix,
        callbacks => #{}
    }},
    {?PLUM_DB_SOURCE_TAB, #{
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
    {?PLUM_DB_TICKET_TAB, #{
        type => disk,
        %% We shard by key as we prioritise ticket creation and lookup over
        %% listing and range operations.
        shard_by => key,
        callbacks => #{}
    }},
    {?PLUM_DB_OAUTH_TOKEN_TAB, #{
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