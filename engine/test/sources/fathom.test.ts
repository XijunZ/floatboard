import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { call, fathomHookPath, newUser } from "../helpers";
import { ensureFathomHook } from "../../src/routes/sources";
import { FATHOM_UNSIGNED_PER_DAY, fathomToMessage, recapKey } from "../../src/sources/fathom";
import type { Message } from "../../src/sources/types";

const payload = {
  title: "Weekly planning with Sam",
  recording_id: 98765,
  share_url: "https://fathom.video/share/AbC123xyz",
  scheduled_start_time: "2026-11-08T12:30:00Z",
  default_summary: { markdown_formatted: "## Summary\nAgreed to start in spring." },
  action_items: [{ description: "Draft the project one-pager", assignee: { name: "Alex", email: "me@gmail.com" } }],
};

describe("fathom connector", () => {
  it("webhook_payload_becomes_message", () => {
    const m = fathomToMessage(payload, "src-f");
    expect(m.messageId).toBe("fathom:AbC123xyz");
    expect(m.subject).toBe("Weekly planning with Sam");
    expect(m.text).toContain("Agreed to start in spring.");
    expect(m.text).toContain("Draft the project one-pager (Alex)");
    expect(m.link).toBe("https://fathom.video/share/AbC123xyz");
  });

  it("email_and_webhook_for_same_meeting_share_key", () => {
    const email: Message = { messageId: "<x@fathom>", sourceId: "g", from: "no-reply@fathom.video", to: [], cc: [],
      subject: "Recap", date: "", labels: [], headers: {}, link: "https://mail/1",
      text: "View the recording: https://fathom.video/share/AbC123xyz?utm=1" };
    expect(recapKey(email)).toBe("fathom:AbC123xyz");
    expect(recapKey(fathomToMessage(payload, "src-f"))).toBe("fathom:AbC123xyz");
  });

  it("register_returns_private_hook_url", async () => {
    const u = await newUser("X");
    const j = await ensureFathomHook(env as any, new Request("https://engine.test/"), u.id);
    expect(j.hook_url).toMatch(/^https:\/\/engine\.test\/hooks\/fathom\/[A-Za-z0-9_-]{30,}$/);
    expect(await ensureFathomHook(env as any, new Request("https://engine.test/"), u.id)).toEqual(j); // one per user
  });

  it("unknown_hook_id_404", async () => {
    const r = await call("/hooks/fathom/not-a-real-id", { method: "POST", body: JSON.stringify(payload) });
    expect(r.status).toBe(404);
  });

  it("webhook_without_claude_key_still_stores_raw_summary", async () => {
    const u = await newUser("X");
    const path = await fathomHookPath(u.id);
    const r = await call(path, { method: "POST", body: JSON.stringify(payload) });
    expect(r.status).toBe(200);
    const again = await call(path, { method: "POST", body: JSON.stringify(payload) });
    expect(again.status).toBe(200);
    const rows = await env.DB.prepare("SELECT kind, message_id, summary FROM items WHERE user_id=?").bind(u.id).all<any>();
    expect(rows.results).toHaveLength(1); // deduped
    expect(rows.results[0]).toMatchObject({ kind: "summary", message_id: "fathom:AbC123xyz" });
    expect(rows.results[0].summary).toContain("Agreed to start in spring.");
  });
});

// Round 29 (security review L3): the webhook takes at most 1 MB, and deliveries without a signature (no signing secret
// saved yet) are limited, so someone who learns the address can't flood the board or the Claude credit.
describe("fathom webhook limits", () => {
  it("a_body_over_a_megabyte_is_refused", async () => {
    const u = await newUser("Fathom big");
    const path = await fathomHookPath(u.id);
    const r = await call(path, { method: "POST", body: JSON.stringify({ ...payload, default_summary: { markdown_formatted: "x".repeat(1_100_000) } }) });
    expect(r.status).toBe(413);
  });

  it("unsigned_deliveries_are_limited_a_day", async () => {
    const u = await newUser("Fathom unsigned");
    const path = await fathomHookPath(u.id);
    let last = 0;
    for (let i = 0; i < FATHOM_UNSIGNED_PER_DAY + 1; i++) {
      last = (await call(path, { method: "POST", body: JSON.stringify({ ...payload, recording_id: 1000 + i, share_url: `https://fathom.video/share/x${i}` }) })).status;
    }
    expect(last).toBe(429);
  });
});

