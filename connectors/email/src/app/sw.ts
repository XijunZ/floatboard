/**
 * The phone app's service worker, served as `/app/sw.js` with `Service-Worker-Allowed: /app/`.
 *
 * - Caches the app shell (page, script, manifest, icons) so the app opens without a connection. The cache name carries a
 *   hash of every asset, so a new engine deploy changes sw.js, the phone installs the new version and drops the old cache.
 * - Never touches `/app/api/*`: board and sign-in requests always go to the network and are never cached.
 * - Shows Web Push alerts (`{title, body, url}`) and opens the app, or the task's link, when one is tapped.
 */
import { APP_JS } from "./client";
import { BADGE_96_B64, ICON_180_B64, ICON_192_B64, ICON_512_B64, ICON_SVG } from "./icons";
import { MANIFEST, PAGE_HTML } from "./page";

/** FNV-1a, 32 bit, as 8 hex digits. */
function fnv(s: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 0x01000193);
  return (h >>> 0).toString(16).padStart(8, "0");
}

export const SHELL = ["/app/", "/app/app.js", "/app/manifest.webmanifest", "/app/icon.svg", "/app/icon-180.png", "/app/icon-192.png",
  "/app/icon-512.png", "/app/badge-96.png"];

const BODY = String.raw`
const CACHE = "floatboard-" + VERSION;

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE)
    .then((cache) => cache.addAll(SHELL.map((u) => new Request(u, { cache: "reload" }))))
    .then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k.startsWith("floatboard-") && k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  // The API is never cached: let those requests go straight to the network.
  if (url.pathname.startsWith("/app/api/") || url.pathname === "/app/sw.js") return;
  const key = req.mode === "navigate" || url.pathname === "/app" ? "/app/" : url.pathname;
  if (SHELL.indexOf(key) < 0) return;
  event.respondWith(caches.open(CACHE).then((cache) => cache.match(key).then((hit) => hit || fetch(req).then((res) => {
    if (res.ok && res.type === "basic") cache.put(key, res.clone());
    return res;
  }))));
});

function tagFor(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (Math.imul(h, 31) + s.charCodeAt(i)) | 0;
  return "fb-" + (h >>> 0).toString(16);
}

self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = { body: event.data ? event.data.text() : "" }; }
  const title = typeof data.title === "string" && data.title ? data.title : "FloatBoard";
  const body = typeof data.body === "string" ? data.body : "";
  const url = typeof data.url === "string" ? data.url : "/app/";
  event.waitUntil(self.registration.showNotification(title, {
    body,
    icon: "/app/icon-192.png",
    badge: "/app/badge-96.png",
    tag: tagFor(title + "\n" + url),
    renotify: true,
    data: { url },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const app = new URL("/app/", self.location.origin).href;
  let target = app;
  try {
    const raw = event.notification.data && event.notification.data.url;
    const u = new URL(raw, self.location.origin);
    if (u.protocol === "https:" || u.protocol === "http:") target = u.href;
  } catch (e) { /* not a web address: open the app */ }
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((wins) => {
    if (target.startsWith(app)) {
      for (const w of wins) if (w.url.startsWith(app) && "focus" in w) return w.focus();
    }
    return self.clients.openWindow(target);
  }));
});
`;

export const VERSION = fnv([PAGE_HTML, APP_JS, MANIFEST, ICON_SVG, ICON_180_B64, ICON_192_B64, ICON_512_B64, BADGE_96_B64, BODY].join("\u0000"));

export const SW_JS = `"use strict";
const VERSION = "${VERSION}";
const SHELL = ${JSON.stringify(SHELL)};
${BODY}`;
