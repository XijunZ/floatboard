import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { newUser } from "./helpers";
import { upsertGmail } from "../src/routes/sources";
import { classify, RULES } from "../src/classify";
import { makeClient, HAIKU } from "../src/llm";
import type { Message } from "../src/sources/types";

function fake(reply: object) {
  const bodies: any[] = [];
  const client = makeClient("sk", (async (_u: any, init?: RequestInit) => {
    bodies.push(JSON.parse(String(init?.body)));
    return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
      content: [{ type: "text", text: JSON.stringify(reply) }], usage: { input_tokens: 1, output_tokens: 1 } });
  }) as typeof fetch);
  return { client, bodies };
}
const m: Message = { messageId: "<a>", sourceId: "s", from: "Rosa <rosa@example.com>", to: ["me@gmail.com"], cc: [], subject: "Form",
  date: "", labels: [], headers: {}, text: "Could you send the signed form?", link: "l" };
const no = { action_required: false, title: "", why: "", due: null, has_time: false, importance: 0, group: null, urgent: false };

describe("what the classifier is told", () => {
  it("claude_sees_group_descriptions_my_rules_and_inbox", async () => {
    const f = fake(no);
    await classify(m, ["me@gmail.com"], [], f.client, ["Acme", "Home"], {
      groupNotes: { "Home": "Household bills, repairs and deliveries" }, myRules: "Webinar invitations are always low.", inbox: "me@gmail.com" });
    const u = f.bodies[0].messages[0].content as string;
    expect(u).toContain("Home: Household bills, repairs and deliveries");
    expect(u).toContain("Webinar invitations are always low.");
    expect(u).toContain("Received in: me@gmail.com");
  });

  it("system_prompt_is_built_from_the_visible_rules", async () => {
    const f = fake(no);
    await classify(m, ["me@gmail.com"], [], f.client);
    for (const r of RULES) expect(f.bodies[0].system).toContain(r);
    expect(RULES.length).toBeGreaterThan(5);
  });

  it("rules_cover_relayed_messages_and_booked_reminders", () => {
    expect(RULES.some((r) => /via LinkedIn/i.test(r) && /Reply to/i.test(r))).toBe(true);
    expect(RULES.some((r) => /reminder/i.test(r) && /booked/i.test(r) && /Attend/i.test(r))).toBe(true);
  });


  it("reconnecting_a_paused_inbox_resumes_it", async () => {
    const u = await newUser("RP");
    const g = { address: "me@gmail.com", refresh_token: "r1", client_id: "c", client_secret: "s" };
    const id = await upsertGmail(env as any, u.id, g);
    await env.DB.prepare("UPDATE sources SET enabled=0 WHERE id=?").bind(id).run();
    await upsertGmail(env as any, u.id, { ...g, refresh_token: "r2" });
    const row = await env.DB.prepare("SELECT enabled FROM sources WHERE id=?").bind(id).first<{ enabled: number }>();
    expect(row!.enabled).toBe(1);
  });
});
