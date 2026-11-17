import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, newUser } from "../helpers";
import { pairPhone } from "../phone-helpers";
import { encrypt } from "../../src/lib/crypto";
import { HAIKU } from "../../src/lib/llm";
import { setJotsClaudeFetch } from "../../src/jots/ai";

// Jots' three Haiku jobs (design §3): tag suggestions (batched), cleanup (before/after on the Mac and phone) and filling the
// Make task form. Claude is a stub here: no live call.

let asked: any[] = [];
let answer: unknown = {};
beforeEach(() => {
  asked = [];
  setJotsClaudeFetch((async (_u: RequestInfo | URL, init?: RequestInit) => {
    asked.push(JSON.parse(String(init?.body)));
    return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
      content: [{ type: "text", text: JSON.stringify(answer) }], usage: { input_tokens: 10, output_tokens: 5 } });
  }) as typeof fetch);
});

async function setup(name: string, jots = true, claude = true) {
  const u = await newUser(name);
  if (claude) await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env, "sk-ant-test"), u.id).run();
  await call("/v2/board", { method: "PUT", key: u.key, body: JSON.stringify({ cards: [], modules: { jots, circle: false, decisions: false, resolutions: false } }) });
  return u;
}
const post = (key: string, path: string, body: unknown) => call(path, { method: "POST", key, body: JSON.stringify(body) });

describe("jots: Claude's jobs (Haiku)", () => {
  it("tags_for_a_batch_of_jots_in_one_call_known_names_only", async () => {
    const u = await setup("Tags");
    answer = { jots: [{ id: 1, tags: ["Work", "Made up"] }, { id: 2, tags: ["health"] }, { id: 99, tags: ["Work"] }] };
    const r = await post(u.key, "/v2/jots/tags", { tags: ["Work", "Health"], jots: [{ id: 1, text: "Budget review notes" }, { id: 2, text: "Run 5k" }] });
    expect(r.status).toBe(200);
    expect((await r.json<any>()).suggestions).toEqual([{ id: 1, tags: ["Work"] }, { id: 2, tags: ["Health"] }]);
    expect(asked).toHaveLength(1);
    expect(asked[0].model).toBe(HAIKU);
    const usage = await env.DB.prepare("SELECT job, calls FROM llm_usage WHERE user_id=?").bind(u.id).all<{ job: string; calls: number }>();
    expect(usage.results).toEqual([{ job: "jot_tags", calls: 1 }]);
  });

  it("cleanup_returns_the_cleaned_text_on_mac_and_phone", async () => {
    const u = await setup("Cleanup");
    answer = { cleaned: "Call Ann about the budget." };
    const r = await post(u.key, "/v2/jots/cleanup", { text: "call ann abt budget" });
    expect(await r.json<any>()).toEqual({ cleaned: "Call Ann about the budget." });
    expect(asked[0].system).toContain("never");
    const { cookie } = await pairPhone(u.key);
    const p = await call("/app/api/jots/cleanup", { method: "POST", headers: { Cookie: cookie, Origin: BASE }, body: JSON.stringify({ text: "call ann abt budget" }) });
    expect(await p.json<any>()).toEqual({ cleaned: "Call Ann about the budget." });
    expect((await call("/app/api/jots/cleanup", { method: "POST", headers: { Cookie: cookie, Origin: "https://evil.example" }, body: "{}" })).status).toBe(403);
  });

  it("fill_form_gives_title_and_due", async () => {
    const u = await setup("Fill");
    answer = { title: "Send Ann the budget", due: "2026-11-21", has_time: false };
    const r = await post(u.key, "/v2/jots/fill", { selection: "send ann the budget by friday", context: "Notes from the review", today: "2026-11-17", zone: "Europe/London" });
    expect(await r.json<any>()).toEqual({ title: "Send Ann the budget", due: "2026-11-21", has_time: false });
    answer = { title: "x", due: "next week", has_time: false };
    expect((await (await post(u.key, "/v2/jots/fill", { selection: "x", today: "2026-11-17", zone: "Europe/London" })).json<any>()).due).toBeNull();
  });

  it("skipped_while_jots_is_off_or_without_a_claude_key", async () => {
    const off = await setup("Off", false);
    expect((await post(off.key, "/v2/jots/cleanup", { text: "x" })).status).toBe(409);
    const nokey = await setup("No key", true, false);
    const r = await post(nokey.key, "/v2/jots/cleanup", { text: "x" });
    expect(r.status).toBe(409);
    expect((await r.json<any>()).error).toBe("no_claude_key");
    expect(asked).toHaveLength(0);
  });

  it("bad_requests_are_refused", async () => {
    const u = await setup("Bad");
    expect((await post(u.key, "/v2/jots/tags", { tags: ["Work"], jots: Array.from({ length: 21 }, (_, i) => ({ id: i + 1, text: "x" })) })).status).toBe(400);
    expect((await post(u.key, "/v2/jots/cleanup", { text: "x".repeat(20_001) })).status).toBe(400);
    expect((await post(u.key, "/v2/jots/fill", { selection: "" })).status).toBe(400);
  });
});
