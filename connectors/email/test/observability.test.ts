import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { Budget } from "../src/budget";
import { runUser, runRounds } from "../src/run";
import { encrypt } from "../src/crypto";
import { HAIKU } from "../src/llm";
import { newUser } from "./helpers";
import type { Message, Source } from "../src/sources/types";

const mail = (n: number, over: Partial<Message> = {}): Message => ({ messageId: `<m${n}@x>`, sourceId: "s", from: "Anna <anna@acme.com>",
  to: ["me@gmail.com"], cc: [], subject: `Ask ${n}`, date: "", labels: ["UNREAD"], headers: {}, text: `Please do thing ${n}`, link: `https://mail/${n}`, ...over });

/** Fake source that charges the budget like Gmail would: 1 call per page + 1 per message. */
function chargingSource(msgs: Message[], budget: Budget): Source {
  return {
    async fetchBatch(cursor, limit) {
      budget.take(1);
      const i = cursor ? Number(cursor) : 0;
      const page = msgs.slice(i, i + limit);
      budget.take(page.length);
      const next = i + page.length;
      return { messages: page, cursor: String(next), done: next >= msgs.length };
    },
  };
}
const claude = (async () => Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn",
  stop_sequence: null, content: [{ type: "text", text: JSON.stringify({ action_required: true, title: "Do it", why: "asked", due: null,
    has_time: false, importance: 1, group: null, urgent: false }) }], usage: { input_tokens: 1, output_tokens: 1 } })) as typeof fetch;

async function setup(msgs: Message[]) {
  const u = await newUser("X");
  await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk"), u.id).run();
  await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,enabled,created) VALUES(?,?,'gmail','me@gmail.com',1,?)")
    .bind(crypto.randomUUID(), u.id, new Date().toISOString()).run();
  return u;
}

describe("call budget & observability", () => {
  it("budget_throws_when_exhausted", () => {
    const b = new Budget(3);
    b.take(2);
    expect(b.remaining).toBe(1);
    expect(() => b.take(2)).toThrow(/budget/i);
  });

  it("stops_cleanly_at_call_budget_and_resumes_without_loss", async () => {
    const msgs = Array.from({ length: 30 }, (_, i) => mail(i));
    const u = await setup(msgs);
    let total = 0;
    for (let i = 0; i < 10; i++) {
      const budget = new Budget(20); // like one Worker invocation
      const r = await runRounds(env as any, u.id, { calls: budget, sourceFor: () => chargingSource(msgs, budget), fetchFn: claude });
      expect(budget.used).toBeLessThanOrEqual(20);
      total += r.processed;
      if (r.done) break;
    }
    const items = await env.DB.prepare("SELECT count(*) AS n FROM items WHERE user_id=?").bind(u.id).first<{ n: number }>();
    const seen = await env.DB.prepare("SELECT count(*) AS n FROM seen WHERE user_id=?").bind(u.id).first<{ n: number }>();
    expect(items!.n).toBe(30);
    expect(seen!.n).toBe(30);
    const bad = await env.DB.prepare("SELECT count(*) AS n FROM runs WHERE user_id=? AND stopped='claude_error'").bind(u.id).first<{ n: number }>();
    expect(bad!.n).toBe(0);
  });

  it("run_stats_and_events_recorded", async () => {
    const u = await setup([]);
    const msgs = [mail(1), mail(2, { labels: ["UNREAD", "CATEGORY_PROMOTIONS"] }), mail(3, { from: "no-reply@shop.com" })];
    await runUser(env as any, u.id, { sourceFor: () => ({ fetchBatch: async () => ({ messages: msgs, cursor: "3", done: true }) }), fetchFn: claude });
    const run = (await env.DB.prepare("SELECT id, stopped, stats FROM runs WHERE user_id=?").bind(u.id).first<any>())!;
    expect(run.stopped).toBe("done");
    expect(JSON.parse(run.stats)).toMatchObject({ fetched: 3, dropped: 2, classified: 1, actions: 1 });
    const events = (await env.DB.prepare("SELECT decision, subject FROM run_events WHERE run_id=?").bind(run.id).all<any>()).results;
    expect(events.map((e) => e.decision)).toEqual(expect.arrayContaining(["action created", "dropped: bulk category", "dropped: automated sender"]));
    expect(events.find((e) => e.decision === "action created").subject).toBe("Ask 1");
  });

  it("old_traces_pruned", async () => {
    const u = await setup([]);
    await env.DB.prepare("INSERT INTO runs(id,user_id,started) VALUES('old',?,?)").bind(u.id, "2026-01-01T00:00:00.000Z").run();
    await env.DB.prepare("INSERT INTO run_events(run_id,user_id,at,decision) VALUES('old',?,?, 'x')").bind(u.id, "2026-01-01T00:00:00.000Z").run();
    await runUser(env as any, u.id, { sourceFor: () => ({ fetchBatch: async () => ({ messages: [], cursor: null, done: true }) }), fetchFn: claude });
    const n = await env.DB.prepare("SELECT count(*) AS n FROM run_events WHERE run_id='old'").first<{ n: number }>();
    expect(n!.n).toBe(0);
  });

  it("pending_critical_alerts_retried_next_run", async () => {
    const u = await setup([]);
    await env.DB.prepare(`INSERT INTO items(id,user_id,message_id,kind,title,critical,alerted,created) VALUES('c1',?,'<c@x>','action','Pay now',1,0,?)`)
      .bind(u.id, new Date().toISOString()).run();
    const sent: string[] = [];
    await runUser(env as any, u.id, { sourceFor: () => ({ fetchBatch: async () => ({ messages: [], cursor: null, done: true }) }),
      fetchFn: claude, alert: async (i) => { sent.push(i.title); } });
    expect(sent).toEqual(["Pay now"]);
    const row = await env.DB.prepare("SELECT alerted FROM items WHERE id='c1'").first<{ alerted: number }>();
    expect(row!.alerted).toBe(1);
  });
});
