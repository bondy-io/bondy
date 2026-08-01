// =============================================================================
// fleet_smoke — "500K vehicles, each on its own topic; a user subscribes to
// 2K vehicles" scenario.
// =============================================================================
// Two roles, selected via ROLE env var, meant to run as SEPARATE k6 processes
// (see harness/fleet-scale/run-fleet-lg.sh):
//
//   ROLE=publisher — each VU is one vehicle. It opens a session and publishes
//     to its own unique topic (com.fleet.vehicle.<id>) every PUB_INTERVAL_MS,
//     with exclude_me:false so self-delivery (if any) is also measured.
//     Fanout=1 per publish (bondy_broker: cheap by design), same shape as
//     pubsub_smoke.js's PER_VU=1 mode.
//
//   ROLE=subscriber — each VU is one user. Users come in GROUP_SIZE-sized
//     groups that watch the SAME 2K-vehicle subset (a shared fleet); the
//     group's vehicle-id set is derived deterministically from its group id
//     via a seeded PRNG, so all GROUP_SIZE members subscribe to identical
//     topics without coordinating. Each VU issues SUBS_PER_USER SUBSCRIBEs
//     in a burst right after WELCOME, then just holds, measuring delivery
//     latency across all of them.
//
// Distributed LGs: pass a distinct VU_OFFSET per LG process so per-VU vehicle
// ids / group ids stay globally unique across the fleet.
//
//   k6 run -e ROLE=publisher  -e WS_URL=... -e VUS=50000 harness/k6/fleet_smoke.js
//   k6 run -e ROLE=subscriber -e WS_URL=... -e VUS=3000  harness/k6/fleet_smoke.js
// =============================================================================

import ws from 'k6/ws';
import { check } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';
import * as wamp from './lib/wamp.js';

const WS_URL = __ENV.WS_URL || 'ws://localhost:18080/ws';
const REALM = __ENV.REALM || 'com.leapsight.fleet';
const TOPIC_BASE = __ENV.TOPIC_BASE || 'com.fleet.vehicle';
const ROLE = __ENV.ROLE || 'publisher'; // publisher | subscriber
const VU_OFFSET = parseInt(__ENV.VU_OFFSET || '0');
const VUS = parseInt(__ENV.VUS || '50');
const PUB_INTERVAL_MS = parseInt(__ENV.PUB_INTERVAL_MS || '1000');
const SESSION_MS = parseInt(__ENV.SESSION_MS || '120000');
const VEHICLE_POOL = parseInt(__ENV.VEHICLE_POOL || '500000');
const GROUP_SIZE = parseInt(__ENV.GROUP_SIZE || '5');
const SUBS_PER_USER = parseInt(__ENV.SUBS_PER_USER || '2000');

const deliveryLatency = new Trend('wamp_delivery_latency_ms', true);
const welcomeLatency = new Trend('wamp_welcome_latency_ms', true);
const subscribeLatency = new Trend('wamp_subscribe_latency_ms', true);
const subscribeBurstLatency = new Trend('wamp_subscribe_burst_ms', true);
const eventsReceived = new Counter('wamp_events_received');
const publishesSent = new Counter('wamp_publishes_sent');
const wampErrors = new Counter('wamp_errors');
const wsConnectErrors = new Counter('wamp_ws_connect_errors');
const sessionOk = new Rate('wamp_session_ok');
const subscribedOk = new Rate('wamp_all_subscribed_ok');

export const options = {
  scenarios: {
    fleet: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: __ENV.RAMP || '60s', target: VUS },
        { duration: __ENV.HOLD || '60s', target: VUS },
        { duration: '10s', target: 0 },
      ],
      gracefulStop: '30s',
    },
  },
  thresholds: {
    wamp_session_ok: ['rate>0.95'],
    wamp_ws_connect_errors: ['count<100'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
};

// mulberry32 — small seedable PRNG (Math.random() is not seedable in k6/JS).
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Deterministic, order-stable sample of `count` distinct ids from
// [0, poolSize) for a given group, without materialising the whole pool.
function groupVehicleIds(groupId, count, poolSize) {
  const rng = mulberry32(groupId + 1);
  const ids = new Set();
  // Rejection sampling: fine while count << poolSize (2000 << 500000).
  while (ids.size < count) {
    ids.add(Math.floor(rng() * poolSize));
  }
  return Array.from(ids);
}

function runPublisher() {
  const vehicleId = VU_OFFSET + __VU;
  const topic = `${TOPIC_BASE}.${vehicleId}`;
  let reqId = 1;
  let welcomed = false;
  let helloTs = 0;

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
        socket.setInterval(() => {
          const ts = Date.now();
          socket.send(wamp.publish(reqId++, topic, [ts], {}, { exclude_me: false }));
          publishesSent.add(1);
        }, PUB_INTERVAL_MS);

      } else if (type === wamp.T.EVENT) {
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

  sessionOk.add(welcomed);
  check(res, { 'ws handshake 101': (r) => r && r.status === 101 });
}

function runSubscriber() {
  const globalIdx = VU_OFFSET + __VU - 1; // 0-based
  const groupId = Math.floor(globalIdx / GROUP_SIZE);
  const vehicleIds = groupVehicleIds(groupId, SUBS_PER_USER, VEHICLE_POOL);

  let reqId = 1;
  let welcomed = false;
  let helloTs = 0;
  let burstStartTs = 0;
  let subscribedCount = 0;
  const pendingSubs = new Map(); // reqId -> sentTs

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
        burstStartTs = Date.now();
        for (const vehicleId of vehicleIds) {
          const id = reqId++;
          const topic = `${TOPIC_BASE}.${vehicleId}`;
          pendingSubs.set(id, Date.now());
          socket.send(wamp.subscribe(id, topic));
        }

      } else if (type === wamp.T.SUBSCRIBED) {
        const id = msg[1];
        const sentTs = pendingSubs.get(id);
        if (sentTs !== undefined) {
          subscribeLatency.add(Date.now() - sentTs);
          pendingSubs.delete(id);
        }
        subscribedCount++;
        if (subscribedCount === vehicleIds.length) {
          subscribeBurstLatency.add(Date.now() - burstStartTs);
        }

      } else if (type === wamp.T.EVENT) {
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

  sessionOk.add(welcomed);
  subscribedOk.add(subscribedCount === vehicleIds.length);
  check(res, { 'ws handshake 101': (r) => r && r.status === 101 });
}

export default function () {
  if (ROLE === 'subscriber') {
    runSubscriber();
  } else {
    runPublisher();
  }
}
