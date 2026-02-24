# Claim-Based OIDC Sessions Without User Provisioning

## Goal

Eliminate the requirement to provision a `bondy_rbac_user` record for
OIDC-authenticated users. Instead, identity and group memberships travel with
the ticket claims.

User provisioning (`auto_provision`) becomes opt-in for operators who want
user-specific grants beyond group-level permissions.

## Current Flow (problems marked with >>)

```
1. IdP callback
   bondy_oidc_handler:handle_token_success
     -> extract authid from id_token claims
     >> ensure_user (provisions bondy_rbac_user record)
     >> roles extracted only for auto-provisioning new users
     >> access token VALUE discarded (only expiry stored)
     -> bondy_oidc_ticket:issue (no roles in claims)

2. Cookie arrives at transport
   bondy_http_transport_session
     -> bondy_ticket:verify(Cookie)
     -> set_auth_claims(Pid, Claims)          % raw ticket JWT stored
     >> claims do not carry authid or roles (authroles)

3. WAMP HELLO
   bondy_wamp_protocol:maybe_auth_challenge (cookie branch, line 758)
     >> auth_claims = raw JWT ticket (not decoded claims)
     >> calls bondy_auth:init/3 — user_id => undefined, roles => undefined
     -> bondy_auth_transport_cookie:authenticate — verifies ticket
     -> open_session — authid = undefined, authroles = undefined

4. Session RBAC
   bondy_session:rbac_context
     -> bondy_rbac:get_context(Uri, Authid)
     -> do_role_groupnames(Authid, user, ...) -> bondy_rbac_user:lookup
     >> Without user record: returns [] groups, only 'all' grants apply
```

## Target Flow

```
1. IdP callback
   bondy_oidc_handler:handle_token_success
     -> extract authid from id_token claims
     -> extract roles from id_token AND/OR access_token claims
     -> map IdP roles to Bondy group names (configurable)
     -> bondy_oidc_ticket:issue with authroles in claims
     -> NO user provisioning (unless auto_provision = true)

2. Cookie arrives at transport
   bondy_http_transport_session
     -> bondy_ticket:verify(Cookie) -> {ok, Claims}
     -> set_auth_claims(Pid, Claims)          % decoded claims map

3. WAMP HELLO
   bondy_wamp_protocol:maybe_auth_challenge (cookie branch)
     -> extract authid, authroles from claims
     -> bondy_auth:init/4 with Opts = #{claims => Claims}
        sets user_id => Authid, roles => Authroles
     -> bondy_auth_transport_cookie:authenticate — verifies ticket
     -> open_session — authid and authroles from claims

4. Session RBAC
   bondy_session:rbac_context
     -> bondy_rbac:get_context(Uri, Authid, Authroles)  % NEW /3 arity
     -> traverses Authroles as group memberships
     -> gathers grants for those groups + direct user grants + 'all' grants
```

## Implementation Steps

### Step 1: Extract roles from OIDC tokens

**File: `bondy_oidc_handler.erl`**

The `handle_token_success/7` function currently only extracts `authid` from
the ID token. Add role extraction from both ID token and access token.

Add a new `extract_roles/3` function:
```erlang
extract_roles(IdClaims, AccessToken, Config) ->
    RoleClaim = maps:get(role_claim, Config, <<"roles">>),
    %% Try ID token first, then access token claims
    case extract_claim(RoleClaim, IdClaims) of
        [] -> extract_from_access_token(RoleClaim, AccessToken);
        Roles -> Roles
    end.
```

- Configurable claim name via `role_claim` in provider config (default `<<"roles">>`)
- Falls back to `role` (singular) if `roles` claim is empty
- Supports nested claims e.g. `realm_access.roles` (Keycloak pattern)
- Returns a list of binaries

Also store the access token value in `build_oidc_tokens_map`:
```erlang
case AccessToken of
    #oidcc_token_access{token = AT, expires = Exp} when is_binary(AT) ->
        Map1#{access_token => AT, access_token_expires_at => Exp};
    ...
```

Pass extracted roles to `bondy_oidc_ticket:issue`.

### Step 2: Store roles in ticket claims

**File: `bondy_oidc_ticket.erl`**

Add `authroles` to the claims map:
```erlang
Claims0 = #{
    ...
    authroles => Authroles,       %% NEW — list of Bondy group names
    ...
},
```

The `issue/5` accepts `authroles` in the Opts map:
```erlang
-spec issue(
    RealmUri :: uri(),
    Authid :: binary(),
    OidcProvider :: binary(),
    OidcTokens :: map(),
    Opts :: map()
) -> {ok, JWT :: binary(), Claims :: bondy_ticket:t()} | {error, term()}.
```

### Step 3: Remove mandatory user provisioning

**File: `bondy_oidc_handler.erl`**

Change `handle_token_success` flow:

```
Before:  extract authid -> ensure_user -> issue ticket
After:   extract authid -> extract roles -> issue ticket (with roles)
         -> optionally ensure_user if auto_provision = true
```

The `ensure_user` call moves inside a conditional:
```erlang
case maps:get(auto_provision, Config, false) of
    true ->
        ok = ensure_user(RealmUri, Authid, Config, IdClaims);
    false ->
        ok
end,
```

This is the default — no user provisioning unless the operator explicitly
configures `auto_provision => true` on the provider.

### Step 4: Pass claims through bondy_wamp_protocol

**File: `bondy_wamp_protocol.erl`**

The cookie branch at line 758 currently has unbound variable issues
(`Claims`, `Details` referenced but not bound in function head).

Rewrite the cookie branch:
```erlang
maybe_auth_challenge(
    enabled, Details, Realm,
    #wamp_state{auth_claims = Claims} = St0
) when is_map(Claims) ->
    Ctxt0 = St0#wamp_state.context,
    Ctxt1 = bondy_context:set_request_details(Ctxt0, Details),

    SessionId = bondy_context:session_id(Ctxt1),
    SourceIP = bondy_context:source_ip(Ctxt1),

    %% Extract identity from ticket claims
    Authid = maps:get(authid, Claims),
    Authroles = maps:get(authroles, Claims, []),

    Ctxt = bondy_context:set_authid(Ctxt1, Authid),
    St1 = update_context(Ctxt, St0),

    Opts = #{claims => Claims},

    case bondy_auth:init(SessionId, Realm, Authid, Authroles, SourceIP, Opts) of
        {ok, AuthCtxt} ->
            St2 = St1#wamp_state{auth_context = AuthCtxt},
            ReqMethods = [?WAMP_COOKIE_AUTH],
            case bondy_auth:available_methods(ReqMethods, AuthCtxt) of
                [] ->
                    {error, {no_authmethod, ReqMethods}, St2};
                [Method | _] ->
                    auth_challenge(Method, St2)
            end;
        {error, Reason} ->
            {error, {authentication_failed, Reason}, St1}
    end;
```

Key changes:
- Uses the 6-arity `init` with authid and roles from claims
- Passes `#{claims => Claims}` as Opts for downstream use

### Step 5: Allow bondy_auth:init to work without a user record

**File: `bondy_auth.erl`**

The `init/6` function calls `get_user/3` which throws `{no_such_user, ...}`
when the user doesn't exist. For transport-cookie auth with claims, we need
to tolerate a missing user record.

Add claims-aware handling in `init/6`:

```erlang
init(SessionId, Realm, Username0, Roles0, SourceIP, Opts)
when is_binary(SessionId), is_tuple(Realm), ?IS_IP(SourceIP), is_map(Opts) ->
    try
        RealmUri = bondy_realm:uri(Realm),
        SSORealmUri = bondy_realm:sso_realm_uri(Realm),

        case maps:find(claims, Opts) of
            {ok, Claims} ->
                %% Transport-level auth with claims — no user lookup needed
                init_from_claims(
                    SessionId, Realm, RealmUri, SSORealmUri,
                    Username0, Roles0, SourceIP, Opts, Claims
                );
            error ->
                %% Standard WAMP auth — user lookup required
                init_from_user(
                    SessionId, Realm, RealmUri, SSORealmUri,
                    Username0, Roles0, SourceIP, Opts
                )
        end
    catch
        throw:Reason ->
            {error, Reason}
    end.
```

New `init_from_claims` (private):
```erlang
init_from_claims(
    SessionId, Realm, RealmUri, SSORealmUri,
    Username, Roles, SourceIP, Opts, _Claims
) ->
    %% Try to find the user but don't fail if not found
    User = try
        get_user(RealmUri, SSORealmUri, Username)
    catch
        throw:{no_such_user, _} -> undefined
    end,

    %% For claims-based auth, we trust the provided roles even without
    %% a user record. If the user exists, we validate against their groups.
    {Role, ValidRoles} = case User of
        undefined ->
            %% No user record — trust claim-sourced roles directly
            {undefined, Roles};
        _ ->
            valid_roles(Roles, User)
    end,

    Ctxt = #{
        provider => ?BONDY_AUTH_PROVIDER,
        session_id => SessionId,
        realm_uri => RealmUri,
        sso_realm_uri => SSORealmUri,
        user_id => Username,
        user => User,
        role => Role,
        roles => ValidRoles,
        source_ip => SourceIP,
        host => maps:get(host, Opts, undefined)
    },
    Methods = compute_available_methods(Realm, Ctxt),
    {ok, maps:put(available_methods, Methods, Ctxt)}.
```

Also fix `matches_requirements/2` to handle `User = undefined` safely:
```erlang
matches_requirements(Method, #{user_id := UserId, user := undefined}) ->
    Requirements = maps:to_list((callback_mod(Method)):requirements()),
    lists:all(
        fun
            Match({identification, false}) -> UserId == anonymous;
            Match({identification, true}) -> UserId =/= anonymous;
            Match({authorized_keys, true}) -> false;
            Match({password, true}) -> false;
            Match({password, _}) -> false;
            Match({_, false}) -> true
        end,
        Requirements
    );

matches_requirements(Method, #{user_id := UserId, user := User}) ->
    %% existing implementation
    ...
```

### Step 6: RBAC context with explicit groups

**File: `bondy_rbac.erl`**

Add a new exported `get_context/3` that accepts explicit group memberships:

```erlang
-export([get_context/3]).

-spec get_context(
    RealmUri :: uri(),
    Username :: binary() | anonymous,
    ExplicitGroups :: [binary()]
) -> context().

get_context(RealmUri, Username, ExplicitGroups)
when is_list(ExplicitGroups), ExplicitGroups =/= [] ->
    ProtoUri = bondy_realm:prototype_uri(RealmUri),
    RealmProto = {RealmUri, ProtoUri},

    %% 'all' grants always apply
    Acc0 = lists:map(
        fun({{all, Resource}, Permissions}) ->
            {{<<"group/all">>, Resource}, Permissions}
        end,
        lists:append(
            find_grants(RealmUri, {all, '_'}, group),
            find_grants(ProtoUri, {all, '_'}, group)
        )
    ),

    %% Traverse explicit groups (from IdP claims) for their grants
    {Acc1, Seen1} = acc_grants(ExplicitGroups, group, RealmProto, [], Acc0),

    %% Also gather direct user grants (if any exist in grant tables)
    {Acc2, _} = acc_grants([Username], user, RealmProto, Seen1, Acc1),

    %% Build context from accumulated grants
    build_context(RealmUri, Username, Acc2).
```

Extract the context-building logic from `get_context/3` (private) into a
`build_context/3` helper (or just inline).

**File: `bondy_session.erl`**

Update `get_rbac_context/1` to use the new arity when authroles are present:

```erlang
get_rbac_context(#session{is_anonymous = true, realm_uri = Uri}) ->
    bondy_rbac:get_context(Uri, anonymous);

get_rbac_context(#session{
    authid = Authid, realm_uri = Uri, authroles = Roles
}) when is_list(Roles), Roles =/= [] ->
    bondy_rbac:get_context(Uri, Authid, Roles);

get_rbac_context(#session{authid = Authid, realm_uri = Uri}) ->
    bondy_rbac:get_context(Uri, Authid).
```

### Step 7: RBAC context refresh with explicit groups

**File: `bondy_rbac.erl`**

The `refresh_context/1` function rebuilds the context but currently only uses
`get_context/2`. It needs to preserve explicit groups across refreshes.

Option A: Store explicit groups in the `bondy_rbac_context` record:
```erlang
-record(bondy_rbac_context, {
    realm_uri               ::  binary(),
    username                ::  binary(),
    explicit_groups = []    ::  [binary()],    %% NEW
    exact_grants = #{}      ::  ...,
    pattern_grants          ::  ...,
    epoch                   ::  integer(),
    is_anonymous = false    ::  boolean()
}).
```

Then `refresh_context/1` uses them:
```erlang
refresh_context(#bondy_rbac_context{
    realm_uri = Uri, username = Username,
    explicit_groups = Groups
} = Context) ->
    ...
    case Groups of
        [_ | _] -> get_context(Uri, Username, Groups);
        [] -> get_context(Uri, Username)
    end.
```

Option B: Always re-derive from session authroles. This avoids changing the
record but requires threading the session through refresh.

**Recommendation: Option A** — simpler, self-contained.

### Step 8: Update bondy_http_transport_session

**File: `bondy_http_transport_session.erl`**

Currently stores the raw JWT ticket as `auth_ticket` and decoded claims as
`auth_claims`. Ensure `set_auth_claims/2` stores the decoded claims map
(already the case).

The `auth_claims` should be the decoded claims from `bondy_ticket:verify/1`.
Verify this is what `maybe_set_auth_ticket` in `bondy_http_longpoll_handler`
already does (it calls `bondy_ticket:verify(Ticket)` and stores the claims).

### Step 9: Remove bondy_auth_oidcrp

**File: `bondy_auth_oidcrp.erl`**

Delete the module. The module is superseded by
`bondy_auth_transport_cookie` which is already registered in
`bondy_security.hrl` under `?WAMP_COOKIE_AUTH`.

Keep `?OIDCRP_AUTH` in `bondy_security.hrl`.

Keep `bondy_oidc_ticket:issue` to use `?OIDCRP_AUTH` as the
`authmethod` in ticket claims. This is becuase a ticket in Bondy is the result of having authenticated using another method first.

## Provider Config Schema

The OIDC provider config in the realm gains these keys:

```erlang
#{
    %% ... existing keys ...
    role_claim => <<"roles">>,         %% Claim name for roles (default)
    role_claim_fallback => <<"role">>, %% Fallback claim name
    role_mapping => #{                 %% Optional: map IdP role names to
        <<"admin">> => <<"administrators">>,  %% Bondy group names
        <<"viewer">> => <<"readers">>
    },
    auto_provision => false            %% Default: no user provisioning
}
```

## Session Cleanup

With this design, session cleanup is trivial:
- Session closes -> nothing else to clean up
- Ticket expires -> can't establish new sessions
- No orphaned user records to garbage-collect
- No sync drift between IdP and Bondy user store

If `auto_provision = true`, the operator accepts responsibility for managing
those user records (same as today).

## Verification

1. `rebar3 compile` — clean compilation
2. `rebar3 xref` — no undefined calls
3. Test: OIDC login with `auto_provision = false` (default)
   - User does NOT exist in Bondy
   - IdP token contains `roles: ["editors"]`
   - `editors` group exists in Bondy realm with grants
   - Session opens with authid from IdP, authroles = `["editors"]`
   - RBAC checks use `editors` group grants
4. Test: OIDC login with `auto_provision = true`
   - Same as today — user record created, roles synced
5. Test: session close — no cleanup needed
6. Test: ticket expiry — new `/receive` fails, new login required

## Files Changed (Summary)

| File | Nature of Change |
|------|-----------------|
| `bondy_oidc_handler.erl` | Extract roles from tokens, make provisioning opt-in |
| `bondy_oidc_ticket.erl` | Add `authroles` to ticket claims, use `cookie` authmethod |
| `bondy_wamp_protocol.erl` | Cookie branch: extract authid/roles from claims, use `init/6` |
| `bondy_auth.erl` | `init_from_claims` path: tolerate missing user, trust claim roles |
| `bondy_rbac.erl` | New `get_context/3` with explicit groups, update context record |
| `bondy_session.erl` | `get_rbac_context` uses authroles when present |
| `bondy_http_transport_session.erl` | Verify claims flow correctly |
| `bondy_auth_oidcrp.erl` | Delete (superseded by `bondy_auth_transport_cookie`) |
