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
// Failure discipline: a failed WS handshake or a session that never reaches
// WELCOME within WELCOME_TIMEOUT_MS ends the iteration with a jittered
// RETRY_BACKOFF_MS sleep, so a struggling server sees a bounded retry rate
// instead of a self-sustaining reconnect storm.
//
// Accounting discipline: success/failure rates are recorded INSIDE the socket
// callbacks (WELCOME / close). Long-lived successful sessions are usually
// still connected when the test ends, so k6 interrupts those iterations and
// any code after ws.connect() never runs for them — recording there
// undercounts every success.
//
// Distributed LGs: pass a distinct VU_OFFSET per LG process so per-VU vehicle
// ids / group ids stay globally unique across the fleet.
//
//   k6 run -e ROLE=publisher  -e WS_URL=... -e VUS=50000 harness/k6/fleet_smoke.js
//   k6 run -e ROLE=subscriber -e WS_URL=... -e VUS=3000  harness/k6/fleet_smoke.js
// =============================================================================

import ws from 'k6/ws';
import { check, sleep } from 'k6';
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
const WELCOME_TIMEOUT_MS = parseInt(__ENV.WELCOME_TIMEOUT_MS || '30000');
const RETRY_BACKOFF_MS = parseInt(__ENV.RETRY_BACKOFF_MS || '2000');
const RETRY_BACKOFF_MAX_MS = parseInt(__ENV.RETRY_BACKOFF_MAX_MS || '60000');

// --- delivery-tail attribution (optional; absent env => original behaviour) --
// A delivery sample is `subscriberClock - publisherClock`, so it carries the
// relative clock skew between two DIFFERENT LG machines. The publisher LGs are
// statistically symmetric (equal VUs, equal rate, same region, same cluster),
// so the TRUE distribution must be identical across them — which makes any
// systematic gap between the per-LG trends a direct read of that skew.
// LG_ID: stamped into each PUBLISH by the publisher; -1 = untagged.
// LG_COUNT: subscriber-side, how many per-LG trends to open (0 = none).
// MEASURE_AFTER_MS: ms after run start before samples count as steady state.
const LG_ID = parseInt(__ENV.LG_ID || '-1');
const LG_COUNT = parseInt(__ENV.LG_COUNT || '0');
const MEASURE_AFTER_MS = parseInt(__ENV.MEASURE_AFTER_MS || '0');
const RUN_START = Date.now();

const deliveryLatency = new Trend('wamp_delivery_latency_ms', true);
const welcomeLatency = new Trend('wamp_welcome_latency_ms', true);
const subscribeLatency = new Trend('wamp_subscribe_latency_ms', true);
const subscribeBurstLatency = new Trend('wamp_subscribe_burst_ms', true);
const eventsReceived = new Counter('wamp_events_received');
const publishesSent = new Counter('wamp_publishes_sent');
const wampErrors = new Counter('wamp_errors'); // aggregate of the three below
const wampAborts = new Counter('wamp_aborts');
const wampProtoErrors = new Counter('wamp_proto_errors'); // WAMP ERROR messages
const wampParseErrors = new Counter('wamp_parse_errors');
const wsConnectErrors = new Counter('wamp_ws_connect_errors');
const sessionOk = new Rate('wamp_session_ok');
const subscribedOk = new Rate('wamp_all_subscribed_ok');

// Phase-split delivery. The aggregate trend cannot separate the subscribe
// burst from steady state, which is how a ramp spike gets reported as a
// steady-state tail (s27). These two do separate them.
const deliveryWarmup = new Trend('wamp_delivery_warmup_ms', true);
const deliverySteady = new Trend('wamp_delivery_steady_ms', true);
// Per-publisher-LG steady-state delivery, for the skew read described above.
const deliveryByLg = [];
for (let i = 0; i < LG_COUNT; i++) {
  deliveryByLg.push(new Trend(`wamp_delivery_lg${i}_ms`, true));
}
// A session admission-refused during the ramp retries later, and its 2000-sub
// burst then lands INSIDE the steady window — load the run really sees, but a
// contaminator of "steady state". Counted so it can never be silently assumed
// absent.
const lateBursts = new Counter('wamp_late_subscribe_bursts');

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

// Exponential per-VU backoff between failed attempts, jittered to avoid
// retry synchronisation. VU-module state persists across iterations, so
// consecutive failures decay this VU's retry rate toward RETRY_BACKOFF_MAX_MS
// — the aggregate attempt rate converges to what the server can absorb
// instead of a fixed-rate reconnect storm. Reset on any successful WELCOME.
let consecutiveFailures = 0;

function backoff() {
  const base = Math.min(
    RETRY_BACKOFF_MS * Math.pow(2, consecutiveFailures),
    RETRY_BACKOFF_MAX_MS
  );
  consecutiveFailures++;
  sleep((base * (0.5 + Math.random())) / 1000);
}

// Log a small sample of ABORT frames verbatim so the reason URI + details
// show up in the k6 output without spamming it (tags on counters are not
// rendered in the text summary).
function sampleAbort(data) {
  if (Math.random() < 0.002) console.error('ABORT sample: ' + data);
}

// Classify an incoming frame; returns the parsed message or null after
// recording the failure. Empty frames (close/keepalive noise surfaced by the
// ws layer) are ignored silently — counting them made wamp_errors read
// one-per-session regardless of health.
function parseFrame(data) {
  if (!data || data.length === 0) return null;
  const msg = wamp.parse(data);
  if (!msg) {
    wampParseErrors.add(1);
    wampErrors.add(1, { reason: 'parse' });
  }
  return msg;
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
      const msg = parseFrame(data);
      if (!msg) return;
      const type = msg[0];

      if (type === wamp.T.WELCOME) {
        welcomed = true;
        consecutiveFailures = 0;
        sessionOk.add(true);
        welcomeLatency.add(Date.now() - helloTs);
        socket.setInterval(() => {
          const ts = Date.now();
          socket.send(wamp.publish(reqId++, topic, [ts, LG_ID], {}, { exclude_me: false }));
          publishesSent.add(1);
        }, PUB_INTERVAL_MS);

      } else if (type === wamp.T.EVENT) {
        const args = msg[4] || [];
        const sentTs = args[0];
        if (typeof sentTs === 'number') deliveryLatency.add(Date.now() - sentTs);
        eventsReceived.add(1);

      } else if (type === wamp.T.ABORT) {
        wampAborts.add(1);
        wampErrors.add(1, { reason: 'abort:' + (msg[2] || '?') });
        sampleAbort(data);
        socket.close();

      } else if (type === wamp.T.ERROR) {
        wampProtoErrors.add(1);
        wampErrors.add(1, { reason: 'wamp_error' });
      }
    });

    socket.on('close', () => {
      if (!welcomed) sessionOk.add(false);
    });

    socket.on('error', () => { wsConnectErrors.add(1); });

    // A session that cannot reach WELCOME is torn down (and retried after
    // backoff) instead of holding the socket until SESSION_MS.
    socket.setTimeout(() => {
      if (!welcomed) socket.close();
    }, WELCOME_TIMEOUT_MS);

    socket.setTimeout(() => { socket.send(wamp.goodbye()); socket.close(); }, SESSION_MS);
  });

  const upgraded = check(res, { 'ws handshake 101': (r) => r && r.status === 101 });
  if (!upgraded) {
    sessionOk.add(false);
    backoff();
  } else if (!welcomed) {
    backoff();
  }
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
      const msg = parseFrame(data);
      if (!msg) return;
      const type = msg[0];

      if (type === wamp.T.WELCOME) {
        welcomed = true;
        consecutiveFailures = 0;
        sessionOk.add(true);
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
          subscribedOk.add(true);
          if (Date.now() - RUN_START >= MEASURE_AFTER_MS) lateBursts.add(1);
        }

      } else if (type === wamp.T.EVENT) {
        const args = msg[4] || [];
        const sentTs = args[0];
        if (typeof sentTs === 'number') {
          const lat = Date.now() - sentTs;
          deliveryLatency.add(lat);
          if (Date.now() - RUN_START >= MEASURE_AFTER_MS) {
            deliverySteady.add(lat);
            const lg = args[1];
            if (typeof lg === 'number' && lg >= 0 && lg < deliveryByLg.length) {
              deliveryByLg[lg].add(lat);
            }
          } else {
            deliveryWarmup.add(lat);
          }
        }
        eventsReceived.add(1);

      } else if (type === wamp.T.ABORT) {
        wampAborts.add(1);
        wampErrors.add(1, { reason: 'abort:' + (msg[2] || '?') });
        sampleAbort(data);
        socket.close();

      } else if (type === wamp.T.ERROR) {
        wampProtoErrors.add(1);
        wampErrors.add(1, { reason: 'wamp_error' });
      }
    });

    socket.on('close', () => {
      if (!welcomed) {
        sessionOk.add(false);
      } else if (subscribedCount !== vehicleIds.length) {
        subscribedOk.add(false);
      }
    });

    socket.on('error', () => { wsConnectErrors.add(1); });

    socket.setTimeout(() => {
      if (!welcomed) socket.close();
    }, WELCOME_TIMEOUT_MS);

    socket.setTimeout(() => { socket.send(wamp.goodbye()); socket.close(); }, SESSION_MS);
  });

  const upgraded = check(res, { 'ws handshake 101': (r) => r && r.status === 101 });
  if (!upgraded) {
    sessionOk.add(false);
    backoff();
  } else if (!welcomed) {
    backoff();
  }
}

export default function () {
  if (ROLE === 'subscriber') {
    runSubscriber();
  } else {
    runPublisher();
  }
}
