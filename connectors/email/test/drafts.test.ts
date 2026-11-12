import { afterEach, describe, expect, it, vi } from "vitest";
import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import worker from "../src/index";
import { Budget } from "../src/budget";
import { encrypt } from "../src/crypto";
import { draftReplyEvent, handleDraftReply, readDraftRequest } from "../src/drafts";
import { processEvents } from "../src/events";
import { HAIKU, SONNET } from "../src/llm";
import { processRecap } from "../src/recap";
import { runUser } from "../src/run";
import type { Message, Source } from "../src/sources/types";
import { BASE, call, newUser } from "./helpers";
import fixture from "./fixtures/v2-draft.example.json";

const b64url = (s: string) => btoa(String.fromCharCode(...new TextEncoder().encode(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64 = (s: string) => new TextDecoder().decode(Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/").replace(/\s+/g, "")), (c) => c.charCodeAt(0)));

const NOTES = "ok tues NOTESMARK, need agenda";
const REPLY = "Hi Anna,\n\nTuesday works REPLYMARK. Could you send the agenda first?\n\nAlex";
const SUBJECT = "Quarterly planning SUBJECTMARK";

const gm = (id: string, headers: Record<string, string>, text: string, labels: string[] = ["INBOX"]) => ({
  id, labelIds: labels, internalDate: "1",
  payload: { mimeType: "text/plain", body: { data: b64url(text) },
    headers: Object.entries({ "Message-ID": `<${id}@mail>`, ...headers }).map(([name, value]) => ({ name, value })) },
});
const THREAD = [gm("m1", { From: "Anna Lee <anna@x.com>", To: "me@gmail.com, bob@x.com", Subject: SUBJECT, Date: "Sat, 07 Nov 2026 10:00:00 +0000" }, "Can we meet Tuesday?")];

/** The text body of a raw (base64url) MIME message, as Gmail would give it back (CRLF line ends). */
const bodyOf = (raw: string) => {
  const mime = unb64(raw);
  const plain = /Content-Type: text\/plain[^\r]*\r\nContent-Transfer-Encoding: base64\r\n\r\n([A-Za-z0-9+/=\r\n]+)/.exec(mime);
  return unb64(plain ? plain[1] : mime.split("\r\n\r\n")[1]);
};
const htmlOf = (raw: string) => {
  const m = /Content-Type: text\/html[^\r]*\r\nContent-Transfer-Encoding: base64\r\n\r\n([A-Za-z0-9+/=\r\n]+)/.exec(unb64(raw));
  return m ? unb64(m[1]) : null;
};

type Opts = { thread?: any[] | null; claude?: "ok" | "fail"; draftGet?: "same" | "edited" | "gone" | "cc" | "to" | "subject" | "attachment"; create?: number; search?: number };

/** The headers of a raw (base64url) MIME message as Gmail lists them (folded lines joined). */
const headersOf = (raw: string) => Object.fromEntries(unb64(raw).split("\r\n\r\n")[0].replace(/\r\n /g, " ").split("\r\n")
  .map((l) => [l.slice(0, l.indexOf(":")), l.slice(l.indexOf(":") + 1).trim()]));
/** One stand-in for Google (token, sendAs, search, thread, drafts) and Claude. Every request is recorded. */
function fake(o: Opts = {}) {
  const s = { o, reqs: [] as string[], creates: [] as any[], updates: [] as any[], claude: [] as any[], raws: new Map<string, string>(), seq: 0, fetch: undefined as any as typeof fetch };
  s.fetch = (async (u: RequestInfo | URL, init?: RequestInit) => {
    const url = String(u), method = init?.method ?? "GET";
    s.reqs.push(`${method} ${url}`);
    if (url.startsWith("https://oauth2.googleapis.com/token")) return Response.json({ access_token: "at" });
    if (url.includes("api.anthropic.com")) {
      s.claude.push(JSON.parse(String(init?.body)));
      if (s.o.claude === "fail") return Response.json({ type: "error", error: { type: "api_error", message: "boom" } }, { status: 500 });
      return Response.json({ id: "m", type: "message", role: "assistant", model: SONNET, stop_reason: "end_turn", stop_sequence: null,
        content: [{ type: "text", text: REPLY }], usage: { input_tokens: 1, output_tokens: 1 } });
    }
    if (url.endsWith("/settings/sendAs")) return Response.json({ sendAs: [{ sendAsEmail: "me@gmail.com", displayName: "Alex Lee", isPrimary: true }] });
    if (url.includes("/messages?")) {
      if (s.o.search) return new Response("x", { status: s.o.search });
      return Response.json(s.o.thread === null ? {} : { messages: [{ id: "g1", threadId: "t1" }] });
    }
    if (url.includes("/threads/t1")) return Response.json({ messages: s.o.thread ?? THREAD });
    if (method === "POST" && url.endsWith("/drafts")) {
      if (s.o.create) return new Response("{}", { status: s.o.create });
      const b = JSON.parse(String(init?.body));
      s.creates.push(b);
      const id = `dr${++s.seq}`;
      s.raws.set(id, b.message.raw);
      return Response.json({ id, message: { id: `mm${s.seq}` } });
    }
    const put = /\/drafts\/(\w+)$/.exec(url);
    if (method === "PUT" && put) {
      const b = JSON.parse(String(init?.body));
      s.updates.push(b);
      s.raws.set(put[1], b.message.raw);
      return Response.json({ id: put[1], message: { id: `mm${++s.seq}` } });
    }
    const get = /\/drafts\/(\w+)\?format=full/.exec(url);
    if (get) {
      if (s.o.draftGet === "gone" || !s.raws.has(get[1])) return new Response("{}", { status: 404 });
      const raw = s.raws.get(get[1])!, g = s.o.draftGet;
      const h = headersOf(raw);
      const headers: Record<string, string> = { From: h.From, To: h.To, Subject: h.Subject, ...(h.Cc ? { Cc: h.Cc } : {}) };
      if (g === "cc") delete headers.Cc;
      if (g === "to") headers.To = "someone@else.com";
      if (g === "subject") headers.Subject = "Re: my own subject";
      const msg = gm("dm", headers, g === "edited" ? "My own words instead" : bodyOf(raw), ["DRAFT"]);
      if (g === "attachment") {
        const text = { ...msg.payload, headers: [] };
        msg.payload = { ...msg.payload, mimeType: "multipart/mixed", body: { size: 0 } as any,
          parts: [text, { mimeType: "application/pdf", filename: "deck.pdf", headers: [], body: { attachmentId: "att1", size: 10 } }] } as any;
      }
      return Response.json({ id: get[1], message: msg });
    }
    return new Response("{}", { status: 404 });
  }) as typeof fetch;
  return s;
}

async function setup(name: string) {
  const u = await newUser(name);
  const srcId = crypto.randomUUID();
  await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,refresh_enc,client_id,client_secret_enc,created) VALUES(?,?,?,?,?,?,?,?)")
    .bind(srcId, u.id, "gmail", "me@gmail.com", await encrypt(env as any, "r"), "c", await encrypt(env as any, "s"), new Date().toISOString()).run();
  await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk"), u.id).run();
  const itemId = crypto.randomUUID();
  await env.DB.prepare(`INSERT INTO items(id,user_id,source_id,message_id,kind,title,why,sender,subject,link,created,sent_at)
      VALUES(?,?,?,'<m1@mail>','action','Reply to Anna','asked','anna@x.com',?,'https://mail.google.com/mail/u/me@gmail.com/#all/g1',?,?)`)
    .bind(itemId, u.id, srcId, SUBJECT, new Date().toISOString(), "2026-11-07T10:00:00.000Z").run();
  return { ...u, srcId, itemId };
}

const payload = (u: { itemId: string }, over: Record<string, unknown> = {}) =>
  ({ source_mid: "<m1@mail>", source_sent: "2026-11-07T10:00:00.000Z", item_id: u.itemId, notes: NOTES, request_id: crypto.randomUUID(), ...over });

async function event(u: { id: string }, p: Record<string, unknown>, uuid = crypto.randomUUID()) {
  await env.DB.prepare("INSERT INTO app_events(uuid,user_id,kind,payload,received) VALUES(?,?,'draft_reply',?,?)")
    .bind(uuid, u.id, JSON.stringify(p), new Date().toISOString()).run();
  return uuid;
}
const run = (u: { id: string }, f: ReturnType<typeof fake>) => processEvents(env as any, u.id, new Budget(10), f.fetch, "draft", "draft_reply");
const drafts = async (u: { key: string }) =>
  ((await (await call("/v2/proposals", { key: u.key })).json()) as any).items.filter((i: any) => i.kind === "draft");
const ev = (uuid: string) => env.DB.prepare("SELECT processed, attempts, last_error FROM app_events WHERE uuid=?").bind(uuid).first<any>();

afterEach(() => { vi.restoreAllMocks(); });

/** POST /v2/events through the Worker itself, then wait for its background work (ctx.waitUntil) to finish. */
async function postEvents(key: string, events: unknown[], f: ReturnType<typeof fake>) {
  vi.spyOn(globalThis, "fetch").mockImplementation(f.fetch as any);
  const ctx = createExecutionContext();
  const r = await worker.fetch(new Request(BASE + "/v2/events", { method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ events }) }), env as any, ctx);
  await waitOnExecutionContext(ctx);
  return r;
}

describe("draft_reply events", () => {
  it("draft_for_an_email_the_user_linked_finds_its_inbox_by_account", async () => {
    const u = await setup("Linked draft");
    await env.DB.prepare("DELETE FROM items WHERE user_id=?").bind(u.id).run(); // the sorting never saw this email
    const f = fake();
    await postEvents(u.key, [{ uuid: crypto.randomUUID(), kind: "draft_reply", payload: payload(u, { item_id: "", account: "me@gmail.com" }) }], f);
    const [d] = await drafts(u);
    expect(d.link).toBe("https://mail.google.com/mail/u/me@gmail.com/#drafts?compose=mm1");
    expect(f.creates[0].message.threadId).toBe("t1");
    // Another address than the user's own inboxes: no inbox, and Gmail is never called.
    const g = fake();
    await postEvents(u.key, [{ uuid: crypto.randomUUID(), kind: "draft_reply", payload: payload(u, { item_id: "", account: "someone@else.com" }) }], g);
    expect((await drafts(u)).map((x: any) => x.why)).toContain("The inbox isn't connected");
    expect(g.creates).toEqual([]);
  });

  it("draft_created_and_proposed", async () => {
    const u = await setup("D1");
    const f = fake();
    const p = payload(u);
    const r = await postEvents(u.key, [{ uuid: crypto.randomUUID(), kind: "draft_reply", payload: p }], f);
    expect(r.status).toBe(200);
    const [d, ...more] = await drafts(u);
    expect(more).toEqual([]);
    expect(d).toMatchObject({ kind: "draft", source_key: { message_id: "<m1@mail>", sent_at: "2026-11-07T10:00:00.000Z" },
      link: "https://mail.google.com/mail/u/me@gmail.com/#drafts?compose=mm1", why: null, task_ref: p.request_id, title: "" });
    expect(d.link.startsWith("https://mail.google.com/mail/u/")).toBe(true);
    // same shape as the shared fixture the app decodes
    expect(Object.keys(d).sort()).toEqual(Object.keys(fixture).sort());
    expect(d.provenance.model).toBe(SONNET);

    // Claude: Sonnet, names, thread and notes
    expect(f.claude).toHaveLength(1);
    expect(f.claude[0].model).toBe(SONNET);
    const prompt = f.claude[0].messages[0].content as string;
    expect(prompt).toContain("sign off with it): Alex");
    expect(prompt).toContain("only if it is a person's name): Anna");
    expect(prompt).toMatch(/<user_notes>[\s\S]*NOTESMARK[\s\S]*<\/user_notes>/);
    // Gmail draft: in the thread, reply-all headers, the reply as body
    expect(f.creates).toHaveLength(1);
    expect(f.creates[0].message.threadId).toBe("t1");
    const mime = unb64(f.creates[0].message.raw);
    expect(mime).toMatch(/^From: Alex Lee <me@gmail\.com>\r\n/m);
    expect(mime).toMatch(/^To: anna@x\.com\r\n/m);
    expect(mime).toMatch(/^Cc: bob@x\.com\r\n/m);
    expect(mime).toMatch(/^In-Reply-To: <m1@mail>\r\n/m);
    expect(mime).toMatch(/^References: <m1@mail>\r\n/m);
    expect(mime).toContain(`Subject: Re: ${SUBJECT}`);
    expect(bodyOf(f.creates[0].message.raw)).toBe(REPLY.replace(/\n/g, "\r\n"));
    expect(f.reqs.some((x) => /\/(messages|drafts)\/send\b/.test(x))).toBe(false);
  });

  it("intake_processes_drafts_immediately", async () => {
    const u = await setup("D2");
    const f = fake();
    const uuid = crypto.randomUUID();
    await postEvents(u.key, [{ uuid, kind: "draft_reply", payload: payload(u) }], f);
    expect(await ev(uuid)).toMatchObject({ processed: 1 });
    const row = await env.DB.prepare("SELECT kind, link, why FROM items WHERE user_id=? AND kind='draft'").bind(u.id).first<any>();
    expect(row).toMatchObject({ kind: "draft", why: null });
    expect(row.link).toMatch(/^https:\/\/mail\.google\.com\/mail\/u\//);
  });

  it("intake_without_drafts_does_no_background_work", async () => {
    const u = await setup("D3");
    const f = fake();
    const uuid = crypto.randomUUID();
    await postEvents(u.key, [{ uuid, kind: "done", payload: { item_id: u.itemId } }], f);
    expect(await ev(uuid)).toMatchObject({ processed: 0 });
    expect(f.reqs).toEqual([]);
  });

  it("second_press_updates_unchanged_draft", async () => {
    const u = await setup("D4");
    const f = fake();
    await event(u, payload(u));
    await run(u, f);
    const p2 = payload(u);
    await event(u, p2);
    await run(u, f);
    expect(f.creates).toHaveLength(1);
    expect(f.updates).toHaveLength(1);
    expect(f.updates[0].message.threadId).toBe("t1");
    expect(f.reqs.filter((x) => x.startsWith("PUT ")).map((x) => x.split("/").pop())).toEqual(["dr1"]);
    const ds = await drafts(u);
    expect(ds).toHaveLength(1); // one result per card: the newest
    expect(ds[0]).toMatchObject({ task_ref: p2.request_id, link: "https://mail.google.com/mail/u/me@gmail.com/#drafts?compose=mm2", why: null });
  });

  it("edited_draft_is_never_overwritten", async () => {
    const u = await setup("D5");
    const f = fake();
    await event(u, payload(u));
    await run(u, f);
    f.o.draftGet = "edited";
    await event(u, payload(u));
    await run(u, f);
    expect(f.creates).toHaveLength(2);
    expect(f.updates).toHaveLength(0);
    // the new draft is now FloatBoard's: a third press updates it (not the user's edited one)
    f.o.draftGet = "same";
    await event(u, payload(u));
    await run(u, f);
    expect(f.creates).toHaveLength(2);
    expect(f.reqs.filter((x) => x.startsWith("PUT ")).map((x) => x.split("/").pop())).toEqual(["dr2"]);
  });

  it("sent_or_deleted_draft_gets_a_new_one", async () => {
    const u = await setup("D6");
    const f = fake();
    await event(u, payload(u));
    await run(u, f);
    f.o.draftGet = "gone";
    await event(u, payload(u));
    await run(u, f);
    expect(f.creates).toHaveLength(2);
    expect(f.updates).toHaveLength(0);
  });

  it("errors_become_failed_results", async () => {
    const cases: [string, Opts, ((u: any) => Promise<unknown>) | null, string][] = [
      ["inbox removed", {}, (u) => env.DB.prepare("DELETE FROM sources WHERE id=?").bind(u.srcId).run(), "The inbox isn't connected"],
      ["inbox disabled", {}, (u) => env.DB.prepare("UPDATE sources SET enabled=0 WHERE id=?").bind(u.srcId).run(), "The inbox isn't connected"],
      ["email gone", { thread: null }, null, "The email is no longer in Gmail"],
      ["claude fails", { claude: "fail" }, null, "Claude couldn't write it"],
      ["no claude key", {}, (u) => env.DB.prepare("UPDATE users SET anthropic_key_enc=NULL WHERE id=?").bind(u.id).run(), "Claude couldn't write it"],
      ["all mine", { thread: [gm("m1", { From: "me@gmail.com", To: "anna@x.com", Subject: "x" }, "hi")] }, null, "Nothing to reply to: the last messages are yours."],
      ["no permission", { create: 403 }, null, "Reconnect me@gmail.com to let FloatBoard create drafts."],
    ];
    for (const [name, o, prep, why] of cases) {
      const u = await setup(`E ${name}`);
      if (prep) await prep(u);
      const f = fake(o);
      const p = payload(u);
      const uuid = await event(u, p);
      await run(u, f);
      expect(await ev(uuid), name).toMatchObject({ processed: 1 });
      const ds = await drafts(u);
      expect(ds, name).toHaveLength(1);
      expect(ds[0], name).toMatchObject({ kind: "draft", link: null, why, task_ref: p.request_id, source_key: { message_id: "<m1@mail>" } });
      expect(f.creates, name).toHaveLength(0);
    }
  });

  it("passing_gmail_errors_retry_then_fail", async () => {
    const u = await setup("D7");
    const f = fake({ search: 500 });
    const p = payload(u);
    const uuid = await event(u, p);
    await run(u, f);
    expect(await ev(uuid)).toMatchObject({ processed: 0, attempts: 1 });
    expect(await drafts(u)).toEqual([]);
    await run(u, f);
    await run(u, f);
    expect(await ev(uuid)).toMatchObject({ processed: 1 });
    expect(await drafts(u)).toMatchObject([{ kind: "draft", link: null, why: "Gmail couldn't be reached", task_ref: p.request_id }]);
  });

  it("rejected_draft_event_still_answers", async () => {
    const u = await setup("D8");
    const f = fake();
    const noNotes = await event(u, payload(u, { notes: "  " }));
    const p2 = payload(u, { source_mid: "<m2@mail>", item_id: 7 });
    const badType = await event(u, p2);
    const unreadable = await event(u, { notes: NOTES }); // no request id or source: nothing to answer
    expect(await run(u, f)).toMatchObject({ processed: 0 });
    for (const x of [noNotes, badType, unreadable]) expect(await ev(x)).toMatchObject({ processed: 2 });
    const ds = await drafts(u);
    expect(ds.map((d: any) => d.why)).toEqual(["The request couldn't be read", "The request couldn't be read"]);
    expect(ds.map((d: any) => d.source_key.message_id).sort()).toEqual(["<m1@mail>", "<m2@mail>"]);
    expect(f.reqs).toEqual([]);
  });

  it("event_finished_by_another_pass_is_not_drafted_again", async () => {
    const u = await setup("F2");
    const f = fake();
    const p = payload(u);
    const uuid = await event(u, p);
    await run(u, f); // pass A finishes the event
    expect(await ev(uuid)).toMatchObject({ processed: 1 });
    const before = await drafts(u);
    // pass B listed the same event before A finished it, and gets to it now
    const r = readDraftRequest(p) as any;
    expect(await draftReplyEvent({ env: env as any, userId: u.id, calls: new Budget(10), fetchFn: f.fetch }, r.req, { runId: "events", uuid, attempts: 0 })).toBe("already");
    expect(f.claude).toHaveLength(1);
    expect(f.creates.length + f.updates.length).toBe(1);
    expect(await drafts(u)).toEqual(before);
    expect((await env.DB.prepare("SELECT locked FROM drafts WHERE user_id=?").bind(u.id).first<any>()).locked).toBeNull();
  });

  it("unreadable_claude_key_is_a_final_claude_failure", async () => {
    const u = await setup("F3");
    await env.DB.prepare("UPDATE users SET anthropic_key_enc='not-a-key' WHERE id=?").bind(u.id).run();
    const f = fake();
    const uuid = await event(u, payload(u));
    await run(u, f);
    expect(await ev(uuid)).toMatchObject({ processed: 1 });
    expect(await drafts(u)).toMatchObject([{ why: "Claude couldn't write it", link: null }]);
    expect(f.creates).toHaveLength(0);
  });

  it("handle_draft_reply_leaves_a_busy_card_to_its_holder", async () => {
    const u = await setup("F4");
    const lockedAt = new Date().toISOString();
    await env.DB.prepare("INSERT INTO drafts(user_id,source_mid,locked) VALUES(?,?,?)").bind(u.id, "<m1@mail>", lockedAt).run();
    const f = fake();
    await handleDraftReply(env as any, u.id, payload(u) as any, new Budget(10), f.fetch);
    expect(await drafts(u)).toEqual([]);
    expect(f.reqs).toEqual([]);
    expect((await env.DB.prepare("SELECT locked FROM drafts WHERE user_id=?").bind(u.id).first<any>()).locked).toBe(lockedAt);
  });

  it("busy_card_waits_and_stale_lock_is_taken", async () => {
    const u = await setup("D9");
    const f = fake();
    await env.DB.prepare("INSERT INTO drafts(user_id,source_mid,locked) VALUES(?,?,?)").bind(u.id, "<m1@mail>", new Date().toISOString()).run();
    const uuid = await event(u, payload(u));
    await run(u, f);
    expect(await ev(uuid)).toMatchObject({ processed: 0, attempts: 0 });
    expect(f.reqs).toEqual([]);
    await env.DB.prepare("UPDATE drafts SET locked=? WHERE user_id=?").bind(new Date(Date.now() - 10 * 60e3).toISOString(), u.id).run();
    await run(u, f);
    expect(await ev(uuid)).toMatchObject({ processed: 1 });
    expect(f.creates).toHaveLength(1);
    expect((await env.DB.prepare("SELECT locked FROM drafts WHERE user_id=?").bind(u.id).first<any>()).locked).toBeNull();
  });

  it("handle_draft_reply_never_throws_and_always_answers", async () => {
    const u = await setup("D10");
    const f = fake({ search: 500 });
    const p = payload(u);
    await expect(handleDraftReply(env as any, u.id, p as any, new Budget(10), f.fetch)).resolves.toBeUndefined();
    expect(await drafts(u)).toMatchObject([{ why: "Gmail couldn't be reached", task_ref: p.request_id }]);
  });

  it("no_notes_or_reply_in_run_events", async () => {
    const u = await setup("D11");
    const f = fake();
    await event(u, payload(u));
    await run(u, f);
    await event(u, payload(u));
    await run(u, fake({ claude: "fail" }));
    const { results } = await env.DB.prepare("SELECT * FROM run_events WHERE user_id=?").bind(u.id).all<any>();
    expect(results.length).toBeGreaterThanOrEqual(2);
    const all = JSON.stringify(results);
    for (const mark of ["NOTESMARK", "REPLYMARK", "SUBJECTMARK", "Tuesday works", "need agenda"]) expect(all).not.toContain(mark);
    expect(results.map((r) => r.decision)).toEqual(expect.arrayContaining(["draft ready", "draft failed"]));
  });
});

/** A card with its own source email (mid), on the same inbox as `u`. */
async function addCard(u: { id: string; srcId: string }, mid: string) {
  const id = crypto.randomUUID();
  await env.DB.prepare(`INSERT INTO items(id,user_id,source_id,message_id,kind,title,created,sent_at) VALUES(?,?,?,?,'action','T',?,?)`)
    .bind(id, u.id, u.srcId, mid, new Date().toISOString(), "2026-11-07T10:00:00.000Z").run();
  return id;
}
const draftsRun = (key: string, f: ReturnType<typeof fake>) => {
  vi.spyOn(globalThis, "fetch").mockImplementation(f.fetch as any);
  return call("/v2/drafts/run", { method: "POST", key });
};

describe("reply draft ordering and retries", () => {
  it("older_retried_request_is_skipped_when_a_newer_one_exists", async () => {
    const u = await setup("G1");
    const f = fake();
    const t0 = Date.now() - 20 * 60e3;
    const a = payload(u, { notes: "OLD NOTES" }), b = payload(u);
    const ua = crypto.randomUUID(), ub = crypto.randomUUID();
    await env.DB.prepare("INSERT INTO app_events(uuid,user_id,kind,payload,received,attempts,last_error) VALUES(?,?,'draft_reply',?,?,1,'Gmail 500')")
      .bind(ua, u.id, JSON.stringify(a), new Date(t0).toISOString()).run();
    await event(u, b, ub);
    await run(u, f);
    expect(f.claude).toHaveLength(1);
    expect(JSON.stringify(f.claude[0])).not.toContain("OLD NOTES");
    expect(f.creates.length + f.updates.length).toBe(1);
    expect(await ev(ua)).toMatchObject({ processed: 1 });
    expect(await ev(ub)).toMatchObject({ processed: 1 });
    expect(await drafts(u)).toMatchObject([{ task_ref: b.request_id, why: null }]);
    const tr = await env.DB.prepare("SELECT decision FROM run_events WHERE trace=?").bind(ua).all<any>();
    expect(tr.results.map((r: any) => r.decision)).toContain("draft skipped: a newer request replaced it");
  });

  it("older_request_is_skipped_even_when_it_runs_first", async () => {
    const u = await setup("G2");
    const f = fake();
    const now = new Date().toISOString(); // same received time: the later insert (rowid) is newer
    const a = payload(u), b = payload(u);
    const ua = crypto.randomUUID(), ub = crypto.randomUUID();
    for (const [uuid, p] of [[ua, a], [ub, b]] as const) {
      await env.DB.prepare("INSERT INTO app_events(uuid,user_id,kind,payload,received) VALUES(?,?,'draft_reply',?,?)").bind(uuid, u.id, JSON.stringify(p), now).run();
    }
    const r = readDraftRequest(a) as any;
    expect(await draftReplyEvent({ env: env as any, userId: u.id, calls: new Budget(10), fetchFn: f.fetch }, r.req, { runId: "events", uuid: ua, attempts: 0 })).toBe("superseded");
    expect(f.reqs).toEqual([]);
    expect(await ev(ua)).toMatchObject({ processed: 1 });
    expect(await drafts(u)).toEqual([]);
    expect((await env.DB.prepare("SELECT locked FROM drafts WHERE user_id=?").bind(u.id).first<any>()).locked).toBeNull();
    await run(u, f);
    expect(await drafts(u)).toMatchObject([{ task_ref: b.request_id }]);
    expect(f.claude).toHaveLength(1);
  });

  it("recipient_subject_or_attachment_edit_gets_a_new_draft", async () => {
    for (const edit of ["cc", "to", "subject", "attachment"] as const) {
      const u = await setup(`G3 ${edit}`);
      const f = fake();
      await event(u, payload(u));
      await run(u, f);
      f.o.draftGet = edit;
      await event(u, payload(u));
      await run(u, f);
      expect(f.creates, edit).toHaveLength(2);
      expect(f.updates, edit).toHaveLength(0);
    }
  });

  it("unchanged_draft_with_non_ascii_subject_and_cc_is_updated", async () => {
    const u = await setup("G6");
    const long = "来週火曜日の四半期計画会議の段取りと事前に準備する資料の一覧およびその他の事項について";
    const f = fake({ thread: [gm("m1", { From: "Anna Lee <anna@x.com>", To: "me@gmail.com, \"Bob B\" <bob@x.com>", Cc: "cat@x.com", Subject: long }, "火曜日は大丈夫ですか？")] });
    await event(u, payload(u));
    await run(u, f);
    await event(u, payload(u));
    await run(u, f);
    expect(f.creates).toHaveLength(1);
    expect(f.updates).toHaveLength(1);
  });

  it("intake_drafts_at_most_two_and_drafts_run_does_one_each", async () => {
    const u = await setup("G4");
    const mids = ["<m1@mail>", "<m2@mail>", "<m3@mail>", "<m4@mail>"];
    const items = [u.itemId];
    for (const mid of mids.slice(1)) items.push(await addCard(u, mid));
    const f = fake();
    const uuids = mids.map(() => crypto.randomUUID());
    await postEvents(u.key, mids.map((mid, i) => ({ uuid: uuids[i], kind: "draft_reply", payload: payload(u, { source_mid: mid, item_id: items[i] }) })), f);
    expect(f.creates).toHaveLength(2);
    expect((await drafts(u)).map((d: any) => d.source_key.message_id).sort()).toEqual(mids.slice(0, 2));
    for (const [i, n] of [[2, 3], [3, 4]]) {
      const r = await draftsRun(u.key, f);
      expect(r.status).toBe(200);
      expect(await r.json()).toEqual({ processed: 1, waiting: 4 - n });
      expect(f.creates).toHaveLength(n);
      expect(await ev(uuids[i])).toMatchObject({ processed: 1 });
    }
    const idle = await draftsRun(u.key, f);
    expect(await idle.json()).toEqual({ processed: 0, waiting: 0 });
    expect(f.creates).toHaveLength(4);
    expect((await drafts(u)).map((d: any) => d.source_key.message_id).sort()).toEqual(mids);
    expect((await call("/v2/drafts/run", { method: "POST" })).status).toBe(401);
  });

  it("run_cut_off_after_create_updates_that_draft_next_time", async () => {
    const u = await setup("G5");
    const f = fake();
    const uuid = await event(u, payload(u));
    const batch = vi.spyOn(env.DB, "batch").mockRejectedValueOnce(new Error("Worker stopped"));
    await run(u, f);
    batch.mockRestore();
    expect(f.creates).toHaveLength(1);
    expect(await ev(uuid)).toMatchObject({ processed: 0, attempts: 1 });
    expect(await drafts(u)).toEqual([]);
    // the cut run never unlocked the card: its lock goes stale, and the next run finishes the request on the same draft
    await env.DB.prepare("UPDATE drafts SET locked=? WHERE user_id=?").bind(new Date(Date.now() - 10 * 60e3).toISOString(), u.id).run();
    await run(u, f);
    expect(await ev(uuid)).toMatchObject({ processed: 1 });
    expect(f.creates).toHaveLength(1);
    expect(f.reqs.filter((x) => x.startsWith("PUT ")).map((x) => x.split("/").pop())).toEqual(["dr1"]);
    expect(await drafts(u)).toMatchObject([{ why: null }]);
  });
});

const sources = (import.meta as any).glob("../src/**/*.ts", { query: "?raw", import: "default", eager: true }) as Record<string, string>;

describe("drafts stay contained", () => {
  it("draft_results_never_reach_v1_style_readers", () => {
    let checked = 0;
    for (const [file, src] of Object.entries(sources)) {
      // proposals deliver every kind; drafts.ts writes them; the archive moves every kind of row to the Mac and deletes it
      if (file.endsWith("/routes/v2.ts") || file.endsWith("/drafts.ts") || file.endsWith("/archive.ts")) continue;
      for (const m of src.matchAll(/(FROM|JOIN) items\b/g)) {
        const end = src.indexOf(".bind(", m.index);
        const stmt = src.slice(m.index, end < 0 ? undefined : end);
        expect(stmt, `${file}: ${stmt}`).toMatch(/kind\s*(=|<>)\s*'/);
        checked++;
      }
    }
    expect(checked).toBeGreaterThanOrEqual(6);
  });

  it("drafts_only_from_draft_reply_events", async () => {
    // Only drafts.ts asks Gmail for a draft, and nothing ever sends.
    for (const [file, src] of Object.entries(sources)) {
      if (!file.endsWith("/drafts.ts")) expect(src, file).not.toMatch(/\.(createDraft|updateDraft)\(/);
      expect(src, file).not.toMatch(/\/send\b|drafts\.send|messages\.send/);
    }
    // A full triage run (with app events waiting) and recap processing make zero Gmail draft calls.
    const u = await setup("D12");
    await env.DB.prepare("INSERT INTO app_events(uuid,user_id,kind,payload,received) VALUES(?,?,'done',?,?)")
      .bind(crypto.randomUUID(), u.id, JSON.stringify({ item_id: u.itemId }), new Date().toISOString()).run();
    const urls: string[] = [];
    const fetchFn = (async (x: RequestInfo | URL, init?: RequestInit) => {
      const url = String(x);
      urls.push(`${init?.method ?? "GET"} ${url}`);
      if (url.includes("oauth2")) return Response.json({ access_token: "at" });
      if (url.includes("api.anthropic.com")) {
        const body = JSON.parse(String(init?.body));
        const recap = /summary/i.test(JSON.stringify(body.output_config ?? ""));
        return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
          content: [{ type: "text", text: JSON.stringify(recap ? { summary: "We met.", actions: [] }
            : { action_required: true, title: "Reply about Tuesday", why: "asked", due: null, has_time: false, importance: 1, group: null, urgent: false }) }],
          usage: { input_tokens: 1, output_tokens: 1 } });
      }
      if (url.includes("format=minimal")) return Response.json({ id: "g1", labelIds: ["UNREAD"], historyId: "1" });
      return Response.json({});
    }) as typeof fetch;
    const mail: Message = { messageId: "<n1@x>", sourceId: u.srcId, from: "Anna <anna@x.com>", to: ["me@gmail.com"], cc: [], subject: "Tuesday?",
      date: "", labels: ["UNREAD"], headers: {}, text: "Can we meet Tuesday? Please reply.", link: "https://mail/1" };
    const src: Source = { async fetchBatch() { return { messages: [mail], cursor: "1", done: true }; } };
    await runUser(env as any, u.id, { sourceFor: () => src, fetchFn });
    await processRecap(env as any, u.id, { ...mail, messageId: "<r1@x>", from: "Fathom <no-reply@fathom.video>", subject: "Recap of your meeting",
      text: "Summary: we met. Action items: Alex to reply to Anna." }, fetchFn);
    expect(urls.length).toBeGreaterThan(0);
    expect(urls.filter((x) => /\/drafts\b/.test(x))).toEqual([]);
    expect(await env.DB.prepare("SELECT COUNT(*) n FROM items WHERE user_id=? AND kind='draft'").bind(u.id).first<any>()).toEqual({ n: 0 });
  });
});

describe("Assisted by AI line (per person)", () => {
  const footerOn = (u: { id: string }) => env.DB.prepare("INSERT INTO settings(user_id, ai_footer) VALUES(?,1) ON CONFLICT(user_id) DO UPDATE SET ai_footer=1").bind(u.id).run();

  it("ai_line_off_by_default", async () => {
    const u = await setup("F1");
    const f = fake();
    await event(u, payload(u));
    await run(u, f);
    const raw = f.creates[0].message.raw;
    expect(unb64(raw)).not.toContain("multipart");
    expect(bodyOf(raw)).not.toContain("Assisted by AI");
  });

  it("ai_line_on_ends_the_draft_in_italics", async () => {
    const u = await setup("F2");
    await footerOn(u);
    const f = fake();
    await event(u, payload(u));
    await run(u, f);
    const raw = f.creates[0].message.raw;
    expect(unb64(raw)).toMatch(/Content-Type: multipart\/alternative; boundary=/);
    expect(bodyOf(raw)).toBe((REPLY + "\n\nAssisted by AI").replace(/\n/g, "\r\n"));
    const html = htmlOf(raw)!;
    expect(html.trimEnd()).toMatch(/<i>Assisted by AI<\/i>(<\/div>)?$/);
    expect(html).toContain("Tuesday works REPLYMARK");
  });

  it("ai_line_on_second_press_still_updates_the_same_draft", async () => {
    const u = await setup("F3");
    await footerOn(u);
    const f = fake();
    await event(u, payload(u));
    await run(u, f);
    await event(u, payload(u));
    await run(u, f);
    expect(f.creates).toHaveLength(1);
    expect(f.updates).toHaveLength(1);
  });

  it("ai_line_setting_round_trips_through_v2_settings", async () => {
    const u = await setup("F4");
    const st = await (await call("/v2/status", { key: u.key })).json<any>();
    expect(st.schema.find((x: any) => x.key === "ai_footer")).toMatchObject({ kind: "bool" });
    const put = await call("/v2/settings", { key: u.key, method: "PUT", body: JSON.stringify({ version: 1, values: { ai_footer: true } }) });
    expect(put.status).toBe(200);
    const row = await env.DB.prepare("SELECT ai_footer FROM settings WHERE user_id=?").bind(u.id).first<{ ai_footer: number }>();
    expect(row!.ai_footer).toBe(1);
  });
});
