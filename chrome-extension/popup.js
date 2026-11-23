"use strict";
const toggle = document.querySelector("#enabled");
const status = document.querySelector("#status");

function render(result) {
  toggle.checked = result.extensionEnabled !== false;
  if (!toggle.checked) status.textContent = "Automatic music pause is off.";
  else if (!result.ok) status.textContent = result.error || "Local helper is disconnected.";
  else if (!result.state.enabled) status.textContent = "The local helper is paused.";
  else if (result.state.sourceCount === 0) status.textContent = "Ready. Waiting for the assistant app’s audio source.";
  else status.textContent = result.state.active ? "App audio detected. Automatic pause enabled." : "Ready. Waiting for app audio.";
}
async function update(message = { type: "get-state" }) {
  try { render(await chrome.runtime.sendMessage(message)); }
  catch { status.textContent = "Extension could not read helper state."; }
}
toggle.addEventListener("change", () => {
  void update({ type: "set-enabled", enabled: toggle.checked });
});
void update();
setInterval(() => void update(), 1000);
