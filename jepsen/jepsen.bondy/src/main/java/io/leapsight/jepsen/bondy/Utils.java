/*
 * SPDX-FileCopyrightText: 2016 - 2026 Leapsight
 * SPDX-License-Identifier: Apache-2.0
 */

package io.leapsight.jepsen.bondy;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.ConnectException;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.URL;
import java.net.UnknownHostException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * The Java half of jepsen.bondy: renders the per-node configuration the
 * db/setup! hook installs, and is the HTTP client the workload drives the
 * Bondy Admin API with. Mirrors the layout of io.leapsight.jepsen.Utils in
 * jepsen.bondymst.
 *
 * Everything here is written against contracts read from the Bondy source:
 *
 *  - The release script `bin/bondy` cd's to the release root and its
 *    pre-start hook renders `etc/bondy.conf` with the release's own schema,
 *    so the conf is written relative to the install dir (`/bondy`, see
 *    {@link #INSTALL_DIR}).
 *    `vm.args` takes the node name and cookie from `BONDY_ERL_NODENAME` /
 *    `BONDY_ERL_DISTRIBUTED_COOKIE`, which relx only expands when
 *    `RELX_REPLACE_OS_VARS=true` is in the environment (config/prod/vm.args),
 *    and distribution needs `ERL_DIST_PORT` in the environment too (see
 *    {@link #DIST_PORT}).
 *  - Cluster membership uses `cluster.peer_discovery.type = list`, i.e.
 *    partisan_peer_discovery_list, whose `addresses` are `bondy@<ip>:<port>`
 *    strings (it drops its own entry, so every node lists every node).
 *    `cluster.peer_ip` must be an IP literal (schema validator
 *    `ip_address`), and peer discovery being on requires
 *    `cluster.tls.allow_insecure = on` (bondy_app:guard_peer_plane/0).
 *  - Admin API (`priv/specs/bondy_admin_api.json`, no security):
 *    `POST /realms/:realm_uri/users` with a JSON body calls
 *    `bondy.user.add(Realm, Body)` and answers with the user;
 *    `GET /realms/:realm_uri/users` calls `bondy.user.list(Realm)` and
 *    answers with every user, unpaginated. The minimal body is
 *    `{"username": ...}` (bondy_rbac_user's validator: username required,
 *    3..254 bytes, casefolded; every other required field has a default).
 */
public final class Utils {

  private Utils() {}

  /**
   * Where the db installs the release on every node. Not a choice: the
   * release's `bin/hooks/pre_start` hardcodes `BONDY_ETC_DIR=/bondy/etc`
   * and, inside a container (`/.dockerenv` present), forces data/log/tmp/run
   * to `/bondy/*` as well — the release is not relocatable, and this is the
   * path deployment/Dockerfile ships it at.
   */
  public static final String INSTALL_DIR = "/bondy";

  /** Partisan peer port (the schema default for `cluster.peer_port`). */
  public static final int PEER_PORT = 18086;

  /**
   * The Erlang distribution port. The release runs epmd-less: the hidden
   * `vm.distribution.port` key (default 27780) puts `-env ERL_DIST_PORT` in
   * the VM args and `vm.distribution.epmd.start` defaults to off, and the
   * relx start script adds `-erl_epmd_port` ONLY when the shell variable
   * `ERL_DIST_PORT` is set (deployment/Dockerfile: `ENV ERL_DIST_PORT=27780`;
   * fly.toml sets its own). Without it the VM tries to register with an epmd
   * that is not running and dies with `register/listen error: econnrefused`.
   * Same value on every node, as `erl_epmd` assumes.
   */
  public static final int DIST_PORT = 27780;

  /** The `early` admin listener: `/ping`, `/ready` and the Admin API. */
  public static final int ADMIN_PORT = 18081;

  /** The client-facing listener (WAMP over WebSocket, API Gateway). */
  public static final int GATEWAY_PORT = 18080;

  /**
   * Bounded so a partitioned node fails an operation as `:info` within the
   * nemesis window rather than parking a worker for minutes: a request that
   * cannot connect fails at once (ConnectException), one that connects but
   * never answers fails after {@link #READ_TIMEOUT_MS}.
   */
  public static final int CONNECT_TIMEOUT_MS = 5_000;
  public static final int READ_TIMEOUT_MS = 10_000;

  /* ------------------------------------------------------------------ */
  /* Node naming and configuration rendering                             */
  /* ------------------------------------------------------------------ */

  /**
   * The node's IP as seen from the control container. Resolved rather than
   * hard-coded: docker compose assigns the addresses, and both the node
   * name (`bondy@<ip>`) and `cluster.peer_ip` must carry a literal.
   */
  public static String nodeIp(Object node) throws UnknownHostException {
    return InetAddress.getByName(node.toString()).getHostAddress();
  }

  public static String erlangNodeName(Object node) throws UnknownHostException {
    return "bondy@" + nodeIp(node);
  }

  /**
   * The `bondy.conf` for `currentNode`. Every node gets the same file
   * except for its own `cluster.peer_ip`.
   *
   * `test` is the Jepsen test map; `:nodes` is the node list and
   * `:aae-interval-ms` the anti-entropy tick (`db.aae.interval`).
   */
  @SuppressWarnings("unchecked")
  public static String configuration(Map<Object, Object> test, Object currentNode)
      throws UnknownHostException {
    List<Object> nodesObj = (List<Object>) get(test, ":nodes");
    List<String> nodes = nodesObj.stream()
        .map(Object::toString)
        .sorted()
        .collect(Collectors.toList());

    Object aae = get(test, ":aae-interval-ms");
    long aaeIntervalMs = aae == null ? 500L : Long.parseLong(aae.toString());

    StringBuilder sb = new StringBuilder();
    sb.append("## Rendered by jepsen.bondy for ").append(currentNode).append('\n');
    sb.append("platform_data_dir = ").append(INSTALL_DIR).append("/data\n");
    sb.append("platform_log_dir = ").append(INSTALL_DIR).append("/log\n");
    sb.append("platform_tmp_dir = ").append(INSTALL_DIR).append("/tmp\n");
    sb.append("platform_runtime_dir = ").append(INSTALL_DIR).append("/run\n");
    sb.append("security.config_file = ").append(INSTALL_DIR)
        .append("/etc/security_config.json\n");
    sb.append("log.level = info\n");
    sb.append("log.handlers.default.level = info\n");

    // Listeners: the early admin listener the probes and the Admin API live
    // on, and the client-facing gateway listener for later WAMP workloads.
    sb.append("listeners.admin.transport = tcp\n");
    sb.append("listeners.admin.protocol = http\n");
    sb.append("listeners.admin.port = ").append(ADMIN_PORT).append('\n');
    sb.append("listeners.admin.start_phase = early\n");
    sb.append("listeners.admin.services = admin_api, admin, metrics\n");
    sb.append("listeners.admin.ip = 0.0.0.0\n");
    sb.append("listeners.admin.ip_version = 4\n");
    sb.append("listeners.api_gateway_http.transport = tcp\n");
    sb.append("listeners.api_gateway_http.protocol = http\n");
    sb.append("listeners.api_gateway_http.port = ").append(GATEWAY_PORT).append('\n');
    sb.append("listeners.api_gateway_http.services = api_gateway, wamp_ws\n");
    sb.append("listeners.api_gateway_http.ip = 0.0.0.0\n");
    sb.append("listeners.api_gateway_http.ip_version = 4\n");

    // Cluster: static peer list, one entry per node (the agent drops its
    // own). Fast discovery so a node killed and restarted by the nemesis
    // rejoins within a couple of seconds.
    sb.append("cluster.peer_ip = ").append(nodeIp(currentNode)).append('\n');
    sb.append("cluster.peer_port = ").append(PEER_PORT).append('\n');
    sb.append("cluster.tls.allow_insecure = on\n");
    sb.append("cluster.automatic_leave = off\n");
    sb.append("cluster.peer_discovery.enabled = on\n");
    sb.append("cluster.peer_discovery.type = list\n");
    sb.append("cluster.peer_discovery.initial_delay = 1s\n");
    sb.append("cluster.peer_discovery.polling_interval = 2s\n");
    sb.append("cluster.peer_discovery.timeout = 5s\n");
    int i = 1;
    for (String n : nodes) {
      sb.append("cluster.peer_discovery.config.addresses.").append(i++)
          .append(" = ").append(erlangNodeName(n)).append(':')
          .append(PEER_PORT).append('\n');
    }

    // Anti-entropy: what makes acknowledged writes reach every replica
    // after a partition heals.
    sb.append("db.aae = on\n");
    sb.append("db.aae.interval = ").append(aaeIntervalMs).append("ms\n");
    return sb.toString();
  }

  /** The master realm; the Admin API's calls are authorised against it. */
  public static final String MASTER_REALM = "com.leapsight.bondy";

  /**
   * The declarative security configuration every node applies at boot.
   * Applied on every node independently (the same file, the same way a
   * multi-node deployment ships it), so both realms exist on each node
   * from its first boot, before any client reaches it.
   *
   * Two realms:
   *
   *  - The master realm, with the grant the Admin API needs. An endpoint
   *    whose spec declares no security scheme (`"security": {}`, every
   *    admin path) is served as the anonymous user on the master realm
   *    (bondy_http_gateway_rest_handler:is_authorized/3), and the WAMP
   *    call it performs (`bondy.user.add` etc.) is then authorised by the
   *    master realm's RBAC — the hardened defaults refuse it with
   *    `wamp.error.not_authorized`. deployment/fly/config/security_config.json
   *    grants the anonymous role `wamp.call` on every URI for exactly this
   *    reason; this is that grant, and nothing more.
   *  - The workload realm, empty: the users are what the workload writes.
   */
  public static String securityConfig(String realmUri) {
    return "[\n" +
        "  {\n" +
        "    \"uri\": \"" + MASTER_REALM + "\",\n" +
        "    \"authmethods\": [\"anonymous\"],\n" +
        "    \"security_enabled\": true,\n" +
        "    \"users\": [],\n" +
        "    \"groups\": [],\n" +
        "    \"sources\": [\n" +
        "      {\"usernames\": [\"anonymous\"], \"authmethod\": \"anonymous\",\n" +
        "       \"cidr\": \"0.0.0.0/0\", \"meta\": {}}\n" +
        "    ],\n" +
        "    \"grants\": [\n" +
        "      {\"permissions\": [\"wamp.call\"], \"uri\": \"\", \"match\": \"prefix\",\n" +
        "       \"roles\": [\"anonymous\"]}\n" +
        "    ]\n" +
        "  },\n" +
        "  {\n" +
        "    \"uri\": \"" + realmUri + "\",\n" +
        "    \"description\": \"jepsen.bondy workload realm\",\n" +
        "    \"authmethods\": [\"anonymous\", \"password\"],\n" +
        "    \"security_enabled\": true,\n" +
        "    \"users\": [],\n" +
        "    \"groups\": [],\n" +
        "    \"sources\": [],\n" +
        "    \"grants\": []\n" +
        "  }\n" +
        "]\n";
  }

  /* ------------------------------------------------------------------ */
  /* HTTP client                                                         */
  /* ------------------------------------------------------------------ */

  public static Client createClient(Object node) {
    return new Client(node.toString());
  }

  public static String node(Client client) {
    return client.node;
  }

  /** `POST /realms/:realm/users` with `{"username": username}`. */
  public static HttpResult userAdd(Client client, String realm, String username)
      throws Exception {
    return client.userAdd(realm, username);
  }

  /** `GET /realms/:realm/users`. The body is the JSON array of users. */
  public static HttpResult usersRead(Client client, String realm) throws Exception {
    return client.usersRead(realm);
  }

  /** `GET /ready` on the admin listener. */
  public static HttpResult ready(Client client) throws Exception {
    return client.get("/ready");
  }

  /**
   * An HTTP outcome the Clojure side maps onto a Jepsen op type. Statuses
   * are handed back rather than turned into exceptions here, so that the
   * mapping — which is the correctness-relevant decision — lives in one
   * place, next to the checker.
   */
  public static final class HttpResult {
    public final int status;
    public final String body;

    HttpResult(int status, String body) {
      this.status = status;
      this.body = body;
    }

    @Override
    public String toString() {
      return "HttpResult{status=" + status + ", body=" + body + "}";
    }
  }

  public static final class Client {
    final String node;

    Client(String node) {
      this.node = node;
    }

    HttpResult userAdd(String realm, String username) throws Exception {
      String body = "{\"username\": \"" + username + "\"}";
      return request("POST", "/realms/" + realm + "/users", body);
    }

    HttpResult usersRead(String realm) throws Exception {
      return request("GET", "/realms/" + realm + "/users", null);
    }

    HttpResult get(String path) throws Exception {
      return request("GET", path, null);
    }

    /**
     * One request. A refused connection is {@link BondyNodeDownException}
     * (the request provably never reached a server); a connect or read
     * timeout is {@link BondyTimeoutException} (indeterminate). Any other
     * I/O failure propagates as-is (also indeterminate).
     */
    private HttpResult request(String method, String path, String jsonBody)
        throws Exception {
      URL u = new URI("http://" + node + ":" + ADMIN_PORT + path).toURL();
      HttpURLConnection conn = (HttpURLConnection) u.openConnection();
      try {
        conn.setRequestMethod(method);
        conn.setConnectTimeout(CONNECT_TIMEOUT_MS);
        conn.setReadTimeout(READ_TIMEOUT_MS);
        conn.setRequestProperty("Accept", "application/json");
        if (jsonBody != null) {
          conn.setDoOutput(true);
          conn.setRequestProperty("Content-Type", "application/json");
          byte[] bytes = jsonBody.getBytes(StandardCharsets.UTF_8);
          conn.setFixedLengthStreamingMode(bytes.length);
          try (OutputStream out = conn.getOutputStream()) {
            out.write(bytes);
          }
        }
        int status = conn.getResponseCode();
        InputStream is = status >= 400 ? conn.getErrorStream() : conn.getInputStream();
        return new HttpResult(status, body(is));
      } catch (ConnectException e) {
        throw new BondyNodeDownException();
      } catch (SocketTimeoutException e) {
        throw new BondyTimeoutException();
      } finally {
        conn.disconnect();
      }
    }
  }

  /* ------------------------------------------------------------------ */
  /* Helpers                                                             */
  /* ------------------------------------------------------------------ */

  /** Look a keyword up in the Jepsen test map by its printed name. */
  private static Object get(Map<Object, Object> map, String keyword) {
    for (Map.Entry<Object, Object> e : map.entrySet()) {
      if (keyword.equals(e.getKey().toString())) {
        return e.getValue();
      }
    }
    return null;
  }

  private static String body(InputStream is) throws IOException {
    if (is == null) return "";
    StringBuilder sb = new StringBuilder();
    try (BufferedReader r =
             new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8))) {
      String line;
      while ((line = r.readLine()) != null) sb.append(line);
    }
    return sb.toString();
  }
}
