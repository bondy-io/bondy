# HTTP connector: liveness probe

The HTTP connector forwards WAMP calls to HTTP services declared under
`http_connector.services.$service.*`. While a service's connection pool is up,
the connector probes the service on a timer, independently of call traffic, so
that an upstream that stops answering is detected even when no call reaches it.

## `http_connector.services.$service.liveness.*`

| Key | Default | Meaning |
| --- | --- | --- |
| `liveness.enabled` | `on` | Run the periodic probe while the pool is up. |
| `liveness.path` | `/` | Path probed, relative to the service's `base_url`. |
| `liveness.method` | `head` | `get` or `head`. |
| `liveness.interval` | `30s` | Time between probes while the pool is up. |
| `liveness.timeout` | `5s` | Connect and receive timeout of one probe. |
| `liveness.failure_threshold` | `3` | Consecutive failed probes that mark the pool down and raise the alarm. |
| `liveness.success_threshold` | `1` | Consecutive successful probes after a recovery that clear the alarm. |

A probe succeeds when the service returns any HTTP response, whatever its
status code. It fails when the request itself fails, for example on a timeout or
a refused connection.

## Down and up

After `failure_threshold` consecutive failed probes the connector:

- marks the pool down and closes it. Calls to the service then fail at once
  with `bondy.error.bad_gateway` instead of waiting on the upstream;
- raises the alarm `{http_connector_service_down, Service}`, with the
  description "An HTTP connector service is failing its liveness probe." and
  details `service`, `endpoint` and `reason` (the last probe error);
- logs "Liveness probe failure threshold reached, marking pool down" at
  warning.

While the pool is down, the connector retries the same probe on its own retry
schedule. The first success marks the pool up, and calls are served again. That
success counts as the first of `success_threshold`. The alarm is cleared when
`success_threshold` consecutive probes have succeeded, so with the default of
`1` it clears together with the pool coming up. A larger value keeps the alarm
raised through the next periodic probes, until the upstream has answered that
many times in a row.

A pool starts down and is marked up by its first successful probe; until then,
calls fail with `bondy.error.bad_gateway` and the probe is retried, with no
alarm. With `liveness.enabled = off`, no probe runs once the pool is up, so the
connector neither marks the pool down nor raises the alarm.

## Observing it

The alarm appears in `bondy_alarm_active{alarm_id}` and `bondy_alarms`. The
probe and pool state are exported as
`bondy_http_connector_liveness_probes_total{service, outcome}`,
`bondy_http_connector_liveness_probe_duration_milliseconds{service}`,
`bondy_http_connector_pool_up{service}` and
`bondy_http_connector_pool_status_changes_total{service, status}`. See
[Metrics](../reference/metrics.md#http-connector).
