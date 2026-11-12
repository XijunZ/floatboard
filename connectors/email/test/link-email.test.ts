import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "./helpers";
import { api, pairPhone } from "./app-helpers";
import { encrypt } from "../src/crypto";
import { cleanQuery, setEmailSearchFetch } from "../src/emails";
import { processEvents } from "../src/events";
import { Budget } from "../src/budget";

/** "Link an email": search the user's own Gmail (subject, sender, date only) and queue a phone link for the Mac. */
type Msg = { id: string; subject: string; from: string; date: string; mid?: string | null };
let lists: { account: string; q: string; max: string }[] = [];

async function addGmail(userId: string, address: string, token: string, enabled = 1) {
  await env.DB.prepare(`INSERT INTO sources(id,user_id,kind,address,refresh_enc,client_id,client_secret_enc,enabled,created)
      VALUES(?,?,'gmail',?,?,'cid',?,?,?)`).bind(crypto.randomUUID(), userId, address, await encrypt(env as any, token),
    await encrypt(env as any, "secret"), enabled, new Date().toISOString()).run();
}

/** A fake Gmail: the access token is the account's refresh token, so each call shows which account it is for. */
function fakeGmail(mail: Record<string, Msg[]>, failing = new Set<string>()) {
  lists = [];
  setEmailSearchFetch((async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    if (url.hostname === "oauth2.googleapis.com") {
      const token = new URLSearchParams(String(init?.body)).get("refresh_token")!;
      return failing.has(token) ? Response.json({ error: "invalid_grant" }, { status: 400 }) : Response.json({ access_token: token });
    }
    const token = (init?.headers as Record<string, string>).Authorization.replace("Bearer ", "");
    const box = mail[token] ?? [];
    if (url.pathname.endsWith("/messages")) {
      lists.push({ account: token, q: url.searchParams.get("q")!, max: url.searchParams.get("maxResults")! });
      return Response.json({ messages: box.map((m) => ({ id: m.id, threadId: "t" + m.id })) });
    }
    const id = url.pathname.split("/").pop()!;
    const m = box.find((x) => x.id === id)!;
    const headers = [["Subject", m.subject], ["From", m.from], ["Date", m.date], ["To", "me@example.com"]];
    if (m.mid !== null) headers.push(["Message-ID", m.mid ?? `<${m.id}@mail>`]);
    // A real answer can carry a snippet and a body: neither may leave the engine.
    return Response.json({ id, internalDate: String(Date.parse(m.date)), snippet: "SECRET SNIPPET",
      payload: { mimeType: "text/plain", body: { data: btoa("SECRET BODY") }, headers: headers.map(([name, value]) => ({ name, value })) } });
  }) as typeof fetch);
}

const search = (key: string, q: string) => call(`/v2/emails/search?q=${encodeURIComponent(q)}`, { key });

describe("email search", () => {
  beforeEach(() => fakeGmail({}));

  it("query_is_cleaned_and_capped_at_100_characters", () => {
    expect(cleanQuery("  invoice\u0000 from\n\tacme  ")).toBe("invoice from acme");
    expect(cleanQuery("x".repeat(150))).toHaveLength(100);
    expect(cleanQuery("   ")).toBeNull();
    expect(cleanQuery(null)).toBeNull();
  });

  it("search_returns_no_body_and_only_this_users_accounts", async () => {
    const a = await newUser("Search A");
    const b = await newUser("Search B");
    await addGmail(a.id, "a1@example.com", "tok-a1");
    await addGmail(a.id, "a2@example.com", "tok-a2");
    await addGmail(b.id, "b@example.com", "tok-b");
    fakeGmail({
      "tok-a1": [{ id: "m1", subject: "Invoice 12", from: "Acme <ap@acme.test>", date: "Tue, 10 Nov 2026 09:00:00 +0000" }],
      "tok-a2": [{ id: "m2", subject: "Invoice 13", from: "Acme <ap@acme.test>", date: "Wed, 11 Nov 2026 09:00:00 +0000" }],
      "tok-b": [{ id: "m3", subject: "Not yours", from: "x@y.test", date: "Thu, 12 Nov 2026 09:00:00 +0000" }],
    });
    const r = await search(a.key, "invoice " + "y".repeat(200));
    expect(r.status).toBe(200);
    const body = await r.json<any>();
    expect(lists.map((l) => l.account).sort()).toEqual(["tok-a1", "tok-a2"]); // never B's inbox
    expect(lists.every((l) => l.q.length === 100 && l.max === "10")).toBe(true);
    expect(body.errors).toEqual([]);
    // Newest first across accounts, and only these fields.
    expect(body.results).toEqual([
      { account: "a2@example.com", gmail_id: "m2", message_id: "<m2@mail>", subject: "Invoice 13", from: "Acme <ap@acme.test>",
        date: "Wed, 11 Nov 2026 09:00:00 +0000", sent_at: "2026-11-11T09:00:00.000Z" },
      { account: "a1@example.com", gmail_id: "m1", message_id: "<m1@mail>", subject: "Invoice 12", from: "Acme <ap@acme.test>",
        date: "Tue, 10 Nov 2026 09:00:00 +0000", sent_at: "2026-11-10T09:00:00.000Z" },
    ]);
    expect(JSON.stringify(body)).not.toContain("SECRET");
  });

  it("a_failing_account_is_reported_and_the_others_still_answer", async () => {
    const u = await newUser("Search errors");
    await addGmail(u.id, "ok@example.com", "tok-ok");
    await addGmail(u.id, "gone@example.com", "tok-gone");
    await addGmail(u.id, "off@example.com", "tok-off", 0); // turned off: not searched
    fakeGmail({ "tok-ok": [{ id: "m1", subject: "Hello", from: "a@b.test", date: "Tue, 10 Nov 2026 09:00:00 +0000" }] }, new Set(["tok-gone"]));
    const body = await (await search(u.key, "hello")).json<any>();
    expect(body.results.map((x: any) => x.gmail_id)).toEqual(["m1"]);
    expect(body.errors).toHaveLength(1);
    expect(body.errors[0].account).toBe("gone@example.com");
    expect(body.errors[0].error).toMatch(/Reconnect/);
    expect(lists.map((l) => l.account)).toEqual(["tok-ok"]);
  });

  it("empty_query_is_refused_and_a_key_is_needed", async () => {
    const u = await newUser("Search refuse");
    expect((await search(u.key, "  ")).status).toBe(400);
    expect((await call("/v2/emails/search?q=x")).status).toBe(401);
  });

  it("the_phone_searches_with_its_session_and_sees_only_its_users_accounts", async () => {
    const a = await newUser("Phone search A");
    const b = await newUser("Phone search B");
    await addGmail(a.id, "pa@example.com", "tok-pa");
    await addGmail(b.id, "pb@example.com", "tok-pb");
    fakeGmail({ "tok-pa": [{ id: "m1", subject: "Mine", from: "a@b.test", date: "Tue, 10 Nov 2026 09:00:00 +0000" }],
      "tok-pb": [{ id: "m2", subject: "Theirs", from: "a@b.test", date: "Tue, 10 Nov 2026 09:00:00 +0000" }] });
    const { cookie } = await pairPhone(b.key);
    const r = await call("/app/api/emails/search?q=mine", { headers: { Cookie: cookie } });
    expect(r.status).toBe(200);
    expect((await r.json<any>()).results.map((x: any) => x.subject)).toEqual(["Theirs"]);
    expect((await call("/app/api/emails/search?q=mine")).status).toBe(401);
    expect((await call("/app/api/emails/search?q=mine", { key: a.key })).status).toBe(401); // the user key is not a session
  });
});

describe("link an email from the phone", () => {
  const card = (id: number, over: Record<string, unknown> = {}) => ({ id, title: `Task ${id}`, group: "Work", color: "#aabbcc", importance: 1,
    due: null, has_time: false, status: "todo", link: null, done_at: null, ...over });
  const put = (key: string, body: unknown) => call("/v2/board", { method: "PUT", key, body: JSON.stringify(body) });
  const link = (id: string, over: Record<string, unknown> = {}) => ({ id, action: "link_email", card_id: 1, message_id: "<m1@mail>",
    gmail_id: "m1", account: "me@example.com", sent_at: "2026-11-10T09:00:00.000Z", ...over });

  it("link_email_is_queued_for_the_mac_with_the_email_details", async () => {
    const u = await newUser("Link queue");
    await addGmail(u.id, "me@example.com", "tok");
    const { cookie } = await pairPhone(u.key);
    await put(u.key, { cards: [card(1)] });
    const r = await api("/app/api/action", { actions: [link("link-0000-1"), { id: "unlink-000-1", action: "unlink_email", card_id: 1 }] }, { cookie });
    expect(r.status).toBe(200);
    const res = await r.json<any>();
    expect(res.accepted).toEqual(["link-0000-1", "unlink-000-1"]);
    expect(res.cards.find((c: any) => c.id === 1).status).toBe("todo"); // a link is not a move
    const q = await (await call("/v2/phone-actions", { key: u.key })).json<any>();
    expect(q.actions.map((a: any) => a.action)).toEqual(["link_email", "unlink_email"]);
    expect(q.actions[0]).toMatchObject({ card_id: 1, client_id: "link-0000-1",
      email: { message_id: "<m1@mail>", gmail_id: "m1", account: "me@example.com", sent_at: "2026-11-10T09:00:00.000Z" } });
    expect(q.actions[1].email).toBeUndefined();
  });

  it("a_mac_push_never_supersedes_a_link", async () => {
    const u = await newUser("Link push");
    await addGmail(u.id, "me@example.com", "tok");
    const { cookie } = await pairPhone(u.key);
    await put(u.key, { cards: [card(1)] });
    await api("/app/api/action", { actions: [link("link-0000-2")] }, { cookie });
    await put(u.key, { cards: [card(1, { status: "doing", status_at: new Date(Date.now() + 60_000).toISOString() })] });
    const q = await (await call("/v2/phone-actions", { key: u.key })).json<any>();
    expect(q.actions.map((a: any) => a.client_id)).toEqual(["link-0000-2"]);
  });

  it("bad_links_are_dropped", async () => {
    const u = await newUser("Link bad");
    await addGmail(u.id, "me@example.com", "tok");
    const other = await newUser("Link other");
    await addGmail(other.id, "other@example.com", "tok2");
    const { cookie } = await pairPhone(u.key);
    await put(u.key, { cards: [card(1)] });
    const r = await (await api("/app/api/action", { actions: [
      link("bad-acct-001", { account: "other@example.com" }),   // not this user's inbox
      link("bad-gmid-001", { gmail_id: "../x" }),
      link("bad-mid-0001", { message_id: "" }),
      link("bad-sent-001", { sent_at: "yesterday" }),
      link("bad-card-001", { card_id: 99 }),
    ] }, { cookie })).json<any>();
    expect(r.accepted).toEqual([]);
    expect(r.dropped.map((d: any) => d.reason)).toEqual(["invalid", "invalid", "invalid", "invalid", "unknown card"]);
    const q = await (await call("/v2/phone-actions", { key: u.key })).json<any>();
    expect(q.actions).toEqual([]);
  });
});

describe("done on a task linked to an email by the user", () => {
  async function doneEvent(userId: string, payload: Record<string, string>) {
    await env.DB.prepare("INSERT INTO app_events(uuid,user_id,kind,payload,received) VALUES(?,?,'done',?,?)")
      .bind(crypto.randomUUID(), userId, JSON.stringify({ source_mid: "<l1@mail>", source_sent: "", item_id: "", verdict: "", detail: "", at: "1", ...payload }),
        new Date().toISOString()).run();
  }
  function gmail() {
    const reqs: string[] = [];
    const f = (async (u: RequestInfo | URL, init?: RequestInit) => {
      const url = String(u);
      if (url.startsWith("https://oauth2.googleapis.com/token")) return Response.json({ access_token: "at" });
      reqs.push(`${init?.method ?? "GET"} ${url}`);
      if (url.includes("format=minimal")) return Response.json({ id: "g9", labelIds: ["INBOX", "UNREAD"], historyId: "5" });
      return Response.json({});
    }) as typeof fetch;
    return { f, reqs };
  }

  it("marks_the_linked_email_read_in_the_named_inbox", async () => {
    const u = await newUser("Linked done");
    await addGmail(u.id, "me@example.com", "tok");
    await doneEvent(u.id, { account: "me@example.com", gmail_id: "g9" });
    const g = gmail();
    await processEvents(env as any, u.id, new Budget(10), g.f, "events", "done");
    expect(g.reqs.some((r) => r.startsWith("POST") && r.includes("/messages/g9/modify"))).toBe(true);
  });

  it("never_touches_an_inbox_that_is_not_the_users", async () => {
    const u = await newUser("Linked done other");
    const other = await newUser("Linked done owner");
    await addGmail(other.id, "owner@example.com", "tok");
    await doneEvent(u.id, { account: "owner@example.com", gmail_id: "g9" });
    await doneEvent(u.id, { account: "owner@example.com", gmail_id: "../bad" });
    const g = gmail();
    await processEvents(env as any, u.id, new Budget(10), g.f, "events", "done");
    expect(g.reqs).toEqual([]);
  });
});
