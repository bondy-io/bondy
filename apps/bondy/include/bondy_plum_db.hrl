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
-define(PLUM_DB_REGISTRATION_TAB, bondy_registration).
-define(PLUM_DB_SUBSCRIPTION_TAB, bondy_subscription).


-define(PLUM_DB_PREFIXES, [
    %% ram
    %% ------------------------------------------
    %% used by bondy_registry.erl
    {?PLUM_DB_REGISTRATION_TAB, ram},
    {?PLUM_DB_SUBSCRIPTION_TAB, ram},

    %% ram_disk
    %% ------------------------------------------
    {?PLUM_DB_REALM_TAB, ram_disk},
    {?PLUM_DB_GROUP_GRANT_TAB, ram_disk},
    {?PLUM_DB_GROUP_TAB, ram_disk},
    {?PLUM_DB_USER_GRANT_TAB, ram_disk},
    {?PLUM_DB_USER_TAB, ram_disk},
    {?PLUM_DB_SOURCE_TAB, ram_disk},

    %% disk
    %% ------------------------------------------
    {api_gateway, disk},
    {?PLUM_DB_TICKET_TAB, disk},
    {oauth2_refresh_tokens, disk},
    {bondy_bridge_relay, disk}
]).