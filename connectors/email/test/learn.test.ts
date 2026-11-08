import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { classify, RULES } from "../src/classify";
import { LEARN_AT, maybeConsolidate } from "../src/learn";
import { encrypt } from "../src/crypto";
import { runUser } from "../src/run";
import { makeClient, HAIKU } from "../src/llm";
import type { Message, Source } from "../src/sources/types";
import { call, newUser } from "./helpers";

function fake(reply: object) {
  const bodies: any[] = [];
  const client = makeClient("sk", (async (_u: any, init?: RequestInit) => {
    bodies.push(JSON.parse(String(init?.body)));
    return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
      content: [{ type: "text", text: JSON.stringify(reply) }], usage: { input_tokens: 1, output_tokens: 1 } });
  }) as typeof fetch);
  return { client, bodies };
}
async function correct(userId: string, n: number) {
  for (let i = 0; i < n; i++) await env.DB.prepare("INSERT INTO feedback(user_id,item_id,verdict,created,subject,sender,detail) VALUES(?,?,?,?,?,?,?)")
    .bind(userId, `i${i}`, "changed", new Date().toISOString(), `Subj ${i}`, "a@b.c", "group: Acme → Personal").run();
}

describe("learning from corrections", () => {
  it("corrections_survive_recheck", async () => {
    const u = await newUser("L1");
    await correct(u.id, 1);
    expect((await call("/v2/recheck?days=3", { key: u.key, method: "POST" })).status).toBe(200);
    const f = await env.DB.prepare("SELECT verdict, detail, subject, sender FROM feedback WHERE user_id=?").bind(u.id).first<any>();
    expect(f).toEqual({ verdict: "changed", detail: "group: Acme → Personal", subject: "Subj 0", sender: "a@b.c" });
  });

  it("waiting_corrections_reach_the_classifier", async () => {
    const u = await newUser("L0");
    await env.DB.prepare("INSERT INTO feedback(user_id,item_id,verdict,created,subject,sender) VALUES(?,?,?,?,?,?)")
      .bind(u.id, "i1", "not_action", new Date().toISOString(), "Your weekly digest", "digest@tool.com").run();
    await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk"), u.id).run();
    const sid = crypto.randomUUID();
    await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,enabled,created) VALUES(?,?,'gmail','me@gmail.com',1,?)").bind(sid, u.id, new Date().toISOString()).run();
    const msg: Message = { messageId: "<n@x>", sourceId: sid, from: "boss@acme.com", to: ["me@gmail.com"], cc: [], subject: "Q",
      date: "", labels: ["UNREAD"], headers: {}, text: "please", link: "" };
    const src: Source = { fetchBatch: async () => ({ messages: [msg], cursor: "1", done: true }) };
    const bodies: string[] = [];
    const fetchFn = (async (_u: RequestInfo | URL, init?: RequestInit) => {
      bodies.push(String(init?.body));
      return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
        content: [{ type: "text", text: JSON.stringify({ action_required: false, title: "", why: "", due: null, has_time: false, importance: 0, group: null, urgent: false }) }],
        usage: { input_tokens: 1, output_tokens: 1 } });
    }) as typeof fetch;
    await runUser(env as any, u.id, { sourceFor: () => src, fetchFn });
    expect(bodies[0]).toContain("Your weekly digest");
  });

  it("no_consolidation_below_20", async () => {
    const u = await newUser("L2");
    await correct(u.id, LEARN_AT - 1);
    const f = fake({ rules: ["x"] });
    expect(await maybeConsolidate(env as any, u.id, f.client)).toBe(false);
    expect(f.bodies).toHaveLength(0);
  });

  it("consolidates_20_into_personal_skill_and_resets_count", async () => {
    const u = await newUser("L3");
    await env.DB.prepare("UPDATE settings SET learned=? WHERE user_id=?").bind("- Older lesson", u.id).run();
    await correct(u.id, LEARN_AT);
    const f = fake({ rules: ["Survey invitations are not tasks", "Delivery updates go to Personal"] });
    expect(await maybeConsolidate(env as any, u.id, f.client)).toBe(true);
    const sent = f.bodies[0].messages[0].content as string;
    expect(sent).toContain("- Older lesson");
    expect(sent).toContain("group: Acme → Personal");
    expect(f.bodies[0].system).toMatch(/security or fraud/i);
    const s = await env.DB.prepare("SELECT learned FROM settings WHERE user_id=?").bind(u.id).first<{ learned: string }>();
    expect(s?.learned).toBe("- Survey invitations are not tasks\n- Delivery updates go to Personal");
    const left = await env.DB.prepare("SELECT COUNT(*) n FROM feedback WHERE user_id=? AND consolidated=0").bind(u.id).first<{ n: number }>();
    expect(left?.n).toBe(0);
    const st = (await (await call("/v2/export", { key: u.key })).json<any>()).settings;
    expect(st.learned).toContain("Delivery updates go to Personal");
  });

  it("learned_skill_is_editable", async () => {
    const u = await newUser("L4");
    await call("/v2/settings", { key: u.key, method: "PUT", body: JSON.stringify({ version: 1, values: { learned: "- My edit" } }) });
    expect((await (await call("/v2/export", { key: u.key })).json<any>()).settings.learned).toBe("- My edit");
  });

  it("claude_sees_personal_skill_and_change_details", async () => {
    const f = fake({ action_required: false, title: "", why: "", due: null, has_time: false, importance: 0, group: null, urgent: false });
    const m: Message = { messageId: "<a>", sourceId: "s", from: "a@b.c", to: [], cc: [], subject: "x", date: "", labels: [], headers: {}, text: "x", link: "" };
    await classify(m, ["me@x.com"], [{ subject: "Intro", sender: "sam@example.com", verdict: "changed", detail: "group: Acme → Personal" }],
      f.client, [], { learned: "- Delivery updates go to Personal" });
    const u = f.bodies[0].messages[0].content as string;
    expect(u).toContain("- Delivery updates go to Personal");
    expect(u).toContain("group: Acme → Personal");
  });

  it("security_alerts_never_learned_away", () => {
    expect(RULES.some((r) => /never/i.test(r) && /security or fraud alert/i.test(r) && /correction/i.test(r))).toBe(true);
  });
});
