// Handshake era against the official v1 SDK: `connect` runs the
// two-phase initialize handshake and every later request rides the
// `Mcp-Session-Id` it minted; `terminateSession` sends the DELETE.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const url = process.argv[2];

function fail(step, error) {
  console.log(JSON.stringify({ ok: false, step, error: String(error) }));
  process.exit(1);
}

const client = new Client({ name: "bondy-e2e-hs", version: "1.0.0" });
const transport = new StreamableHTTPClientTransport(new URL(url));
try {
  await client.connect(transport);
  if (!transport.sessionId) throw new Error("no Mcp-Session-Id assigned");
} catch (e) {
  fail("initialize", e);
}

let tools;
try {
  tools = (await client.listTools()).tools.map((t) => t.name);
  if (!tools.includes("echo")) throw new Error("tool echo not listed");
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
} catch (e) {
  fail("tools_call", e);
}

try {
  const read = await client.readResource({ uri: "test://static-text" });
  const first = read.contents?.[0];
  if (!first?.uri || !first?.mimeType || !first?.text) {
    throw new Error(`read missing uri/mimeType/text: ${JSON.stringify(first)}`);
  }
} catch (e) {
  fail("resources_read", e);
}

try {
  await client.subscribeResource({ uri: "test://watched-resource" });
  await client.unsubscribeResource({ uri: "test://watched-resource" });
} catch (e) {
  fail("subscribe", e);
}

try {
  await transport.terminateSession();
} catch (e) {
  fail("terminate", e);
}
await client.close();
console.log(JSON.stringify({ ok: true, era: "handshake", tools }));
