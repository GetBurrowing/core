// Service worker for the Suite PWA.
//
// Design: bypass-by-default, intercept-by-allowlist.
//
// The previous revision (suite-v1) ran `event.respondWith` for every
// same-origin GET and fell back to `Response.error()` on upstream
// failures. That turned transient network blips into hard failures on
// LiveView's reconnect path (/live/longpoll): Phoenix saw "longpoll
// failed" instead of "longpoll slow, retrying" and the reconnect toast
// got stuck. It also meant dynamic auth-scoped paths (/chat/attachments/:id)
// had the potential to surface stale or cross-session cached bytes.
//
// suite-v2 only intercepts static assets (hashed JS/CSS, images, fonts)
// using stale-while-revalidate. Everything else — LiveView transports,
// attachment streams, API endpoints — is passed straight through to the
// network with no SW involvement. The activate handler deletes every
// cache that isn't the current CACHE_NAME, so the version bump below
// wipes anything leaked under suite-v1 as a one-shot.

const CACHE_NAME = "suite-v2";

// Static-asset path matchers. A request must match BOTH a known static
// prefix AND a static-asset extension to be eligible for caching. This
// keeps the SW from accidentally caching a future auth-scoped endpoint
// that happens to sit under a path ending in `.png` or `.js` — the
// regex alone is too permissive because it has no knowledge of whether
// a given path is public or per-user.
//
// If we ever introduce a new static-asset location, add it here
// explicitly rather than relaxing the extension check.
const STATIC_PREFIXES = ["/assets/", "/images/", "/fonts/"];
const STATIC_EXT = /\.(?:js|mjs|css|woff2?|ttf|otf|eot|png|jpg|jpeg|gif|webp|avif|svg|ico)$/i;

function isStatic(url) {
  return (
    STATIC_PREFIXES.some((p) => url.pathname.startsWith(p)) &&
    STATIC_EXT.test(url.pathname)
  );
}

self.addEventListener("install", (_event) => {
  // No precache: Phoenix digests static asset filenames, so the first
  // fetch populates the cache naturally and there is no value in racing
  // the install step to pre-populate.
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))
        )
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;

  const url = new URL(event.request.url);

  // Only touch same-origin requests. Cross-origin (LiveKit, third-party
  // CDNs) must reach the network directly or their SDKs break.
  if (url.origin !== self.location.origin) return;

  // Bypass for any path that isn't a static asset. Covers /live/*,
  // /chat/attachments/*, /api/*, and plain LV-served HTML routes.
  if (!isStatic(url)) return;

  event.respondWith(staleWhileRevalidate(event.request));
});

async function staleWhileRevalidate(request) {
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(request);

  const networkPromise = fetch(request)
    .then((response) => {
      // Only cache successful responses. Without this check, a 5xx from
      // the origin (or an edge-level error from a CDN) would poison the
      // cache for the lifetime of this cache version.
      if (response && response.ok) {
        cache.put(request, response.clone());
      }
      return response;
    })
    .catch(() => cached || Response.error());

  return cached || networkPromise;
}

self.addEventListener("push", (event) => {
  const data = event.data?.json() ?? {};
  event.waitUntil(
    self.registration.showNotification(data.title ?? "Suite", {
      body: data.body,
      icon: "/images/icon-192.png",
      badge: "/images/icon-192.png",
      data: { url: data.url ?? "/chat" },
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(clients.openWindow(event.notification.data.url));
});
