import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { encrypt } from "../src/crypto";
import { GmailSource, SourceAuthError } from "../src/sources/gmail";
import { replyMime, draftLink } from "../src/mime";

const b64url = (s: string) => btoa(unescape(encodeURIComponent(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64url = (s: string) => decodeURIComponent(escape(atob(s.replace(/-/g, "+").replace(/_/g, "/"))));

async function row() {
  return { id: "src1", user_id: "u1", kind: "gmail", address: "me@gmail.com", client_id: "cid",
    refresh_enc: await encrypt(env as any, "refresh"), client_secret_enc: await encrypt(env as any, "secret"), cursor: null as string | null };
}

type Req = { method: string; url: string; body?: any };
function stub(handler: (r: Req) => Response | undefined) {
  const reqs: Req[] = [];
  const f = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url.startsWith("https://oauth2.googleapis.com/token")) return Response.json({ access_token: "at" });
    const r: Req = { method: init?.method ?? "GET", url, body: init?.body ? JSON.parse(String(init.body)) : undefined };
    reqs.push(r);
    return handler(r) ?? new Response("{}", { status: 404 });
  };
  return { f: f as typeof fetch, reqs };
}

const gm = (id: string, headers: Record<string, string>, text: string, labels: string[] = ["INBOX"]) => ({
  id, labelIds: labels, internalDate: "1",
  payload: { mimeType: "text/plain", body: { data: b64url(text) },
    headers: Object.entries({ "Message-ID": `<${id}@mail>`, ...headers }).map(([name, value]) => ({ name, value })) },
});

describe("gmail drafts", () => {
  it("find_thread_by_message_id", async () => {
    const g = stub((r) => {
      if (r.url.includes("/messages?")) return Response.json({ messages: [{ id: "g2", threadId: "t1" }] });
      if (r.url.includes("/threads/t1")) return Response.json({ messages: [
        gm("m1", { From: "Anna <anna@x.com>", "Reply-To": "anna@work.com", To: "me@gmail.com, bob@x.com", Cc: "cat@x.com", Subject: "Hi", Date: "Sat, 07 Nov 2026 10:00:00 +0000" }, "Hello there"),
        gm("m2", { From: "me@gmail.com", To: "anna@x.com", Subject: "Re: Hi", Date: "Sat, 07 Nov 2026 11:00:00 +0000" }, "Hey"),
        gm("d1", { From: "me@gmail.com", To: "anna@x.com", Subject: "Re: Hi" }, "draft", ["DRAFT"]),
      ] });
    });
    const s = new GmailSource(env as any, await row(), g.f);
    const t = await s.findThread("<m1@mail>");
    expect(decodeURIComponent(g.reqs[0].url)).toContain("rfc822msgid:m1@mail");
    expect(t!.threadId).toBe("t1");
    expect(t!.messages).toHaveLength(2);
    expect(t!.messages[0]).toMatchObject({ messageId: "<m1@mail>", replyTo: "anna@work.com", to: ["me@gmail.com", "bob@x.com"], cc: ["cat@x.com"], subject: "Hi", text: "Hello there" });
  });

  it("find_thread_keeps_quoted_commas_in_addresses", async () => {
    const g = stub((r) => {
      if (r.url.includes("/messages?")) return Response.json({ messages: [{ id: "g1", threadId: "t1" }] });
      if (r.url.includes("/threads/t1")) return Response.json({ messages: [gm("m1", { From: "a@x.com", To: '"Lee, Jamie" <c@x.com>, b@x.com', Cc: '"A, B" <ab@x.com>' }, "hi")] });
    });
    const t = await new GmailSource(env as any, await row(), g.f).findThread("<m1@mail>");
    expect(t!.messages[0].to).toEqual(['"Lee, Jamie" <c@x.com>', "b@x.com"]);
    expect(t!.messages[0].cc).toEqual(['"A, B" <ab@x.com>']);
  });

  it("find_thread_null_when_no_match", async () => {
    const g = stub((r) => (r.url.includes("/messages?") ? Response.json({}) : undefined));
    expect(await new GmailSource(env as any, await row(), g.f).findThread("<zz@mail>")).toBeNull();
  });

  it("own_addresses_from_send_as", async () => {
    const g = stub((r) => (r.url.endsWith("/settings/sendAs") ? Response.json({ sendAs: [
      { sendAsEmail: "Me@Gmail.com", displayName: "Sam Lee", isPrimary: true }, { sendAsEmail: "alias@x.com", displayName: "Alias" }] }) : undefined));
    expect(await new GmailSource(env as any, await row(), g.f).ownAddresses()).toEqual({ addresses: ["me@gmail.com", "alias@x.com"], displayName: "Sam Lee" });
  });

  it("create_draft_in_thread", async () => {
    const g = stub((r) => (r.method === "POST" && r.url.endsWith("/drafts") ? Response.json({ id: "dr1", message: { id: "mm1" } }) : undefined));
    const out = await new GmailSource(env as any, await row(), g.f).createDraft("RAW", "t1");
    expect(out).toEqual({ draftId: "dr1", messageId: "mm1" });
    expect(g.reqs[0].body).toEqual({ message: { raw: "RAW", threadId: "t1" } });
  });

  it("update_draft", async () => {
    const g = stub((r) => (r.method === "PUT" && r.url.endsWith("/drafts/dr1") ? Response.json({ id: "dr1", message: { id: "mm2" } }) : undefined));
    const out = await new GmailSource(env as any, await row(), g.f).updateDraft("dr1", "RAW", "t1");
    expect(out).toEqual({ draftId: "dr1", messageId: "mm2" });
    expect(g.reqs[0].body).toEqual({ message: { raw: "RAW", threadId: "t1" } });
  });

  it("draft_snapshot_reads_recipients_subject_text_and_attachments", async () => {
    const msg = gm("mm1", { To: "Anna Lee <anna@x.com>", Cc: "bob@x.com, \"Lee, Cat\" <cat@x.com>", Subject: "=?UTF-8?B?UmU6IOOBk+OCk+OBq+OBoeOBrw==?=" }, "Body text");
    const g = stub((r) => (r.url.includes("/drafts/dr1?format=full") ? Response.json({ id: "dr1", message: msg }) : undefined));
    expect(await new GmailSource(env as any, await row(), g.f).draftSnapshot("dr1"))
      .toEqual({ to: ["Anna Lee <anna@x.com>"], cc: ["bob@x.com", "\"Lee, Cat\" <cat@x.com>"], subject: "Re: こんにちは", body: "Body text", attachments: false });
    const withFile = { ...msg, payload: { mimeType: "multipart/mixed", headers: msg.payload.headers, parts: [
      { ...msg.payload, headers: [] }, { mimeType: "image/png", filename: "a.png", headers: [], body: { attachmentId: "x", size: 3 } }] } };
    const g2 = stub((r) => (r.url.includes("/drafts/dr1?format=full") ? Response.json({ id: "dr1", message: withFile }) : undefined));
    expect(await new GmailSource(env as any, await row(), g2.f).draftSnapshot("dr1")).toMatchObject({ body: "Body text", attachments: true });
  });

  it("draft_snapshot_null_when_gone", async () => {
    const g = stub(() => new Response("{}", { status: 404 }));
    expect(await new GmailSource(env as any, await row(), g.f).draftSnapshot("dr1")).toBeNull();
  });

  it("draft_403_is_reconnect_error", async () => {
    const g = stub(() => new Response("{}", { status: 403 }));
    const s = new GmailSource(env as any, await row(), g.f);
    const e = await s.createDraft("RAW", "t1").catch((x) => x);
    expect(e).toBeInstanceOf(SourceAuthError);
    expect(e.message).toBe("Reconnect me@gmail.com to let FloatBoard create drafts.");
    expect(await s.updateDraft("d", "RAW", "t1").catch((x) => x)).toBeInstanceOf(SourceAuthError);
  });
});

const base = { from: "me@gmail.com", to: "anna@x.com", cc: [] as string[], subject: "Hi", inReplyTo: "<m1@mail>", references: "<m0@mail> <m1@mail>", body: "Thanks" };
const decode = (raw: string) => unb64url(raw);

describe("replyMime", () => {
  it("mime_sets_reply_headers", () => {
    const m = decode(replyMime(base));
    expect(m).toContain("In-Reply-To: <m1@mail>");
    expect(m).toContain("References: <m0@mail> <m1@mail>");
    expect(m).toContain("Subject: Re: Hi");
    expect(m).toContain("To: anna@x.com");
    expect(m).not.toMatch(/^Cc:/m);
    expect(decode(replyMime({ ...base, subject: "Re: Hi", cc: ["b@x.com", "c@x.com"] }))).toMatch(/Subject: Re: Hi\r\n/);
    expect(decode(replyMime({ ...base, subject: "RE: Hi" }))).not.toContain("Re: RE:");
    expect(decode(replyMime({ ...base, cc: ["b@x.com", "c@x.com"] }))).toContain("Cc: b@x.com, c@x.com");
  });

  it("mime_encodes_non_ascii_subject_and_body", () => {
    const body = "はい、火曜日で大丈夫です。\nSee you";
    const m = decode(replyMime({ ...base, subject: "火曜日の打ち合わせについて", body }));
    const subj = m.match(/^Subject: (.*)\r\n/m)![1];
    expect(subj).toMatch(/^=\?UTF-8\?B\?[A-Za-z0-9+/=]+\?=/);
    const decoded = [...subj.matchAll(/=\?UTF-8\?B\?([^?]+)\?=/g)].map((x) => new TextDecoder().decode(Uint8Array.from(atob(x[1]), (c) => c.charCodeAt(0)))).join("");
    expect(decoded).toBe("Re: 火曜日の打ち合わせについて");
    expect(m).toMatch(/Content-Type: text\/plain; charset="UTF-8"/);
    expect(m).toContain("Content-Transfer-Encoding: base64");
    const b64 = m.split("\r\n\r\n")[1].replace(/\s+/g, "");
    expect(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)))).toBe(body.replace(/\n/g, "\r\n"));
  });

  it("mime_folds_long_encoded_subject", () => {
    const subject = "日".repeat(300);
    const m = decode(replyMime({ ...base, subject }));
    const head = m.split("\r\n\r\n")[0];
    for (const line of head.split("\r\n")) expect(line.length).toBeLessThanOrEqual(998);
    const unfolded = head.replace(/\r\n /g, " ");
    const subj = unfolded.match(/^Subject: (.*)$/m)![1];
    const words = [...subj.matchAll(/=\?UTF-8\?B\?([^?]+)\?=/g)];
    for (const w of words) expect(w[0].length).toBeLessThanOrEqual(75);
    expect(words.map((x) => new TextDecoder().decode(Uint8Array.from(atob(x[1]), (c) => c.charCodeAt(0)))).join("")).toBe("Re: " + subject);
    expect(head).toMatch(/\r\n =\?UTF-8/);
  });

  it("mime_body_uses_crlf", () => {
    const m = decode(replyMime({ ...base, body: "a\nb\r\nc" }));
    const b64 = m.split("\r\n\r\n")[1].replace(/\s+/g, "");
    expect(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)))).toBe("a\r\nb\r\nc");
  });

  it("mime_blocks_header_injection", () => {
    const m = decode(replyMime({ ...base, subject: "x\r\nBcc: evil@x.com" }));
    expect(m).not.toMatch(/^Bcc:/m);
  });

  it("draft_link", () => {
    expect(draftLink("me@gmail.com", "mm1")).toBe("https://mail.google.com/mail/u/me@gmail.com/#drafts?compose=mm1");
  });
});
