import { describe, it, expect } from "vitest";
import { classify, RULES, SKILL } from "../src/classify";
import { makeClient, HAIKU } from "../src/llm";
import type { Message } from "../src/sources/types";

describe("email triage skill", () => {
  it("skill_file_is_what_claude_is_told", async () => {
    const bodies: any[] = [];
    const client = makeClient("sk", (async (_u: any, init?: RequestInit) => {
      bodies.push(JSON.parse(String(init?.body)));
      return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
        content: [{ type: "text", text: JSON.stringify({ action_required: false, title: "", why: "", due: null, has_time: false, importance: 0, group: null, urgent: false }) }],
        usage: { input_tokens: 1, output_tokens: 1 } });
    }) as typeof fetch);
    const m: Message = { messageId: "<a>", sourceId: "s", from: "a@b.c", to: [], cc: [], subject: "x", date: "", labels: [], headers: {}, text: "x", link: "" };
    await classify(m, ["me@x.com"], [], client);
    expect(SKILL).toMatch(/^# Email triage/);
    expect(bodies[0].system).toContain(SKILL.trim());
  });

  it("visible_rules_are_the_skill_bullets", () => {
    const bullets = SKILL.split("\n").filter((l) => l.startsWith("- ")).map((l) => l.slice(2).trim());
    expect(RULES).toEqual(bullets);
    expect(RULES.length).toBeGreaterThan(15);
  });

  it("skill_is_not_personal", () => {
    for (const w of ["Alex", "Anna", "Acme", "Bloggs", "Example Clinic"]) expect(SKILL).not.toContain(w);
  });
});
