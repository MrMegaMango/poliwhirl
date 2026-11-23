(() => {
  "use strict";
  const { PauseLeaseMachine, sameIdentity } = globalThis.VoiceMusicPause;
  const machine = new PauseLeaseMachine();
  let stopped = false;

  function snapshot() {
    const element = document.querySelector("video.html5-main-video") || document.querySelector("video");
    if (!element) return null;
    return {
      element, src: element.currentSrc,
      trackId: new URL(location.href).searchParams.get("v") || "",
      time: element.currentTime, paused: element.paused, ended: element.ended,
      seeking: element.seeking, connected: element.isConnected
    };
  }

  async function apply(actions) {
    for (const action of actions) {
      const media = snapshot();
      if (!sameIdentity(action, media) || !media.connected || media.ended || media.seeking) {
        machine.manualOverride();
        continue;
      }
      if (action.type === "pause") {
        if (media.paused) { machine.manualOverride(); continue; }
        try {
          media.element.pause();
          machine.pauseApplied(snapshot());
        } catch { machine.manualOverride(); }
      } else if (media.paused && Math.abs(media.time - action.time) <= machine.timeTolerance) {
        try {
          // A play() promise can remain pending while media buffers. Keep polling so
          // a new speaking cycle is still handled, and never retry a rejected resume.
          Promise.resolve(media.element.play()).catch(() => {});
        } catch { /* Chrome may require a user gesture; leave playback to the user. */ }
      }
    }
  }

  function isPlayControl(event) {
    return event.composedPath().some(node => node instanceof Element && node.matches(
      '#play-pause-button,#play-pause,.play-pause-button,[aria-label^="Play"],[aria-label^="Pause"],[title^="Play"],[title^="Pause"]'
    ));
  }
  document.addEventListener("pointerdown", event => {
    if (event.isTrusted && isPlayControl(event)) machine.manualOverride();
  }, true);
  document.addEventListener("click", event => {
    if (event.isTrusted && isPlayControl(event)) machine.manualOverride();
  }, true);
  document.addEventListener("keydown", event => {
    if (!event.isTrusted || event.repeat) return;
    const editable = event.target instanceof Element && event.target.closest('input,textarea,[contenteditable="true"]');
    if (!editable && (event.code === "Space" || event.key === " " ||
        ["MediaPlayPause", "MediaPlay", "MediaPause"].includes(event.key))) machine.manualOverride();
  }, true);
  // Any playback restart during a speaking cycle is treated as a user override.
  document.addEventListener("play", event => {
    if (event.target instanceof HTMLMediaElement && machine.active) machine.manualOverride();
  }, true);
  document.addEventListener("seeking", event => {
    if (event.target instanceof HTMLMediaElement && machine.active) machine.manualOverride();
  }, true);

  async function poll() {
    while (!stopped) {
      let result;
      try {
        result = await chrome.runtime.sendMessage({ type: "get-state" });
        if (!result || typeof result.ok !== "boolean") throw new Error("Extension is unavailable");
      } catch {
        // Runtime failure means no future poll is guaranteed. Restore before any timer.
        await apply(machine.finish(snapshot()));
        if (!chrome.runtime?.id) { stopped = true; return; }
        result = { ok: false };
        // This timer is only the recovery path for an unavailable extension runtime.
        await new Promise(resolve => setTimeout(resolve, 250));
      }
      await apply(machine.step(result, snapshot(), performance.now(), Date.now()));
      if (!chrome.runtime?.id) {
        // An extension reload invalidates this isolated script. Release its own lease.
        await apply(machine.finish(snapshot()));
        stopped = true;
      }
    }
  }
  void poll();
})();
