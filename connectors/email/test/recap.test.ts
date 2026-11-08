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
function fakeClaude(obj: unknown) {
  const f = async () => Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn",
    stop_sequence: null, content: [{ type: "text", text: JSON.stringify(obj) }], usage: { input_tokens: 1, output_tokens: 1 } });
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
});
