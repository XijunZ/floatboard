import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { encrypt } from "../src/crypto";
import { GmailSource } from "../src/sources/gmail";
import { classify } from "../src/classify";
import { isCritical, runUser } from "../src/run";
import { makeClient, HAIKU } from "../src/llm";
import type { Message, Source } from "../src/sources/types";
import type { Action } from "../src/classify";
import { newUser } from "./helpers";

const b64url = (s: string) => btoa(unescape(encodeURIComponent(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const row = async () => ({ id: "src1", user_id: "u1", kind: "gmail", address: "me@gmail.com", client_id: "cid",
  refresh_enc: await encrypt(env as any, "refresh"), client_secret_enc: await encrypt(env as any, "secret"), cursor: null as string | null });
const gm = (id: string, at: number, text: string, labels: string[] = ["INBOX"], from = "Peter <peter@x.com>") => ({
  id, threadId: "t1", internalDate: String(at), labelIds: labels,
  payload: { headers: [{ name: "Message-ID", value: `<${id}@mail>` }, { name: "From", value: from }, { name: "To", value: "me@gmail.com" },
    { name: "Subject", value: "Prize" }, { name: "Date", value: "Tue, 03 Nov 2026 10:00:00 +0000" }],
    mimeType: "text/plain", body: { data: b64url(text) } },
});
/** Fake Google that serves one thread for every listed message; records URLs. */
function google(ids: string[], thread: any[]) {
  const urls: string[] = [];
  const f = (async (input: RequestInfo | URL) => {
    const url = String(input); urls.push(url);
    if (url.includes("oauth2")) return Response.json({ access_token: "at" });
    if (new URL(url).pathname.endsWith("/messages")) return Response.json({ messages: ids.map((id) => ({ id, threadId: "t1" })) });
    if (url.includes("/threads/t1")) return Response.json({ id: "t1", messages: thread });
    return new Response("not found", { status: 404 });
  }) as typeof fetch;
  return { f, urls };
}

describe("threads", () => {
  it("my_later_reply_is_attached_to_the_message", async () => {
    const g = google(["a"], [gm("a", 1000, "Option 1 or 2?"), gm("s", 2000, "Option 1 please, thanks", ["SENT"], "Me <me@gmail.com>")]);
    const res = await new GmailSource(env as any, await row(), g.f).fetchBatch(null, 5);
    expect(res.messages[0].thread?.myReply?.text).toContain("Option 1 please");
    expect(res.messages[0].thread?.superseded).toBe(false);
    expect(g.urls.filter((u) => !u.includes("oauth2"))).toHaveLength(2); // list + one thread fetch: no extra calls
  });

  it("older_message_superseded_by_newer_one_in_thread", async () => {
    const g = google(["a", "b"], [gm("a", 1000, "first ask"), gm("b", 3000, "chasing")]);
    const res = await new GmailSource(env as any, await row(), g.f).fetchBatch(null, 5);
    expect(res.messages.map((m) => m.thread?.superseded)).toEqual([true, false]);
  });

  it("reply_before_message_is_not_attached", async () => {
    const g = google(["a"], [gm("s", 500, "earlier note", ["SENT"], "Me <me@gmail.com>"), gm("a", 1000, "new ask")]);
    const res = await new GmailSource(env as any, await row(), g.f).fetchBatch(null, 5);
    expect(res.messages[0].thread?.myReply).toBeUndefined();
  });

  it("claude_sees_my_reply", async () => {
    const bodies: any[] = [];
    const client = makeClient("sk", (async (_u: any, init?: RequestInit) => {
      bodies.push(JSON.parse(String(init?.body)));
      return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
        content: [{ type: "text", text: JSON.stringify({ action_required: false, title: "", why: "", due: null, has_time: false, importance: 0, group: null, urgent: false }) }],
        usage: { input_tokens: 1, output_tokens: 1 } });
    }) as typeof fetch);
    const m: Message = { messageId: "<a>", sourceId: "s", from: "Peter <p@x.com>", to: ["me@gmail.com"], cc: [], subject: "Prize", date: "",
      labels: [], headers: {}, text: "Option 1 or 2?", link: "l", thread: { superseded: false, myReply: { date: "Tue 3 Nov 11:38", text: "Option 1 please" } } };
    await classify(m, ["me@gmail.com"], [], client);
    expect(bodies[0].messages[0].content).toContain("Option 1 please");
    expect(bodies[0].system).toMatch(/already replied/i);
  });

  it("long_overdue_is_not_critical", () => {
    const a: Action = { title: "x", why: "", due: "2026-11-01", hasTime: false, importance: 1, group: null, urgent: false };
    expect(isCritical(a, new Date("2026-11-07T12:00:00Z"), 24)).toBe(false);
  });
});

describe("run with threads", () => {
  async function setup(msgs: Message[], reply: object) {
    const u = await newUser("T");
    await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
    await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,enabled,created) VALUES(?,?,'gmail','me@gmail.com',1,?)")
      .bind(crypto.randomUUID(), u.id, new Date().toISOString()).run();
    const src: Source = { async fetchBatch() { return { messages: msgs, cursor: "1", done: true }; } };
    let claudeCalls = 0;
    const fetchFn = (async () => {
      claudeCalls++;
      return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
        content: [{ type: "text", text: JSON.stringify(reply) }], usage: { input_tokens: 1, output_tokens: 1 } });
    }) as typeof fetch;
    return { u, opts: { sourceFor: () => src, fetchFn }, claude: () => claudeCalls };
  }
  const mail = (n: number, over: Partial<Message> = {}): Message => ({ messageId: `<t${n}@x>`, sourceId: "s", from: "Anna <anna@acme.com>",
    to: ["me@gmail.com"], cc: [], subject: `Ask ${n}`, date: "", labels: ["UNREAD"], headers: {}, text: "Please", link: `l${n}`, ...over });

  it("superseded_message_skipped_without_claude", async () => {
    const s = await setup([mail(1, { thread: { superseded: true } })], { action_required: true, title: "X", why: "", due: null, has_time: false, importance: 1, group: null, urgent: false });
    await runUser(env as any, s.u.id, s.opts);
    expect(s.claude()).toBe(0);
    const ev = await env.DB.prepare("SELECT decision FROM run_events WHERE user_id=?").bind(s.u.id).first<{ decision: string }>();
    expect(ev?.decision).toMatch(/newer message in the same thread/);
  });

  it("event_that_already_happened_is_not_a_task", async () => {
    const s = await setup([mail(2)], { action_required: true, title: "Join the call", why: "", due: "2026-11-01T16:00", has_time: true, importance: 2, group: null, urgent: false });
    await runUser(env as any, s.u.id, s.opts);
    const n = await env.DB.prepare("SELECT COUNT(*) n FROM items WHERE user_id=?").bind(s.u.id).first<{ n: number }>();
    expect(n?.n).toBe(0);
  });
});
