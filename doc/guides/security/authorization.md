# Authorization

## Claim-restricted sessions

Some sessions carry their group memberships from the credential rather than
from Bondy's user record. An OIDC session, for example, carries the groups
that the identity provider claims for the subject; Bondy keeps only the
claimed groups that exist in the realm and ignores the rest. Such a session
has a non-empty list of `authroles`, and Bondy computes its permissions from
that list.

A claim-restricted session receives the grants of:

- the user itself (grants whose role is the username);
- each claimed group, and every group that a claimed group is a member of,
  transitively;
- the `all` group.

Grants are read from the realm and from its prototype realm.

The session does **not** receive grants through the groups that the user's
locally stored record is a member of. The claimed groups are the only source
of group-derived permissions, so a claim-restricted session cannot exceed what
its claims allow
(`bondy_rbac_SUITE:explicit_groups_exclude_local_memberships`,
`bondy_rbac_SUITE:explicit_groups_deep_inheritance`).

A session without `authroles` receives the grants of the user, of every group
the user is a member of (transitively), and of the `all` group.

## Ticket revocation

A ticket is checked against the copy that Bondy stores when it issues the
ticket. Revoking a ticket replaces that copy with a revocation marker, which
replicates like any other write and stays until the ticket would have
expired. `bondy.ticket.revoke` revokes the ticket passed to it, and
`bondy.ticket.revoke_all` revokes every ticket of a user. Deleting a user, or
any update to it (disabling it and changing its credentials included), does
the same.

A node refuses a revoked ticket once the marker has reached it, whatever
`security.ticket.allow_not_found` says (`bondy_http_verify_SUITE`:
`revoked_ticket_is_rejected`; `bondy_ticket_store_test`:
`revoke_unseen_ticket`). That setting (`on | off`, default `on`) decides only
what a node does with a valid ticket of which it holds neither a copy nor a
marker, typically one issued on another node that has not replicated yet:
`on` accepts it on its signature, `off` refuses it.

The stored copy exists only for scopes whose persistence is on:
`security.ticket.scope.{local,sso,client_local,client_sso}.persistence`, each
`on` by default. A ticket issued into a scope whose persistence is `off` is
accepted on its signature alone, and cannot be revoked.
