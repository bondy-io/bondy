/*
 * SPDX-FileCopyrightText: 2023 - 2026 Leapsight
 * SPDX-License-Identifier: Apache-2.0
 */

package io.leapsight.jepsen;

import java.io.BufferedReader;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.ConnectException;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicReference;
import java.util.stream.Collectors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Static helpers and the HTTP client the Clojure side uses to talk to
 * a bondy_mst_jepsen node. Mirrors the layout of
 * com.rabbitmq.jepsen.Utils in ra-kv-store.
 */
@SuppressWarnings("unchecked")
public class Utils {

  private static final Logger LOGGER = LoggerFactory.getLogger("jepsen.bondymst");

  private static final int HTTP_REQUEST_TIMEOUT = 600_000;

  /** Table names the Erlang side opens. Keep in sync with sys.config. */
  private static final List<String> TABLES = List.of(
      "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9");

  /** Default realm under the single namespace; tests use one realm. */
  private static final String DEFAULT_REALM = "r1";

  private static final Map<String, String> NODE_TO_ERLANG_NODE =
      new ConcurrentHashMap<>();

  /* ------------------------------------------------------------------ */
  /* Erlang node + sys.config rendering                                  */
  /* ------------------------------------------------------------------ */

  public static String erlangNodeName(Object n) {
    return String.format("bondy_mst@%s", n.toString());
  }

  /**
   * Render the per-node sys.config the Jepsen db/setup! hook installs
   * into the release tree. The peer list is the other two cluster
   * nodes; the current node is omitted so disterl connections only
   * fan out.
   */
  public static String configuration(Map<Object, Object> test, Object currentNode) {
    List<Object> nodesObj = (List<Object>) get(test, ":nodes");
    List<String> nodes = nodesObj.stream()
        .map(Object::toString)
        .sorted()
        .collect(Collectors.toList());
    String node = currentNode.toString();

    String peerList = nodes.stream()
        .filter(n -> !n.equals(node))
        .map(n -> "'" + erlangNodeName(n) + "'")
        .collect(Collectors.joining(", "));

    NODE_TO_ERLANG_NODE.putIfAbsent(node, erlangNodeName(node));

    Object syncMs = get(test, ":sync-interval-ms");
    long syncIntervalMs = syncMs == null ? 200L
        : Long.parseLong(syncMs.toString());

    Object foldObj = get(test, ":fold-module");
    String foldModule = foldObj == null ? "lww_register"
        : foldObj.toString();

    // Optional explicit CRDT module under test (e.g. aw_set, rw_set,
    // two_p_set, g_set, pn_counter). When unset, render `undefined` so
    // the Erlang cluster keeps the legacy fold_module-driven behaviour.
    Object crdtObj = get(test, ":crdt-module");
    String crdtModule = crdtObj == null ? "undefined"
        : crdtObj.toString();

    Object shardCountObj = get(test, ":shard-count");
    long shardCount = shardCountObj == null ? 16L
        : Long.parseLong(shardCountObj.toString());

    String tableList = TABLES.stream()
        .collect(Collectors.joining(", "));

    return String.format(
        "[\n" +
        "    {kernel, [{logger_level, notice}]},\n" +
        "    {bondy_mst_jepsen, [\n" +
        "        {http_port, 8080},\n" +
        "        {db_name, jepsen},\n" +
        "        {tables, [%s]},\n" +
        "        {shard_count, %d},\n" +
        "        {fold_module, %s},\n" +
        "        {crdt_module, %s},\n" +
        "        {peers, [%s]},\n" +
        "        {data_dir, \"/var/lib/bondy_mst_jepsen\"},\n" +
        "        {reconnect_interval_ms, 1000}\n" +
        "    ]},\n" +
        "    {bondy_mst, [\n" +
        "        {sync_scheduler, true},\n" +
        "        {sync_interval_ms, %d}\n" +
        "    ]}\n" +
        "].",
        tableList, shardCount, foldModule, crdtModule, peerList,
        syncIntervalMs);
  }

  /** Render vm.args with the per-node sname + shared cookie. */
  public static String vmArgs(Object currentNode) {
    return "-sname " + erlangNodeName(currentNode) + "\n" +
        "-setcookie bondy_mst_jepsen\n" +
        "+P 1048576\n" +
        "+Q 1048576\n" +
        "-kernel inet_dist_listen_min 25000\n" +
        "-kernel inet_dist_listen_max 25099\n";
  }

  /* ------------------------------------------------------------------ */
  /* Routing keys to (table, realm, key)                                 */
  /* ------------------------------------------------------------------ */

  /**
   * Deterministically map an integer Jepsen key onto a (table, realm,
   * key) tuple. The mapping fans the test workload over all 10
   * tables and (later, when realm-scoped tests land) all configured
   * realms.
   */
  public static String tableFor(Object key) {
    int k = ((Number) key).intValue();
    return TABLES.get(Math.floorMod(k, TABLES.size()));
  }

  public static String realmFor(Object key) {
    return DEFAULT_REALM;
  }

  public static String keyFor(Object key) {
    return "k" + key.toString();
  }

  /* ------------------------------------------------------------------ */
  /* Client API exposed to Clojure                                       */
  /* ------------------------------------------------------------------ */

  public static Client createClient(Object node) {
    return new Client(node.toString());
  }

  public static String node(Client client) {
    return client.node;
  }

  public static String get(Client client, Object key) throws Exception {
    return client.get(key);
  }

  public static Response write(Client client, Object key, Object value)
      throws Exception {
    return client.write(key, value);
  }

  public static Response cas(Client client, Object key, Object oldValue,
                              Object newValue) throws Exception {
    return client.cas(key, oldValue, newValue);
  }

  /** OR-set add (POST /sets/:table/:realm/:key with form value=...). */
  public static Response setAdd(Client client, Object key, Object value)
      throws Exception {
    return client.setAdd(key, value);
  }

  /** Set read (GET /sets/...). Returns members as a String like "1 4 7"
   *  so the Clojure caller can split on whitespace. Empty set → "". */
  public static String setRead(Client client, Object key) throws Exception {
    return client.setRead(key);
  }

  /** PN-Counter increment (POST /counters/... with form value=delta). */
  public static Response counterAdd(Client client, Object key, Object delta)
      throws Exception {
    return client.counterAdd(key, delta);
  }

  /** PN-Counter read (GET /counters/...). Returns the integer value as a
   *  decimal String (e.g. "42"); absent counter → "0". */
  public static String counterRead(Client client, Object key)
      throws Exception {
    return client.counterRead(key);
  }

  static Object get(Map<Object, Object> map, String keyStringValue) {
    for (Map.Entry<Object, Object> entry : map.entrySet()) {
      if (keyStringValue.equals(entry.getKey().toString())) {
        return entry.getValue();
      }
    }
    return null;
  }

  /* ------------------------------------------------------------------ */
  /* Client                                                              */
  /* ------------------------------------------------------------------ */

  public static class Client {
    final String node;

    public Client(String node) {
      this.node = node;
    }

    private URL url(Object key) throws Exception {
      String table = tableFor(key);
      String realm = realmFor(key);
      String k     = keyFor(key);
      return new URI(String.format("http://%s:8080/tables/%s/%s/%s",
          node, table, realm, k)).toURL();
    }

    private URL setUrl(Object key) throws Exception {
      String table = tableFor(key);
      String realm = realmFor(key);
      String k     = keyFor(key);
      return new URI(String.format("http://%s:8080/sets/%s/%s/%s",
          node, table, realm, k)).toURL();
    }

    private URL counterUrl(Object key) throws Exception {
      String table = tableFor(key);
      String realm = realmFor(key);
      String k     = keyFor(key);
      return new URI(String.format("http://%s:8080/counters/%s/%s/%s",
          node, table, realm, k)).toURL();
    }

    public String get(Object key) throws Exception {
      try {
        URL u = url(key);
        HttpURLConnection conn = (HttpURLConnection) u.openConnection();
        try {
          conn.setRequestMethod("GET");
          conn.setConnectTimeout(HTTP_REQUEST_TIMEOUT);
          conn.setReadTimeout(HTTP_REQUEST_TIMEOUT);
          int code = conn.getResponseCode();
          if (code == 404) {
            return null;
          }
          if (code == 503) {
            throw new BondyTimeoutException();
          }
          String body = body(conn.getInputStream());
          return body == null || body.isEmpty() ? null : body;
        } finally {
          conn.disconnect();
        }
      } catch (ConnectException e) {
        throw new BondyNodeDownException();
      }
    }

    public Response write(Object key, Object value) throws Exception {
      try {
        URL u = url(key);
        HttpURLConnection conn = (HttpURLConnection) u.openConnection();
        try {
          conn.setRequestMethod("PUT");
          conn.setDoOutput(true);
          conn.setConnectTimeout(HTTP_REQUEST_TIMEOUT);
          conn.setReadTimeout(HTTP_REQUEST_TIMEOUT);
          try (OutputStreamWriter out =
                   new OutputStreamWriter(conn.getOutputStream())) {
            out.write("value=" + value);
          }
          int code = conn.getResponseCode();
          if (code == 503) {
            throw new BondyTimeoutException();
          }
          conn.getInputStream();
          return new Response(true, hlcHeaders(conn));
        } finally {
          conn.disconnect();
        }
      } catch (ConnectException e) {
        throw new BondyNodeDownException();
      }
    }

    public Response setAdd(Object key, Object value) throws Exception {
      try {
        URL u = setUrl(key);
        HttpURLConnection conn = (HttpURLConnection) u.openConnection();
        try {
          conn.setRequestMethod("POST");
          conn.setDoOutput(true);
          conn.setConnectTimeout(HTTP_REQUEST_TIMEOUT);
          conn.setReadTimeout(HTTP_REQUEST_TIMEOUT);
          try (OutputStreamWriter out =
                   new OutputStreamWriter(conn.getOutputStream())) {
            out.write("value=" + value);
          }
          int code = conn.getResponseCode();
          if (code == 503) {
            throw new BondyTimeoutException();
          }
          conn.getInputStream();
          return new Response(true, hlcHeaders(conn));
        } finally {
          conn.disconnect();
        }
      } catch (ConnectException e) {
        throw new BondyNodeDownException();
      }
    }

    public String setRead(Object key) throws Exception {
      try {
        URL u = setUrl(key);
        HttpURLConnection conn = (HttpURLConnection) u.openConnection();
        try {
          conn.setRequestMethod("GET");
          conn.setConnectTimeout(HTTP_REQUEST_TIMEOUT);
          conn.setReadTimeout(HTTP_REQUEST_TIMEOUT);
          int code = conn.getResponseCode();
          if (code == 503) {
            throw new BondyTimeoutException();
          }
          if (code == 404) {
            return "";
          }
          return body(conn.getInputStream());
        } finally {
          conn.disconnect();
        }
      } catch (ConnectException e) {
        throw new BondyNodeDownException();
      }
    }

    public Response counterAdd(Object key, Object delta) throws Exception {
      try {
        URL u = counterUrl(key);
        HttpURLConnection conn = (HttpURLConnection) u.openConnection();
        try {
          conn.setRequestMethod("POST");
          conn.setDoOutput(true);
          conn.setConnectTimeout(HTTP_REQUEST_TIMEOUT);
          conn.setReadTimeout(HTTP_REQUEST_TIMEOUT);
          try (OutputStreamWriter out =
                   new OutputStreamWriter(conn.getOutputStream())) {
            out.write("value=" + delta);
          }
          int code = conn.getResponseCode();
          if (code == 503) {
            throw new BondyTimeoutException();
          }
          conn.getInputStream();
          return new Response(true, hlcHeaders(conn));
        } finally {
          conn.disconnect();
        }
      } catch (ConnectException e) {
        throw new BondyNodeDownException();
      }
    }

    public String counterRead(Object key) throws Exception {
      try {
        URL u = counterUrl(key);
        HttpURLConnection conn = (HttpURLConnection) u.openConnection();
        try {
          conn.setRequestMethod("GET");
          conn.setConnectTimeout(HTTP_REQUEST_TIMEOUT);
          conn.setReadTimeout(HTTP_REQUEST_TIMEOUT);
          int code = conn.getResponseCode();
          if (code == 503) {
            throw new BondyTimeoutException();
          }
          if (code == 404) {
            return "0";
          }
          String b = body(conn.getInputStream());
          return b == null || b.isEmpty() ? "0" : b;
        } finally {
          conn.disconnect();
        }
      } catch (ConnectException e) {
        throw new BondyNodeDownException();
      }
    }

    public Response cas(Object key, Object oldValue, Object newValue)
        throws Exception {
      try {
        URL u = url(key);
        HttpURLConnection conn = (HttpURLConnection) u.openConnection();
        try {
          conn.setRequestMethod("PUT");
          conn.setDoOutput(true);
          conn.setConnectTimeout(HTTP_REQUEST_TIMEOUT);
          conn.setReadTimeout(HTTP_REQUEST_TIMEOUT);
          try (OutputStreamWriter out =
                   new OutputStreamWriter(conn.getOutputStream())) {
            out.write(String.format("value=%s&expected=%s",
                newValue.toString(), oldValue.toString()));
          }
          int code = conn.getResponseCode();
          if (code == 409) {
            return new Response(false, hlcHeaders(conn));
          }
          if (code == 503) {
            throw new BondyTimeoutException();
          }
          conn.getInputStream();
          return new Response(true, hlcHeaders(conn));
        } finally {
          conn.disconnect();
        }
      } catch (ConnectException e) {
        throw new BondyNodeDownException();
      }
    }
  }

  private static Map<String, String> hlcHeaders(HttpURLConnection c) {
    Map<String, String> headers = new LinkedHashMap<>();
    for (Map.Entry<String, List<String>> entry : c.getHeaderFields().entrySet()) {
      if (entry.getKey() != null && entry.getKey().toLowerCase()
              .startsWith("x-bondy-")) {
        headers.put(entry.getKey(), String.join(",", entry.getValue()));
      }
    }
    return headers;
  }

  private static String body(InputStream is) throws IOException {
    if (is == null) return "";
    StringBuilder sb = new StringBuilder();
    try (BufferedReader r = new BufferedReader(new InputStreamReader(is))) {
      String line;
      while ((line = r.readLine()) != null) sb.append(line);
    }
    return sb.toString();
  }

  /* ------------------------------------------------------------------ */
  /* Response                                                            */
  /* ------------------------------------------------------------------ */

  public static class Response {
    private final boolean ok;
    private final Map<String, String> headers;

    public Response(boolean ok, Map<String, String> headers) {
      this.ok = ok;
      this.headers = headers;
    }

    public boolean isOk() {
      return ok;
    }

    public Map<String, String> getHeaders() {
      return headers;
    }

    @Override
    public String toString() {
      return "Response{ok=" + ok + ", headers=" + headers + "}";
    }
  }
}
