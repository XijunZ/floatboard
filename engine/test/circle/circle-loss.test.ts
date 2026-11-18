import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "../helpers";
import { encrypt } from "../../src/lib/crypto";
import { Budget } from "../../src/lib/budget";
import { runCircleUpdates } from "../../src/circle/updates";

// Round 13 (C1): Claude failing (overloaded, rate-limited, budget) in the news match must not lose what Companies House
// returned: the cursor and the "checked" marks are saved only together with what was found.
const DAY = 86400_000;
const NOW = Date.parse("2026-11-18T12:00:00Z");
const rss = `<?xml version="1.0"?><rss><channel><item><title>Ivy Example joins board - P</title><link>https://example.com/a</link><pubDate>Mon, 16 Nov 2026 10:00:00 GMT</pubDate></item></channel></rss>`;
function world(claudeStatus: number, appts: any[]) {
  return (async (input: RequestInfo | URL) => {
    const url = String(input);
    if (url.startsWith("https://api.anthropic.com")) {
      return claudeStatus === 200
        ? Response.json({ id: "m", type: "message", role: "assistant", model: "claude-haiku-5-5", stop_reason: "end_turn", stop_sequence: null,
            content: [{ type: "text", text: JSON.stringify({ items: [{ n: 1, about_them: true }] }) }], usage: { input_tokens: 1, output_tokens: 1 } })
        : new Response(JSON.stringify({ type: "error", error: { type: "overloaded_error", message: "x" } }), { status: claudeStatus, headers: { "content-type": "application/json" } });
    }
    if (url.includes("/officers/OFF1/appointments")) return Response.json({ items: appts });
    if (url.startsWith("https://news.google.com/rss")) return new Response(rss);
    return new Response("nf", { status: 404 });
  }) as typeof fetch;
}

describe("circle: a failing news match never loses Companies House changes (round 13, C1)", () => {
  it("claude_overloaded_keeps_the_directorships_and_the_news", async () => {
    const u = await newUser("loss");
    await env.DB.prepare("UPDATE settings SET modules=? WHERE user_id=?").bind(JSON.stringify({ circle: true }), u.id).run();
    await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
    await call("/v2/keys", { method: "PUT", key: u.key, body: JSON.stringify({ companies_house_key: "ch-key" }) });
    const ivy = { person: "P-3", name: "Ivy Example", firm: "Acme", company: "", officer_id: "OFF1", born: "", feed_url: "", news: true, ch: true };
    expect((await call("/v2/circle/watch", { method: "PUT", key: u.key, body: JSON.stringify({ people: [ivy] }) })).status).toBe(200);
    const a1 = { appointed_to: { company_name: "BETA LTD", company_number: "123" }, appointed_on: "2020-01-01", officer_role: "director" };
    await runCircleUpdates(env as any, u.id, new Budget(40), { now: NOW, fetchFn: world(529, [a1]) });
    const kinds = (await (await call("/v2/circle/updates", { key: u.key })).json<any>()).updates.map((x: any) => x.kind).sort();
    expect(kinds).toEqual(["directorship", "news_person"]);   // news stays "possible"
    // A week later, a new appointment is still found (the cursor moved on only with what was saved).
    const a2 = { appointed_to: { company_name: "GAMMA LTD", company_number: "456" }, appointed_on: "2026-11-20", officer_role: "director" };
    await runCircleUpdates(env as any, u.id, new Budget(40), { now: NOW + 8 * DAY, fetchFn: world(200, [a1, a2]) });
    const all = (await (await call("/v2/circle/updates", { key: u.key })).json<any>()).updates.map((x: any) => x.kind);
    expect(all).toContain("appointment");
  });

  it("a_run_that_fails_before_saving_saves_no_cursor_either", async () => {
    const u = await newUser("loss2");
    await env.DB.prepare("UPDATE settings SET modules=? WHERE user_id=?").bind(JSON.stringify({ circle: true }), u.id).run();
    await call("/v2/keys", { method: "PUT", key: u.key, body: JSON.stringify({ companies_house_key: "ch-key" }) });
    const ivy = { person: "P-4", name: "Ivy Example", firm: "", company: "", officer_id: "OFF1", born: "", feed_url: "", news: false, ch: true };
    await call("/v2/circle/watch", { method: "PUT", key: u.key, body: JSON.stringify({ people: [ivy] }) });
    const a1 = { appointed_to: { company_name: "BETA LTD", company_number: "123" }, appointed_on: "2020-01-01", officer_role: "director" };
    // Budget too small for even one person: nothing is looked at, nothing is marked.
    await runCircleUpdates(env as any, u.id, new Budget(2), { now: NOW, fetchFn: world(200, [a1]) });
    const marks = await env.DB.prepare("SELECT count(*) AS n FROM circle_checked WHERE user_id=?").bind(u.id).first<{ n: number }>();
    const cursor = await env.DB.prepare("SELECT count(*) AS n FROM circle_readers WHERE user_id=? AND reader LIKE 'ch:%'").bind(u.id).first<{ n: number }>();
    expect([marks!.n, cursor!.n]).toEqual([0, 0]);
  });
});
