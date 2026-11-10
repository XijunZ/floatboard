import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { encrypt } from "../src/crypto";
import { GmailSource, SourceAuthError } from "../src/sources/gmail";

const b64url = (s: string) => btoa(unescape(encodeURIComponent(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function row(over: Record<string, unknown> = {}) {
  return { id: "src1", user_id: "u1", kind: "gmail", address: "me@gmail.com", client_id: "cid",
    refresh_enc: await encrypt(env as any, "refresh"), client_secret_enc: await encrypt(env as any, "secret"),
    cursor: null as string | null, ...over };
}

/** Fake Google: token endpoint + list + get. Records requested URLs. */
function fakeGoogle(opts: { pages?: Record<string, { ids: string[]; next?: string }>; messages?: Record<string, any>; tokenFails?: boolean }) {
  const urls: string[] = [];
  const f = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    urls.push(url);
    if (url.startsWith("https://oauth2.googleapis.com/token")) {
      return opts.tokenFails ? new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 })
        : Response.json({ access_token: "at", expires_in: 3600 });
    }
    const u = new URL(url);
    if (u.pathname.endsWith("/messages")) {
      const page = opts.pages?.[u.searchParams.get("pageToken") ?? ""] ?? { ids: [] };
      return Response.json({ messages: page.ids.map((id) => ({ id })), nextPageToken: page.next });
    }
    const id = u.pathname.split("/").pop()!;
    return Response.json(opts.messages![id]);
  };
  return { f: f as typeof fetch, urls };
}

const msg = (id: string, parts: any[], headers: Record<string, string> = {}, labels: string[] = ["INBOX"]) => ({
  id, labelIds: labels,
  payload: { headers: Object.entries({ "Message-ID": `<${id}@mail>`, From: "Anna <anna@x.com>", To: "me@gmail.com",
    Subject: `Subject ${id}`, Date: "Sat, 07 Nov 2026 10:00:00 +0000", ...headers }).map(([name, value]) => ({ name, value })),
    mimeType: "multipart/alternative", parts },
});

describe("gmail source", () => {
  it("default_fetch_is_called_unbound_safely", async () => {
    // Workers' global fetch throws "Illegal invocation" when called as a method of another object.
    const real = globalThis.fetch;
    let sawThis: unknown = "unset";
    globalThis.fetch = (function (this: unknown, input: RequestInfo | URL) {
      sawThis = this;
      if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
      return Promise.resolve(String(input).includes("oauth2") ? Response.json({ access_token: "at" }) : Response.json({ messages: [] }));
    }) as typeof fetch;
    try {
      const res = await new GmailSource(env as any, await row()).fetchBatch(null, 5);
      expect(res.done).toBe(true);
    } finally { globalThis.fetch = real; }
    expect(sawThis === undefined || sawThis === globalThis).toBe(true);
  });

  it("first_run_queries_7_days", async () => {
    const g = fakeGoogle({ pages: { "": { ids: [] } } });
    const src = new GmailSource(env as any, await row(), g.f);
    const res = await src.fetchBatch(null, 10);
    const list = new URL(g.urls.find((u) => u.includes("/messages?"))!);
    const after = Number(/after:(\d+)/.exec(list.searchParams.get("q")!)![1]);
    expect(Math.abs(after - (Date.now() / 1000 - 7 * 86400))).toBeLessThan(120);
    expect(list.searchParams.get("q")).toContain("-in:sent");
    // Gmail filters bulk categories itself (no call spent on them), but recap senders always come through.
    expect(list.searchParams.get("q")).toContain("category:primary"); // exactly what Gmail shows in the Primary tab
    expect(list.searchParams.get("q")).toContain("from:no-reply@fathom.video");
    expect(list.searchParams.get("q")).toContain("is:unread");
    expect(res.done).toBe(true);
  });

  it("paginates_with_cursor", async () => {
    const text = [{ mimeType: "text/plain", body: { data: b64url("hi") } }];
    const g = fakeGoogle({ pages: { "": { ids: ["m1", "m2"], next: "p2" }, p2: { ids: ["m3"] } },
      messages: { m1: msg("m1", text), m2: msg("m2", text), m3: msg("m3", text) } });
    const src = new GmailSource(env as any, await row(), g.f);
    const first = await src.fetchBatch(null, 2);
    expect(first.messages.map((m) => m.messageId)).toEqual(["<m1@mail>", "<m2@mail>"]);
    expect(first.done).toBe(false);
    const second = await src.fetchBatch(first.cursor, 2);
    expect(g.urls.some((u) => u.includes("pageToken=p2"))).toBe(true);
    expect(second.messages.map((m) => m.messageId)).toEqual(["<m3@mail>"]);
    expect(second.done).toBe(true);
    expect(JSON.parse(second.cursor!).pageToken).toBeUndefined(); // next run starts fresh from the saved time
  });

  it("extracts_plain_text_and_message_id", async () => {
    const g = fakeGoogle({ pages: { "": { ids: ["m1"] } }, messages: { m1: msg("m1", [
      { mimeType: "text/plain", body: { data: b64url("Please send the deck by Friday — thanks") } },
      { mimeType: "text/html", body: { data: b64url("<p>ignored</p>") } },
    ], { "List-Unsubscribe": "<mailto:x>" }, ["INBOX", "CATEGORY_PERSONAL"]) } });
    const [m] = (await new GmailSource(env as any, await row(), g.f).fetchBatch(null, 10)).messages;
    expect(m).toMatchObject({ messageId: "<m1@mail>", sourceId: "src1", from: "Anna <anna@x.com>", subject: "Subject m1",
      text: "Please send the deck by Friday — thanks", labels: ["INBOX", "CATEGORY_PERSONAL"],
      link: "https://mail.google.com/mail/u/me@gmail.com/#all/m1" });
    expect(m.headers["list-unsubscribe"]).toBe("<mailto:x>");
    expect(m.to).toEqual(["me@gmail.com"]);
  });

  it("strips_html_when_no_plain", async () => {
    const g = fakeGoogle({ pages: { "": { ids: ["m1"] } }, messages: { m1: msg("m1", [
      { mimeType: "text/html", body: { data: b64url("<style>p{}</style><p>Hello&nbsp;<b>there</b> &amp; welcome</p>") } },
    ]) } });
    const [m] = (await new GmailSource(env as any, await row(), g.f).fetchBatch(null, 10)).messages;
    expect(m.text).toBe("Hello there & welcome");
  });

  it("refresh_failure_marks_source_error", async () => {
    const g = fakeGoogle({ tokenFails: true });
    await expect(new GmailSource(env as any, await row(), g.f).fetchBatch(null, 10)).rejects.toBeInstanceOf(SourceAuthError);
  });

  it("collects_links_from_the_html_part", async () => {
    const html = `<p>Fill in <a href="https://forms.example.com/a?x=1&amp;y=2">the form</a></p><a href="mailto:a@x.com">mail</a>
      <a href="https://forms.example.com/a?x=1&amp;y=2">again</a>`;
    const g = fakeGoogle({ messages: { m1: msg("m1", [
      { mimeType: "text/plain", body: { data: b64url("Fill in the form") } }, { mimeType: "text/html", body: { data: b64url(html) } }]) } });
    const m = await new GmailSource(env as any, await row(), g.f).fetchFull("m1");
    expect(m.links).toEqual(["https://forms.example.com/a?x=1&y=2"]);
  });
});
