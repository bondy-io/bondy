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
%% Interface metadata (procedure/topic/error descriptions and schemas), read
%% through WAMP Interface Reflection. Keyed per realm by {Kind, MatchPolicy,
%% Uri} — a URI, never a registration; the registry does not know it exists.
-define(BONDY_DB_INTERFACE_TAB, bondy_interface).
-define(BONDY_DB_REGISTRY_ACTOR, '$bondy_registry').

%% REGISTRY
%% The RIB (Routing Information Base) summary tables — the replicated
%% routing cells: one cell per (Realm, MatchPolicy, Uri, Node), written
%% only by Node. Maintained by bondy_registry_rib.
-define(BONDY_DB_REGISTRATION_RIB_TAB, bondy_registration_rib).
-define(BONDY_DB_SUBSCRIPTION_RIB_TAB, bondy_subscription_rib).
