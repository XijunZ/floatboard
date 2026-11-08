import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { Budget } from "../src/budget";
import { runUser } from "../src/run";
import { runAllUsers } from "../src/index";
import { encrypt } from "../src/crypto";
import { LEARN_AT, maybeConsolidate } from "../src/learn";
import { newTelegramLink, setTelegramFetch } from "../src/telegram";
import { GmailSource } from "../src/sources/gmail";
import { HAIKU, makeClient } from "../src/llm";
import type { Message, Source } from "../src/sources/types";
import { call, fathomHookPath, newUser } from "./helpers";

const mail = (n: number, over: Partial<Message> = {}): Message => ({ messageId: `<m${n}@x>`, sourceId: "s", from: "Anna <anna@acme.com>",
  to: ["me@gmail.com"], cc: [], subject: `Ask ${n}`, date: "", labels: ["UNREAD"], headers: {}, text: `Please do thing ${n}`, link: `https://mail/${n}`, gmailId: `g${n}`, ...over });

/** Fake Claude that answers with `text` as the model's words (so a non-JSON text is an unreadable answer). */
const claudeSays = (text: string, stop = "end_turn") => (async () => Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU,
  stop_reason: stop, stop_sequence: null, content: [{ type: "text", text }], usage: { input_tokens: 1, output_tokens: 1 } })) as unknown as typeof fetch;
const YES = JSON.stringify({ action_required: true, title: "Do it", why: "asked", due: null, has_time: false, importance: 1, group: null, urgent: false });

type Fake = { msgs: Message[]; notes?: { messageId?: string; decision: string; detail?: string }[] };
const fetched: string[] = [];
async function setup(f: Fake) {
  fetched.length = 0;
  const u = await newUser("X");
  await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
  const id = crypto.randomUUID();
  await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,enabled,created) VALUES(?,?,'gmail','me@gmail.com',1,?)").bind(id, u.id, new Date().toISOString()).run();
  const src: Source = {
    async fetchBatch(cursor, limit) {
      const i = cursor ? Number(cursor) : 0, page = f.msgs.slice(i, i + limit), next = i + page.length;
      return { messages: page, cursor: String(next), done: next >= f.msgs.length, notes: f.notes };
    },
    async fetchFull(gid) { fetched.push(gid); const m = f.msgs.find((x) => x.gmailId === gid); if (!m) throw new Error("Gmail 404"); return m; },
  };
  return { u, sourceId: id, sourceFor: () => src };
}
const seen = (uid: string) => env.DB.prepare("SELECT COUNT(*) n FROM seen WHERE user_id=?").bind(uid).first<{ n: number }>().then((r) => r!.n);
const events = (uid: string) => env.DB.prepare("SELECT decision, detail, subject, trace, run_id FROM run_events WHERE user_id=? ORDER BY rowid").bind(uid).all<any>().then((r) => r.results);

describe("no silent failures", () => {
  it("unreadable_answer_not_marked_seen", async () => {
    const { u, sourceId, sourceFor } = await setup({ msgs: [mail(1)] });
    await runUser(env as any, u.id, { sourceFor, fetchFn: claudeSays("not json") });
    expect(await seen(u.id)).toBe(0);
    const items = await env.DB.prepare("SELECT COUNT(*) n FROM items WHERE user_id=?").bind(u.id).first<{ n: number }>();
    expect(items!.n).toBe(0);
    const a = await env.DB.prepare("SELECT attempts, last_error FROM judge_attempts WHERE user_id=? AND message_id=?").bind(u.id, "<m1@x>").first<any>();
    expect(a.attempts).toBe(1);
    expect(a.last_error).toBeTruthy();
    expect((await events(u.id)).some((e) => /couldn't judge/.test(e.decision) && e.trace === "<m1@x>")).toBe(true);
    // The cursor moves on (a bad message never holds up newer mail); the message is retried by id next run.
    expect((await env.DB.prepare("SELECT cursor, last_error FROM sources WHERE id=?").bind(sourceId).first<any>()).cursor).toBe("1");
    expect((await env.DB.prepare("SELECT gmail_id, source_id FROM judge_attempts WHERE user_id=?").bind(u.id).first<any>())).toEqual({ gmail_id: "g1", source_id: sourceId });
    // A good answer next time works and clears the problem.
    await runUser(env as any, u.id, { sourceFor, fetchFn: claudeSays(YES) });
    expect(fetched).toEqual(["g1"]);
    expect(await seen(u.id)).toBe(1);
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM items WHERE user_id=?").bind(u.id).first<any>()).n).toBe(1);
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM judge_attempts WHERE user_id=?").bind(u.id).first<any>()).n).toBe(0);
  });

  it("refusal_is_not_no_action", async () => {
    const { u, sourceFor } = await setup({ msgs: [mail(1)] });
    await runUser(env as any, u.id, { sourceFor, fetchFn: claudeSays("", "refusal") });
    expect(await seen(u.id)).toBe(0);
  });

  it("three_failures_become_visible", async () => {
    const long = "A very long subject line that goes on and on and on and on and on and on and on";
    const { u, sourceFor } = await setup({ msgs: [mail(1, { subject: long })] });
    for (let i = 0; i < 3; i++) await runUser(env as any, u.id, { sourceFor, fetchFn: claudeSays("garbage") });
    expect((await events(u.id)).some((e) => e.decision === "couldn't judge (3 tries)")).toBe(true);
    expect(await seen(u.id)).toBe(1);
    const st = await (await call("/v2/status", { key: u.key })).json<any>();
    const line = st.needs_attention.find((l: string) => l.includes("A very long subject"));
    expect(line).toBeTruthy();
    expect(line).not.toContain(long); // subject cut to 60 characters
    // Given up: a fourth run does not read it again.
    fetched.length = 0;
    await runUser(env as any, u.id, { sourceFor, fetchFn: claudeSays(YES) });
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM items WHERE user_id=?").bind(u.id).first<any>()).n).toBe(0);
    expect(fetched).toEqual([]);
  });

  it("unreadable_message_does_not_stop_newer_mail_and_is_retried_within_budget", async () => {
    const { u, sourceFor } = await setup({ msgs: [mail(1)] });
    const mixed = (async (_u: any, init?: RequestInit) => {
      const subject = /Subject: (.*)/.exec(JSON.parse(String(init?.body)).messages[0].content)?.[1] ?? "";
      return subject === "Ask 1" ? (claudeSays("garbage") as any)() : (claudeSays(YES) as any)();
    }) as unknown as typeof fetch;
    const calls = new Budget(45);
    await runUser(env as any, u.id, { sourceFor, fetchFn: mixed, calls });
    expect(calls.used).toBe(1); // only the one Claude call (the fake source costs nothing)
    // A newer message arrives; next run retries the old one by id (1 fetch) and reads the new one.
    const { msgs } = { msgs: [mail(1), mail(2)] };
    const src2: Source = { async fetchBatch(c, l) { const i = c ? Number(c) : 0; const p = msgs.slice(i, i + l); return { messages: p, cursor: String(i + p.length), done: true }; },
      async fetchFull(g) { fetched.push(g); return msgs.find((x) => x.gmailId === g)!; } };
    const sid = (await env.DB.prepare("SELECT id FROM sources WHERE user_id=?").bind(u.id).first<any>()).id;
    expect(sid).toBeTruthy();
    const calls2 = new Budget(45);
    await runUser(env as any, u.id, { sourceFor: () => src2, fetchFn: mixed, calls: calls2 });
    expect(fetched).toEqual(["g1"]);
    expect((await env.DB.prepare("SELECT title FROM items WHERE user_id=?").bind(u.id).all<any>()).results.map((r) => r.title)).toEqual(["Do it"]); // Ask 2 only
    expect(calls2.used).toBe(2); // the retry's Claude call + the new mail's (the fake source's own reads cost nothing)
    expect((await env.DB.prepare("SELECT attempts FROM judge_attempts WHERE user_id=?").bind(u.id).first<any>()).attempts).toBe(2);
  });

  it("unreadable_recap_not_reported_handled", async () => {
    const recap = mail(2, { from: "Fathom <no-reply@fathom.video>", subject: "Recap: sync", text: "notes about the sync", labels: [] });
    const { u, sourceFor } = await setup({ msgs: [recap] });
    await runUser(env as any, u.id, { sourceFor, fetchFn: claudeSays("garbage") });
    const ev = await events(u.id);
    expect(ev.some((e) => /already handled/.test(e.decision))).toBe(false);
    expect(ev.some((e) => /couldn't judge/.test(e.decision))).toBe(true);
    expect(await seen(u.id)).toBe(0);
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM items WHERE user_id=?").bind(u.id).first<any>()).n).toBe(0);
    for (let i = 0; i < 2; i++) await runUser(env as any, u.id, { sourceFor, fetchFn: claudeSays("garbage") });
    expect(await seen(u.id)).toBe(1);
    const st = await (await call("/v2/status", { key: u.key })).json<any>();
    expect(st.needs_attention.some((l: string) => l.includes("Recap: sync"))).toBe(true);
  });

  it("source_notes_are_recorded_in_run_log", async () => {
    const { u, sourceFor } = await setup({ msgs: [], notes: [{ messageId: "<m9@x>", decision: "message missing from its thread; fetched directly" }] });
    await runUser(env as any, u.id, { sourceFor, fetchFn: claudeSays(YES) });
    const e = (await events(u.id)).find((x) => /missing from its thread/.test(x.decision));
    expect(e?.trace).toBe("<m9@x>");
  });

  it("message_missing_from_thread_falls_back_to_message_fetch", async () => {
    const part = (id: string) => ({ id, threadId: "t1", labelIds: ["INBOX"], internalDate: "1", payload: { headers: [
      { name: "Message-ID", value: `<${id}@mail>` }, { name: "From", value: "a@x.com" }, { name: "Subject", value: `S ${id}` }], mimeType: "text/plain",
      body: { data: btoa("hello") } } });
    const urls: string[] = [];
    const f = (async (input: RequestInfo | URL) => {
      const url = String(input); urls.push(url);
      if (url.startsWith("https://oauth2")) return Response.json({ access_token: "at" });
      const u = new URL(url);
      if (u.pathname.endsWith("/messages")) return Response.json({ messages: [{ id: "a", threadId: "t1" }] });
      if (u.pathname.includes("/threads/")) return Response.json({ messages: [part("other")] });
      return Response.json(part("a"));
    }) as typeof fetch;
    const row = { id: "src1", user_id: "u1", kind: "gmail", address: "me@gmail.com", client_id: "cid",
      refresh_enc: await encrypt(env as any, "r"), client_secret_enc: await encrypt(env as any, "s"), cursor: null };
    const res = await new GmailSource(env as any, row, f).fetchBatch(null, 5);
    expect(res.messages.map((m) => m.subject)).toEqual(["S a"]);
    expect(urls.some((x) => x.includes("/messages/a?format=full"))).toBe(true);
    expect(res.notes).toHaveLength(1);
    expect(res.notes![0].decision).toMatch(/missing from its thread/);
    expect(res.notes![0].messageId).toBe("<a@mail>");
  });

  it("learning_failure_in_run_log", async () => {
    const u = await newUser("L");
    for (let i = 0; i < LEARN_AT; i++) await env.DB.prepare("INSERT INTO feedback(user_id,item_id,verdict,created,subject,sender,detail) VALUES(?,?,?,?,?,?,?)")
      .bind(u.id, `i${i}`, "changed", new Date().toISOString(), `S${i}`, "a@b.c", "x").run();
    expect(await maybeConsolidate(env as any, u.id, makeClient("sk", claudeSays("garbage")))).toBe(false);
    const e = (await events(u.id)).find((x) => x.decision === "learning failed; will retry");
    expect(e).toBeTruthy();
    expect(e.trace).toBe("learning");
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM feedback WHERE user_id=? AND consolidated=0").bind(u.id).first<any>()).n).toBe(LEARN_AT);
  });

  it("cron_one_user_crash_others_run", async () => {
    const a = await setup({ msgs: [] }), b = await setup({ msgs: [] });
    const ran: string[] = [];
    await runAllUsers(env as any, async (_e, userId) => {
      if (userId === a.u.id) throw new Error("boom");
      ran.push(userId); return { processed: 0, done: true };
    }, [a.u.id, b.u.id]);
    expect(ran).toEqual([b.u.id]);
    const r = await env.DB.prepare("SELECT stopped, error FROM runs WHERE user_id=?").bind(a.u.id).first<any>();
    expect(r.stopped).toBe("crashed");
    expect(r.error).toContain("boom");
  });

  it("telegram_reply_failure_in_run_log", async () => {
    const u = await newUser("T");
    const code = new URL((await newTelegramLink(env as any, u.id))!).searchParams.get("start")!;
    setTelegramFetch((async () => new Response(JSON.stringify({ description: "bot was blocked" }), { status: 403 })) as typeof fetch);
    const r = await call("/telegram/webhook", { method: "POST", headers: { "X-Telegram-Bot-Api-Secret-Token": "tg-secret" },
      body: JSON.stringify({ update_id: 42, message: { message_id: 1, chat: { id: 555, type: "private" }, text: `/start ${code}` } }) });
    expect(r.status).toBe(200);
    const e = (await events(u.id)).find((x) => x.decision === "telegram reply failed");
    expect(e?.detail).toContain("bot was blocked");
    expect(e?.trace).toBe("42");
  });

  it("recap_give_up_says_what_happened", async () => {
    const recap = mail(2, { from: "Fathom <no-reply@fathom.video>", subject: "Recap: sync", text: "notes about the sync", labels: [] });
    const { u, sourceFor } = await setup({ msgs: [recap] });
    for (let i = 0; i < 3; i++) await runUser(env as any, u.id, { sourceFor, fetchFn: claudeSays("garbage") });
    const ev = await events(u.id);
    expect(ev.some((e) => e.decision === "meeting notes saved without a summary — couldn't read the model's answer")).toBe(true);
    expect((await env.DB.prepare("SELECT kind FROM items WHERE user_id=?").bind(u.id).all<any>()).results.map((r) => r.kind)).toEqual(["summary"]);
    const st = await (await call("/v2/status", { key: u.key })).json<any>();
    const line = st.needs_attention.find((l: string) => l.includes("Recap: sync"));
    expect(line).toMatch(/saved without a summary/);
    expect(line).not.toMatch(/skipped/);
  });

  it("fathom_webhook_keeps_raw_notes_on_unusable_answer", async () => {
    const u = await newUser("F");
    await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
    const path = await fathomHookPath(u.id);
    const real = globalThis.fetch;
    globalThis.fetch = claudeSays("garbage");
    try {
      const r = await call(path, { method: "POST", body: JSON.stringify({ title: "Sync", share_url: "https://fathom.video/share/abc", summary: "We agreed things." }) });
      expect(r.status).toBe(200);
    } finally { globalThis.fetch = real; }
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM items WHERE user_id=? AND kind='summary'").bind(u.id).first<any>()).n).toBe(1);
    expect((await events(u.id)).some((e) => e.decision === "meeting notes kept unsummarised")).toBe(true);
  });

  it("recheck_clears_judge_attempts", async () => {
    const u = await newUser("R");
    const add = () => env.DB.prepare("INSERT INTO judge_attempts(user_id,message_id,attempts,updated) VALUES(?,?,3,?)").bind(u.id, "<x>", new Date().toISOString()).run();
    const n = async () => (await env.DB.prepare("SELECT COUNT(*) n FROM judge_attempts WHERE user_id=?").bind(u.id).first<any>()).n;
    await add();
    expect((await call("/v2/recheck?days=3", { key: u.key, method: "POST" })).status).toBe(200);
    expect(await n()).toBe(0);
  });

  it("telegram_failures_carry_the_user_id", async () => {
    const u = await newUser("T2");
    const code = new URL((await newTelegramLink(env as any, u.id))!).searchParams.get("start")!;
    setTelegramFetch((async () => new Response("{}", { status: 500 })) as typeof fetch);
    await call("/telegram/webhook", { method: "POST", headers: { "X-Telegram-Bot-Api-Secret-Token": "tg-secret" },
      body: JSON.stringify({ update_id: 7, message: { message_id: 1, chat: { id: 556, type: "private" }, text: `/start ${code}` } }) });
    const e = (await events(u.id)).find((x) => x.decision === "telegram reply failed");
    expect(e).toBeTruthy();
  });

  it("crashed_run_finishes_its_own_row", async () => {
    const a = await setup({ msgs: [] });
    await runAllUsers(env as any, async (e: any, userId) => {
      await e.DB.prepare("INSERT INTO runs(id,user_id,started) VALUES('open1',?,?)").bind(userId, new Date().toISOString()).run();
      throw new Error("mid-run");
    }, [a.u.id]);
    const rows = await env.DB.prepare("SELECT id, stopped, error, finished FROM runs WHERE user_id=?").bind(a.u.id).all<any>();
    expect(rows.results).toHaveLength(1);
    expect(rows.results[0]).toMatchObject({ id: "open1", stopped: "crashed" });
    expect(rows.results[0].finished).toBeTruthy();
    expect(rows.results[0].error).toContain("mid-run");
  });

  it("cron_user_lookup_failure_is_recorded", async () => {
    const broken = { ...env, DB: new Proxy(env.DB, { get(t: any, k) {
      if (k === "prepare") return (sql: string) => { if (sql.includes("SELECT DISTINCT user_id")) throw new Error("d1 down"); return t.prepare(sql); };
      const v = t[k]; return typeof v === "function" ? v.bind(t) : v;
    } }) };
    await runAllUsers(broken as any);
    const r = await env.DB.prepare("SELECT stopped, error FROM runs WHERE user_id='' ORDER BY started DESC LIMIT 1").first<any>();
    expect(r).toMatchObject({ stopped: "crashed" });
    expect(r.error).toContain("d1 down");
    expect((await env.DB.prepare("SELECT decision FROM run_events WHERE run_id='cron'").first<any>()).decision).toBe("cron could not list users");
  });

  it("malformed_bodies_400", async () => {
    const u = await newUser("M");
    const bad = (path: string, method: string, headers: Record<string, string> = {}) =>
      call(path, { method, key: headers["X-Admin-Key"] ? undefined : u.key, headers, body: "{not json" });
    const cases: [string, string, Record<string, string>?][] = [
      ["/v2/settings", "PUT"], ["/admin/users", "POST", { "X-Admin-Key": "admin-test-key" }], ["/v2/events", "POST"], ["/v2/recheck?days=3", "POST"],
    ];
    for (const [p, m, h] of cases) {
      const r = await bad(p, m, h);
      expect([p, r.status]).toEqual([p, 400]);
      expect(await r.json()).toEqual({ error: "Invalid JSON" });
    }
  });
});
