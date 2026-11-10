import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { encrypt } from "../src/crypto";
import { GmailSource } from "../src/sources/gmail";
import { fathomToMessage, recapKeys } from "../src/sources/fathom";
import { processRecap } from "../src/recap";
import type { Message } from "../src/sources/types";
import { newUser } from "./helpers";

const b64url = (s: string) => btoa(unescape(encodeURIComponent(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

// Shaped like a real Fathom delivery: the share link uses a token, the action items link to /calls/<number>.
const webhook = {
  title: "Impromptu Call",
  recording_id: 555000111,
  share_url: "https://fathom.video/share/TokEN_abc-123",
  url: "https://fathom.video/calls/896667811",
  default_summary: { markdown_formatted: "## Summary\nWe agreed things." },
  action_items: [{ description: "Send the deck", recording_playback_url: "https://fathom.video/calls/896667811?timestamp=90.9" }],
};

// Shaped like a real Fathom recap email: the plain part has no links; the HTML part links to /calls/<number>.
const emailPlain = "FATHOM\nMeeting Purpose We agreed things. Next Steps - Send the deck.";
const emailHtml = `<p>Impromptu Call</p><a href="https://fathom.video/calls/896667811?tab=summary">View Meeting</a>
  <a href="https://fathom.video/calls/896667811?tab=summary&amp;timestamp=90.9999">Send the deck</a>`;

async function parsedEmail(): Promise<Message> {
  const row = { id: "src-g", user_id: "u1", kind: "gmail", address: "me@gmail.com", client_id: "cid",
    refresh_enc: await encrypt(env as any, "refresh"), client_secret_enc: await encrypt(env as any, "secret"), cursor: null };
  const raw = { id: "g1", labelIds: ["INBOX"], payload: { mimeType: "multipart/alternative",
    headers: [{ name: "Message-ID", value: "<abc@fathom-sidekiq.mail>" }, { name: "From", value: "Fathom <no-reply@fathom.video>" },
      { name: "Subject", value: 'Recap for "Impromptu Call"' }, { name: "Date", value: "Tue, 10 Nov 2026 16:12:23 +0000" }],
    parts: [{ mimeType: "text/plain", body: { data: b64url(emailPlain) } }, { mimeType: "text/html", body: { data: b64url(emailHtml) } }] } };
  const f = (async (input: RequestInfo | URL) => String(input).includes("oauth2")
    ? Response.json({ access_token: "at", expires_in: 3600 }) : Response.json(raw)) as typeof fetch;
  return new GmailSource(env as any, row as any, f).fetchFull("g1");
}

async function stored(userId: string) {
  return (await env.DB.prepare("SELECT kind, message_id FROM items WHERE user_id=? ORDER BY message_id").bind(userId).all<any>()).results;
}

describe("fathom recap dedupe across webhook and email", () => {
  it("gmail_recap_email_keeps_fathom_call_links_from_html", async () => {
    const m = await parsedEmail();
    expect(m.text).not.toContain("fathom.video/calls"); // the plain part is still what Claude reads
    expect(recapKeys(m)).toContain("fathom:call:896667811");
  });

  it("webhook_keys_include_share_token_and_call_numbers", () => {
    const keys = recapKeys(fathomToMessage(webhook, "src-f"));
    expect(keys[0]).toBe("fathom:TokEN_abc-123"); // same primary key as before, so older deliveries still match
    expect(keys).toEqual(expect.arrayContaining(["fathom:call:896667811", "fathom:call:555000111"]));
  });

  it("email_after_webhook_is_a_duplicate", async () => {
    const u = await newUser("X");
    expect((await processRecap(env as any, u.id, fathomToMessage(webhook, "src-f"))).status).toBe("stored");
    expect((await processRecap(env as any, u.id, await parsedEmail())).status).toBe("duplicate");
    expect(await stored(u.id)).toEqual([{ kind: "summary", message_id: "fathom:TokEN_abc-123" }]);
  });

  it("webhook_after_email_is_a_duplicate", async () => {
    const u = await newUser("X");
    expect((await processRecap(env as any, u.id, await parsedEmail())).status).toBe("stored");
    expect((await processRecap(env as any, u.id, fathomToMessage(webhook, "src-f"))).status).toBe("duplicate");
    expect(await stored(u.id)).toHaveLength(1);
  });

  it("different_meetings_are_both_stored", async () => {
    const u = await newUser("X");
    const other = { ...webhook, share_url: "https://fathom.video/share/Other999", url: "https://fathom.video/calls/111",
      recording_id: 111, action_items: [] };
    await processRecap(env as any, u.id, fathomToMessage(webhook, "src-f"));
    expect((await processRecap(env as any, u.id, fathomToMessage(other, "src-f"))).status).toBe("stored");
  });

  it("recap_stored_before_this_change_still_blocks_its_email", async () => {
    // A webhook recap saved by the old code has only its items row (no key list).
    const u = await newUser("X");
    await env.DB.prepare("INSERT INTO items(id,user_id,source_id,message_id,kind,title,created) VALUES('old',?, 'src-f', 'fathom:TokEN_abc-123', 'summary', 't', '2026-11-10')")
      .bind(u.id).run();
    expect((await processRecap(env as any, u.id, fathomToMessage(webhook, "src-f"))).status).toBe("duplicate");
  });
});
