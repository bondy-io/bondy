// =============================================================================
// RPC smoke — exercises the DEALER (CALL -> INVOCATION -> YIELD -> RESULT).
// =============================================================================
// Each VU registers its own procedure, then calls it on an interval. The dealer
// routes CALL -> the VU's own registration -> INVOCATION back to the VU, which
// YIELDs the echoed payload -> RESULT to the caller. Round-trip latency =
// (RESULT received) - (CALL sent), the send timestamp carried in the args.
// Per-VU procedure => O(N), scalable to thousands of sessions.
//
//   k6 run -e WS_URL=... -e REALM=com.leapsight.perf -e VUS=1000 rpc_smoke.js
// =============================================================================

import ws from 'k6/ws';
import { check } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';
import * as wamp from './lib/wamp.js';

const WS_URL = __ENV.WS_URL || 'ws://localhost:18080/ws';
const REALM = __ENV.REALM || 'com.leapsight.perf';
const PROC_BASE = __ENV.PROC || 'perf.rpc';
const CALL_INTERVAL_MS = parseInt(__ENV.CALL_INTERVAL_MS || '200');
const SESSION_MS = parseInt(__ENV.SESSION_MS || '40000');
const VUS = parseInt(__ENV.VUS || '50');

const callLatency = new Trend('wamp_call_latency_ms', true);
const welcomeLatency = new Trend('wamp_welcome_latency_ms', true);
const registerLatency = new Trend('wamp_register_latency_ms', true);
const resultsReceived = new Counter('wamp_results_received');
const callsSent = new Counter('wamp_calls_sent');
const invocations = new Counter('wamp_invocations');
const wampErrors = new Counter('wamp_errors');
const wsConnectErrors = new Counter('wamp_ws_connect_errors');
const sessionOk = new Rate('wamp_session_ok');

export const options = {
  scenarios: {
    rpc: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: __ENV.RAMP || '15s', target: VUS },
        { duration: __ENV.HOLD || '30s', target: VUS },
        { duration: '5s', target: 0 },
      ],
      gracefulStop: '15s',
    },
  },
  thresholds: {
    wamp_session_ok: ['rate>0.95'],
    wamp_call_latency_ms: ['p(95)<1000'],
    wamp_ws_connect_errors: ['count<10'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const proc = `${PROC_BASE}.${__VU}`;
  let reqId = 1;
  let welcomed = false;
  let registered = false;
  let helloTs = 0;
  let regTs = 0;

  const res = ws.connect(WS_URL, { headers: { 'Sec-WebSocket-Protocol': wamp.SUBPROTOCOL } }, function (socket) {
    socket.on('open', () => {
      helloTs = Date.now();
      socket.send(wamp.hello(REALM));
    });

    socket.on('message', (data) => {
      const msg = wamp.parse(data);
      if (!msg) { wampErrors.add(1, { reason: 'parse' }); return; }
      const type = msg[0];

      if (type === wamp.T.WELCOME) {
        welcomed = true;
        welcomeLatency.add(Date.now() - helloTs);
        regTs = Date.now();
        socket.send(wamp.register(reqId++, proc));

      } else if (type === wamp.T.REGISTERED) {
        registered = true;
        registerLatency.add(Date.now() - regTs);
        socket.setInterval(() => {
          const ts = Date.now();
          socket.send(wamp.call(reqId++, proc, [ts], {}));
          callsSent.add(1);
        }, CALL_INTERVAL_MS);

      } else if (type === wamp.T.INVOCATION) {
        // INVOCATION = [68, requestId, registrationId, details, args, kwargs]
        const invReqId = msg[1];
        const args = msg[4] || [];
        socket.send(wamp.wampYield(invReqId, args, {}));   // echo the payload back
        invocations.add(1);

      } else if (type === wamp.T.RESULT) {
        // RESULT = [50, callReqId, details, args, kwargs]
        const args = msg[3] || [];
        const sentTs = args[0];
        if (typeof sentTs === 'number') callLatency.add(Date.now() - sentTs);
        resultsReceived.add(1);

      } else if (type === wamp.T.ABORT) {
        wampErrors.add(1, { reason: 'abort:' + (msg[2] || '?') });
        socket.close();

      } else if (type === wamp.T.ERROR) {
        wampErrors.add(1, { reason: 'wamp_error' });
      }
    });

    socket.on('error', () => { wsConnectErrors.add(1); });
    socket.setTimeout(() => { socket.send(wamp.goodbye()); socket.close(); }, SESSION_MS);
  });

  sessionOk.add(welcomed && registered);
  check(res, { 'ws handshake 101': (r) => r && r.status === 101 });
}
