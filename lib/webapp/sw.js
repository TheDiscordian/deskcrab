// Network-only for fetches: the brain is on the laptop, so there is nothing
// useful to serve offline. The service worker exists to make the page
// installable — and to receive Web Push, which is the ONLY channel that works
// with the page closed.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", e => e.respondWith(fetch(e.request)));

// The payload arrives already decrypted by the browser (RFC 8291 — the push
// service in the middle never saw the text). showNotification inside waitUntil
// is not optional politeness: a push with no visible notification gets the
// subscription throttled or revoked by the browser.
self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; }
  catch (_) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "DeskCrab", {
    body: d.body || "",
    icon: "/icon.svg",
    badge: "/icon.svg",
    tag: d.tag || "deskcrab",
    data: { url: d.url || "/" },
  }));
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true })
    .then(list => {
      for (const c of list) if ("focus" in c) return c.focus();
      return self.clients.openWindow((e.notification.data || {}).url || "/");
    }));
});
