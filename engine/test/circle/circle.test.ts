import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, newUser } from "../helpers";
import { pairPhone } from "../phone-helpers";
import { encrypt } from "../../src/lib/crypto";
import { HAIKU } from "../../src/lib/llm";
import { Budget } from "../../src/lib/budget";
import { setCircleFetch } from "../../src/circle/net";
import { readGmailMeta, splitWho } from "../../src/circle/gmail";
import { runCircleUpdates, parseFeed, newsTitleKey } from "../../src/circle/updates";
import { circleOf } from "../../src/reminders/alerts";
import { payloadJSON } from "../../src/phone/webpush";
import { issueOutlookToken } from "../../src/sources/outlook-ingest";

// Circle in the engine (docs/superpowers/specs/2026-11-17-circle-design.md): Gmail/Outlook metadata readers, What's new
// (Companies House, news with the ⚑ news_match, feeds), the phone copy and actions, and the on-request AI jobs.

const DAY = 86400_000;
const NOW = Date.parse("2026-11-18T12:00:00Z");
const iso = (ms: number) => new Date(ms).toISOString();

async function circleUser(name: string, on = true) {
  const u = await newUser(name);
  await env.DB.prepare("UPDATE settings SET modules=? WHERE user_id=?").bind(JSON.stringify({ jots: false, circle: on, decisions: false, resolutions: false }), u.id).run();
  await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
  return u;
}

async function gmailSource(userId: string, address = "me@gmail.com") {
  const id = crypto.randomUUID();
  await env.DB.prepare(`INSERT INTO sources(id,user_id,kind,address,enabled,created,client_id,refresh_enc,client_secret_enc) VALUES(?,?,'gmail',?,1,?,?,?,?)`)
    .bind(id, userId, address, iso(NOW), "cid", await encrypt(env as any, "refresh"), await encrypt(env as any, "secret")).run();
  return { id, user_id: userId, kind: "gmail", address, refresh_enc: await encrypt(env as any, "refresh"), client_id: "cid",
    client_secret_enc: await encrypt(env as any, "secret"), cursor: null };
}

const hdrs = (o: Record<string, string>) => Object.entries(o).map(([name, value]) => ({ name, value }));

/** Fake Google for the metadata reader: pages of ids (the backfill's "before:" query; new mail: `live`), then each message's
 *  headers. Records the URLs asked. */
function fakeGmail(pages: Record<string, { ids: string[]; next?: string }>, messages: Record<string, any>, live: Record<string, { ids: string[]; next?: string }> = {}) {
  const urls: string[] = [];
  const f = (async (input: RequestInfo | URL) => {
    const url = String(input);
    urls.push(url);
    if (url.startsWith("https://oauth2.googleapis.com/token")) return Response.json({ access_token: "at", expires_in: 3600 });
    const u = new URL(url);
    if (u.pathname.endsWith("/messages")) {
      const q = u.searchParams.get("q") ?? "";
      const p = (q.includes("before:") ? pages : live)[u.searchParams.get("pageToken") ?? ""] ?? { ids: [] };
      return Response.json({ messages: p.ids.map((id) => ({ id })), nextPageToken: p.next });
    }
    const id = u.pathname.split("/").pop()!;
    if (u.searchParams.get("format") !== "metadata") return new Response("only metadata may be read", { status: 400 });
    return Response.json(messages[id]);
  }) as typeof fetch;
  return { f, urls };
}

const claudeReply = (obj: unknown) => Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn",
  stop_sequence: null, content: [{ type: "text", text: JSON.stringify(obj) }], usage: { input_tokens: 50, output_tokens: 20 } });

describe("circle: Gmail metadata reader", () => {
  const messages = {
    m1: { id: "m1", labelIds: ["INBOX"], internalDate: String(NOW - 2 * DAY), payload: { headers: hdrs({ From: "Anna Example <Anna@Example.com>", To: "me@gmail.com", Subject: "Secret plans", Date: "Mon, 16 Nov 2026 12:00:00 +0000" }) } },
    m2: { id: "m2", labelIds: ["SENT"], internalDate: String(NOW - DAY), payload: { headers: hdrs({ From: "me@gmail.com", To: "anna@example.com, \"Bo, Example\" <bo@example.com>", Date: "Tue, 17 Nov 2026 12:00:00 +0000" }) } },
    m3: { id: "m3", labelIds: ["INBOX"], internalDate: String(NOW - DAY), payload: { headers: hdrs({ From: "News <news@example.com>", To: "me@gmail.com", "List-Unsubscribe": "<mailto:x>", Date: "Tue, 17 Nov 2026 12:00:00 +0000" }) } },
    m4: { id: "m4", labelIds: ["SENT"], internalDate: String(NOW - DAY), payload: { headers: hdrs({ From: "me@gmail.com", To: "a@x.com, b@x.com, c@x.com, d@x.com, e@x.com, f@x.com", Date: "Tue, 17 Nov 2026 12:00:00 +0000" }) } },
    m5: { id: "m5", labelIds: ["INBOX"], internalDate: String(NOW - DAY), payload: { headers: hdrs({ From: "No Reply <noreply@example.com>", To: "me@gmail.com", Date: "Tue, 17 Nov 2026 12:00:00 +0000" }) } },
  };

  it("records_who_when_and_direction_never_text", async () => {
    const u = await circleUser("Gmail meta");
    const row = await gmailSource(u.id);
    const g = fakeGmail({ "": { ids: ["m1", "m2", "m3", "m4", "m5"] } }, messages);
    const r = await readGmailMeta(env as any, u.id, row as any, new Budget(40), { now: NOW, fetchFn: g.f });
    expect(r.stored).toBe(3);
    expect(g.urls.some((x) => x.includes("format=full"))).toBe(false);
    const raw = await env.DB.prepare("SELECT * FROM circle_exchanges WHERE user_id=?").bind(u.id).all<any>();
    expect(JSON.stringify(raw.results)).not.toMatch(/Secret|anna@example/i);   // no subject; addresses encrypted
    const res = await (await call("/v2/circle/exchanges", { key: u.key })).json<any>();
    const got = res.exchanges.map((e: any) => `${e.direction}:${e.handle}:${e.name}`).sort();
    expect(got).toEqual(["in:anna@example.com:Anna Example", "out:anna@example.com:", "out:bo@example.com:Bo, Example"]);
    expect(res.exchanges[0]).toMatchObject({ channel: "gmail", account: "me@gmail.com" });
    const reader = res.readers.find((x: any) => x.reader === "gmail:me@gmail.com");
    expect(reader.as_of).toBeTruthy();
    // The Mac asks again from the last seq: nothing new.
    const again = await (await call(`/v2/circle/exchanges?after=${res.next}`, { key: u.key })).json<any>();
    expect(again.exchanges).toEqual([]);
  });

  it("backfills_in_pages_within_the_call_budget", async () => {
    const u = await circleUser("Gmail pages");
    const row = await gmailSource(u.id);
    const g = fakeGmail({ "": { ids: ["m1", "m2"], next: "p2" }, p2: { ids: ["m3"] } }, messages);
    const r1 = await readGmailMeta(env as any, u.id, row as any, new Budget(5), { now: NOW, fetchFn: g.f });
    expect(r1.done).toBe(false);
    const r2 = await readGmailMeta(env as any, u.id, row as any, new Budget(40), { now: NOW + 600_000, fetchFn: g.f });
    expect(r2.done).toBe(true);
    const st = await env.DB.prepare("SELECT * FROM circle_readers WHERE user_id=?").bind(u.id).first<any>();
    expect(st.complete_from).toBeTruthy();
  });

  it("does_nothing_while_circle_is_off", async () => {
    const u = await circleUser("Gmail off", false);
    const row = await gmailSource(u.id);
    const g = fakeGmail({ "": { ids: ["m1"] } }, messages);
    const r = await readGmailMeta(env as any, u.id, row as any, new Budget(40), { now: NOW, fetchFn: g.f });
    expect(r.stored).toBe(0);
    expect(g.urls).toEqual([]);
  });

  it("splits_names_and_addresses", () => {
    expect(splitWho('"Bo, Example" <BO@example.com>, plain@x.com')).toEqual([{ h: "bo@example.com", n: "Bo, Example" }, { h: "plain@x.com", n: "" }]);
  });
});

describe("circle: Outlook heard-from", () => {
  it("ingest_records_incoming_metadata_only_when_circle_is_on", async () => {
    const u = await circleUser("Outlook circle");
    const { token } = await issueOutlookToken(env as any, u.id);
    const row = { rowId: "r1", fromName: "Cara Example", fromAddr: "Cara@Example.com", subject: "Private", preview: "Private text", received: iso(NOW), unread: true };
    const r = await call("/ingest/outlook", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify({ mailbox: "me@corp.com", items: [row] }) });
    expect(r.status).toBe(200);
    const res = await (await call("/v2/circle/exchanges", { key: u.key })).json<any>();
    expect(res.exchanges).toHaveLength(1);
    expect(res.exchanges[0]).toMatchObject({ channel: "outlook", direction: "in", handle: "cara@example.com", name: "Cara Example" });
    expect(JSON.stringify(res)).not.toContain("Private");
  });
});

describe("circle: What's new", () => {
  const rss = (items: { title: string; link: string; date: string; source?: string }[]) => `<?xml version="1.0"?><rss><channel>${items.map((i) =>
    `<item><title><![CDATA[${i.title}]]></title><link>${i.link}</link><pubDate>${i.date}</pubDate>${i.source ? `<source url="x">${i.source}</source>` : ""}</item>`).join("")}</channel></rss>`;

  function fakeWorld(opts: { claude?: (body: any) => unknown; appointments?: any[] } = {}) {
    const urls: string[] = [];
    const prompts: string[] = [];
    const f = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      urls.push(url);
      if (url.startsWith("https://api.anthropic.com")) {
        const body = JSON.parse(String(init?.body));
        prompts.push(JSON.stringify(body.messages));
        return claudeReply(opts.claude ? opts.claude(body) : { items: [] });
      }
      if (url.includes("/search/officers")) {
        return Response.json({ items: [
          { title: "EXAMPLE, Ivy", links: { self: "/officers/OFF1/appointments" }, date_of_birth: { month: 4, year: 1980 }, address_snippet: "London", appointment_count: 2 },
          { title: "EXAMPLE, Ivy Jane", links: { self: "/officers/OFF2/appointments" }, date_of_birth: { month: 2, year: 1981 }, address_snippet: "Leeds", appointment_count: 1 },
        ] });
      }
      if (url.includes("/officers/OFF1/appointments")) return Response.json({ items: opts.appointments ?? [] });
      if (url.startsWith("https://news.google.com/rss")) {
        const q = new URL(url).searchParams.get("q") ?? "";
        if (q.includes('"Ivy Example"')) return new Response(rss([
          { title: "Ivy Example joins Beta board - The Paper", link: "https://example.com/a", date: "Mon, 16 Nov 2026 10:00:00 GMT", source: "The Paper" },
          { title: "Ivy Example joins Beta board - Other Paper", link: "https://example.com/a2", date: "Mon, 16 Nov 2026 11:00:00 GMT", source: "Other Paper" },
          { title: "Ivy Example wins bake-off - Village News", link: "https://example.com/b", date: "Sun, 15 Nov 2026 10:00:00 GMT" },
        ]));
        return new Response(rss([{ title: "Acme Capital closes fund - Wire", link: "https://example.com/c", date: "Mon, 16 Nov 2026 09:00:00 GMT" }]));
      }
      if (url === "https://blog.example.com/feed") {
        return new Response(`<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>My new post</title><link href="https://blog.example.com/p1"/><updated>2026-11-15T08:00:00Z</updated></entry></feed>`);
      }
      return new Response("not found", { status: 404 });
    }) as typeof fetch;
    return { f, urls, prompts };
  }

  async function watch(key: string, people: unknown[]) {
    return call("/v2/circle/watch", { method: "PUT", key, body: JSON.stringify({ people }) });
  }
  const ivy = { person: "P-3", name: "Ivy Example", firm: "Acme Capital", company: "", officer_id: "", born: "1980-04", feed_url: "https://blog.example.com/feed", news: true, ch: true };

  it("finds_officer_candidates_news_and_posts_with_news_match_set_aside", async () => {
    const u = await circleUser("Updates");
    await call("/v2/keys", { method: "PUT", key: u.key, body: JSON.stringify({ companies_house_key: "ch-key" }) });
    expect((await watch(u.key, [ivy])).status).toBe(200);
    const w = fakeWorld({ claude: () => ({ items: [{ n: 1, about_them: true }, { n: 2, about_them: false }, { n: 3, about_them: true }] }) });
    const r = await runCircleUpdates(env as any, u.id, new Budget(40), { now: NOW, fetchFn: w.f });
    expect(r.found).toBeGreaterThan(0);
    // Companies House: basic auth with the key; candidates only (never linked here).
    expect(w.urls.some((x) => x.includes("api.company-information.service.gov.uk/search/officers"))).toBe(true);
    const res = await (await call("/v2/circle/updates", { key: u.key })).json<any>();
    const byKind = (k: string) => res.updates.filter((x: any) => x.kind === k);
    expect(byKind("officer_candidate").map((x: any) => [x.officer, x.born])).toEqual([["OFF1", "1980-04"], ["OFF2", "1981-02"]]);
    // News: duplicates merged, person and firm separate, one Claude batch, the "no" one set aside (kept, never dropped).
    expect(byKind("news_person").map((x: any) => [x.title, x.match]).sort()).toEqual([["Ivy Example joins Beta board", "possible"], ["Ivy Example wins bake-off", "unlikely"]]);
    expect(byKind("news_firm").map((x: any) => x.title)).toEqual(["Acme Capital closes fund"]);
    expect(w.prompts).toHaveLength(1);
    expect(byKind("post").map((x: any) => [x.title, x.url])).toEqual([["My new post", "https://blog.example.com/p1"]]);
    // At most weekly per person: a run the next day asks nothing.
    const w2 = fakeWorld();
    await runCircleUpdates(env as any, u.id, new Budget(40), { now: NOW + DAY, fetchFn: w2.f });
    expect(w2.urls).toEqual([]);
  });

  it("without_a_claude_key_all_news_stays_possible", async () => {
    const u = await circleUser("No key news");
    await env.DB.prepare("UPDATE users SET anthropic_key_enc=NULL WHERE id=?").bind(u.id).run();
    await watch(u.key, [{ ...ivy, feed_url: "" }]);
    const w = fakeWorld();
    await runCircleUpdates(env as any, u.id, new Budget(40), { now: NOW, fetchFn: w.f });
    const res = await (await call("/v2/circle/updates", { key: u.key })).json<any>();
    expect(res.updates.filter((x: any) => x.kind.startsWith("news")).every((x: any) => x.match === "possible")).toBe(true);
    expect(w.urls.some((x) => x.includes("company-information"))).toBe(false);   // no Companies House key: not asked
  });

  it("confirmed_officer_reports_directorships_then_new_appointments_and_resignations", async () => {
    const u = await circleUser("Officer");
    await call("/v2/keys", { method: "PUT", key: u.key, body: JSON.stringify({ companies_house_key: "ch-key" }) });
    await watch(u.key, [{ ...ivy, officer_id: "OFF1", feed_url: "", news: false }]);
    const a1 = { appointed_to: { company_name: "BETA LTD", company_number: "123" }, appointed_on: "2020-01-01", officer_role: "director" };
    await runCircleUpdates(env as any, u.id, new Budget(40), { now: NOW, fetchFn: fakeWorld({ appointments: [a1] }).f });
    const a2 = { appointed_to: { company_name: "GAMMA LTD", company_number: "456" }, appointed_on: "2026-11-20", officer_role: "director" };
    const gone = { ...a1, resigned_on: "2026-11-21" };
    await runCircleUpdates(env as any, u.id, new Budget(40), { now: NOW + 8 * DAY, fetchFn: fakeWorld({ appointments: [gone, a2] }).f });
    const res = await (await call("/v2/circle/updates", { key: u.key })).json<any>();
    expect(res.updates.map((x: any) => `${x.kind}:${x.title}`)).toEqual(["directorship:Director, Beta Ltd", "appointment:Director, Gamma Ltd", "resignation:Director, Beta Ltd"]);
  });

  it("parses_rss_and_atom_and_merges_titles", () => {
    expect(parseFeed(rss([{ title: "A &amp; B - Wire", link: "https://x/1", date: "Mon, 16 Nov 2026 10:00:00 GMT" }]))[0]).toMatchObject({ title: "A & B - Wire", link: "https://x/1" });
    expect(newsTitleKey("Ivy Example joins Beta board - The Paper")).toBe(newsTitleKey("Ivy  example joins Beta board – Other Paper"));
  });

  it("watch_list_is_checked_and_stored_encrypted", async () => {
    const u = await circleUser("Watch");
    expect((await watch(u.key, [{ person: "nope" }])).status).toBe(400);
    expect((await watch(u.key, [ivy])).status).toBe(200);
    const row = await env.DB.prepare("SELECT data_enc FROM circle_watch WHERE user_id=?").bind(u.id).first<any>();
    expect(row.data_enc).not.toContain("Ivy");
  });
});

describe("circle: phone copy and actions", () => {
  const copy = { due: ["P-1"], as_of: { whatsapp: iso(NOW) }, people: [{ id: "P-1", name: "Kim Example", tier: "close", tags: [], company: "", last_talked: null,
    last_heard: null, last_outreach: null, snoozed_until: null, due_at: iso(NOW - DAY), due: true, interval: "2 weeks", context: [], whats_new: [],
    open_tasks: [], timeline: [], wa: "447700900777", email: "kim@example.com", language: "English", notes: "Likes hiking" }] };

  it("mac_copy_reaches_the_phone_and_phone_actions_reach_the_mac", async () => {
    const u = await circleUser("Phone circle");
    const { cookie } = await pairPhone(u.key);
    expect((await call("/v2/circle", { method: "PUT", key: u.key, body: JSON.stringify({ copy }) })).status).toBe(200);
    const stored = await env.DB.prepare("SELECT data_enc FROM circle_copy WHERE user_id=?").bind(u.id).first<any>();
    expect(stored.data_enc).not.toContain("Kim");
    const got = await (await call("/app/api/circle", { headers: { Cookie: cookie } })).json<any>();
    expect(got.copy.people[0].name).toBe("Kim Example");
    const me = await (await call("/app/api/me", { headers: { Cookie: cookie } })).json<any>();
    expect(got.account).toBe(me.account);   // the phone drops an answer that belongs to another account
    expect(got.pending).toBe(0);
    // Refused without the same origin; then accepted, once per id.
    const made = iso(Date.now() - 60_000);
    const body = JSON.stringify({ actions: [{ id: "cact-0001", person: "P-1", action: "contacted", made_at: made },
      { id: "cact-0002", person: "P-1", action: "dance", made_at: made }] });
    expect((await call("/app/api/circle/action", { method: "POST", headers: { Cookie: cookie }, body })).status).toBe(403);
    const r = await (await call("/app/api/circle/action", { method: "POST", headers: { Cookie: cookie, Origin: BASE }, body })).json<any>();
    expect(r.accepted).toEqual(["cact-0001"]);
    expect(r.dropped.map((d: any) => d.id)).toEqual(["cact-0002"]);
    await call("/app/api/circle/action", { method: "POST", headers: { Cookie: cookie, Origin: BASE }, body });
    expect((await (await call("/app/api/circle", { headers: { Cookie: cookie } })).json<any>()).pending).toBe(1);
    const mac = await (await call("/v2/circle/actions", { key: u.key })).json<any>();
    expect(mac.actions).toEqual([{ id: "cact-0001", person: "P-1", action: "contacted", made_at: made }]);
    await call("/v2/circle/actions/ack", { method: "POST", key: u.key, body: JSON.stringify({ ids: ["cact-0001"] }) });
    expect((await (await call("/v2/circle/actions", { key: u.key })).json<any>()).actions).toEqual([]);
  });

  it("phone_draft_uses_the_cards_notes_and_is_never_kept", async () => {
    const u = await circleUser("Phone draft");
    const { cookie } = await pairPhone(u.key);
    await call("/v2/circle", { method: "PUT", key: u.key, body: JSON.stringify({ copy }) });
    let prompt = "";
    setCircleFetch((async (_i: RequestInfo | URL, init?: RequestInit) => { prompt = String(init?.body); return claudeReply({ draft: "Hi Kim, fancy a walk this weekend?" }); }) as typeof fetch);
    try {
      const r = await call("/app/api/circle/draft", { method: "POST", headers: { Cookie: cookie, Origin: BASE }, body: JSON.stringify({ person: "P-1" }) });
      expect(r.status).toBe(200);
      expect((await r.json<any>()).draft).toBe("Hi Kim, fancy a walk this weekend?");
      expect(prompt).toContain("Likes hiking");
      expect(prompt).toContain(HAIKU);
    } finally { setCircleFetch(null); }
  });
});

describe("circle: on-request AI (Haiku)", () => {
  it("fill_uses_header_names_addresses_and_phones_only", async () => {
    const u = await circleUser("Fill");
    let sent = "";
    setCircleFetch((async (_i: RequestInfo | URL, init?: RequestInit) => { sent = String(init?.body); return claudeReply({ name: "Anna Example", emails: ["anna@example.com"], phones: [], company: "Example" }); }) as typeof fetch);
    try {
      const r = await call("/v2/circle/fill", { method: "POST", key: u.key, body: JSON.stringify({ headers: [{ name: "Anna Example", address: "anna@example.com", body: "SECRET" }] }) });
      expect(r.status).toBe(200);
      expect(await r.json<any>()).toMatchObject({ name: "Anna Example", emails: ["anna@example.com"], company: "Example" });
      expect(sent).not.toContain("SECRET");
    } finally { setCircleFetch(null); }
  });

  it("mac_draft_returns_text_and_stores_nothing", async () => {
    const u = await circleUser("Draft");
    setCircleFetch((async () => claudeReply({ draft: "Hi Anna, how did the move go?" })) as typeof fetch);
    try {
      const before = await env.DB.prepare("SELECT count(*) n FROM circle_exchanges").first<any>();
      const r = await call("/v2/circle/draft", { method: "POST", key: u.key, body: JSON.stringify({ name: "Anna", language: "English", notes: "Moved house in October",
        messages: [{ direction: "in", at: iso(NOW - DAY), text: "We finally moved!" }] }) });
      expect((await r.json<any>()).draft).toBe("Hi Anna, how did the move go?");
      expect((await env.DB.prepare("SELECT count(*) n FROM circle_exchanges").first<any>()).n).toBe(before.n);
      const usage = await env.DB.prepare("SELECT job FROM llm_usage WHERE user_id=?").bind(u.id).all<any>();
      expect(usage.results.map((x: any) => x.job)).toEqual(["draft_message"]);
    } finally { setCircleFetch(null); }
  });

  it("refused_while_circle_is_off", async () => {
    const u = await circleUser("Off AI", false);
    expect((await call("/v2/circle/draft", { method: "POST", key: u.key, body: JSON.stringify({ name: "A" }) })).status).toBe(409);
  });
});

describe("circle: notification buttons", () => {
  it("a_due_person_reminder_names_the_person_for_the_buttons", () => {
    expect(circleOf("rb-circle_due-P-12-2026-11-18")).toBe("P-12");
    expect(circleOf("rb-decision_review-D-1-2026-11-18")).toBeUndefined();
    expect(JSON.parse(payloadJSON({ title: "Kim", body: "Time to get in touch", url: "/app/", circle: "P-12" }))).toMatchObject({ circle: "P-12" });
  });
});

beforeEach(() => { setCircleFetch(null); });

describe("circle: feed fetches stay on the public internet (Codex round 2, #1)", () => {
  it("unsafe_feed_urls_are_refused_when_watched", async () => {
    const { publicHttpUrl } = await import("../../src/circle/safe-url");
    for (const bad of ["file:///etc/passwd", "ftp://example.com/feed", "http://localhost/feed", "http://app.localhost/x", "http://127.0.0.1/feed",
      "http://2130706433/", "http://0x7f.0.0.1/", "http://10.1.2.3/", "http://172.16.0.1/", "http://192.168.1.1/", "http://169.254.169.254/latest",
      "http://100.64.0.1/", "http://0.0.0.0/", "http://[::1]/", "http://[fe80::1]/", "http://[fd00::1]/", "http://[::ffff:127.0.0.1]/", "http://user:pw@example.com/"]) {
      expect(publicHttpUrl(bad), bad).toBeNull();
    }
    expect(publicHttpUrl("https://blog.example.com/feed")?.href).toBe("https://blog.example.com/feed");
    expect(publicHttpUrl("http://93.184.216.34/rss")).not.toBeNull();
    const u = await circleUser("Unsafe feed");
    const r = await call("/v2/circle/watch", { method: "PUT", key: u.key, body: JSON.stringify({ people: [{ person: "P-1", name: "A", feed_url: "http://127.0.0.1:8080/admin" }] }) });
    expect(r.status).toBe(400);
  });

  it("redirects_are_checked_each_hop_and_stop_after_three", async () => {
    const u = await circleUser("Redirect feed");
    const { seal } = await import("../../src/circle/common");
    const watchOf = async (feed: string) => env.DB.prepare(`INSERT INTO circle_watch(user_id,data_enc,updated) VALUES(?,?,?)
        ON CONFLICT(user_id) DO UPDATE SET data_enc=excluded.data_enc`).bind(u.id, await seal(env as any,
      [{ person: "P-1", name: "A", firm: "", company: "", officer_id: "", born: "", feed_url: feed, news: false, ch: false }]), iso(NOW)).run();
    const asked: string[] = [];
    const redirects: Record<string, string> = { "https://a.example.com/feed": "http://169.254.169.254/latest/meta-data",
      "https://b.example.com/1": "https://b.example.com/2", "https://b.example.com/2": "https://b.example.com/3",
      "https://b.example.com/3": "https://b.example.com/4", "https://b.example.com/4": "https://b.example.com/5" };
    const f = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      asked.push(url);
      expect(init?.redirect).toBe("manual");
      if (redirects[url]) return new Response(null, { status: 302, headers: { Location: redirects[url] } });
      return new Response(`<rss><channel><item><title>Post</title><link>https://b.example.com/p</link></item></channel></rss>`);
    }) as typeof fetch;
    await watchOf("https://a.example.com/feed");
    await runCircleUpdates(env as any, u.id, new Budget(40), { now: NOW, fetchFn: f });
    expect(asked).toEqual(["https://a.example.com/feed"]);            // the private hop is never fetched
    await env.DB.prepare("DELETE FROM circle_checked WHERE user_id=?").bind(u.id).run();
    asked.length = 0;
    await watchOf("https://b.example.com/1");
    await runCircleUpdates(env as any, u.id, new Budget(40), { now: NOW, fetchFn: f });
    expect(asked).toEqual(["https://b.example.com/1", "https://b.example.com/2", "https://b.example.com/3", "https://b.example.com/4"]);
    const res = await (await call("/v2/circle/updates", { key: u.key })).json<any>();
    expect(res.updates.filter((x: any) => x.kind === "post")).toEqual([]);
  });
});

describe("circle: notification buttons are bound to their account (Codex round 2, #4)", () => {
  it("push_carries_the_account_and_the_server_refuses_another", async () => {
    const { circlePushExtras } = await import("../../src/reminders/alerts");
    const { accountMarker } = await import("../../src/phone/auth");
    const a = await circleUser("Account A"), b = await circleUser("Account B");
    const extras = await circlePushExtras(a.id, "rb-circle_due-P-1-2026-11-18");
    expect(extras).toEqual({ circle: "P-1", account: await accountMarker(a.id) });
    expect(await circlePushExtras(a.id, "due:5")).toEqual({});
    expect(JSON.parse(payloadJSON({ title: "t", body: "b", url: "/app/", ...extras }))).toMatchObject({ circle: "P-1", account: extras.account });
    expect(JSON.parse(payloadJSON({ title: "t", body: "b", url: "/app/", circle: "P-1", account: "<script>" })).account).toBeUndefined();
    // A's notification tapped while the phone is signed in to B: refused, nothing queued for B.
    const { cookie } = await pairPhone(b.key);
    const made = iso(Date.now() - 60_000);
    const send = (account: string) => call("/app/api/circle/action", { method: "POST", headers: { Cookie: cookie, Origin: BASE },
      body: JSON.stringify({ account, actions: [{ id: "nbact-0001", person: "P-1", action: "contacted", made_at: made }] }) });
    expect((await send(extras.account!)).status).toBe(409);
    expect((await (await call("/v2/circle/actions", { key: b.key })).json<any>()).actions).toEqual([]);
    expect((await send(await accountMarker(b.id))).status).toBe(200);
    expect((await (await call("/v2/circle/actions", { key: b.key })).json<any>()).actions).toHaveLength(1);
  });
});

describe("circle: feed fetches on the Mac's engine (Codex round 3, #1)", () => {
  it("marks_feed_fetches_public_only_for_the_mac_bridge", async () => {
    const { fetchPublic } = await import("../../src/circle/safe-url");
    const inits: any[] = [];
    await fetchPublic((async (_u: RequestInfo | URL, init?: RequestInit) => { inits.push(init); return new Response("ok"); }) as typeof fetch, "https://blog.example.com/feed");
    expect(inits[0]).toMatchObject({ redirect: "manual", fbPublicOnly: true });
    // The Mac runtime passing these to the app is checked on the Mac (circleBridgeChecks reads engine/local/runtime.js).
  });
});
