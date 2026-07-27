// =============================================================================
// Minimal WAMP v2 (JSON) message helpers for k6 load tests.
// =============================================================================
// Framing per the WAMP spec, matching the Bondy client shape (subprotocol
// `wamp.2.json`; HELLO = [1, realm, details]; etc.). Pure functions — no k6
// imports — so this is reusable across workload scripts. Anonymous auth only
// for now (no CHALLENGE round-trip); cryptosign/ticket come with M2 proper.
// =============================================================================

export const T = {
  HELLO: 1, WELCOME: 2, ABORT: 3, CHALLENGE: 4, AUTHENTICATE: 5, GOODBYE: 6,
  ERROR: 8,
  PUBLISH: 16, PUBLISHED: 17,
  SUBSCRIBE: 32, SUBSCRIBED: 33, UNSUBSCRIBE: 34, UNSUBSCRIBED: 35, EVENT: 36,
  CALL: 48, RESULT: 50,
  REGISTER: 64, REGISTERED: 65, UNREGISTER: 66, UNREGISTERED: 67,
  INVOCATION: 68, YIELD: 70,
};

// Human name for a message type code (diagnostics only).
export const NAME = Object.fromEntries(Object.entries(T).map(([k, v]) => [v, k]));

// Bondy requires this WS subprotocol; send it in the Sec-WebSocket-Protocol
// header or the upgrade is rejected.
export const SUBPROTOCOL = 'wamp.2.json';

// Client roles advertised in HELLO. publisher_exclusion lets us set
// exclude_me:false so a publisher receives its own EVENT (clean self-delivery
// latency probe without a second session).
const ROLES = {
  publisher: { features: { publisher_exclusion: true } },
  subscriber: {},
  caller: {},
  callee: {},
};

export function hello(realm, authid) {
  return JSON.stringify([T.HELLO, realm, {
    roles: ROLES,
    authmethods: ['anonymous'],
    authid: authid || 'anonymous',
  }]);
}

export function subscribe(reqId, topic, options) {
  return JSON.stringify([T.SUBSCRIBE, reqId, options || {}, topic]);
}

export function publish(reqId, topic, args, kwargs, options) {
  return JSON.stringify([T.PUBLISH, reqId, options || {}, topic, args || [], kwargs || {}]);
}

export function call(reqId, procedure, args, kwargs, options) {
  return JSON.stringify([T.CALL, reqId, options || {}, procedure, args || [], kwargs || {}]);
}

export function register(reqId, procedure, options) {
  return JSON.stringify([T.REGISTER, reqId, options || {}, procedure]);
}

export function wampYield(reqId, args, kwargs, options) {
  return JSON.stringify([T.YIELD, reqId, options || {}, args || [], kwargs || {}]);
}

export function goodbye(reason) {
  return JSON.stringify([T.GOODBYE, {}, reason || 'wamp.close.normal']);
}

// Parse an incoming WAMP frame -> array [type, ...rest], or null on bad JSON.
export function parse(data) {
  try {
    const m = JSON.parse(data);
    return Array.isArray(m) ? m : null;
  } catch (_) {
    return null;
  }
}
