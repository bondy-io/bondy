// Modern era (2026-07-28) against the official v2 client, pinned: the
// connect-time `server/discover` probe MUST yield a modern verdict — pin
// mode has no legacy fallback, so a server that cannot answer the probe
// fails this script rather than silently downgrading the era.
import {
  Client,
  StreamableHTTPClientTransport
} from "@modelcontextprotocol/client";

const url = process.argv[2];

function fail(step, error) {
  console.log(JSON.stringify({ ok: false, step, error: String(error) }));
  process.exit(1);
}

let client;
try {
  client = new Client(
    { name: "bondy-e2e-modern", version: "1.0.0" },
    { versionNegotiation: { mode: { pin: "2026-07-28" } } }
  );
  await client.connect(new StreamableHTTPClientTransport(new URL(url)));
} catch (e) {
  fail("connect", e);
}

let tools;
try {
  tools = (await client.listTools()).tools.map((t) => t.name);
  for (const name of ["echo", "test_simple_text", "test_error_handling"]) {
    if (!tools.includes(name)) throw new Error(`tool ${name} not listed`);
  }
} catch (e) {
  fail("tools_list", e);
}

try {
  const res = await client.callTool({
    name: "echo",
    arguments: { message: "round-trip", n: 7 }
  });
  const sc = res.structuredContent;
  if (!sc || sc.message !== "round-trip" || sc.n !== 7) {
    throw new Error(`structuredContent did not round-trip: ${JSON.stringify(sc)}`);
  }
  if (res.isError) throw new Error("echo reported isError");
} catch (e) {
  fail("tools_call", e);
}

try {
  const res = await client.callTool({ name: "test_error_handling" });
  if (res.isError !== true) throw new Error("expected isError: true");
} catch (e) {
  fail("tools_call_error", e);
}

try {
  const read = await client.readResource({ uri: "test://template/123/data" });
  const text = read.contents?.[0]?.text ?? "";
  if (!text.includes("123")) {
    throw new Error(`template binding not reflected: ${text}`);
  }
} catch (e) {
  fail("resources_read", e);
}

await client.close();
console.log(JSON.stringify({ ok: true, era: "2026-07-28", tools }));
