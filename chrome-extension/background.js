import { AUTH_TOKEN } from "./config.js";

const ENDPOINT = "http://127.0.0.1:49753/v1/state";
const settingsReady = chrome.storage.local.get("enabled").then(({ enabled }) => enabled !== false);
let enabled = true;
let lastResult = { ok: false, error: "Waiting for the local helper" };
let cachedAt = 0;
let inFlight = null;
settingsReady.then(value => { enabled = value; });

chrome.runtime.onInstalled.addListener(async () => {
  const existing = await chrome.storage.local.get("enabled");
  if (existing.enabled === undefined) await chrome.storage.local.set({ enabled: true });
});
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.enabled) enabled = changes.enabled.newValue !== false;
});

function validState(value) {
  return value && typeof value.session === "string" && value.session.length > 0 &&
    value.session.length <= 256 && Number.isSafeInteger(value.seq) && value.seq >= 0 &&
    typeof value.active === "boolean" && typeof value.enabled === "boolean" &&
    Number.isFinite(value.updatedAt) && value.updatedAt > 0 && Math.abs(Date.now() - value.updatedAt) <= 3000 &&
    Number.isSafeInteger(value.sourceCount) && value.sourceCount >= 0;
}

async function readHelper() {
  if (Date.now() - cachedAt < 150) return lastResult;
  if (inFlight) return inFlight;
  const request = (async () => {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 650);
    try {
      if (AUTH_TOKEN === "VOICE_MUSIC_PAUSE_TOKEN" || !AUTH_TOKEN) {
        throw new Error("The extension has not been paired with its local helper");
      }
      const response = await fetch(ENDPOINT, {
        headers: { Authorization: `Bearer ${AUTH_TOKEN}`, Accept: "application/json" },
        cache: "no-store", credentials: "omit", redirect: "error", signal: controller.signal
      });
      if (!response.ok) throw new Error(response.status === 401 ? "Helper pairing was rejected" : "Local helper returned an error");
      const state = await response.json();
      if (!validState(state)) throw new Error("Local helper returned an invalid state");
      lastResult = { ok: true, state };
    } catch (error) {
      lastResult = {
        ok: false,
        error: error.name === "AbortError" || error instanceof TypeError
          ? "Local helper is disconnected" : error.message
      };
    } finally {
      clearTimeout(timeout);
      cachedAt = Date.now();
    }
    return lastResult;
  })();
  inFlight = request.finally(() => { inFlight = null; });
  return inFlight;
}

function senderKind(sender) {
  if (sender.id !== chrome.runtime.id) return null;
  try {
    const url = new URL(sender.url);
    if (url.origin === "https://music.youtube.com" && sender.frameId === 0) return "music";
    if (url.href === chrome.runtime.getURL("popup.html")) return "popup";
  } catch { /* Reject malformed and missing sender URLs. */ }
  return null;
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const kind = senderKind(sender);
  if (!kind || !message || (message.type !== "get-state" && message.type !== "set-enabled")) return false;
  if (message.type === "set-enabled" && (kind !== "popup" || typeof message.enabled !== "boolean")) return false;
  (async () => {
    await settingsReady;
    if (message.type === "set-enabled") {
      enabled = message.enabled;
      await chrome.storage.local.set({ enabled });
    }
    // Pace requests here, not in the hidden music tab, whose timers Chrome can throttle.
    // The next content request arrives immediately after this response and keeps the
    // service worker active only while a YouTube Music page is open.
    if (kind === "music") await new Promise(resolve => setTimeout(resolve, 200));
    const result = await readHelper();
    sendResponse({ ...result, extensionEnabled: enabled });
  })().catch(() => sendResponse({ ok: false, extensionEnabled: enabled, error: "Extension could not read helper state" }));
  return true;
});
