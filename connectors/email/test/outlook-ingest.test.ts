import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { call, form, get, newUser, signIn } from "./helpers";
import { sha256Hex } from "../src/auth";
import { issueOutlookToken } from "../src/outlook";

type Row = { rowId: string; fromName: string; fromAddr?: string; subject: string; preview: string; received: string; unread: boolean };

const row = (n: number, over: Partial<Row> = {}): Row => ({ rowId: `AAQkAD${n}xyz=`, fromName: "Anna Lee", fromAddr: "anna@acme.com",
  subject: `Contract ${n}`, preview: `Could you sign contract ${n} by Friday?`, received: `2026-11-0${(n % 9) + 1}T10:00:00.000Z`, unread: true, ...over });

/** POST /ingest/outlook exactly as the extension sends it (src/queue.ts postIngest). */
const ingest = (token: string | null, body: unknown) => call("/ingest/outlook", {
  method: "POST", headers: token === null ? {} : { Authorization: `Bearer ${token}` }, body: JSON.stringify(body),
});

const rowsOf = async (userId: string) => (await env.DB.prepare("SELECT * FROM outlook_rows WHERE user_id=? ORDER BY row_key").bind(userId).all<any>()).results;
const sourceOf = (userId: string) => env.DB.prepare("SELECT * FROM sources WHERE user_id=? AND kind='outlook_web'").bind(userId).first<any>();

async function outlookUser(name = "O") {
  const u = await newUser(name);
  const { token } = await issueOutlookToken(env as any, u.id);
  return { ...u, token };
}

const status = async (key: string) => (await (await call("/v2/status", { key })).json()) as any;

describe("POST /ingest/outlook", () => {
  it("ingest_is_idempotent", async () => {
    const u = await outlookUser();
    const body = { mailbox: "Me@Corp.com", items: [row(1), row(2)] };
    const r1 = await ingest(u.token, body);
    expect(r1.status).toBe(200);
    expect(await r1.json()).toMatchObject({ ok: true, stored: 2, duplicates: 0 });
    // Chrome killed the worker before the ack arrived: the same batch is sent again (plus one new row).
    const r2 = await ingest(u.token, { ...body, items: [row(1), row(2), row(3)] });
    expect(r2.status).toBe(200);
    expect(await r2.json()).toMatchObject({ ok: true, stored: 1, duplicates: 2 });
    const rows = await rowsOf(u.id);
    expect(rows.map((r) => r.row_key)).toEqual([row(1), row(2), row(3)].map((x) => `owa:${x.rowId}:${x.received}`));
    const src = await sourceOf(u.id);
    expect(rows.every((r) => r.source_id === src.id && r.processed === 0)).toBe(true);
    expect(rows[0]).toMatchObject({ from_name: "Anna Lee", from_addr: "anna@acme.com", subject: "Contract 1",
      preview: "Could you sign contract 1 by Friday?", received: row(1).received });
  });

  it("ingest_requires_token_and_only_writes_its_source", async () => {
    const a = await outlookUser("A"), b = await outlookUser("B");
    const body = { mailbox: "a@corp.com", items: [row(1)] };
    for (const bad of [null, "", "nope", a.key /* the user key is not an ingest token */]) {
      const r = await ingest(bad, body);
      expect(r.status).toBe(401);
    }
    expect(await rowsOf(a.id)).toEqual([]);
    expect((await ingest(a.token, body)).status).toBe(200);
    expect((await rowsOf(a.id)).length).toBe(1);
    expect(await rowsOf(b.id)).toEqual([]);
    expect((await sourceOf(b.id)).address).toBe("");
    // A disabled source refuses its token.
    await env.DB.prepare("UPDATE sources SET enabled=0 WHERE user_id=? AND kind='outlook_web'").bind(b.id).run();
    expect((await ingest(b.token, { mailbox: "b@corp.com", items: [row(2)] })).status).toBe(403);
    expect(await rowsOf(b.id)).toEqual([]);
    // Malformed bodies are refused without writing.
    expect((await call("/ingest/outlook", { method: "POST", headers: { Authorization: `Bearer ${a.token}` }, body: "{nope" })).status).toBe(400);
    expect((await ingest(a.token, { items: "x" })).status).toBe(400);
    expect((await rowsOf(a.id)).length).toBe(1);
  });

  it("ingest_skips_malformed_rows_but_acknowledges_the_batch", async () => {
    const u = await outlookUser();
    const r = await ingest(u.token, { mailbox: "me@corp.com", items: [row(1), { rowId: "", received: "x" }, row(2, { received: "not a date" }), 7, row(3, { unread: false })] });
    expect(r.status).toBe(200); // a poison row must never block the extension's queue
    expect(await r.json()).toMatchObject({ stored: 1, skipped: 4 });
    expect((await rowsOf(u.id)).length).toBe(1);
  });

  it("ingest_token_cannot_read_proposals_or_status", async () => {
    const u = await outlookUser();
    expect((await ingest(u.token, { mailbox: "me@corp.com", items: [row(1)] })).status).toBe(200);
    for (const [method, path] of [["GET", "/v2/proposals"], ["GET", "/v2/status"], ["GET", "/v2/export"], ["POST", "/v2/events"], ["POST", "/v2/run"]]) {
      const r = await call(path, { method, key: u.token, ...(method === "POST" ? { body: "{}" } : {}) });
      expect(r.status, path).toBe(401);
    }
    // Nor sign in to the setup page.
    const r = await form("/setup/signin", { key: u.token }, { ip: "10.9.9.9" });
    expect(r.status).toBe(401);
  });

  it("first_ingest_sets_mailbox_then_other_mailboxes_refused", async () => {
    const u = await outlookUser();
    expect((await sourceOf(u.id)).address).toBe("");
    expect((await ingest(u.token, { mailbox: "Me@Corp.com", items: [row(1)] })).status).toBe(200);
    expect((await sourceOf(u.id)).address).toBe("me@corp.com");
    const r = await ingest(u.token, { mailbox: "other@corp.com", items: [row(2)] });
    expect(r.status).toBe(409);
    expect((await rowsOf(u.id)).length).toBe(1);
    const src = await sourceOf(u.id);
    expect(src.address).toBe("me@corp.com");
    expect(src.last_error).toContain("This isn't the connected Outlook mailbox");
    expect((await status(u.key)).needs_attention.join("\n")).toContain("This isn't the connected Outlook mailbox");
    // The right mailbox again (any case): accepted, and the refusal clears.
    expect((await ingest(u.token, { mailbox: "ME@corp.com", items: [row(3)] })).status).toBe(200);
    expect((await sourceOf(u.id)).last_error).toBeNull();
    expect((await status(u.key)).needs_attention.join("\n")).not.toContain("Outlook");
  });

  it("problem_reports_show_in_needs_attention", async () => {
    const u = await outlookUser();
    const r = await ingest(u.token, { problem: "Outlook page not recognised: no message list" });
    expect(r.status).toBe(200);
    expect(await rowsOf(u.id)).toEqual([]);
    const lines: string[] = (await status(u.key)).needs_attention;
    expect(lines).toContain("Outlook: Outlook page not recognised: no message list");
    // A report naming a mailbox is accepted (2xx, so the extension stops resending it) and never sets the mailbox.
    expect((await ingest(u.token, { mailbox: "x@corp.com", problem: "This isn't the connected mailbox" })).status).toBe(200);
    expect((await sourceOf(u.id)).address).toBe("");
    expect((await status(u.key)).needs_attention).toContain("Outlook: This isn't the connected mailbox");
    // Rows read again mean the page is fine: the problem clears.
    expect((await ingest(u.token, { mailbox: "me@corp.com", items: [row(1)] })).status).toBe(200);
    expect((await status(u.key)).needs_attention.join("\n")).not.toContain("Outlook");
  });

  it("empty_batch_is_a_connection_test", async () => {
    const u = await outlookUser();
    const before = await sourceOf(u.id);
    expect(before.last_run).toBeNull();
    const r = await ingest(u.token, { items: [] });
    expect(r.status).toBe(200);
    const after = await sourceOf(u.id);
    expect(after.last_run).not.toBeNull();
    expect({ ...after, last_run: null }).toEqual(before);
    expect(await rowsOf(u.id)).toEqual([]);
    // A bad token is reported as such (the options page shows "key rejected").
    expect((await ingest("wrong", { items: [] })).status).toBe(401);
  });

  it("rows_pruned_30_days_after_processing", async () => {
    const u = await outlookUser();
    expect((await ingest(u.token, { mailbox: "me@corp.com", items: [row(1), row(2), row(3)] })).status).toBe(200);
    const day = 86400e3, ago = (d: number) => new Date(Date.now() - d * day).toISOString();
    const set = (n: number, processed: number, at: string | null) => env.DB.prepare("UPDATE outlook_rows SET processed=?, processed_at=? WHERE user_id=? AND row_key=?")
      .bind(processed, at, u.id, `owa:${row(n).rowId}:${row(n).received}`).run();
    await set(1, 1, ago(31)); // processed long ago: goes
    await set(2, 1, ago(29)); // processed recently: stays
    await env.DB.prepare("UPDATE outlook_rows SET created=? WHERE user_id=?").bind(ago(60), u.id).run(); // row 3: old but never processed: stays
    expect((await ingest(u.token, { items: [] })).status).toBe(200); // every ingest prunes
    expect((await rowsOf(u.id)).map((r) => r.subject)).toEqual(["Contract 2", "Contract 3"]);
  });
});

describe("setup page: Outlook (Chrome extension)", () => {
  it("setup_creates_source_and_shows_token_once", async () => {
    const u = await newUser("S");
    const s = await signIn(u.key);
    expect(s.page).toContain("Outlook (Chrome extension)");
    expect(s.page).toMatch(/20 to 50/);
    const section = /Outlook \(Chrome extension\)[\s\S]*?<\/section>/.exec(s.page)![0];
    expect(section).not.toContain("—"); // no em dashes in user-facing text
    const r = await form("/setup/outlook", { csrf: s.csrf }, { cookie: s.cookie });
    expect(r.status).toBe(200);
    const page = await r.text();
    const token = /id="outlook_token"[^>]*value="([^"]+)"/.exec(page)?.[1];
    expect(token).toBeTruthy();
    const made = /Outlook \(Chrome extension\)[\s\S]*?<\/section>/.exec(page)![0];
    expect(made).toContain("<code>https://engine.test</code>"); // the engine address to paste in the extension
    expect(made).not.toContain("\u2014");
    const src = await sourceOf(u.id);
    expect(src).toMatchObject({ kind: "outlook_web", address: "", enabled: 1, hook_id: await sha256Hex(token!) });
    expect(JSON.stringify(src)).not.toContain(token);
    // Shown once: reloading the page never shows it again.
    expect(await (await get("/setup", s.cookie)).text()).not.toContain(token);
    expect((await ingest(token!, { items: [] })).status).toBe(200);
    // Creating again doesn't make a second source or show the token.
    const again = await (await form("/setup/outlook", { csrf: s.csrf }, { cookie: s.cookie })).text();
    expect(again).not.toContain(token);
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM sources WHERE user_id=? AND kind='outlook_web'").bind(u.id).first<any>()).n).toBe(1);
    // Rotating shows a new token once; the old one stops working, the mailbox is kept.
    expect((await ingest(token!, { mailbox: "me@corp.com", items: [row(1)] })).status).toBe(200);
    const rot = await (await form("/setup/outlook/rotate", { csrf: s.csrf }, { cookie: s.cookie })).text();
    const token2 = /id="outlook_token"[^>]*value="([^"]+)"/.exec(rot)?.[1];
    expect(token2).toBeTruthy();
    expect(token2).not.toBe(token);
    expect((await ingest(token!, { items: [] })).status).toBe(401);
    expect((await ingest(token2!, { items: [] })).status).toBe(200);
    expect((await sourceOf(u.id)).address).toBe("me@corp.com");
    const shown = await (await get("/setup", s.cookie)).text();
    expect(shown).toContain("me@corp.com");
    expect(shown).not.toContain(token2);
    // Without the page's CSRF token nothing happens.
    expect((await form("/setup/outlook/rotate", { csrf: "x" }, { cookie: s.cookie })).status).toBe(403);
    expect((await ingest(token2!, { items: [] })).status).toBe(200);
  });
});
