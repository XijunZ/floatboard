/**
 * Static files of the phone app (no sign-in needed): `/app/` (page), `/app/app.js`, `/app/sw.js`,
 * `/app/manifest.webmanifest` and the icons. `/app` redirects to `/app/` so the page always sits inside the service
 * worker's and the manifest's scope. The page gets a strict CSP: scripts only from this origin, no inline script.
 */
import { APP_JS } from "./client";
import { BADGE_96_B64, ICON_180_B64, ICON_192_B64, ICON_512_B64, ICON_SVG } from "./icons";
import { MANIFEST, PAGE_HTML } from "./page";
import { SW_JS } from "./sw";

export const APP_CSP = [
  "default-src 'self'", "script-src 'self'", "style-src 'self' 'unsafe-inline'", "img-src 'self' data:", "connect-src 'self'",
  "manifest-src 'self'", "worker-src 'self'", "object-src 'none'", "frame-ancestors 'none'", "base-uri 'none'", "form-action 'none'",
].join("; ");

const png = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

type Asset = { body: string | Uint8Array; type: string; headers?: Record<string, string> };

let assets: Record<string, Asset> | null = null;
function table(): Record<string, Asset> {
  return assets ??= {
    "/app/": {
      body: PAGE_HTML, type: "text/html; charset=utf-8",
      headers: { "Content-Security-Policy": APP_CSP, "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY", "Cache-Control": "no-cache" },
    },
    "/app/app.js": { body: APP_JS, type: "application/javascript; charset=utf-8", headers: { "Cache-Control": "no-cache" } },
    "/app/sw.js": { body: SW_JS, type: "application/javascript; charset=utf-8", headers: { "Service-Worker-Allowed": "/app/", "Cache-Control": "no-cache" } },
    "/app/manifest.webmanifest": { body: MANIFEST, type: "application/manifest+json", headers: { "Cache-Control": "no-cache" } },
    "/app/icon.svg": { body: ICON_SVG, type: "image/svg+xml" },
    "/app/icon-180.png": { body: png(ICON_180_B64), type: "image/png" },
    "/app/icon-192.png": { body: png(ICON_192_B64), type: "image/png" },
    "/app/icon-512.png": { body: png(ICON_512_B64), type: "image/png" },
    "/app/badge-96.png": { body: png(BADGE_96_B64), type: "image/png" },
  };
}

/** The phone app's static files; null for paths it doesn't own (including everything under /app/api/). */
export function handleAppStatic(req: Request): Response | null {
  const path = new URL(req.url).pathname;
  if (path !== "/app" && !path.startsWith("/app/")) return null;
  if (path.startsWith("/app/api/")) return null;
  if (path === "/app") return new Response(null, { status: 308, headers: { Location: "/app/" } });
  const a = table()[path];
  if (!a) return new Response("Not found", { status: 404, headers: { "Content-Type": "text/plain; charset=utf-8", "X-Content-Type-Options": "nosniff" } });
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD", "Content-Type": "text/plain; charset=utf-8" } });
  }
  const headers: Record<string, string> = {
    "Content-Type": a.type, "X-Content-Type-Options": "nosniff", "Cache-Control": "public, max-age=86400", ...a.headers,
  };
  return new Response(req.method === "HEAD" ? null : a.body, { headers });
}
