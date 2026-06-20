"use strict";

const params = new URLSearchParams(window.location.search);
const trackId = params.get("track") || params.get("video") || params.get("v") || "";
const title = params.get("title") || "MusicTube track";
const artist = params.get("artist") || "Open this song in the app.";
const artwork = params.get("artwork") || "";

document.getElementById("title").textContent = title;
document.getElementById("artist").textContent = artist;

const artworkEl = document.getElementById("artwork");
if (artwork) {
  try {
    const artworkURL = new URL(artwork);
    if (artworkURL.protocol === "https:") {
      artworkEl.src = artworkURL.href;
      artworkEl.hidden = false;
    }
  } catch {
    // Keep the artwork placeholder hidden for malformed shared URLs.
  }
}

const openURL = trackId ? `musictube://track/${encodeURIComponent(trackId)}` : "musictube://";
document.getElementById("open-app").href = openURL;

if (trackId) {
  const hint = document.getElementById("hint");
  hint.dataset.state = "opening";
  hint.textContent = "Trying to open MusicTube now…";

  window.setTimeout(() => {
    window.location.href = openURL;
  }, 120);

  window.setTimeout(() => {
    hint.dataset.state = "fallback";
    hint.textContent = "If MusicTube didn’t open, tap the button above. If it still doesn’t work, make sure the app is installed.";
  }, 1400);
}
