import { describe, it, expect, afterEach } from "vitest";
import { env } from "cloudflare:test";
import { addItem, call, newUser } from "./helpers";
import { encrypt } from "../src/crypto";
import { runUser } from "../src/run";
import { HAIKU } from "../src/llm";
import { GmailSource } from "../src/sources/gmail";
import type { Message, Source } from "../src/sources/types";
import fixture from "./fixtures/v2-status.example.json";

const post = (path: string, key: string, body: unknown, method = "POST") =>
  call(path, { key, method, body: typeof body === "string" ? body : JSON.stringify(body) });

const mail = (n: number, over: Partial<Message> = {}): Message => ({ messageId: `<m${n}@x>`, sourceId: "s", from: "Anna <anna@acme.com>",
  to: ["me@gmail.com"], cc: [], subject: `Ask ${n}`, date: "", labels: ["UNREAD"], headers: {}, text: `Please do thing ${n}`, link: `https://mail/${n}`,
  sentAt: "2026-11-07T10:00:00.000Z", ...over });
const claude = (actionRequired: boolean) => (async () => Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU,
  stop_reason: "end_turn", stop_sequence: null, content: [{ type: "text", text: JSON.stringify({ action_required: actionRequired,
    title: actionRequired ? "Do it" : "", why: "asked", due: null, has_time: false, importance: 1, group: null, urgent: false }) }],
  usage: { input_tokens: 1, output_tokens: 1 } })) as unknown as typeof fetch;
async function setupRun(address = "me@gmail.com") {
  const u = await newUser("X");
  await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
  await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,enabled,created) VALUES(?,?,'gmail',?,1,?)").bind(crypto.randomUUID(), u.id, address, new Date().toISOString()).run();
  return u;
}
const once = (m: Message): Source => ({ fetchBatch: async () => ({ messages: [m], cursor: "1", done: true }) });

describe("v2", () => {
  it("proposals_page_and_cursor", async () => {
    const u = await newUser("A"), o = await newUser("B");
    const ids: string[] = [];
    for (let i = 0; i < 5; i++) ids.push((await addItem(u.id, { created: `2026-11-07T10:00:0${i < 3 ? 0 : i}.000Z`, id: `id${i}` })).id);
    await addItem(o.id);
    await addItem(u.id, { kind: "summary", message_id: "fathom:Z", sent_at: null, task_ref: "card:3", created: "2026-11-07T11:00:00.000Z", id: "id9" });
    const p1 = await (await call("/v2/proposals?limit=2", { key: u.key })).json<any>();
    expect(p1.items.map((i: any) => i.id)).toEqual(["id0", "id1"]); // same created: ordered by id
    expect(p1.cursor).toMatch(/^2026-11-07T10:00:00\.000Z\|id1\|\d+$/);
    const p2 = await (await call(`/v2/proposals?limit=2&after=${encodeURIComponent(p1.cursor)}`, { key: u.key })).json<any>();
    expect(p2.items.map((i: any) => i.id)).toEqual(["id2", "id3"]);
    const p3 = await (await call(`/v2/proposals?after=${encodeURIComponent(p2.cursor)}`, { key: u.key })).json<any>();
    expect(p3.items.map((i: any) => i.id)).toEqual(["id4", "id9"]);
    expect(p3.items[0]).toEqual({ id: "id4", kind: "task", source_key: { message_id: expect.stringMatching(/^<.*@x>$/), sent_at: "2026-11-07T10:00:00.000Z" },
      title: "Reply to Anna", why: "asked", due: "2026-11-10T17:00", has_time: true, group: null, importance: 2, source_label: null,
      link: "https://mail/1", summary: null, task_ref: null, learned: null, sender: "anna@acme.com", sender_name: null,
      provenance: { model: HAIKU, skill_version: expect.stringMatching(/^[0-9a-f]{12}$/), created: "2026-11-07T10:00:04.000Z" } });
    expect(p3.items[1]).toMatchObject({ kind: "summary", source_key: null, task_ref: "card:3" });
    for (const bad of ["garbage", "2026-11-07T10:00:00.000Z|id1", "2026-11-07T10:00:00.000Z|id1|x", "nope|id1|3", "a|b|1|2"]) {
      expect((await call(`/v2/proposals?after=${encodeURIComponent(bad)}`, { key: u.key })).status, bad).toBe(400);
    }
  });

  it("events_are_idempotent_by_uuid", async () => {
    const u = await newUser("A");
    const ev = (uuid: string) => ({ uuid, connector: "email", kind: "done", payload: { id: "x" }, created: "2026-11-07T10:00:00Z", attempts: 0, next_try: null, last_error: null });
    const batch = { events: [ev("u1"), ev("u2")] };
    for (let i = 0; i < 2; i++) {
      const r = await post("/v2/events", u.key, batch);
      expect(r.status).toBe(200);
      expect((await r.json<any>()).acked).toEqual(["u1", "u2"]);
    }
    const n = await env.DB.prepare("SELECT COUNT(*) n FROM app_events WHERE user_id=?").bind(u.id).first<any>();
    expect(n.n).toBe(2);
  });

  it("settings_version_round_trip", async () => {
    const u = await newUser("A");
    const r = await post("/v2/settings", u.key, { version: 3, values: { my_rules: "No newsletters", ignore_senders: ["Spam@X.com"], critical_hours: 12,
      alerts_on: false, group_notes: { Work: "job" }, learn_at: 50 } }, "PUT");
    expect(r.status).toBe(200);
    expect((await (await call("/v2/status", { key: u.key })).json<any>()).settings_version).toBe(3);
    const saved = (await (await call("/v2/export", { key: u.key })).json<any>()).settings;
    expect(saved).toMatchObject({ my_rules: "No newsletters", ignore_senders: ["spam@x.com"], critical_hours: 12, alerts_on: false, group_notes: { Work: "job" } });
    const stale = await post("/v2/settings", u.key, { version: 2, values: { my_rules: "old" } }, "PUT");
    expect(stale.status).toBe(409);
    expect(await stale.json()).toEqual({ error: "stale settings version", settings_version: 3 });
    const same = await post("/v2/settings", u.key, { version: 3, values: { my_rules: "No newsletters" } }, "PUT");
    expect(same.status).toBe(200);
    expect((await (await call("/v2/export", { key: u.key })).json<any>()).settings.my_rules).toBe("No newsletters");
    expect((await post("/v2/settings", u.key, { version: 4, values: { nonsense: 1 } }, "PUT")).status).toBe(400);
    expect((await post("/v2/settings", u.key, { version: 4, values: { learn_at: 7 } }, "PUT")).status).toBe(400);
    const ex = await (await call("/v2/export", { key: u.key })).json<any>();
    expect(ex.settings).toMatchObject({ my_rules: "No newsletters", learn_at: 50 });
    expect(ex.feedback).toEqual([]);
  });

  it("read_options_and_groups_round_trip", async () => {
    const u = await newUser("A");
    const saved = async () => (await (await call("/v2/export", { key: u.key })).json<any>()).settings;
    expect(await saved()).toMatchObject({ unread_only: true, mark_read_on_done: true, groups: [] }); // defaults
    const put = await post("/v2/settings", u.key, { version: 1, values: { unread_only: false, mark_read_on_done: false, groups: ["Acme", "Personal", " "] } }, "PUT");
    expect(put.status).toBe(200);
    expect(await saved()).toMatchObject({ unread_only: false, mark_read_on_done: false, groups: ["Acme", "Personal"] });
  });

  it("status_schema_matches_shared_fixture", async () => {
    const u = await newUser("A");
    const s = await (await call("/v2/status", { key: u.key })).json<any>();
    expect(s.schema).toEqual(fixture.schema);
    expect(typeof s.settings_version).toBe("number");
    expect(Array.isArray(s.needs_attention) && s.needs_attention.every((x: unknown) => typeof x === "string")).toBe(true);
    expect(Number.isInteger(s.waiting)).toBe(true);
    for (const k of ["last_run_ok", "last_run_error", "oldest_unprocessed_event"]) expect(s[k] === null || typeof s[k] === "string").toBe(true);
    expect(s).toMatchObject({ last_run_ok: null, last_run_error: null, oldest_unprocessed_event: null });
    expect(typeof s.db_size_bytes).toBe(typeof fixture.db_size_bytes); // a number, as in the shared fixture
    await post("/v2/events", u.key, { events: [{ uuid: "e1", kind: "done", payload: {} }] });
    expect((await (await call("/v2/status", { key: u.key })).json<any>()).oldest_unprocessed_event).toEqual(expect.any(String));
  });

  it("settings_accept_learn_at_and_critical_hours_as_numbers_or_strings", async () => {
    const u = await newUser("A");
    const put = (version: number, values: unknown) => post("/v2/settings", u.key, { version, values }, "PUT");
    const exported = async () => (await (await call("/v2/export", { key: u.key })).json<any>()).settings;
    expect((await put(1, { learn_at: "100", critical_hours: "12" })).status).toBe(200);
    expect(await exported()).toMatchObject({ learn_at: 100, critical_hours: 12 });
    expect((await put(2, { learn_at: 50, critical_hours: 6 })).status).toBe(200);
    expect(await exported()).toMatchObject({ learn_at: 50, critical_hours: 6 });
    expect((await put(3, { learn_at: "50" })).status).toBe(200);
    expect(await exported()).toMatchObject({ learn_at: 50 });
    for (const bad of [{ learn_at: "75" }, { learn_at: 7 }, { learn_at: "" }, { learn_at: null }, { critical_hours: "1.5" }, { critical_hours: "abc" }, { critical_hours: "" }, { critical_hours: 1.5 }]) {
      const r = await put(4, bad);
      expect(r.status, JSON.stringify(bad)).toBe(400);
      expect((await r.json<any>()).error).toMatch(/learn_at|critical_hours/);
    }
  });

  it("recheck_keeps_items", async () => {
    const u = await newUser("A");
    await addItem(u.id);
    const sid = crypto.randomUUID();
    await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,enabled,created,cursor) VALUES(?,?,'gmail','me@gmail.com',1,?, '{\"after\":1}')").bind(sid, u.id, new Date().toISOString()).run();
    const old = new Date(Date.now() - 20 * 86400e3).toISOString(), recent = new Date(Date.now() - 86400e3).toISOString();
    await env.DB.batch([
      env.DB.prepare("INSERT INTO seen(user_id,message_id,at) VALUES(?,?,?)").bind(u.id, "<old>", old),
      env.DB.prepare("INSERT INTO seen(user_id,message_id,at) VALUES(?,?,?)").bind(u.id, "<recent>", recent)]);
    expect((await call("/v2/recheck?days=0", { key: u.key, method: "POST" })).status).toBe(400);
    expect((await call("/v2/recheck?days=31", { key: u.key, method: "POST" })).status).toBe(400);
    expect((await call("/v2/recheck?days=3", { key: u.key, method: "POST" })).status).toBe(200);
    const seen = await env.DB.prepare("SELECT message_id FROM seen WHERE user_id=?").bind(u.id).all<any>();
    expect(seen.results.map((r) => r.message_id)).toEqual(["<old>"]);
    const items = await env.DB.prepare("SELECT COUNT(*) n FROM items WHERE user_id=?").bind(u.id).first<any>();
    expect(items.n).toBe(1);
    const src = await env.DB.prepare("SELECT cursor FROM sources WHERE id=?").bind(sid).first<any>();
    const after = JSON.parse(src.cursor).after;
    expect(Math.abs(after - (Date.now() / 1000 - 3 * 86400))).toBeLessThan(60);
  });

  it("source_key_uses_date_header", async () => {
    // Two people's inboxes receive the same email at different times: the source key must be identical.
    const keys: any[] = [];
    for (const received of ["2026-11-07T10:00:05.000Z", "2026-11-07T10:09:40.000Z"]) {
      const u = await setupRun();
      await runUser(env as any, u.id, { sourceFor: () => once(mail(1)), fetchFn: claude(true) });
      await env.DB.prepare("UPDATE items SET created=? WHERE user_id=?").bind(received, u.id).run();
      keys.push((await (await call("/v2/proposals", { key: u.key })).json<any>()).items[0].source_key);
    }
    expect(keys[0]).toEqual({ message_id: "<m1@x>", sent_at: "2026-11-07T10:00:00.000Z" });
    expect(keys[1]).toEqual(keys[0]);
    // The Gmail parser turns the Date header (any zone) into ISO UTC, and falls back to account + gmail id.
    const src = new GmailSource(env as any, { id: "s", user_id: "u", kind: "gmail", address: "me@gmail.com", refresh_enc: null, client_id: null, client_secret_enc: null, cursor: null });
    const hdr = (h: Record<string, string>) => ({ id: "g1", payload: { headers: Object.entries(h).map(([name, value]) => ({ name, value })) } });
    const a = (src as any).parse(hdr({ "Message-ID": "<a@b>", Date: "Sat, 07 Nov 2026 11:00:00 +0100" }));
    expect(a).toMatchObject({ messageId: "<a@b>", sentAt: "2026-11-07T10:00:00.000Z" });
    const b = (src as any).parse({ ...hdr({ Date: "Sat, 07 Nov 2026 11:00:00 +0100" }), internalDate: "1" });
    expect(b.messageId).toBe("gmail:me@gmail.com:g1");
  });

  it("not_action_on_known_key_emits_withdraw", async () => {
    const u = await setupRun();
    await runUser(env as any, u.id, { sourceFor: () => once(mail(1)), fetchFn: claude(true) });
    // Re-check: forget what was read, and now Claude says it is not an action.
    expect((await call("/v2/recheck?days=3", { key: u.key, method: "POST" })).status).toBe(200);
    await runUser(env as any, u.id, { sourceFor: () => once(mail(1)), fetchFn: claude(false) });
    const items = (await (await call("/v2/proposals", { key: u.key })).json<any>()).items;
    expect(items.map((i: any) => i.kind)).toEqual(["task", "withdraw"]);
    expect(items[1].source_key).toEqual(items[0].source_key);
    // an unknown key that is not an action stays silent
    await runUser(env as any, u.id, { sourceFor: () => once(mail(2)), fetchFn: claude(false) });
    expect((await (await call("/v2/proposals", { key: u.key })).json<any>()).items).toHaveLength(2);
  });

  it("bad_json_body_is_400", async () => {
    const u = await newUser("A");
    for (const [path, method] of [["/v2/events", "POST"], ["/v2/settings", "PUT"], ["/v2/recheck?days=3", "POST"]]) {
      const r = await post(path, u.key, "{nope", method);
      expect(r.status, path).toBe(400);
      expect(await r.json()).toEqual({ error: "Invalid JSON" });
    }
  });

  it("status_field_types", async () => {
    const u = await newUser("A");
    await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,enabled,created,last_error) VALUES(?,?,'gmail','me@gmail.com',1,?, 'Reconnect it')")
      .bind(crypto.randomUUID(), u.id, new Date().toISOString()).run();
    await post("/v2/events", u.key, { events: [{ uuid: "w1", kind: "done", payload: {} }] });
    const s = await (await call("/v2/status", { key: u.key })).json<any>();
    expect(Array.isArray(s.needs_attention) && s.needs_attention.every((x: unknown) => typeof x === "string")).toBe(true);
    expect(s.needs_attention).toContain("me@gmail.com: Reconnect it");
    expect(s.waiting).toBe(1);
    expect(Number.isInteger(s.settings_version)).toBe(true);
  });

  it("unknown_event_kind_is_acked_and_flagged", async () => {
    const u = await newUser("A");
    const r = await post("/v2/events", u.key, { events: [{ uuid: "k1", kind: "teleport", payload: { a: "b" } }, { uuid: "k2", kind: "done", payload: {} }, { uuid: "k3", kind: "done" }] });
    expect(r.status).toBe(200);
    expect((await r.json<any>()).acked).toEqual(["k1", "k2", "k3"]);
    const rows = await env.DB.prepare("SELECT uuid, processed, last_error FROM app_events WHERE user_id=? ORDER BY uuid").bind(u.id).all<any>();
    expect(rows.results).toEqual([{ uuid: "k1", processed: 2, last_error: "unknown kind" }, { uuid: "k2", processed: 0, last_error: null },
      { uuid: "k3", processed: 2, last_error: "payload must be an object" }]);
    const s = await (await call("/v2/status", { key: u.key })).json<any>();
    expect(s.waiting).toBe(1);
    expect(s.needs_attention.some((x: string) => x.includes("2 event(s)"))).toBe(true);
    expect((await post("/v2/events", u.key, { events: [{ kind: "done", payload: {} }] })).status).toBe(400);
  });

  it("withdraw_for_legacy_item_uses_same_key", async () => {
    const u = await setupRun();
    const it = await addItem(u.id, { message_id: "<m1@x>", sent_at: null, link: "https://mail/1", created: "2026-11-01T00:00:00.000Z" });
    await runUser(env as any, u.id, { sourceFor: () => once(mail(1)), fetchFn: claude(false) });
    const items = (await (await call("/v2/proposals", { key: u.key })).json<any>()).items;
    expect(items.map((i: any) => i.kind)).toEqual(["task", "withdraw"]);
    expect(items[0].id).toBe(it.id);
    expect(items[0].source_key).toEqual({ message_id: "<m1@x>", sent_at: "2026-11-07T10:00:00.000Z" });
    expect(items[1].source_key).toEqual(items[0].source_key);
  });
});

describe("v2 run", () => {
  const real = globalThis.fetch;
  afterEach(() => { globalThis.fetch = real; });
  const b64 = (s: string) => btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  /** Fake Google (token, list, message) and a Claude that says every email is an action. */
  function fakes() {
    const llm = claude(true);
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.includes("oauth2.googleapis.com")) return Response.json({ access_token: "at", expires_in: 3600 });
      if (url.includes("gmail.googleapis.com")) {
        const u = new URL(url);
        if (u.pathname.endsWith("/messages")) return Response.json({ messages: [{ id: "g1" }] });
        return Response.json({ id: "g1", labelIds: ["INBOX", "UNREAD"], payload: { mimeType: "text/plain", body: { data: b64("Please do thing") },
          headers: [["Message-ID", "<g1@x>"], ["From", "Anna <anna@acme.com>"], ["To", "me@gmail.com"], ["Subject", "Ask"], ["Date", "Sat, 07 Nov 2026 10:00:00 +0000"]]
            .map(([name, value]) => ({ name, value })) } });
      }
      return llm(input, init);
    }) as typeof fetch;
  }
  async function user() {
    const u = await setupRun();
    await env.DB.prepare("UPDATE sources SET client_id='cid', refresh_enc=?, client_secret_enc=? WHERE user_id=?")
      .bind(await encrypt(env as any, "r"), await encrypt(env as any, "s"), u.id).run();
    return u;
  }

  it("v2_run_processes_now_and_reports_done", async () => {
    const u = await user();
    fakes();
    expect((await call("/v2/recheck?days=3", { key: u.key, method: "POST" })).status).toBe(200);
    const r = await call("/v2/run", { key: u.key, method: "POST" });
    expect(r.status).toBe(200);
    const body = await r.json<any>();
    expect(body.processed).toBeGreaterThan(0);
    expect(body.done).toBe(true);
    const items = (await (await call("/v2/proposals", { key: u.key })).json<any>()).items;
    expect(items.length).toBeGreaterThan(0);
    expect(items[0].source_key.message_id).toBe("<g1@x>");
    const runs = await env.DB.prepare("SELECT finished, processed FROM runs WHERE user_id=?").bind(u.id).all<any>();
    expect(runs.results.length).toBeGreaterThan(0);
    expect(runs.results.every((x) => x.finished)).toBe(true);
    expect(runs.results.reduce((n, x) => n + x.processed, 0)).toBe(body.processed);
  });

  it("v2_run_crash_is_500_with_one_crashed_run", async () => {
    const u = await user();
    fakes();
    await env.DB.prepare("UPDATE users SET anthropic_key_enc='not-decryptable' WHERE id=?").bind(u.id).run();
    const r = await call("/v2/run", { key: u.key, method: "POST" });
    expect(r.status).toBe(500);
    expect((await r.json<any>()).error).toMatch(/^Run crashed: /);
    const runs = await env.DB.prepare("SELECT stopped, finished, error FROM runs WHERE user_id=?").bind(u.id).all<any>();
    expect(runs.results).toHaveLength(1);
    expect(runs.results[0].stopped).toBe("crashed");
    expect(runs.results[0].finished).toBeTruthy();
    expect(runs.results[0].error).toMatch(/Run crashed/);
  });

  it("v2_run_requires_auth", async () => {
    expect((await call("/v2/run", { method: "POST" })).status).toBe(401);
  });

  it("v2_run_shape", async () => {
    const u = await newUser("S");
    const body = await (await call("/v2/run", { key: u.key, method: "POST" })).json<any>();
    expect(Object.keys(body).sort()).toEqual(["done", "processed"]);
    expect(typeof body.processed).toBe("number");
    expect(typeof body.done).toBe("boolean");
  });
});
