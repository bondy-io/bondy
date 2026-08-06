# Error Catalogue

Every failure Bondy reports to a peer is one error value, projected onto the
transport in use. A WAMP `ERROR` carries the error's URI as its `ErrorUri`, one
human-readable sentence as `Args[0]`, and the payload below as `KWArgs`. An HTTP
API Gateway response carries the same payload as its JSON body, with a status
code derived from the same URI. Identifying a failure therefore means the same
thing on both transports.

## The error payload

```json
{
  "uri":         "bondy.error.invalid_value",
  "code":        "invalid_value",
  "handle":      "C010",
  "nature":      "permanent",
  "message":     "The operation failed due to an invalid value.",
  "description": "The value for property 'email' is invalid.",
  "details":     { "key": "email", "value": "not-an-address" },
  "causes":      [],
  "doc_uri":     "/errors/C010"
}
```

| Field | Contract |
| --- | --- |
| `uri` | The error's identity, and the only field to branch on. Always present, always a valid URI. |
| `code` | A short token retained for compatibility with the payloads Bondy emitted before this catalogue existed. Fixed per error type, and not always derivable from `uri`. New code should not branch on it. |
| `handle` | A stable identifier for support and documentation, such as `C010`. Never interpreted by software. |
| `nature` | `transient` or `permanent`. See [Retry semantics](#retry-semantics). |
| `message` | One sentence, safe to show a user. Also `Args[0]` of a WAMP `ERROR`. |
| `description` | A longer explanation, safe to show a user. May be empty. |
| `details` | Structured context: the offending key, the limit reached, the realm that was missing. Values are JSON scalars, lists or maps. |
| `causes` | Errors that led to this one, outermost first. Each entry has this same shape. Usually empty. |
| `doc_uri` | Path to this error's entry in the catalogue. |
| `trace_id` | Present only on an internal error. A W3C Trace Context `trace-id`: 32 lowercase hex characters. |

Every key of `details` also appears at the top level of the payload, because
`key`, `value`, `limit` and `keys` have always been read from there. Read
`details`; the top-level copies exist for older clients.

### What a peer never receives

Stacktraces, exception reasons and internal terms are held outside the payload
and written only to the log. A failure Bondy cannot explain safely is reported
as `bondy.error.internal_error` with a `trace_id` and nothing else. The same
`trace_id` appears on the server log entry that holds the actual reason, so an
operator can join the two without the peer ever seeing it.

Every value in the payload is JSON-encodable by construction. A term with no
JSON representation is rendered as text, and both nesting depth and total size
are bounded.

## Retry semantics

`nature` tells a client whether retrying can succeed.

`transient` means the condition is in the server, the cluster or the network.
The same request may succeed later, so retry with backoff.
`bondy.error.temporarily_unavailable` is worth singling out: the node has not
yet confirmed its security state with the rest of the cluster, so another node
may answer immediately.

`permanent` means the request itself is the problem. Retrying it unchanged
fails identically. Change the request, the credentials or the permissions.

Two URIs are easy to confuse. `wamp.error.not_authorized` is the router refusing
a peer, and is permanent. `wamp.error.authorization_failed` is the router being
unable to decide whether the operation is permitted, and is transient.

## The catalogue

`HTTP` is the status an API Gateway response uses. An API specification can
override it per host or version through its `status_codes` map. A `†` marks a
type that shares another's URI.

### Authentication

| Type | URI | Code | Nature | HTTP | Handle |
| --- | --- | --- | --- | --- | --- |
| `invalid_credentials` | `bondy.error.invalid_credentials` | `invalid_credentials` | permanent | 401 | A001 |
| `authentication_failed` | `wamp.error.authentication_failed` | `authentication_failed` | permanent | 401 | A002 |
| `token_expired` | `bondy.error.token_expired` | `token_expired` | permanent | 401 | A003 |
| `token_invalid` | `bondy.error.token_invalid` | `token_invalid` | permanent | 401 | A004 |
| `not_auth_method` | `wamp.error.not_auth_method` | `not_auth_method` | permanent | 400 | A005 |
| `no_such_principal` | `wamp.error.no_such_principal` | `no_such_principal` | permanent | 400 | A006 |
| `no_such_user` | `wamp.error.no_such_principal` | `wamp.error.no_such_principal` | permanent | 400 | A007 † |

### Authorization

| Type | URI | Code | Nature | HTTP | Handle |
| --- | --- | --- | --- | --- | --- |
| `forbidden` | `bondy.error.forbidden` | `forbidden` | permanent | 403 | Z001 |
| `not_authorized` | `wamp.error.not_authorized` | `not_authorized` | permanent | 403 | Z002 |
| `authorization_failed` | `wamp.error.authorization_failed` | `authorization_failed` | transient | 500 | Z003 |
| `insufficient_permissions` | `bondy.error.insufficient_permissions` | `insufficient_permissions` | permanent | 403 | Z004 |
| `role_not_allowed` | `bondy.error.role_not_allowed` | `role_not_allowed` | permanent | 403 | Z005 |
| `no_such_role` | `wamp.error.no_such_role` | `no_such_role` | permanent | 400 | Z006 |
| `unauthorized` | `wamp.error.not_authorized` | `not_authorized` | permanent | 403 | Z007 † |

### Client and request

| Type | URI | Code | Nature | HTTP | Handle |
| --- | --- | --- | --- | --- | --- |
| `bad_request` | `bondy.error.bad_request` | `bad_request` | permanent | 400 | C001 |
| `invalid_request` | `bondy.error.invalid_request` | `invalid_request` | permanent | 400 | C002 |
| `not_found` | `bondy.error.not_found` | `not_found` | permanent | 404 | C003 |
| `already_exists` | `bondy.error.already_exists` | `already_exists` | permanent | 400 | C004 |
| `method_not_allowed` | `bondy.error.method_not_allowed` | `method_not_allowed` | permanent | 405 | C005 |
| `request_timeout` | `bondy.error.request_timeout` | `request_timeout` | transient | 408 | C006 |
| `timeout` | `wamp.error.timeout` | `timeout` | transient | 504 | C007 |
| `argument_error` | `wamp.error.invalid_argument` | `invalid_argument` | permanent | 400 | C008 † |
| `invalid_argument` | `wamp.error.invalid_argument` | `invalid_argument` | permanent | 400 | C009 |
| `invalid_value` | `bondy.error.invalid_value` | `invalid_value` | permanent | 400 | C010 |
| `missing_required_value` | `bondy.error.missing_required_value` | `missing_required_value` | permanent | 400 | C011 |
| `property_range_limit` | `bondy.error.property_range_limit` | `property_range_limit` | permanent | 400 | C012 |
| `inconsistency_error` | `bondy.error.inconsistency_error` | `invalid_argument` | permanent | 400 | C013 |
| `invalid_data` | `bondy.error.invalid_data` | `invalid_data` | permanent | 400 | C014 |
| `invalid_uri` | `wamp.error.invalid_uri` | `invalid_uri` | permanent | 400 | C015 |
| `conflict` | `bondy.error.conflict` | `conflict` | permanent | 409 | C016 |
| `proxy_protocol_error` | `bondy.error.proxy_protocol_error` | `proxy_protocol_error` | permanent | 403 | C017 |
| `badarg` | `wamp.error.invalid_argument` | `invalid_argument` | permanent | 400 | C018 † |

### Limits

| Type | URI | Code | Nature | HTTP | Handle |
| --- | --- | --- | --- | --- | --- |
| `rate_limit_exceeded` | `bondy.error.rate_limit_exceeded` | `rate_limit_exceeded` | transient | 429 | L001 |
| `quota_exceeded` | `bondy.error.quota_exceeded` | `quota_exceeded` | permanent | 429 | L002 |
| `too_many_requests` | `bondy.error.too_many_requests` | `too_many_requests` | transient | 429 | L003 |
| `too_many_sessions` | `bondy.error.too_many_sessions` | `too_many_sessions` | transient | 429 | L004 |
| `too_large_payload` | `bondy.error.too_large_payload` | `too_large_payload` | permanent | 413 | L005 |
| `too_many_results` | `bondy.error.too_many_results` | `too_many_results` | permanent | 400 | L006 |
| `body_max_bytes_exceeded` | `bondy.error.body_max_bytes_exceeded` | `body_max_bytes_exceeded` | permanent | 400 | L007 |
| `payload_size_exceeded` | `wamp.error.payload_size_exceeded` | `payload_size_exceeded` | permanent | 413 | L008 |

### API Gateway and OAuth2

| Type | URI | Code | Nature | HTTP | Handle |
| --- | --- | --- | --- | --- | --- |
| `oauth2_invalid_request` | `bondy.error.invalid_request` | `invalid_request` | permanent | 400 | G001 † |
| `oauth2_invalid_client` | `bondy.error.invalid_client` | `invalid_client` | permanent | 401 | G002 |
| `oauth2_invalid_grant` | `bondy.error.invalid_grant` | `invalid_grant` | permanent | 400 | G003 |
| `oauth2_unauthorized_client` | `bondy.error.unauthorized_client` | `unauthorized_client` | permanent | 400 | G004 |
| `oauth2_unsupported_grant_type` | `bondy.error.unsupported_grant_type` | `unsupported_grant_type` | permanent | 400 | G005 |
| `oauth2_invalid_scope` | `bondy.error.invalid_scope` | `invalid_scope` | permanent | 400 | G006 |
| `unsupported_token_type` | `bondy.error.unsupported_token_type` | `unsupported_token_type` | transient | 503 | G007 |
| `invalid_scheme` | `bondy.error.invalid_client` | `invalid_client` | permanent | 401 | G008 † |
| `invalid_expression` | `bondy.error.http_gateway.invalid_expression` | `invalid_expression` | permanent | 500 | G009 |

### WAMP protocol

| Type | URI | Code | Nature | HTTP | Handle |
| --- | --- | --- | --- | --- | --- |
| `no_such_realm` | `wamp.error.no_such_realm` | `wamp.error.no_such_realm` | permanent | 502 | W001 |
| `no_such_procedure` | `wamp.error.no_such_procedure` | `no_such_procedure` | permanent | 501 | W002 |
| `no_such_registration` | `wamp.error.no_such_registration` | `no_such_registration` | permanent | 502 | W003 |
| `no_such_subscription` | `wamp.error.no_such_subscription` | `no_such_subscription` | permanent | 502 | W004 |
| `no_such_session` | `wamp.error.no_such_session` | `no_such_session` | permanent | 500 | W005 |
| `procedure_already_exists` | `wamp.error.procedure_already_exists` | `procedure_already_exists` | permanent | 400 | W006 |
| `option_not_allowed` | `wamp.error.option_not_allowed` | `option_not_allowed` | permanent | 400 | W007 |
| `disclose_me_not_allowed` | `wamp.error.disclose_me.not_allowed` | `not_allowed` | permanent | 400 | W008 |
| `no_eligible_callee` | `wamp.error.no_eligible_callee` | `no_eligible_callee` | transient | 502 | W009 |
| `no_available_callee` | `wamp.error.no_available_callee` | `no_available_callee` | transient | 502 | W010 |
| `protocol_violation` | `wamp.error.protocol_violation` | `protocol_violation` | permanent | 400 | W011 |
| `invalid_payload` | `wamp.error.invalid_payload` | `invalid_payload` | permanent | 400 | W012 |
| `canceled` | `wamp.error.canceled` | `canceled` | permanent | 400 | W013 |
| `not_in_session` | `bondy.error.not_in_session` | `not_in_session` | permanent | 400 | W014 |
| `deprecated_procedure` | `bondy.error.deprecated_procedure` | `deprecated_procedure` | permanent | 410 | W015 |
| `feature_not_supported` | `wamp.error.feature_not_supported` | `feature_not_supported` | permanent | 501 | W016 |

### Cluster

| Type | URI | Code | Nature | HTTP | Handle |
| --- | --- | --- | --- | --- | --- |
| `node_down` | `bondy.error.node_down` | `node_down` | transient | 503 | K001 |
| `cluster_not_formed` | `bondy.error.cluster_not_formed` | `cluster_not_formed` | transient | 503 | K002 |
| `partition_detected` | `bondy.error.partition_detected` | `partition_detected` | transient | 503 | K003 |

### System

| Type | URI | Code | Nature | HTTP | Handle |
| --- | --- | --- | --- | --- | --- |
| `internal_error` | `bondy.error.internal_error` | `internal_error` | transient | 500 | S001 |
| `unknown_error` | `bondy.error.unknown_error` | `unknown_error` | transient | 500 | S002 |
| `service_unavailable` | `wamp.error.unavailable` | `unavailable` | transient | 503 | S003 |
| `unavailable` | `bondy.error.unavailable` | `unavailable` | transient | 503 | S004 |
| `temporarily_unavailable` | `bondy.error.temporarily_unavailable` | `temporarily_unavailable` | transient | 503 | S005 |
| `gateway_timeout` | `bondy.error.gateway_timeout` | `gateway_timeout` | transient | 504 | S006 |
| `bad_gateway` | `bondy.error.bad_gateway` | `bad_gateway` | transient | 503 | S007 |
| `disk_full` | `bondy.error.disk_full` | `disk_full` | transient | 500 | S008 |
| `out_of_memory` | `bondy.error.out_of_memory` | `out_of_memory` | transient | 500 | S009 |
| `too_many_connections` | `bondy.error.too_many_connections` | `too_many_connections` | transient | 503 | S010 |
| `too_many_processes` | `bondy.error.too_many_processes` | `too_many_processes` | transient | 500 | S011 |
| `insufficient_resources` | `bondy.error.insufficient_resources` | `insufficient_resources` | transient | 503 | S012 |
| `system_shutdown` | `wamp.error.system_shutdown` | `system_shutdown` | transient | 500 | S013 |
| `noproc` | `wamp.error.unavailable` | `unavailable` | transient | 503 | S014 † |
| `overload` | `bondy.error.too_many_requests` | `too_many_requests` | transient | 429 | S015 † |
| `overloaded` | `bondy.error.too_many_requests` | `too_many_requests` | transient | 429 | S016 † |
### POSIX errors

Errors named by a POSIX atom — `enoent`, `econnrefused`, `etimedout` and the
rest — are not listed. They resolve to `bondy.error.<name>`, carry the message
the runtime gives them, are always `transient`, and use the handle `P-<name>`.
