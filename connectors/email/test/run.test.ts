import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { isCritical, wallClockToDate, runUser } from "../src/run";
import { encrypt } from "../src/crypto";
import { SourceAuthError, type Message, type Source } from "../src/sources/types";
import { HAIKU } from "../src/llm";
import { newUser } from "./helpers";
import type { Action } from "../src/classify";

const act = (over: Partial<Action> = {}): Action => ({ title: "Do it", why: "asked", due: null, hasTime: false, importance: 1, group: null, urgent: false, ...over });

/** Fake source serving `msgs` in pages of `limit`, cursor = next index. */
function fakeSource(msgs: Message[], fail = false): Source {
  return {
    async fetchBatch(cursor, limit) {
      if (fail) throw new SourceAuthError("Google sign-in expired");
      const i = cursor ? Number(cursor) : 0;
      const page = msgs.slice(i, i + limit);
      const next = i + page.length;
      return { messages: page, cursor: String(next), done: next >= msgs.length };
    },
  };
}
const mail = (n: number, over: Partial<Message> = {}): Message => ({ messageId: `<m${n}@x>`, sourceId: "s", from: "Anna <anna@acme.com>",
  to: ["me@gmail.com"], cc: [], subject: `Ask ${n}`, date: "", labels: ["UNREAD"], headers: {}, text: `Please do thing ${n}`, link: `https://mail/${n}`, ...over });

/** Fake Claude: every email is an action; title echoes the subject so we can check what was classified. */
const claudeFetch = (async (_u: RequestInfo | URL, init?: RequestInit) => {
  const body = JSON.parse(String(init?.body));
  const subject = /Subject: (.*)/.exec(body.messages[0].content)?.[1] ?? "";
  const urgent = subject.includes("URGENT");
  return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
    content: [{ type: "text", text: JSON.stringify({ action_required: true, title: `Handle ${subject}`, why: "asked", due: null,
      has_time: false, importance: 1, group: null, urgent }) }], usage: { input_tokens: 1, output_tokens: 1 } });
}) as typeof fetch;

async function setup(sources: { address: string; msgs: Message[]; fail?: boolean }[]) {
  const u = await newUser("X");
  await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
  const map = new Map<string, Source>();
  for (const s of sources) {
    const id = crypto.randomUUID();
    await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,enabled,created) VALUES(?,?,'gmail',?,1,?)").bind(id, u.id, s.address, new Date().toISOString()).run();
    map.set(id, fakeSource(s.msgs, s.fail));
  }
  return { u, sourceFor: (row: { id: string }) => map.get(row.id)! };
}

describe("run", () => {
  it("critical_by_due_within_hours_dst", () => {
    for (const now of [new Date("2026-07-10T09:00:00Z"), new Date("2027-01-10T09:00:00Z")]) {
      const in23 = new Date(now.getTime() + 23 * 3600e3), in25 = new Date(now.getTime() + 25 * 3600e3);
      const fmt = (d: Date) => new Intl.DateTimeFormat("sv-SE", { timeZone: "Europe/Berlin", year: "numeric", month: "2-digit",
        day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(d).replace(" ", "T");
      expect(isCritical(act({ due: fmt(in23), hasTime: true }), now, 24, "Europe/Berlin")).toBe(true);
      expect(isCritical(act({ due: fmt(in25), hasTime: true }), now, 24, "Europe/Berlin")).toBe(false);
      expect(isCritical(act({ urgent: true }), now, 24)).toBe(true);
    }
    expect(wallClockToDate("2026-07-10T12:00", "Europe/Berlin").toISOString()).toBe("2026-07-10T10:00:00.000Z"); // summer time
    expect(wallClockToDate("2027-01-10T12:00", "Europe/Berlin").toISOString()).toBe("2027-01-10T11:00:00.000Z"); // winter time
  });

  it("critical_alerts_normal_does_not", async () => {
    const { u, sourceFor } = await setup([{ address: "me@gmail.com", msgs: [mail(1, { subject: "URGENT invoice" }), mail(2)] }]);
    const alerts: string[] = [];
    await runUser(env as any, u.id, { sourceFor, fetchFn: claudeFetch, alert: async (item) => { alerts.push(item.title); } });
    expect(alerts).toEqual(["Handle URGENT invoice"]);
    const rows = await env.DB.prepare("SELECT title, critical FROM items WHERE user_id=? ORDER BY title").bind(u.id).all<any>();
    expect(rows.results).toEqual([{ title: "Handle Ask 2", critical: 0 }, { title: "Handle URGENT invoice", critical: 1 }]);
  });

  it("backlog_spans_runs_with_cursor", async () => {
    const msgs = Array.from({ length: 25 }, (_, i) => mail(i));
    const { u, sourceFor } = await setup([{ address: "me@gmail.com", msgs }]);
    const r1 = await runUser(env as any, u.id, { sourceFor, fetchFn: claudeFetch, budget: 10 });
    expect(r1).toEqual({ processed: 10, done: false });
    const r2 = await runUser(env as any, u.id, { sourceFor, fetchFn: claudeFetch, budget: 10 });
    const r3 = await runUser(env as any, u.id, { sourceFor, fetchFn: claudeFetch, budget: 10 });
    expect([r2, r3]).toEqual([{ processed: 10, done: false }, { processed: 5, done: true }]);
    const seen = await env.DB.prepare("SELECT count(*) AS n FROM seen WHERE user_id=?").bind(u.id).first<{ n: number }>();
    expect(seen!.n).toBe(25);
  });

  it("dedupes_same_message_id_across_sources", async () => {
    const shared = mail(7);
    const { u, sourceFor } = await setup([{ address: "a@gmail.com", msgs: [shared] }, { address: "b@gmail.com", msgs: [shared] }]);
    await runUser(env as any, u.id, { sourceFor, fetchFn: claudeFetch });
    const n = await env.DB.prepare("SELECT count(*) AS n FROM items WHERE user_id=?").bind(u.id).first<{ n: number }>();
    expect(n!.n).toBe(1);
  });

  it("auth_error_isolated_to_source", async () => {
    const { u, sourceFor } = await setup([{ address: "bad@gmail.com", msgs: [], fail: true }, { address: "good@gmail.com", msgs: [mail(1)] }]);
    await runUser(env as any, u.id, { sourceFor, fetchFn: claudeFetch });
    const src = await env.DB.prepare("SELECT address, last_error FROM sources WHERE user_id=? ORDER BY address").bind(u.id).all<any>();
    expect(src.results[0].last_error).toContain("Google sign-in expired");
    expect(src.results[1].last_error).toBeNull();
    const n = await env.DB.prepare("SELECT count(*) AS n FROM items WHERE user_id=?").bind(u.id).first<{ n: number }>();
    expect(n!.n).toBe(1);
  });

  it("dropped_mail_never_reaches_claude", async () => {
    let calls = 0;
    const counting = (async (u: RequestInfo | URL, i?: RequestInit) => { calls++; return claudeFetch(u, i); }) as typeof fetch;
    const { u, sourceFor } = await setup([{ address: "me@gmail.com", msgs: [mail(1, { labels: ["UNREAD", "CATEGORY_PROMOTIONS"] }), mail(2, { from: "no-reply@shop.com" })] }]);
    await runUser(env as any, u.id, { sourceFor, fetchFn: counting });
    expect(calls).toBe(0);
  });

  it("no_claude_key_reports_error_and_keeps_mail", async () => {
    const { u, sourceFor } = await setup([{ address: "me@gmail.com", msgs: [mail(1)] }]);
    await env.DB.prepare("UPDATE users SET anthropic_key_enc=NULL WHERE id=?").bind(u.id).run();
    const r = await runUser(env as any, u.id, { sourceFor, fetchFn: claudeFetch });
    expect(r.processed).toBe(0);
    const run = await env.DB.prepare("SELECT error FROM runs WHERE user_id=?").bind(u.id).first<{ error: string }>();
    expect(run!.error).toContain("Claude API key");
    const seen = await env.DB.prepare("SELECT count(*) AS n FROM seen WHERE user_id=?").bind(u.id).first<{ n: number }>();
    expect(seen!.n).toBe(0); // nothing lost: processed once a key is added
  });
});
