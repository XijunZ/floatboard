import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "./helpers";
import { encrypt } from "../src/crypto";
import { parseCards } from "../src/app/board";
import { setNtfyFetch } from "../src/alerts";
import { runDueAlerts } from "../src/due";
import { Budget } from "../src/budget";
import { chaseFor, checkWatchReplies, replyQuery, setWatchGmailFetch } from "../src/watch";
import { senderName } from "../src/run";

const DAY = 86_400_000;
const card = (id: number, over: Record<string, unknown> = {}) => ({ id, title: `Contract ${id}`, group: "Work", color: "#aabbcc", importance: 1,
  due: null, has_time: false, status: "watch", link: null, done_at: null, ...over });
const put = (key: string, cards: unknown[]) => call("/v2/board", { method: "PUT", key, body: JSON.stringify({ cards }) });

let ntfy: string[] = [];
beforeEach(() => {
  ntfy = [];
  setNtfyFetch((async (_u: RequestInfo | URL, init?: RequestInit) => { ntfy.push(String(init?.body)); return new Response("{}"); }) as typeof fetch);
});

describe("watch details on the board copy", () => {
  it("accepts_person_contact_and_since_and_refuses_bad_contacts", () => {
    const w = { person: "Anna", contact: "email:anna@acme.com", since: "2026-11-10T09:00:00.000Z" };
    expect(parseCards({ cards: [card(1, { watch: w })] })[0].watch).toEqual(w);
    expect(parseCards({ cards: [card(1, { watch: { ...w, contact: "wa:447700900123@s.whatsapp.net" } })] })[0].watch?.contact).toBe("wa:447700900123@s.whatsapp.net");
    expect(parseCards({ cards: [card(1, { watch: { ...w, contact: "" } })] })[0].watch?.contact).toBe("");
    expect(() => parseCards({ cards: [card(1, { watch: { ...w, contact: "javascript:x" } })] })).toThrow(/watch.contact/);
    expect(() => parseCards({ cards: [card(1, { watch: { ...w, since: "soon" } })] })).toThrow();
    expect(parseCards({ cards: [card(1)] })[0].watch).toBeUndefined();
  });

  it("sender_name_comes_from_the_from_line_or_the_chat", () => {
    expect(senderName({ from: '"Lee, Anna" <anna@acme.com>' } as any)).toBe("Lee, Anna");
    expect(senderName({ from: "anna@acme.com" } as any)).toBe("anna@acme.com");
    expect(senderName({ from: "x", chat: { app: "WhatsApp", group: false, name: "Mum", senders: "Mum" } } as any)).toBe("Mum");
  });
});

describe("chase reminders", () => {
  const since = "2026-11-10T09:00:00.000Z";
  const w = { status: "watch" as const, watch: { person: "Anna", contact: "", since } };
  it("every_3_days_without_a_reply", () => {
    expect(chaseFor(w, Date.parse(since) + 3 * DAY - 1)).toBeNull();
    expect(chaseFor(w, Date.parse(since) + 3 * DAY)).toEqual({ key: `chase:${since}:1`, text: "Still waiting on Anna · 3 days" });
    expect(chaseFor(w, Date.parse(since) + 7 * DAY)).toEqual({ key: `chase:${since}:2`, text: "Still waiting on Anna · 6 days" });
    expect(chaseFor({ ...w, status: "todo" }, Date.parse(since) + 9 * DAY)).toBeNull();
    expect(chaseFor({ status: "watch" }, Date.parse(since) + 9 * DAY)).toBeNull();
  });

  it("the_engine_sends_each_chase_once", async () => {
    const u = await newUser("W1");
    await env.DB.prepare("UPDATE users SET ntfy_topic='t' WHERE id=?").bind(u.id).run();
    expect((await put(u.key, [card(5, { watch: { person: "Anna", contact: "", since } })])).status).toBe(200);
    const day4 = Date.parse(since) + 4 * DAY;
    expect(await runDueAlerts(env as any, day4)).toBe(1);
    expect(await runDueAlerts(env as any, day4 + 3600_000)).toBe(0);
    expect(ntfy).toHaveLength(1);
    expect(await runDueAlerts(env as any, Date.parse(since) + 6 * DAY + 60_000)).toBe(1);
  });
});

describe("reply detection (email)", () => {
  const since = "2026-11-10T09:00:00.000Z";
  let queries: string[] = [];
  function gmail(hit: boolean) {
    queries = [];
    setWatchGmailFetch((async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("oauth2")) return Response.json({ access_token: "at", expires_in: 3600 });
      if (url.includes("/messages?")) { queries.push(new URL(url).searchParams.get("q")!); return Response.json(hit ? { messages: [{ id: "m1" }] } : {}); }
      return Response.json({ id: "m1", threadId: "t1", labelIds: ["INBOX"], payload: { headers: [
        { name: "From", value: "Anna <anna@acme.com>" }, { name: "Subject", value: "Re: contract" },
        { name: "Date", value: "Wed, 11 Nov 2026 10:00:00 +0000" }, { name: "Message-ID", value: "<r1@acme>" }] } });
    }) as typeof fetch);
  }
  async function setup(name: string) {
    const u = await newUser(name);
    await env.DB.prepare(`INSERT INTO sources(id,user_id,kind,address,client_id,refresh_enc,client_secret_enc,enabled,created)
        VALUES(?,?,'gmail','me@gmail.com','cid',?,?,1,?)`)
      .bind(`g-${name}`, u.id, await encrypt(env as any, "r"), await encrypt(env as any, "s"), new Date().toISOString()).run();
    await put(u.key, [card(7, { watch: { person: "Anna", contact: "email:anna@acme.com", since } }), card(8, { status: "todo" })]);
    return u;
  }

  it("a_reply_moves_the_task_back_once", async () => {
    const u = await setup("W2");
    gmail(true);
    expect(await checkWatchReplies(env as any, u.id, new Budget(20))).toBe(1);
    expect(queries).toEqual([replyQuery("anna@acme.com", since)]);
    expect(queries[0]).toBe(`from:anna@acme.com after:${Date.parse(since) / 1000} -in:sent -in:drafts`);
    const acts = (await (await call("/v2/phone-actions", { key: u.key })).json<any>()).actions;
    expect(acts).toEqual([expect.objectContaining({ card_id: 7, action: "watch_reply", reason: "Anna replied by email", made_at: "2026-11-11T10:00:00.000Z" })]);
    expect(await checkWatchReplies(env as any, u.id, new Budget(20))).toBe(0);
    expect(queries).toHaveLength(1); // already answered: not searched again
  });

  it("no_reply_no_action", async () => {
    const u = await setup("W3");
    gmail(false);
    expect(await checkWatchReplies(env as any, u.id, new Budget(20))).toBe(0);
    expect((await (await call("/v2/phone-actions", { key: u.key })).json<any>()).actions).toEqual([]);
  });
});
