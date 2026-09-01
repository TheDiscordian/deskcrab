// Network-only by design: installation gives the spectator its own app shell,
// never an offline copy of a live game, HUD, portrait state, or credential.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()));
self.addEventListener("fetch", event => event.respondWith(fetch(event.request)));
