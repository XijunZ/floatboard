import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { prefilter, DEFAULT_RECAP_SENDERS } from "../src/filter";
import { gmailIdFromLink, gmailSource } from "../src/sources/gmail";
import { encrypt } from "../src/crypto";
import type { Message } from "../src/sources/types";

const m = (over: Partial<Message> = {}): Message => ({ messageId: "<1@x>", sourceId: "s", from: "Anna <anna@acme.com>", to: [], cc: [],
  subject: "Q", date: "", labels: ["INBOX"], headers: {}, text: "please", link: "https://mail.google.com/mail/u/me@gmail.com/#all/18abc", ...over });
const rules = (unreadOnly: boolean) => ({ ignore: [], allow: [], recapSenders: DEFAULT_RECAP_SENDERS, unreadOnly });

describe("read status", () => {
  it("read_emails_skipped_when_unread_only", () => {
    expect(prefilter(m({ labels: ["INBOX"] }), rules(true))).toBe("drop");
    expect(prefilter(m({ labels: ["INBOX", "UNREAD"] }), rules(true))).toBe("classify");
    expect(prefilter(m({ labels: ["INBOX"] }), rules(false))).toBe("classify");
  });

  it("recaps_kept_even_if_read", () => {
    expect(prefilter(m({ from: "no-reply@fathom.video", labels: ["INBOX"] }), rules(true))).toBe("recap");
  });

  it("allow_listed_kept_even_if_read", () => {
    expect(prefilter(m({ labels: ["INBOX"] }), { ...rules(true), allow: ["anna@acme.com"] })).toBe("classify");
  });

  it("gmail_id_from_link", () => {
    expect(gmailIdFromLink("https://mail.google.com/mail/u/me@gmail.com/#all/18abc")).toBe("18abc");
    expect(gmailIdFromLink("https://fathom.video/share/x")).toBeNull();
  });

  it("mark_read_removes_unread_label", async () => {
    const calls: { url: string; body?: string }[] = [];
    const f = (async (u: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ url: String(u), body: init?.body ? String(init.body) : undefined });
      return String(u).includes("oauth2") ? Response.json({ access_token: "at" }) : Response.json({ id: "18abc" });
    }) as typeof fetch;
    const row = { id: "s", user_id: "u", kind: "gmail", address: "me@gmail.com", client_id: "c", cursor: null,
      refresh_enc: await encrypt(env as any, "r"), client_secret_enc: await encrypt(env as any, "s") };
    await gmailSource(env as any, row, f).markRead("18abc");
    const mod = calls.find((c) => c.url.endsWith("/messages/18abc/modify"))!;
    expect(JSON.parse(mod.body!)).toEqual({ removeLabelIds: ["UNREAD"] });
  });
});
