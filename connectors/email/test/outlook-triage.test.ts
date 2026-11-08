import { afterEach, describe, expect, it, vi } from "vitest";
import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import worker from "../src/index";
import { Budget } from "../src/budget";
import { encrypt } from "../src/crypto";
import { processEvents } from "../src/events";
import { HAIKU } from "../src/llm";
import { issueOutlookToken, outlookSilent } from "../src/outlook";
import { runUser } from "../src/run";
import { BASE, call, newUser } from "./helpers";

afterEach(() => { vi.restoreAllMocks(); });

type Row = { rowId: string; fromName: string; fromAddr?: string; subject: string; preview: string; received: string; unread: boolean };
const ITEM_ID = "AAQkADAwATM0MDAAMS1hYmNkLTAwAi0wMAoAEABvXyZ5b2xYQ6c2L1EgO0+z";
const row = (n: number, over: Partial<Row> = {}): Row => ({ rowId: `${ITEM_ID}${n}`, fromName: "Anna Lee", fromAddr: "anna@acme.com",
  subject: `Contract ${n}`, preview: `Could you sign contract ${n} by Friday?`, received: `2026-11-0${n}T10:00:00.000Z`, unread: true, ...over });
const keyOf = (r: Row) => `owa:${r.rowId}:${r.received}`;

/** Stand-in for Claude: every email is an action titled after its subject. Records what it was asked and every call. */
function fakeClaude(verdict: "action" | "none" = "action") {
  const s = { bodies: [] as any[], urls: [] as string[], fetch: undefined as any as typeof fetch };
  s.fetch = (async (u: RequestInfo | URL, init?: RequestInit) => {
    s.urls.push(String(u));
    if (!String(u).includes("api.anthropic.com")) return new Response("unexpected call", { status: 500 });
    const body = JSON.parse(String(init?.body));
    s.bodies.push(body);
    const subject = /Subject: (.*)/.exec(body.messages[0].content)?.[1] ?? "";
    const v = verdict === "action"
      ? { action_required: true, title: `Sign ${subject}`, why: "asked to sign", due: null, has_time: false, importance: 1, group: null, urgent: false }
      : { action_required: false, title: "", why: "", due: null, has_time: false, importance: 0, group: null, urgent: false };
    return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
      content: [{ type: "text", text: JSON.stringify(v) }], usage: { input_tokens: 1, output_tokens: 1 } });
  }) as typeof fetch;
  return s;
}

/** A user with an Outlook source (mailbox me@corp.com) and the given rows ingested, plus a Claude key. */
async function outlookUser(rows: Row[]) {
  const u = await newUser("T");
  const { id: sourceId, token } = await issueOutlookToken(env as any, u.id);
  // Stored before the Claude key exists, so nothing is judged in the background here.
  const r = await call("/ingest/outlook", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify({ mailbox: "me@corp.com", items: rows }) });
  expect(r.status).toBe(200);
  await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
  return { ...u, sourceId, token };
}

const proposals = async (key: string) => ((await (await call("/v2/proposals", { key })).json()) as any).items as any[];
const waiting = async (userId: string) => (await env.DB.prepare("SELECT row_key FROM outlook_rows WHERE user_id=? AND processed=0 ORDER BY row_key")
  .bind(userId).all<{ row_key: string }>()).results.map((r) => r.row_key);

describe("Outlook triage", () => {
  it("outlook_rows_become_tasks_through_triage", async () => {
    const plain = row(2, { rowId: "row-17", subject: "Budget & plan" });
    const u = await outlookUser([row(1), plain]);
    const claude = fakeClaude();
    await runUser(env as any, u.id, { fetchFn: claude.fetch });
    expect(claude.urls.every((x) => x.includes("api.anthropic.com"))).toBe(true); // no mail service is ever called
    expect(claude.bodies.length).toBe(2);
    const tasks = (await proposals(u.key)).filter((i) => i.kind === "task");
    const t1 = tasks.find((t) => t.title === "Sign Contract 1");
    expect(t1).toMatchObject({ source_key: { message_id: keyOf(row(1)), sent_at: row(1).received }, source_label: "me@corp.com",
      link: `https://outlook.office.com/mail/inbox/id/${encodeURIComponent(row(1).rowId)}`, why: "asked to sign" });
    const t2 = tasks.find((t) => t.title === "Sign Budget & plan");
    expect(t2.link).toBe(`https://outlook.office.com/mail/search?q=${encodeURIComponent("Budget & plan")}`);
    const item = await env.DB.prepare("SELECT sender, snippet, source_id FROM items WHERE user_id=? AND message_id=?").bind(u.id, keyOf(row(1))).first<any>();
    expect(item).toEqual({ sender: "anna@acme.com", snippet: row(1).preview, source_id: u.sourceId });
    // Marked processed once the decision is stored: the next run judges nothing again.
    expect(await waiting(u.id)).toEqual([]);
    const again = fakeClaude();
    await runUser(env as any, u.id, { fetchFn: again.fetch });
    expect(again.bodies.length).toBe(0);
    // The run never touches what the extension reports (last_run = last ingest, last_error = its problems).
    const src = await env.DB.prepare("SELECT last_run, last_error, cursor FROM sources WHERE id=?").bind(u.sourceId).first<any>();
    expect(src.last_error).toBeNull();
    expect(Date.now() - Date.parse(src.last_run)).toBeLessThan(60e3);
  });

  it("ignore_list_matches_name_or_address", async () => {
    const u = await outlookUser([row(1, { fromName: "Payroll Bot", fromAddr: undefined }), row(2, { fromName: "Nina", fromAddr: "nina@spam.com" }), row(3)]);
    await env.DB.prepare("UPDATE settings SET ignore_senders=? WHERE user_id=?").bind(JSON.stringify(["payroll bot", "@spam.com"]), u.id).run();
    const claude = fakeClaude();
    await runUser(env as any, u.id, { fetchFn: claude.fetch });
    expect(claude.bodies.length).toBe(1); // only row 3 reached Claude
    expect(await waiting(u.id)).toEqual([]); // dropped rows are settled too
  });

  it("classifier_told_text_is_a_preview", async () => {
    const u = await outlookUser([row(1)]);
    const claude = fakeClaude("none");
    await runUser(env as any, u.id, { fetchFn: claude.fetch });
    const asked = claude.bodies[0].messages[0].content as string;
    expect(asked).toContain("This is the preview Outlook shows, not the full email.");
    expect(asked).toContain(row(1).preview);
    expect(asked).toContain("From: Anna Lee <anna@acme.com>");
    expect(await waiting(u.id)).toEqual([]); // "no action" is a decision too
  });

  it("rows_judged_right_after_ingest_at_most_5", async () => {
    const u = await newUser("N");
    await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
    const { token } = await issueOutlookToken(env as any, u.id);
    const claude = fakeClaude();
    vi.spyOn(globalThis, "fetch").mockImplementation(claude.fetch as any);
    const ctx = createExecutionContext();
    const rows = [1, 2, 3, 4, 5, 6, 7].map((n) => row(n));
    const r = await worker.fetch(new Request(BASE + "/ingest/outlook", { method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify({ mailbox: "me@corp.com", items: rows }) }), env as any, ctx);
    expect(r.status).toBe(200);
    await waitOnExecutionContext(ctx);
    expect(claude.bodies.length).toBe(5);
    expect((await waiting(u.id)).length).toBe(2); // the hourly run is the second layer
  });

  it("done_on_outlook_task_makes_no_mail_call", async () => {
    const u = await outlookUser([row(1)]);
    await runUser(env as any, u.id, { fetchFn: fakeClaude().fetch });
    const t = (await proposals(u.key)).find((i) => i.kind === "task");
    const uuid = crypto.randomUUID();
    const ev = await call("/v2/events", { method: "POST", key: u.key, body: JSON.stringify({ events: [{ uuid, kind: "done", payload: { item_id: t.id, source_mid: t.source_key.message_id } }] }) });
    expect(ev.status).toBe(200);
    const calls: string[] = [];
    const res = await processEvents(env as any, u.id, new Budget(10), (async (x: RequestInfo | URL) => { calls.push(String(x)); return new Response("no", { status: 500 }); }) as typeof fetch);
    expect(calls).toEqual([]);
    expect(res.failed).toBe(0);
    expect(await env.DB.prepare("SELECT processed, last_error FROM app_events WHERE uuid=?").bind(uuid).first()).toEqual({ processed: 1, last_error: null });
    const trace = await env.DB.prepare("SELECT decision, detail FROM run_events WHERE trace=?").bind(uuid).first<any>();
    expect(trace.decision).toBe("done: nothing to mark read");
    expect(trace.detail).toContain("Outlook");
  });

  it("outlook_rows_never_drafted", async () => {
    const u = await outlookUser([row(1)]);
    await runUser(env as any, u.id, { fetchFn: fakeClaude().fetch });
    const t = (await proposals(u.key)).find((i) => i.kind === "task");
    const calls: string[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation((async (x: RequestInfo | URL) => { calls.push(String(x)); return new Response("no", { status: 500 }); }) as any);
    const request_id = crypto.randomUUID();
    const ctx = createExecutionContext();
    const r = await worker.fetch(new Request(BASE + "/v2/events", { method: "POST", headers: { Authorization: `Bearer ${u.key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ events: [{ uuid: crypto.randomUUID(), kind: "draft_reply",
        payload: { request_id, source_mid: t.source_key.message_id, source_sent: t.source_key.sent_at, item_id: t.id, notes: "say yes" } }] }) }), env as any, ctx);
    expect(r.status).toBe(200);
    await waitOnExecutionContext(ctx);
    expect(calls).toEqual([]);
    const d = (await proposals(u.key)).find((i) => i.kind === "draft");
    expect(d).toMatchObject({ task_ref: request_id, link: null, why: "Draft reply works for Gmail emails only for now",
      source_key: { message_id: keyOf(row(1)), sent_at: row(1).received } });
  });

  it("silence_after_two_working_days_only", async () => {
    // Last ingest Friday 6 Nov 2026, 17:00 in Berlin (16:00 UTC).
    const fri = "2026-11-06T16:00:00.000Z", zone = "Europe/Berlin";
    expect(outlookSilent(fri, new Date("2026-11-08T12:00:00Z"), zone)).toBe(false); // Sunday
    expect(outlookSilent(fri, new Date("2026-11-09T15:00:00Z"), zone)).toBe(false); // Monday 16:00
    expect(outlookSilent(fri, new Date("2026-11-10T15:59:00Z"), zone)).toBe(false); // Tuesday 16:59
    expect(outlookSilent(fri, new Date("2026-11-10T16:01:00Z"), zone)).toBe(true);  // Tuesday 17:01
    // Midweek: Wednesday 9:00 -> Friday 9:00.
    expect(outlookSilent("2026-11-04T08:00:00.000Z", new Date("2026-11-06T07:59:00Z"), zone)).toBe(false);
    expect(outlookSilent("2026-11-04T08:00:00.000Z", new Date("2026-11-06T08:01:00Z"), zone)).toBe(true);

    const NOTICE = "Outlook hasn't reported for 2 working days: sign in to Outlook in Chrome, or check the FloatBoard extension.";
    const u = await outlookUser([row(1)]);
    const lines = async () => ((await (await call("/v2/status", { key: u.key })).json()) as any).needs_attention as string[];
    expect(await lines()).not.toContain(NOTICE); // just reported
    const old = new Date(Date.now() - 5 * 86400e3).toISOString(); // 5 days always spans 2 working days
    await env.DB.prepare("UPDATE sources SET last_run=? WHERE id=?").bind(old, u.sourceId).run();
    expect(await lines()).toContain(NOTICE);
    expect((await lines()).join("\n")).not.toContain("—");
    await env.DB.prepare("UPDATE sources SET enabled=0 WHERE id=?").bind(u.sourceId).run();
    expect(await lines()).not.toContain(NOTICE); // only while the source is enabled
    // Never reported at all since it was set up: counts from creation.
    const v = await newUser("V");
    const { id } = await issueOutlookToken(env as any, v.id);
    await env.DB.prepare("UPDATE sources SET created=? WHERE id=?").bind(old, id).run();
    expect(((await (await call("/v2/status", { key: v.key })).json()) as any).needs_attention).toContain(NOTICE);
  });
});
