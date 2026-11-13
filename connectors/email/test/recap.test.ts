import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { summariseRecap, storeRecap } from "../src/recap";
import { makeClient, HAIKU } from "../src/llm";
import { newUser } from "./helpers";
import type { Message } from "../src/sources/types";

const recap = (over: Partial<Message> = {}): Message => ({
  messageId: "<r1@fathom>", sourceId: "s", from: "Fathom <no-reply@fathom.video>", to: ["me@gmail.com"], cc: [],
  subject: "Recap: Weekly planning with Sam", date: "Sun, 08 Nov 2026 13:10:00 +0000",
  labels: [], headers: {}, text: "Meeting summary... https://meet.google.com/abc-defg-hij ...", link: "https://fathom.video/r/1", ...over,
});
let lastBody: any = null;
function fakeClaude(obj: unknown) {
  const f = async (_u: unknown, init?: RequestInit) => { lastBody = JSON.parse(String(init?.body)); return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn",
    stop_sequence: null, content: [{ type: "text", text: JSON.stringify(obj) }], usage: { input_tokens: 1, output_tokens: 1 } }); };
  return makeClient("sk-test", f as typeof fetch);
}

describe("meeting recaps", () => {
  it("follow_ups_become_actions", async () => {
    const u = await newUser("X");
    const client = fakeClaude({ decisions: ["Start in spring"], next_steps: ["Sam shares the budget"],
      my_actions: [{ title: "Draft the project one-pager for Sam", due: "2026-11-12", has_time: false, importance: 2 }] });
    const res = await summariseRecap(recap(), client);
    const r = res.ok ? res.recap : null;
    expect(r!.summary).toContain("Decisions: Start in spring");
    expect(r!.summary).toContain("Next steps: Sam shares the budget");
    expect(r!.summary.length).toBeLessThanOrEqual(700);
    await storeRecap(env as any, u.id, recap(), r!);
    const rows = await env.DB.prepare("SELECT kind, title, task_ref, summary FROM items WHERE user_id=? ORDER BY kind").bind(u.id).all<any>();
    expect(rows.results.map((x) => x.kind)).toEqual(["action", "summary"]);
    expect(rows.results[0].title).toBe("Draft the project one-pager for Sam");
    expect(rows.results[1].task_ref).toBeNull();
  });

  it("follow_ups_carry_the_meeting_notes", async () => {
    const u = await newUser("X");
    const client = fakeClaude({ decisions: ["Start in spring"], next_steps: [],
      my_actions: [{ title: "Draft the one-pager", due: null, has_time: false, importance: 1 }] });
    const res = await summariseRecap(recap(), client);
    await storeRecap(env as any, u.id, recap(), res.ok ? res.recap : null!);
    const a = await env.DB.prepare("SELECT summary FROM items WHERE user_id=? AND kind='action'").bind(u.id).first<any>();
    expect(a.summary).toContain("Decisions: Start in spring");
    expect(a.summary).toContain("Full notes: https://fathom.video/r/1");
  });

  it("follow_ups_get_a_group_and_only_the_users_own_actions", async () => {
    const u = await newUser("X");
    const client = fakeClaude({ decisions: [], next_steps: [], my_actions: [
      { title: "Send the target list to John", due: null, has_time: false, importance: 1, group: "Entrepreneurship" },
      { title: "Book the dentist", due: null, has_time: false, importance: 0, group: "Not a group" },
    ] });
    const ctx = { name: "Robin", groups: ["Entrepreneurship", "Personal"], groupNotes: { Entrepreneurship: "search fund ideas" }, myRules: "" };
    const res = await summariseRecap(recap(), client, ctx);
    const prompt = lastBody.system + JSON.stringify(lastBody.messages);
    expect(prompt).toContain("The attendee is Robin.");
    expect(prompt).toContain("Entrepreneurship: search fund ideas");
    expect(prompt).toMatch(/owned by other people are not my_actions/);
    await storeRecap(env as any, u.id, recap(), res.ok ? res.recap : null!);
    const rows = await env.DB.prepare("SELECT title, group_name FROM items WHERE user_id=? AND kind='action' ORDER BY title").bind(u.id).all<any>();
    expect(rows.results).toEqual([
      { title: "Book the dentist", group_name: null },
      { title: "Send the target list to John", group_name: "Entrepreneurship" },
    ]);
  });
});
