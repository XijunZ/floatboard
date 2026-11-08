import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { call, fathomHookPath, newUser } from "./helpers";
import { ensureFathomHook } from "../src/routes/sources";
import { fathomToMessage, recapKey } from "../src/sources/fathom";
import type { Message } from "../src/sources/types";

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
