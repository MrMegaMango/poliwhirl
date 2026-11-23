const { test } = require("node:test");
const assert = require("node:assert/strict");
const { PauseLeaseMachine } = require("../../chrome-extension/state-machine.js");

function setup() {
  const machine = new PauseLeaseMachine();
  const media = { element: {}, src: "blob:track-a", trackId: "track-a", time: 42,
    paused: false, ended: false, seeking: false, connected: true };
  let seq = 0;
  const state = (active, extra = {}) => ({ ok: true, extensionEnabled: true, state: {
    session: "session-a", seq: ++seq, active, enabled: true, updatedAt: 1000 + seq,
    sourceCount: 1, ...extra
  } });
  const applyPause = () => { media.paused = true; machine.pauseApplied(media); };
  const begin = () => {
    const actions = machine.step(state(true), media, 1000);
    assert.equal(actions[0]?.type, "pause");
    assert.ok(machine.lease, "Ownership exists before invoking pause()");
    applyPause();
    return actions;
  };
  return { machine, media, state, applyPause, begin };
}

test("initially paused music is never resumed", () => {
  const { machine, media, state } = setup();
  media.paused = true;
  assert.deepEqual(machine.step(state(true), media, 1000), []);
  assert.deepEqual(machine.step(state(false), media, 2000), []);
  assert.equal(machine.lease, null);
});

test("playing music gets one owned pause and one resume", () => {
  const { machine, media, state, begin } = setup();
  begin();
  assert.deepEqual(machine.step(state(true), media, 1200), []);
  assert.equal(machine.step(state(false), media, 1400)[0]?.type, "resume");
  assert.deepEqual(machine.step(state(false), media, 1600), []);
});

test("manual playback overrides cancel ownership for the rest of this burst", () => {
  const { machine, media, state, begin } = setup();
  begin();
  machine.manualOverride();
  media.paused = false;
  assert.deepEqual(machine.step(state(true), media, 1200), []);
  assert.deepEqual(machine.step(state(false), media, 1400), []);
  assert.equal(machine.step(state(true), media, 1600)[0]?.type, "pause");
});

test("a playback restart detected without an input event still cancels ownership", () => {
  const { machine, media, state, begin } = setup();
  begin();
  media.paused = false;
  assert.deepEqual(machine.step(state(true), media, 1200), []);
  assert.equal(machine.blocked, true);
  media.paused = true;
  assert.deepEqual(machine.step(state(false), media, 1400), []);
});

test("a user play from an initially paused track is respected during speech", () => {
  const { machine, media, state } = setup();
  media.paused = true;
  machine.step(state(true), media, 1000);
  machine.manualOverride();
  media.paused = false;
  assert.deepEqual(machine.step(state(true), media, 1200), []);
});

for (const [label, change] of [
  ["route track id even with an unchanged MSE source", m => { m.trackId = "track-b"; }],
  ["currentSrc", m => { m.src = "blob:track-b"; }],
  ["media element", m => { m.element = {}; }],
  ["playback position", m => { m.time += 10; }],
  ["disconnected media", m => { m.connected = false; }],
  ["seeking media", m => { m.seeking = true; }],
  ["ended media", m => { m.ended = true; }]
]) {
  test(`changing ${label} prevents an automatic resume`, () => {
    const { machine, media, state, begin } = setup();
    begin();
    change(media);
    assert.deepEqual(machine.step(state(false), media, 1200), []);
    assert.equal(machine.lease, null);
  });
}

test("track switches skip the current speaking cycle", () => {
  const { machine, media, state, begin } = setup();
  begin();
  media.trackId = "track-b";
  media.paused = false;
  assert.deepEqual(machine.step(state(true), media, 1200), []);
  assert.deepEqual(machine.step(state(true), media, 1400), []);
  assert.equal(machine.blocked, true);
});

test("short disconnects preserve the pause; a disconnect over three seconds restores once", () => {
  const { machine, media, begin } = setup();
  begin();
  assert.deepEqual(machine.step({ ok: false }, media, 3999), []);
  assert.equal(machine.step({ ok: false }, media, 4001)[0]?.type, "resume");
  assert.deepEqual(machine.step({ ok: false }, media, 5000), []);
});

test("a helper disconnect never starts initially paused playback", () => {
  const { machine, media, state } = setup();
  media.paused = true;
  machine.step(state(true), media, 1000);
  assert.deepEqual(machine.step({ ok: false }, media, 5000), []);
});

test("extension disable restores its own pause even with a disconnected helper", () => {
  const { machine, media, begin } = setup();
  begin();
  assert.equal(machine.step({ ok: false, extensionEnabled: false }, media, 1100)[0]?.type, "resume");
});

for (const [label, extra] of [["disabled", { enabled: false }], ["without a source", { sourceCount: 0 }]]) {
  test(`a helper ${label} restores its own pause immediately`, () => {
    const { machine, media, state, begin } = setup();
    begin();
    assert.equal(machine.step(state(true, extra), media, 1100)[0]?.type, "resume");
  });
}

test("session changes release the previous lease before accepting new active audio", () => {
  const { machine, media, state, begin } = setup();
  begin();
  assert.equal(machine.step(state(true, { session: "session-b", seq: 0 }), media, 1200)[0]?.type, "resume");
  media.paused = false;
  assert.equal(machine.step(state(true, { session: "session-b", seq: 1 }), media, 1400)[0]?.type, "pause");
});

test("older sequence numbers cannot resurrect speech or release an active lease", () => {
  const { machine, media, state, begin } = setup();
  begin();
  assert.deepEqual(machine.step(state(false, { seq: 0 }), media, 1200), []);
  assert.ok(machine.lease);
  assert.equal(machine.step(state(false, { seq: 3 }), media, 1400)[0]?.type, "resume");
  media.paused = false;
  assert.deepEqual(machine.step(state(true, { seq: 2 }), media, 1600), []);
});

test("the same native sequence is a valid heartbeat during long speech", () => {
  const { machine, media, state, begin } = setup();
  begin();
  assert.deepEqual(machine.step(state(true, { seq: 1, updatedAt: 5000 }), media, 5000), []);
  assert.equal(machine.lastContact, 5000);
  assert.deepEqual(machine.step({ ok: false }, media, 7000), []);
});

test("stale or future native heartbeats are treated as a disconnected helper", () => {
  for (const updatedAt of [1000, 20000]) {
    const { machine, media, state, begin } = setup();
    begin();
    assert.equal(machine.step(state(true, { updatedAt }), media, 5000)[0]?.type, "resume");
    assert.equal(machine.lastContact, 1000);
  }
});

test("rejected old sequences do not refresh the disconnect deadline", () => {
  const { machine, media, state, begin } = setup();
  begin();
  machine.step(state(true, { seq: 0, updatedAt: 3900 }), media, 3900);
  assert.equal(machine.lastContact, 1000);
  assert.equal(machine.step(state(true, { seq: 0, updatedAt: 4100 }), media, 4100)[0]?.type, "resume");
});

test("elapsed disconnect recovery uses monotonic time independently of a wall clock change", () => {
  const { machine, media, state } = setup();
  machine.step(state(true, { updatedAt: 500000 }), media, 1000, 500000);
  media.paused = true;
  machine.pauseApplied(media);
  assert.equal(machine.step({ ok: false }, media, 4100, 490000)[0]?.type, "resume");
});

test("failed pause never acquires resume ownership", () => {
  const { machine, media, state } = setup();
  machine.step(state(true), media, 1000);
  machine.pauseApplied(media); // pause() did not actually pause the player.
  media.paused = true;
  assert.deepEqual(machine.step(state(false), media, 1400), []);
});

test("the confirmed pause position allows tiny playback advances before pause takes effect", () => {
  const { machine, media, state } = setup();
  machine.step(state(true), media, 1000);
  media.paused = true;
  media.time += 0.1;
  machine.pauseApplied(media);
  assert.equal(machine.step(state(false), media, 1400)[0]?.type, "resume");
});

test("missing source or ended playback never creates an owned pause", () => {
  for (const props of [{ src: "" }, { ended: true }, { connected: false }, { seeking: true }]) {
    const { machine, media, state } = setup();
    Object.assign(media, props);
    assert.deepEqual(machine.step(state(true), media, 1000), []);
    assert.equal(machine.lease, null);
  }
});
