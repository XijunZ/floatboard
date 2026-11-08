import { describe, it, expect } from "vitest";
import { classify, type FeedbackExample } from "../src/classify";
import { makeClient, HAIKU } from "../src/llm";
import type { Message } from "../src/sources/types";

const email = (over: Partial<Message> = {}): Message => ({
  messageId: "<1@x>", sourceId: "s", from: "Anna <anna@acme.com>", to: ["me@gmail.com"], cc: [],
  subject: "Deck", date: "Sat, 07 Nov 2026 10:00:00 +0000", labels: [], headers: {},
  text: "Hi, could you send me the quarterly report by Tuesday 5pm? Thanks, Anna", link: "https://mail/1", ...over,
});

/** Fake Messages API: answers with `reply` as the model's text, records request bodies. */
function fakeClaude(reply: string, stop = "end_turn") {
  const bodies: any[] = [];
  const f = async (_url: RequestInfo | URL, init?: RequestInit) => {
    bodies.push(JSON.parse(String(init?.body)));
    return Response.json({
      id: "msg_1", type: "message", role: "assistant", model: HAIKU, stop_reason: stop, stop_sequence: null,
      content: [{ type: "text", text: reply }], usage: { input_tokens: 100, output_tokens: 40 },
    });
  };
  return { client: makeClient("sk-test", f as typeof fetch), bodies };
}

const yes = JSON.stringify({ action_required: true, title: "Send Anna the quarterly report", why: "Anna asked for the report by Tuesday",
  due: "2026-11-10T17:00", has_time: true, importance: 2, group: null, urgent: false });

describe("classify", () => {
  it("long_titles_cut_at_word_boundary", async () => {
    const { shortTitle } = await import("../src/classify");
    const t = shortTitle("Collect the parcel from the post office and bring the receipt to the front desk before Tuesday afternoon");
    expect(t.length).toBeLessThanOrEqual(80);
    expect(t.endsWith("…")).toBe(true);
    expect(t).not.toMatch(/detai…$/);
    expect(shortTitle("Short title")).toBe("Short title");
  });

  it("returns_action_when_asked_to_do_something", async () => {
    const { client } = fakeClaude(yes);
    const a = await classify(email(), ["me@gmail.com"], [], client);
    expect(a).toEqual({ ok: true, action: { title: "Send Anna the quarterly report", why: "Anna asked for the report by Tuesday", due: "2026-11-10T17:00",
      hasTime: true, importance: 2, group: null, urgent: false } });
  });

  it("returns_null_for_fyi", async () => {
    const { client } = fakeClaude(JSON.stringify({ action_required: false, title: "", why: "FYI only", due: null,
      has_time: false, importance: 0, group: null, urgent: false }));
    expect(await classify(email({ text: "FYI the office is closed Monday." }), ["me@gmail.com"], [], client)).toEqual({ ok: true, action: null });
  });

  it("uses_haiku_low_effort_with_schema", async () => {
    const { client, bodies } = fakeClaude(yes);
    await classify(email(), ["me@gmail.com"], [], client);
    expect(bodies[0].model).toBe("claude-haiku-5-5");
    expect(bodies[0].output_config.effort).toBe("low");
    expect(bodies[0].output_config.format.type).toBe("json_schema");
    expect(JSON.stringify(bodies[0].messages)).toContain("quarterly report by Tuesday");
  });

  it("includes_feedback_examples_in_prompt", async () => {
    const { client, bodies } = fakeClaude(yes);
    const ex: FeedbackExample[] = [{ subject: "Your weekly summary", sender: "bot@tool.com", verdict: "not_action" }];
    await classify(email(), ["me@gmail.com"], ex, client);
    const sent = JSON.stringify(bodies[0]);
    expect(sent).toContain("Your weekly summary");
    expect(sent).toContain("not an action");
  });

  it("group_kept_only_if_users_group", async () => {
    const pick = (g: string | null) => fakeClaude(JSON.stringify({ action_required: true, title: "Buy printer paper", why: "x", due: null,
      has_time: false, importance: 1, group: g, urgent: false }));
    const ok = pick("Personal");
    expect((await classify(email(), ["me@gmail.com"], [], ok.client, ["Acme", "Personal"]) as any).action.group).toBe("Personal");
    expect(JSON.stringify(ok.bodies[0])).toMatch(/- Acme\\n- Personal/);
    const bad = pick("Finance");
    expect((await classify(email(), ["me@gmail.com"], [], bad.client, ["Acme", "Personal"]) as any).action.group).toBeNull();
  });

  it("invalid_model_json_is_unusable_not_no_action", async () => {
    const { client } = fakeClaude("not json at all");
    expect(await classify(email(), ["me@gmail.com"], [], client)).toEqual({ ok: false, reason: "unparseable" });
  });

  it("refusal_is_unusable_not_no_action", async () => {
    const { client } = fakeClaude("", "refusal");
    expect(await classify(email(), ["me@gmail.com"], [], client)).toMatchObject({ ok: false }); // reason may be "refusal" or "unparseable": both mean "couldn't read the answer"
  });
});
