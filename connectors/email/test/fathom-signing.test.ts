import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { call, form, get, newUser, signIn } from "./helpers";
import { decrypt } from "../src/crypto";

// A Standard Webhooks secret: "whsec_" + base64 of the HMAC key.
const KEY = new Uint8Array(24).map((_, i) => i * 7 + 3);
const SECRET = "whsec_" + btoa(String.fromCharCode(...KEY));

async function sign(id: string, ts: number, body: string, key = KEY): Promise<string> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(`${id}.${ts}.${body}`)));
  return "v1," + btoa(String.fromCharCode(...mac));
}

const payload = { title: "Sync with Sam", share_url: "https://fathom.video/share/abcDEF123",
  default_summary: { markdown_formatted: "We agreed the plan." }, action_items: [], scheduled_start_time: "2026-11-08T10:00:00Z" };

async function userWithHook(name: string, withSecret: boolean) {
  const u = await newUser(name);
  const s = await signIn(u.key);
  await form("/setup/fathom", { csrf: s.csrf }, { cookie: s.cookie });
  if (withSecret) {
    const r = await form("/setup/fathom/secret", { csrf: s.csrf, fathom_secret: SECRET }, { cookie: s.cookie });
    expect(r.status).toBe(200);
  }
  const h = await env.DB.prepare("SELECT hook_id FROM sources WHERE user_id=? AND kind='fathom'").bind(u.id).first<{ hook_id: string }>();
  return { u, s, path: `/hooks/fathom/${h!.hook_id}` };
}

const deliver = (path: string, body: string, headers: Record<string, string> = {}) =>
  call(path, { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body });
const summaries = async (userId: string) =>
  (await env.DB.prepare("SELECT count(*) n FROM items WHERE user_id=? AND kind='summary'").bind(userId).first<{ n: number }>())!.n;

describe("Fathom webhook signatures", () => {
  it("fathom_secret_saved_encrypted_and_shown_as_saved", async () => {
    const { u, s } = await userWithHook("FS1", true);
    const row = await env.DB.prepare("SELECT hook_secret_enc FROM sources WHERE user_id=? AND kind='fathom'").bind(u.id).first<{ hook_secret_enc: string }>();
    expect(row!.hook_secret_enc).not.toContain("whsec_");
    expect(await decrypt(env as any, row!.hook_secret_enc)).toBe(SECRET);
    const page = await (await get("/setup", s.cookie)).text();
    expect(page).toContain("Signing secret: <span class=\"ok\">saved ✓</span>");
    expect(page).not.toContain(SECRET);
  });

  it("fathom_secret_must_look_like_a_webhook_secret", async () => {
    const { s } = await userWithHook("FS2", false);
    expect((await form("/setup/fathom/secret", { csrf: s.csrf, fathom_secret: "not-a-secret" }, { cookie: s.cookie })).status).toBe(400);
    expect((await form("/setup/fathom/secret", { csrf: s.csrf, fathom_secret: "whsec_%%%" }, { cookie: s.cookie })).status).toBe(400);
  });

  it("signed_delivery_accepted", async () => {
    const { u, path } = await userWithHook("FS3", true);
    const body = JSON.stringify(payload), ts = Math.floor(Date.now() / 1000);
    const r = await deliver(path, body, { "webhook-id": "msg_1", "webhook-timestamp": String(ts),
      "webhook-signature": `v1,AAAA ${await sign("msg_1", ts, body)}` });
    expect(r.status).toBe(200);
    expect(await summaries(u.id)).toBe(1);
  });

  it("unsigned_or_wrongly_signed_delivery_rejected_and_logged", async () => {
    const { u, path } = await userWithHook("FS4", true);
    const body = JSON.stringify(payload), ts = Math.floor(Date.now() / 1000);
    expect((await deliver(path, body)).status).toBe(401);
    const wrongKey = new Uint8Array(24).fill(9);
    expect((await deliver(path, body, { "webhook-id": "m", "webhook-timestamp": String(ts),
      "webhook-signature": await sign("m", ts, body, wrongKey) })).status).toBe(401);
    // Body changed after signing.
    expect((await deliver(path, body.replace("Sam", "Eve"), { "webhook-id": "m", "webhook-timestamp": String(ts),
      "webhook-signature": await sign("m", ts, body) })).status).toBe(401);
    expect(await summaries(u.id)).toBe(0);
    const ev = await env.DB.prepare("SELECT count(*) n FROM run_events WHERE user_id=? AND decision='Fathom delivery rejected'")
      .bind(u.id).first<{ n: number }>();
    expect(ev!.n).toBe(3);
  });

  it("stale_signed_delivery_rejected", async () => {
    const { u, path } = await userWithHook("FS5", true);
    const body = JSON.stringify(payload), ts = Math.floor(Date.now() / 1000) - 600;
    expect((await deliver(path, body, { "webhook-id": "m", "webhook-timestamp": String(ts),
      "webhook-signature": await sign("m", ts, body) })).status).toBe(401);
    expect(await summaries(u.id)).toBe(0);
  });

  it("without_a_saved_secret_unsigned_delivery_still_accepted", async () => {
    const { u, path } = await userWithHook("FS6", false);
    expect((await deliver(path, JSON.stringify(payload))).status).toBe(200);
    expect(await summaries(u.id)).toBe(1);
  });
});

describe("Fathom deliveries that fail after arriving", () => {
  it("delivery_that_cannot_be_saved_is_logged_and_retried", async () => {
    const { u, path } = await userWithHook("FF1", false);
    const r = await deliver(path, JSON.stringify({ ...payload, action_items: "not a list" }));
    expect(r.status).toBe(500); // Fathom retries a failed delivery
    const ev = await env.DB.prepare("SELECT detail FROM run_events WHERE user_id=? AND decision='Fathom delivery failed'").bind(u.id).first<{ detail: string }>();
    expect(ev?.detail).toBeTruthy();
    const src = await env.DB.prepare("SELECT last_error FROM sources WHERE user_id=? AND kind='fathom'").bind(u.id).first<{ last_error: string }>();
    expect(src!.last_error).toContain("Fathom");
  });

  it("unreadable_delivery_is_logged", async () => {
    const { u, path } = await userWithHook("FF2", false);
    expect((await deliver(path, "{not json")).status).toBe(400);
    const ev = await env.DB.prepare("SELECT count(*) n FROM run_events WHERE user_id=? AND decision='Fathom delivery unreadable'").bind(u.id).first<{ n: number }>();
    expect(ev!.n).toBe(1);
  });
});
