const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const directory = path.join(__dirname, '..', '..', 'chrome-extension');
const read = name => fs.readFileSync(path.join(directory, name), 'utf8');
const settle = () => new Promise(resolve => setImmediate(resolve));

function contentHarness({ paused = false, rejectPlay = false, pendingPlay = false } = {}) {
  let monotonic = 1000;
  const pending = [], calls = [], handlers = new Map(), timers = [];
  class Element {
    matches() { return false; }
    closest() { return null; }
  }
  class HTMLMediaElement extends Element {
    constructor() {
      super();
      Object.assign(this, { currentSrc: 'blob:track-a', currentTime: 73, paused,
        ended: false, seeking: false, isConnected: true });
    }
    pause() { calls.push('pause'); this.paused = true; }
    play() {
      calls.push('play');
      if (rejectPlay) return Promise.reject(new Error('gesture required'));
      this.paused = false;
      queueMicrotask(() => emit('play', { target: this }));
      if (pendingPlay) return new Promise(() => {});
      return Promise.resolve();
    }
  }
  const media = new HTMLMediaElement();
  function emit(type, event = {}) {
    for (const fn of handlers.get(type) || []) fn(event);
  }
  const location = { href: 'https://music.youtube.com/watch?v=track-a' };
  const runtime = {
    id: 'test-extension',
    sendMessage(message) {
      assert.equal(message.type, 'get-state');
      return new Promise((resolve, reject) => pending.push({ resolve, reject }));
    },
  };
  const context = vm.createContext({
    document: { querySelector: () => media, addEventListener(type, fn) {
      if (!handlers.has(type)) handlers.set(type, []);
      handlers.get(type).push(fn);
    } },
    chrome: { runtime }, location, Element, HTMLMediaElement, URL, Date,
    performance: { now: () => monotonic },
    setTimeout(fn, delay) { timers.push(delay); return setTimeout(fn, delay); },
  });
  vm.runInContext(read('state-machine.js'), context);
  vm.runInContext(read('content.js'), context);
  let seq = 0;
  return {
    media, calls, pending, timers, runtime, location, emit,
    async state(active, extras = {}) {
      monotonic += 200;
      assert.equal(pending.length, 1, 'one outstanding content poll');
      pending.shift().resolve({ ok: true, extensionEnabled: true, state: {
        session: 'session-a', seq: ++seq, active, enabled: true,
        sourceCount: 1, updatedAt: Date.now(), ...extras,
      } });
      await settle();
    },
  };
}

test('content applies one owned pause/resume and supports a second speech burst without page timers', async () => {
  const h = contentHarness();
  await h.state(true); await h.state(true); await h.state(false); await h.state(false);
  assert.deepEqual(h.calls, ['pause', 'play']);
  await h.state(true); await h.state(false);
  assert.deepEqual(h.calls, ['pause', 'play', 'pause', 'play']);
  assert.deepEqual(h.timers, []);
});

test('content never starts initially paused music', async () => {
  const h = contentHarness({ paused: true });
  await h.state(true); await h.state(false);
  assert.deepEqual(h.calls, []);
});

test('content respects a playback restart while assistant audio remains active', async () => {
  const h = contentHarness();
  await h.state(true);
  h.media.paused = false; h.emit('play', { target: h.media });
  await h.state(true); await h.state(false);
  assert.deepEqual(h.calls, ['pause']);
  assert.equal(h.media.paused, false);
});

test('content cancels restoration after seek or track identity change', async () => {
  const seeking = contentHarness();
  await seeking.state(true);
  seeking.emit('seeking', { target: seeking.media });
  await seeking.state(false);
  assert.deepEqual(seeking.calls, ['pause']);
  const changed = contentHarness();
  await changed.state(true);
  changed.location.href = 'https://music.youtube.com/watch?v=track-b';
  await changed.state(false);
  assert.deepEqual(changed.calls, ['pause']);
});

test('runtime invalidation restores owned pause before any recovery timer', async () => {
  const h = contentHarness();
  await h.state(true);
  h.runtime.id = undefined;
  h.pending.shift().reject(new Error('Extension context invalidated'));
  await settle();
  assert.deepEqual(h.calls, ['pause', 'play']);
  assert.deepEqual(h.timers, []);
  assert.equal(h.pending.length, 0);
});

test('rejected automatic resume is not retried', async () => {
  const h = contentHarness({ rejectPlay: true });
  await h.state(true); await h.state(false); await h.state(false);
  assert.deepEqual(h.calls, ['pause', 'play']);
  assert.equal(h.media.paused, true);
});

test('pending media play promise does not stall later speech detection', async () => {
  const h = contentHarness({ pendingPlay: true });
  await h.state(true); await h.state(false);
  assert.equal(h.pending.length, 1);
  await h.state(true);
  assert.deepEqual(h.calls, ['pause', 'play', 'pause']);
});

function backgroundHarness({ helper = {} } = {}) {
  let listener, now = Date.now();
  const fetches = [], writes = [];
  const token = 'x'.repeat(64), id = 'test-extension';
  const state = { session: 'session-a', seq: 1, active: false, enabled: false,
    sourceCount: 0, updatedAt: now, ...helper };
  class Clock extends Date { static now() { return now; } }
  const runtime = { id, getURL: file => `chrome-extension://${id}/${file}`,
    onInstalled: { addListener() {} }, onMessage: { addListener(fn) { listener = fn; } } };
  const context = vm.createContext({
    AUTH_TOKEN: token, URL, Date: Clock, AbortController, TypeError,
    chrome: { runtime, storage: {
      local: { get: async () => ({ enabled: true }), set: async value => writes.push(value) },
      onChanged: { addListener() {} },
    } },
    setTimeout(fn, delay) { if (delay === 200) { queueMicrotask(fn); return null; } return setTimeout(fn, delay); },
    clearTimeout,
    async fetch(url, options) {
      fetches.push({ url, options });
      return { ok: true, status: 200, json: async () => ({ ...state, updatedAt: now }) };
    },
  });
  vm.runInContext(read('background.js').replace(/^import .*?;\s*/s, ''), context);
  const sender = { id, url: 'https://music.youtube.com/watch?v=a', frameId: 0 };
  return {
    fetches, writes, token,
    async message(message, customSender = {}) {
      now += 200;
      return new Promise(resolve => {
        const accepted = listener(message, { ...sender, ...customSender }, value => resolve(value));
        if (!accepted) resolve(null);
      });
    },
  };
}

test('background rejects other origins, frames and senders without contacting helper', async () => {
  const h = backgroundHarness();
  for (const sender of [{ url: 'https://youtube.com/' }, { frameId: 1 }, { id: 'other-extension' }, { url: 'not a URL' }]) {
    assert.equal(await h.message({ type: 'get-state' }, sender), null);
  }
  assert.equal(h.fetches.length, 0);
});

test('background authenticates only a fixed local endpoint and does not return token to content', async () => {
  const h = backgroundHarness();
  const response = await h.message({ type: 'get-state', url: 'https://attacker.example/' });
  assert.equal(response.ok, true);
  assert.equal(h.fetches[0].url, 'http://127.0.0.1:49753/v1/state');
  assert.equal(h.fetches[0].options.headers.Authorization, `Bearer ${h.token}`);
  assert.equal(h.fetches[0].options.redirect, 'error');
  assert.equal(JSON.stringify(response).includes(h.token), false);
});

test('only extension popup can change enabled setting', async () => {
  const h = backgroundHarness();
  assert.equal(await h.message({ type: 'set-enabled', enabled: false }), null);
  assert.equal(h.writes.length, 0);
  const response = await h.message({ type: 'set-enabled', enabled: false },
    { url: 'chrome-extension://test-extension/popup.html', frameId: undefined });
  assert.equal(response.extensionEnabled, false);
  assert.equal(h.writes[0].enabled, false);
});

test('background refuses malformed helper state', async () => {
  const h = backgroundHarness({ helper: { seq: -1 } });
  const response = await h.message({ type: 'get-state' });
  assert.equal(response.ok, false);
  assert.match(response.error, /invalid state/);
});
