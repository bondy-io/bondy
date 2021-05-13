# Migrating to 0.9.0

## Authmethods changes
In 0.9.0 a new 'anonymous' authentication method is introduced and clearly distinguished from the 'trust' method.

* In 'anonymous' authentication a client connects using the 'anonymous' username and potentially requesting the 'anonymous' authrole (the anonymous user is by default a member of the anonymous group only). It allows the creation of a session without performing the authentication challenge step. An anonymous user is only restricted by the 'anonymous' group restrictions and the anonymous group cannot be a member of another group.

* The 'trust' method requires the client to provide an existing authid (username). It allows the creation of a session for the authid without performing the authentication challenge step. As opposed to 'anonymous' all restrictions made in the RBAC system for this user applies e.g. group membership, permissions granted, etc.

In previous versions a configuration like the following was used

```javascript
{
    "usernames" : ["anonymous"],
    "authmethod" : "trust",
    "cidr" : "0.0.0.0/0",
    "meta" : {
        "description" : "Allows all users from any network authenticate as anonymous."
    }
}
```

That is no longer valid.  You need to change the authmethod value from 'trust' to 'anonymous' resulting in the following config block:

```javascript
{
    "usernames" : ["anonymous"],
    "authmethod" : "anonymous",
    "cidr" : "0.0.0.0/0",
    "meta" : {
        "description" : "Allows all users from any network authenticate as anonymous."
    }
}
```

