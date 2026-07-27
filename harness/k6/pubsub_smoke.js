// =============================================================================
// pub/sub smoke — first perf numbers for the Bondy router (M7-min).
// =============================================================================
// Each VU opens one WAMP-over-WS session, subscribes to a shared topic, then
// publishes to it every PUB_INTERVAL_MS with exclude_me:false so it receives
// its OWN event back. Delivery latency = (event received) - (publish sent),
// with the send timestamp carried in the event payload — a clean per-session
// probe of the broker's subscribe-match-deliver path. Same k6 process = one
// clock, so the latency is honest even across VUs.
//
// Deliberately small first (tens of VUs) to validate the pipeline before the
// 3000/node target. Tunables via env: VUS, RAMP, HOLD, PUB_INTERVAL_MS, WS_URL,
// REALM, TOPIC.
//
//   k6 run -e WS_URL=wss://<app>.fly.dev/ws -e REALM=com.leapsight.perf \
//          -e VUS=50 harness/k6/pubsub_smoke.js
// =============================================================================

import ws from 'k6/ws';
import { check } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';
import * as wamp from './lib/wamp.js';

const WS_URL = __ENV.WS_URL || 'ws://localhost:18080/ws';
const REALM = __ENV.REALM || 'com.leapsight.perf';
const TOPIC_BASE = __ENV.TOPIC || 'perf.echo';
// PER_VU=1 gives each VU its OWN topic (self-delivery, fanout=1, O(N) load) —
// the right shape for scaling to thousands of sessions. Default 0 = one shared
// topic (fanout to every subscriber, O(N^2)) — only sane at small VU counts.
const PER_VU = (__ENV.PER_VU || '0') === '1';
// Distributed LGs: each generator passes a distinct VU_OFFSET so per-VU topics
// are globally unique (else LG A's VU 5 and LG B's VU 5 would share a topic).
const VU_OFFSET = parseInt(__ENV.VU_OFFSET || '0');
const PUB_INTERVAL_MS = parseInt(__ENV.PUB_INTERVAL_MS || '200');
const SESSION_MS = parseInt(__ENV.SESSION_MS || '30000');
const VUS = parseInt(__ENV.VUS || '50');

const deliveryLatency = new Trend('wamp_delivery_latency_ms', true);
const welcomeLatency = new Trend('wamp_welcome_latency_ms', true);
const subscribeLatency = new Trend('wamp_subscribe_latency_ms', true);
const eventsReceived = new Counter('wamp_events_received');
const publishesSent = new Counter('wamp_publishes_sent');
const wampErrors = new Counter('wamp_errors');
const wsConnectErrors = new Counter('wamp_ws_connect_errors');
const sessionOk = new Rate('wamp_session_ok');

export const options = {
  scenarios: {
    pubsub: {
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
    wamp_delivery_latency_ms: ['p(95)<1000'],
    wamp_ws_connect_errors: ['count<10'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const topic = PER_VU ? `${TOPIC_BASE}.${VU_OFFSET + __VU}` : TOPIC_BASE;
  let reqId = 1;
  let welcomed = false;
  let subscribed = false;
  let helloTs = 0;
  let subTs = 0;

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
        subTs = Date.now();
        socket.send(wamp.subscribe(reqId++, topic));

      } else if (type === wamp.T.SUBSCRIBED) {
        subscribed = true;
        subscribeLatency.add(Date.now() - subTs);
        // Sustained publish loop for the session lifetime.
        socket.setInterval(() => {
          const ts = Date.now();
          socket.send(wamp.publish(reqId++, topic, [ts], {}, { exclude_me: false }));
          publishesSent.add(1);
        }, PUB_INTERVAL_MS);

      } else if (type === wamp.T.EVENT) {
        // EVENT = [36, subId, pubId, details, args, kwargs]
        const args = msg[4] || [];
        const sentTs = args[0];
        if (typeof sentTs === 'number') deliveryLatency.add(Date.now() - sentTs);
        eventsReceived.add(1);

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

  sessionOk.add(welcomed && subscribed);
  check(res, { 'ws handshake 101': (r) => r && r.status === 101 });
}
