import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { Budget } from "../src/budget";
import { runUser, runRounds } from "../src/run";
import { classify } from "../src/classify";
import { encrypt } from "../src/crypto";
import { HAIKU, makeClient } from "../src/llm";
import { setTelegramFetch } from "../src/telegram";
import { alertFor } from "../src/alerts";
import { newUser } from "./helpers";
import type { Message, Source } from "../src/sources/types";

const mail = (id: string, over: Partial<Message> = {}): Message => ({ messageId: `<${id}@x>`, sourceId: "s", from: "Anna <anna@acme.com>",
  to: ["me@gmail.com"], cc: [], subject: `Ask ${id}`, date: "", labels: ["UNREAD"], headers: {}, text: `Please ${id}`, link: `https://mail/${id}`, ...over });
const claudeReply = (urgent = false) => (async () => Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU,
  stop_reason: "end_turn", stop_sequence: null, content: [{ type: "text", text: JSON.stringify({ action_required: true, title: "Do it",
    why: "asked", due: null, has_time: false, importance: 1, group: null, urgent }) }], usage: { input_tokens: 1, output_tokens: 1 } })) as typeof fetch;

async function userWithSources(addresses: string[]) {
  const u = await newUser("X");
  await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk"), u.id).run();
  const ids: string[] = [];
  for (const a of addresses) {
    const id = crypto.randomUUID(); ids.push(id);
    await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,enabled,created) VALUES(?,?,'gmail',?,1,?)").bind(id, u.id, a, new Date().toISOString()).run();
  }
  return { u, ids };
}

/** Source with an endless backlog; charges the budget like Gmail (1 per page + 1 per message). */
const endless = (prefix: string, budget?: Budget): Source => ({
  async fetchBatch(cursor, limit) {
    budget?.take(1);
    const i = cursor ? Number(cursor) : 0;
    budget?.take(limit);
    return { messages: Array.from({ length: limit }, (_, k) => mail(`${prefix}${i + k}`)), cursor: String(i + limit), done: false };
  },
});

describe("run fairness, budget and alerts", () => {
  beforeEach(() => setTelegramFetch((async () => Response.json({ ok: true })) as typeof fetch));

  it("second_inbox_not_starved_by_first_backlog", async () => {
    const { u, ids } = await userWithSources(["a@gmail.com", "b@gmail.com"]);
    const src = new Map([[ids[0], endless("a")], [ids[1], endless("b")]]);
    await runUser(env as any, u.id, { sourceFor: (r) => src.get(r.id)!, fetchFn: claudeReply() });
    const per = await env.DB.prepare("SELECT substr(message_id,2,1) AS s, count(*) AS n FROM seen WHERE user_id=? GROUP BY s").bind(u.id).all<any>();
    expect(per.results.map((r) => r.s).sort()).toEqual(["a", "b"]);
  });

  it("budget_running_out_during_claude_is_not_a_claude_error", async () => {
    const { u, ids } = await userWithSources(["a@gmail.com"]);
    for (let i = 0; i < 3; i++) {
      const budget = new Budget(9);
      await runRounds(env as any, u.id, { calls: budget, sourceFor: () => endless("c", budget), fetchFn: claudeReply(true),
        alert: alertFor(env as any, u.id) });
    }
    const runs = await env.DB.prepare("SELECT stopped, error FROM runs WHERE user_id=?").bind(u.id).all<any>();
    expect(runs.results.length).toBeGreaterThan(0);
    for (const r of runs.results) expect(r.stopped).not.toBe("claude_error");
    void ids;
  });

  it("classifier_gets_local_time_and_urgent_means_explicit", async () => {
    const bodies: string[] = [];
    const f = (async (_u: RequestInfo | URL, init?: RequestInit) => { bodies.push(String(init?.body)); return claudeReply()(_u, init); }) as typeof fetch;
    await classify(mail("x"), ["me@gmail.com"], [], makeClient("sk", f));
    const sent = JSON.parse(bodies[0]);
    const user = sent.messages[0].content as string;
    expect(user).toMatch(/Now \(UTC\): \w+day \d{4}-\d{2}-\d{2} \d{2}:\d{2}/);
    expect(sent.system).toMatch(/Urgent only when the email itself says urgent/i);
    expect(sent.system).not.toMatch(/due within 24 hours/i);
  });

  it("failed_telegram_alert_is_retried_and_does_not_blame_gmail", async () => {
    setTelegramFetch((async () => new Response(JSON.stringify({ ok: false, description: "Forbidden: bot was blocked" }), { status: 403 })) as typeof fetch);
    const { u, ids } = await userWithSources(["a@gmail.com"]);
    await env.DB.prepare("UPDATE users SET telegram_chat_id='42' WHERE id=?").bind(u.id).run();
    await runUser(env as any, u.id, { sourceFor: () => ({ fetchBatch: async () => ({ messages: [mail("u1")], cursor: "1", done: true }) }),
      fetchFn: claudeReply(true), alert: alertFor(env as any, u.id) });
    const it = await env.DB.prepare("SELECT critical, alerted FROM items WHERE user_id=?").bind(u.id).first<any>();
    expect(it).toEqual({ critical: 1, alerted: 0 });
    const src = await env.DB.prepare("SELECT last_error FROM sources WHERE id=?").bind(ids[0]).first<any>();
    expect(src.last_error).toBeNull();
    const ev = await env.DB.prepare("SELECT decision FROM run_events WHERE user_id=?").bind(u.id).all<any>();
    expect(ev.results.map((e) => e.decision)).toContain("alert failed");
  });
});
