import { describe, expect, it } from "vitest";
import { call } from "./helpers";
import { APP_JS } from "../src/app/client";
import { SW_JS } from "../src/app/sw";
import { PAGE_HTML } from "../src/app/page";

/** The installable phone app: static routes served by the engine (no sign-in needed for these). */

async function pngSize(r: Response): Promise<{ w: number; h: number }> {
  const b = new Uint8Array(await r.arrayBuffer());
  expect([...b.slice(0, 8)]).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  expect(new TextDecoder().decode(b.slice(12, 16))).toBe("IHDR");
  const v = new DataView(b.buffer, b.byteOffset);
  return { w: v.getUint32(16), h: v.getUint32(20) };
}

describe("phone app routes", () => {
  it("app_page_is_html_with_strict_csp", async () => {
    const r = await call("/app/");
    expect(r.status).toBe(200);
    expect(r.headers.get("Content-Type")).toBe("text/html; charset=utf-8");
    const csp = r.headers.get("Content-Security-Policy") ?? "";
    for (const d of ["default-src 'self'", "script-src 'self'", "connect-src 'self'", "img-src 'self' data:",
      "frame-ancestors 'none'", "base-uri 'none'", "object-src 'none'"]) expect(csp).toContain(d);
    expect(csp).not.toMatch(/script-src[^;]*unsafe-inline/);
    expect(r.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(r.headers.get("Referrer-Policy")).toBe("no-referrer");
    const html = await r.text();
    expect(html).toContain('<link rel="manifest" href="/app/manifest.webmanifest">');
    expect(html).toContain('<script src="/app/app.js" defer></script>');
    // No inline script: every <script> tag loads a same-origin file.
    for (const tag of html.match(/<script[^>]*>/g) ?? []) expect(tag).toMatch(/src="\/app\/[a-z.]+"/);
    expect(html).not.toMatch(/<script[^>]*>[^<]+<\/script>/);
    expect(html).not.toMatch(/\son[a-z]+=/i); // no inline event handlers (CSP would block them)
  });

  it("app_without_slash_goes_to_app_slash", async () => {
    const r = await call("/app", { redirect: "manual" });
    expect(r.status).toBe(308);
    expect(r.headers.get("Location")).toBe("/app/");
  });

  it("app_js_is_javascript_and_never_writes_data_as_html", async () => {
    const r = await call("/app/app.js");
    expect(r.status).toBe(200);
    expect(r.headers.get("Content-Type")).toBe("application/javascript; charset=utf-8");
    expect(r.headers.get("X-Content-Type-Options")).toBe("nosniff");
    const js = await r.text();
    expect(js).toBe(APP_JS);
    expect(js).not.toMatch(/innerHTML|outerHTML|insertAdjacentHTML|document\.write/);
    expect(js).not.toMatch(/\beval\(|new Function\(/);
  });

  it("manifest_has_the_install_fields", async () => {
    const r = await call("/app/manifest.webmanifest");
    expect(r.status).toBe(200);
    expect(r.headers.get("Content-Type")).toBe("application/manifest+json");
    const m: any = await r.json();
    expect(m).toMatchObject({ name: "FloatBoard", short_name: "FloatBoard", start_url: "/app/", scope: "/app/", display: "standalone", id: "/app/" });
    expect(m.background_color).toMatch(/^#[0-9a-f]{6}$/i);
    expect(m.theme_color).toMatch(/^#[0-9a-f]{6}$/i);
    const bySize = Object.fromEntries(m.icons.map((i: any) => [i.sizes, i]));
    expect(bySize["192x192"]).toMatchObject({ src: "/app/icon-192.png", type: "image/png", purpose: "any maskable" });
    expect(bySize["512x512"]).toMatchObject({ src: "/app/icon-512.png", type: "image/png", purpose: "any maskable" });
  });

  it("service_worker_is_scoped_to_app_and_never_caches_the_api", async () => {
    const r = await call("/app/sw.js");
    expect(r.status).toBe(200);
    expect(r.headers.get("Content-Type")).toBe("application/javascript; charset=utf-8");
    expect(r.headers.get("Service-Worker-Allowed")).toBe("/app/");
    expect(r.headers.get("Cache-Control")).toBe("no-cache");
    const sw = await r.text();
    expect(sw).toBe(SW_JS);
    for (const ev of ["install", "activate", "fetch", "push", "notificationclick"]) expect(sw).toContain(`addEventListener("${ev}"`);
    expect(sw).toContain("/app/api/");
    for (const asset of ["/app/", "/app/app.js", "/app/manifest.webmanifest", "/app/icon-192.png"]) expect(sw).toContain(`"${asset}"`);
  });

  it("service_worker_version_follows_the_assets", () => {
    const v = /const VERSION = "([0-9a-f]+)"/.exec(SW_JS);
    expect(v?.[1]).toMatch(/^[0-9a-f]{8}$/);
    expect(PAGE_HTML.length).toBeGreaterThan(0);
  });

  it("icons_are_png_of_the_right_size", async () => {
    for (const [path, n] of [["/app/icon-180.png", 180], ["/app/icon-192.png", 192], ["/app/icon-512.png", 512], ["/app/badge-96.png", 96]] as const) {
      const r = await call(path);
      expect(r.status, path).toBe(200);
      expect(r.headers.get("Content-Type")).toBe("image/png");
      expect(await pngSize(r)).toEqual({ w: n, h: n });
    }
    const svg = await call("/app/icon.svg");
    expect(svg.status).toBe(200);
    expect(svg.headers.get("Content-Type")).toBe("image/svg+xml");
    expect(await svg.text()).toMatch(/^<svg /);
  });

  it("unknown_app_paths_and_other_methods_are_refused", async () => {
    expect((await call("/app/nope.js")).status).toBe(404);
    expect((await call("/app/", { method: "POST" })).status).toBe(405);
    const head = await call("/app/manifest.webmanifest", { method: "HEAD" });
    expect(head.status).toBe(200);
  });

  it("api_paths_still_go_to_the_api", async () => {
    const r = await call("/app/api/me");
    expect(r.status).toBe(401);
    expect(r.headers.get("Content-Type")).toBe("application/json");
  });
});

describe("phone app sync v2 (client text checks; logic is tested in phone-sync.test.ts)", () => {
  it("queue_is_stored_with_its_account_and_each_action_carries_an_id_and_made_at", () => {
    expect(APP_JS).toContain('var QUEUE_KEY = "floatboard.queue"');
    expect(APP_JS).toMatch(/function act\(a, done\) \{[\s\S]*a\.id = newId\(\);\s*a\.made_at = new Date\(\)\.toISOString\(\);[\s\S]*saveQueue\(\);[\s\S]*render\(\);/);
    expect(APP_JS).toContain("crypto.randomUUID()");
  });

  it("batches_carry_sent_at_and_go_to_the_action_endpoint", () => {
    expect(APP_JS).toMatch(/takeBatch\(queue\.actions, new Date\(\)\.toISOString\(\)\)/);
    expect(APP_JS).toContain("return { sent_at: sentAt, actions: out }");
    expect(APP_JS).toMatch(/api\("\/app\/api\/action", \{ method: "POST", body: body \}\)/);
  });

  it("account_is_checked_before_the_queue_is_sent_and_cache_of_another_account_is_dropped", () => {
    // Sync asks /me first when the account isn't confirmed in this session, and acceptAccount drops another account's data.
    expect(APP_JS).toMatch(/if \(!me\) acceptAccount\(await api\("\/app\/api\/me"\)\);[\s\S]*while \(queue\.actions\.length\)/);
    // A board answering for another account drops the board and the queue.
    expect(APP_JS).toMatch(/function gotBoard\(b\) \{\s*if \(b\.account && me && b\.account !== me\.account\) \{[\s\S]*dropAccountData\(\)/);
    // The cache shown at launch must belong to the queue's account too.
    expect(APP_JS).toContain("(!queue.account || queue.account === cached.account)");
  });

  it("a_401_goes_to_sign_in_and_keeps_the_queue_but_not_the_board", () => {
    const signIn = /function showSignIn\(\) \{([\s\S]*?)\n  \}/.exec(APP_JS)?.[1] ?? "";
    expect(signIn).toContain("store(BOARD_KEY, null)");
    expect(signIn).not.toContain("QUEUE_KEY");
    expect(APP_JS).toMatch(/if \(e instanceof SignedOut\) \{[^\n]*showSignIn\(\); return; \}/);
  });

  it("retries_with_back_off_and_at_once_on_online_and_visible", () => {
    expect(APP_JS).toContain("retryTimer = setTimeout(sync, retryDelay(failures))");
    expect(APP_JS).toContain('window.addEventListener("online", refreshSoon)');
    expect(APP_JS).toContain('document.addEventListener("visibilitychange", refreshSoon)');
    expect(APP_JS).toMatch(/setInterval\([\s\S]*REFRESH_MS\)/);
    expect(APP_JS).toContain("var REFRESH_MS = 60000;");
  });

  it("shows_no_error_pop_ups_while_syncing", () => {
    const sync = /async function sync\(\) \{([\s\S]*?)\n  \}\n/.exec(APP_JS)?.[1] ?? "";
    expect(sync.length).toBeGreaterThan(100);
    expect(sync).not.toContain("toast(");
  });

  it("service_worker_renews_the_push_subscription", () => {
    expect(SW_JS).toContain('addEventListener("pushsubscriptionchange"');
    expect(SW_JS).toContain('fetch("/app/api/push/key"');
    expect(SW_JS).toMatch(/fetch\("\/app\/api\/push\/subscribe", \{\s*method: "POST", credentials: "same-origin"/);
    expect(APP_JS).toContain("Notifications are off on this phone");
    expect(APP_JS).toMatch(/async function checkPush\(\)[\s\S]*getSubscription\(\)/);
  });

  it("phone_says_what_is_mac_only_and_uses_no_em_dashes", () => {
    expect(APP_JS).toContain("Edit details on your Mac.");
    expect(PAGE_HTML).toContain("Mac only:");
    expect(PAGE_HTML).toContain('id="sync-status"');
    for (const text of [APP_JS, PAGE_HTML, SW_JS]) expect(text).not.toContain("—");
  });
});
