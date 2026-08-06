// Deliberately network-only. The whole point of this client is that the brain
// is on the laptop, so there is nothing useful to serve offline — the service
// worker exists only to make the page installable to a phone home screen.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", e => e.respondWith(fetch(e.request)));
