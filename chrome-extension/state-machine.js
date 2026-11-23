(function expose(root) {
  "use strict";

  const sameIdentity = (a, b) => Boolean(a && b && a.element === b.element &&
    a.src === b.src && a.trackId === b.trackId);

  class PauseLeaseMachine {
    constructor({ disconnectTimeoutMs = 3000, timeTolerance = 0.35 } = {}) {
      this.disconnectTimeoutMs = disconnectTimeoutMs;
      this.timeTolerance = timeTolerance;
      this.session = null;
      this.seq = -1;
      this.lastContact = null;
      this.active = false;
      this.blocked = false;
      this.lease = null;
      this.cycleIdentity = null;
    }

    validLease(media) {
      return Boolean(this.lease && sameIdentity(this.lease, media) &&
        media.connected && media.paused && !media.ended && !media.seeking &&
        Number.isFinite(media.time) &&
        Math.abs(media.time - this.lease.time) <= this.timeTolerance);
    }

    release(media) {
      const action = this.validLease(media) ? [{ type: "resume", ...this.lease }] : [];
      this.lease = null;
      return action;
    }

    finish(media) {
      const actions = this.release(media);
      this.active = false;
      this.blocked = false;
      this.cycleIdentity = null;
      return actions;
    }

    manualOverride() {
      this.lease = null;
      if (this.active) this.blocked = true;
    }

    pauseApplied(media) {
      if (this.lease && sameIdentity(this.lease, media) && media.paused &&
          media.connected && !media.ended && !media.seeking) {
        this.lease.time = media.time;
      } else {
        this.manualOverride();
      }
    }

    step(result, media, now, wallNow = now) {
      // Disabling the extension must restore an owned pause even when its helper is down.
      if (result.extensionEnabled === false) return this.finish(media);

      if (result.ok && Math.abs(wallNow - result.state.updatedAt) > this.disconnectTimeoutMs) {
        result = { ...result, ok: false };
      }
      if (!result.ok) {
        if (this.lastContact !== null && now - this.lastContact > this.disconnectTimeoutMs) {
          return this.finish(media);
        }
        if (this.lease && !this.validLease(media)) this.manualOverride();
        return [];
      }

      const state = result.state;
      if (this.session !== null && state.session !== this.session) {
        const actions = this.finish(media);
        this.session = state.session;
        this.seq = state.seq;
        this.lastContact = now;
        // Restore the old session's lease first; the next poll can start a new lease.
        return actions;
      }
      if (this.session === null) this.session = state.session;
      // Repeated sequence numbers are heartbeats; older replies must not revive speech.
      if (state.seq < this.seq) return this.step({ ok: false }, media, now, wallNow);
      this.seq = state.seq;
      this.lastContact = now;

      if (!state.enabled || !state.active || state.sourceCount === 0) return this.finish(media);

      if (!this.active) {
        this.active = true;
        this.blocked = false;
        this.cycleIdentity = media ? { ...media } : null;
      } else if (this.cycleIdentity && !sameIdentity(this.cycleIdentity, media)) {
        this.manualOverride();
      }
      if (this.lease && !this.validLease(media)) this.manualOverride();
      if (this.blocked || this.lease || !media || !media.connected || media.paused ||
          media.ended || media.seeking || !media.src || !Number.isFinite(media.time)) return [];

      this.cycleIdentity = { ...media };
      this.lease = { element: media.element, src: media.src, trackId: media.trackId, time: media.time };
      return [{ type: "pause", ...this.lease }];
    }
  }

  const api = Object.freeze({ PauseLeaseMachine, sameIdentity });
  root.VoiceMusicPause = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(globalThis);
