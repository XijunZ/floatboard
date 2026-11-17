import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, newUser } from "../helpers";
import { pairPhone } from "../phone-helpers";
import { encrypt } from "../../src/lib/crypto";
import { HAIKU } from "../../src/lib/llm";
import { setDecisionsFetch } from "../../src/routes/decisions";
import DECISIONS_SKILL from "../../src/skills/decisions.md";

// Decisions (docs/superpowers/specs/2026-11-17-decisions-design.md §8): the Haiku jobs the Mac asks for (screening ⚑, form
// filling, supersedes ⚑, tell / ask), the Decisions rulebook, the phone's copy and its two actions. No live AI: every
// Claude answer here is a stub.

type Sent = { model: string; system: string; user: string };
let sent: Sent[] = [];
let answers: unknown[] = [];

function stubClaude() {
  sent = [];
  setDecisionsFetch((async (_u: RequestInfo | URL, init?: RequestInit) => {
    const b = JSON.parse(String(init?.body));
    sent.push({ model: b.model, system: typeof b.system === "string" ? b.system : JSON.stringify(b.system), user: b.messages[0].content });
    const next = answers.shift();
    const text = typeof next === "string" ? next : JSON.stringify(next ?? {});
    return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
      content: [{ type: "text", text }], usage: { input_tokens: 100, output_tokens: 20 } });
  }) as typeof fetch);
}

beforeEach(() => { answers = []; stubClaude(); });

async function user(name: string, opts: { key?: boolean } = {}) {
  const u = await newUser(name);
  if (opts.key !== false) await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
  return u;
}
const post = (key: string, path: string, body: unknown) => call(path, { method: "POST", key, body: JSON.stringify(body) });
const jot = (n: number, text: string, refs: { id: string; text: string }[] = []) =>
  ({ ref: `J-${n}@abc${n}`, kind: "jot", added: "2026-11-10T09:00:00Z", text, references: refs });

describe("decisions: weekly screening (⚑)", () => {
  it("screens_a_batch_with_one_haiku_call_and_the_builtin_rulebook", async () => {
    const u = await user("Screen");
    answers = [{ jots: [
      { ref: "J-1@abc1", decisions: [{ quote: "we will stop the newsletter", decision: "Stop the newsletter", type: "operational", why: "", decided_on: "", sure: true }] },
      { ref: "J-2@abc2", decisions: [] },
    ] }];
    const r = await post(u.key, "/v2/decisions/screen", { jots: [jot(1, "Decided: we will stop the newsletter."), jot(2, "Milk, eggs.")] });
    expect(r.status).toBe(200);
    const out = await r.json<any>();
    expect(out.results).toEqual([
      { ref: "J-1@abc1", ok: true, decisions: [{ quote: "we will stop the newsletter", decision: "Stop the newsletter", type: "operational", why: null, decided_on: null, sure: true }] },
      { ref: "J-2@abc2", ok: true, decisions: [] },
    ]);
    expect(sent.length).toBe(1);
    expect(sent[0].model).toBe(HAIKU);
    expect(sent[0].system).toContain(DECISIONS_SKILL.trim().split("\n")[0]);
    expect(sent[0].user).toContain("J-1@abc1");
    const use = await env.DB.prepare("SELECT job, calls FROM llm_usage WHERE user_id=?").bind(u.id).all<any>();
    expect(use.results).toEqual([{ job: "decisions", calls: 1 }]);
  });

  it("uses_the_owners_rulebook_copy_and_sends_references", async () => {
    const u = await user("Copy");
    await env.DB.prepare("UPDATE settings SET rulebook_decisions=? WHERE user_id=?").bind("MY RULES\n- Not a decision: \"maybe hire\"", u.id).run();
    answers = [{ jots: [{ ref: "J-3@abc3", decisions: [] }] }];
    await post(u.key, "/v2/decisions/screen", { jots: [jot(3, "Review of D-1: it went well", [{ id: "D-1", text: "Stop the newsletter" }])] });
    expect(sent[0].system).toContain("MY RULES");
    expect(sent[0].system).not.toContain(DECISIONS_SKILL.trim().split("\n")[0]);
    expect(sent[0].user).toContain("D-1");
    expect(sent[0].user).toContain("references");
  });

  it("an_unreadable_answer_marks_every_jot_not_ok", async () => {
    const u = await user("Bad");
    answers = ["not json"];
    const out = await (await post(u.key, "/v2/decisions/screen", { jots: [jot(1, "x")] })).json<any>();
    expect(out.results).toEqual([{ ref: "J-1@abc1", ok: false, decisions: [] }]);
  });

  it("a_jot_missing_from_the_answer_is_not_ok_and_unknown_refs_are_dropped", async () => {
    const u = await user("Missing");
    answers = [{ jots: [{ ref: "J-9@zzz", decisions: [{ quote: "q", decision: "d", type: "operational", sure: true }] }] }];
    const out = await (await post(u.key, "/v2/decisions/screen", { jots: [jot(1, "x")] })).json<any>();
    expect(out.results).toEqual([{ ref: "J-1@abc1", ok: false, decisions: [] }]);
  });

  it("accepts_chunk_refs_of_a_long_jot", async () => {
    const u = await user("Chunks");
    answers = [{ jots: [{ ref: "J-4@abc4-c2of3", decisions: [] }] }];
    const r = await post(u.key, "/v2/decisions/screen", { jots: [{ ...jot(4, "part two"), ref: "J-4@abc4-c2of3" }] });
    expect(r.status).toBe(200);
    expect((await r.json<any>()).results).toEqual([{ ref: "J-4@abc4-c2of3", ok: true, decisions: [] }]);
  });

  it("refuses_bad_requests_no_key_and_decisions_off", async () => {
    const u = await user("Refuse");
    expect((await post(u.key, "/v2/decisions/screen", { jots: [] })).status).toBe(400);
    expect((await post(u.key, "/v2/decisions/screen", { jots: Array.from({ length: 11 }, (_, i) => jot(i + 1, "x")) })).status).toBe(400);
    expect((await post(u.key, "/v2/decisions/screen", { jots: [{ ref: "nope", text: "x" }] })).status).toBe(400);
    await env.DB.prepare("UPDATE settings SET modules=? WHERE user_id=?").bind(JSON.stringify({ jots: true, circle: true, decisions: false, resolutions: true }), u.id).run();
    expect((await post(u.key, "/v2/decisions/screen", { jots: [jot(1, "x")] })).status).toBe(409);
    const nokey = await user("NoKey", { key: false });
    expect((await post(nokey.key, "/v2/decisions/screen", { jots: [jot(1, "x")] })).status).toBe(400);
    expect(sent.length).toBe(0);
  });
});

describe("decisions: form filling, supersedes (⚑) and tell / ask", () => {
  it("fills_the_form_from_the_selection_only", async () => {
    const u = await user("Fill");
    answers = [{ decision: "Move the offsite to March", why: "", expected: "", confidence: "", type: "strategic", alternatives: "" }];
    const r = await post(u.key, "/v2/decisions/fill", { selection: "We moved the offsite to March.", context: "Board call notes" });
    expect(await r.json()).toEqual({ decision: "Move the offsite to March", why: "not recorded", expected: "", confidence: null, type: "strategic", alternatives: "" });
    expect(sent[0].user).toContain("We moved the offsite to March.");
    expect((await env.DB.prepare("SELECT job FROM llm_usage WHERE user_id=?").bind(u.id).first<any>()).job).toBe("fill_form");
  });

  it("supersedes_answers_only_ids_offered", async () => {
    const u = await user("Sup");
    answers = [{ results: [{ id: "D-5", supersedes: "D-2" }, { id: "D-6", supersedes: "D-99" }] }];
    const r = await post(u.key, "/v2/decisions/supersedes", { items: [
      { id: "D-5", text: "Move to a monthly digest", earlier: [{ id: "D-2", text: "Send a weekly newsletter" }] },
      { id: "D-6", text: "Hire a designer", earlier: [{ id: "D-3", text: "No new hires" }] }] });
    expect(await r.json()).toEqual({ results: [{ id: "D-5", supersedes: "D-2" }, { id: "D-6", supersedes: null }] });
  });

  it("tell_ask_suggests_only_for_listed_people", async () => {
    const u = await user("Tell");
    answers = [{ results: [{ id: "D-5", suggestions: [{ person: "P-1", kind: "tell", title: "Tell Anna the offsite moved" },
      { person: "P-9", kind: "ask", title: "Ask a stranger" }, { person: "P-1", kind: "shout", title: "x" }] }] }];
    const r = await post(u.key, "/v2/decisions/tell-ask", { items: [{ id: "D-5", text: "Move the offsite", people: [{ id: "P-1", name: "Anna" }] }] });
    expect(await r.json()).toEqual({ results: [{ id: "D-5", suggestions: [{ person: "P-1", kind: "tell", title: "Tell Anna the offsite moved" }] }] });
  });
});

describe("decisions: rulebook", () => {
  it("rulebook_listed_and_owner_copy_saved", async () => {
    const u = await user("Book");
    const books = await (await call("/v2/rulebook", { key: u.key })).json<any>();
    expect(books.rulebooks.map((b: any) => b.key)).toContain("decisions");
    const r = await call("/v2/settings", { method: "PUT", key: u.key, body: JSON.stringify({ version: 5, values: { rulebook_decisions: "Mine\n- Not a decision: \"x\"" } }) });
    expect(r.status).toBe(200);
    expect((await env.DB.prepare("SELECT rulebook_decisions r FROM settings WHERE user_id=?").bind(u.id).first<any>()).r).toContain("Mine");
    const status = await (await call("/v2/status", { key: u.key })).json<any>();
    expect(status.schema.map((f: any) => f.key)).toContain("rulebook_decisions");
  });
});

describe("decisions: phone copy and actions", () => {
  const d = (n: number, over: Record<string, unknown> = {}) => ({ id: `D-${n}`, text: `Decision ${n}`, quote: "q", source: "J-1", recorded: "2026-11-10",
    decided: "", type: "operational", status: "decided", found_by: "claude", why: "", expected: "", expected_later: false, confidence: "",
    confidence_later: false, tags: ["Work"], people: [], review_due: "2026-12-10", review: "scheduled", this_week: true, ...over });

  it("mac_copy_reaches_the_phone_and_actions_come_back_once", async () => {
    const u = await user("Phone");
    const { cookie } = await pairPhone(u.key);
    expect((await call("/v2/decisions", { method: "PUT", key: u.key, body: JSON.stringify({ decisions: [d(1, { review: "due" }), d(2)] }) })).status).toBe(200);
    const raw = await env.DB.prepare("SELECT data_enc FROM decision_copies WHERE user_id=?").bind(u.id).first<any>();
    expect(raw.data_enc).not.toContain("Decision 1");
    const phone = await (await call("/app/api/decisions", { headers: { Cookie: cookie } })).json<any>();
    expect(phone.decisions.map((x: any) => x.id)).toEqual(["D-1", "D-2"]);
    const act = (body: unknown, origin = BASE) => call("/app/api/decisions/action", { method: "POST", headers: { Cookie: cookie, Origin: origin }, body: JSON.stringify(body) });
    const a1 = { id: "act-00000001", decision: "D-1", action: "review", happened: "It worked", sound: "Yes", made_at: "2026-11-15T10:00:00Z" };
    expect((await act({ actions: [a1, { id: "act-00000002", decision: "D-2", action: "not_decision" }] })).status).toBe(200);
    expect((await act({ actions: [a1] })).status).toBe(200);           // a repeat is applied once
    expect((await act({ actions: [a1] }, "https://evil.example")).status).toBe(403);
    expect((await act({ actions: [{ id: "act-00000003", decision: "T-1", action: "review" }] })).status).toBe(400);
    expect((await act({ actions: [{ id: "act-00000004", decision: "D-1", action: "delete" }] })).status).toBe(400);
    const stored = await env.DB.prepare("SELECT payload_enc FROM decision_actions WHERE user_id=? AND client_id='act-00000001'").bind(u.id).first<any>();
    expect(stored.payload_enc).not.toContain("It worked");
    const mac = await (await call("/v2/decision-actions", { key: u.key })).json<any>();
    expect(mac.actions.map((x: any) => [x.id, x.decision, x.action, x.happened ?? null])).toEqual([
      ["act-00000001", "D-1", "review", "It worked"], ["act-00000002", "D-2", "not_decision", null]]);
    expect((await post(u.key, "/v2/decision-actions/ack", { ids: ["act-00000001", "act-00000002"] })).status).toBe(200);
    expect((await (await call("/v2/decision-actions", { key: u.key })).json<any>()).actions).toEqual([]);
    // The phone sees what is still waiting.
    expect((await (await call("/app/api/decisions", { headers: { Cookie: cookie } })).json<any>()).waiting).toBe(0);
  });

  it("phone_make_decision_is_queued_encrypted_and_reaches_the_mac", async () => {
    const u = await user("PhoneMake");
    const { cookie } = await pairPhone(u.key);
    const act = (body: unknown) => call("/app/api/decisions/action", { method: "POST", headers: { Cookie: cookie, Origin: BASE }, body: JSON.stringify(body) });
    const make = { id: "make-0000001", action: "make", text: "Keep the old supplier", why: "Cheaper", expected: "Costs flat", confidence: "medium",
      type: "operational", quote: "we decided to keep the old supplier", source: "phone:abc-123", made_at: "2026-11-15T10:00:00Z" };
    expect((await act({ actions: [make] })).status).toBe(200);
    expect((await act({ actions: [{ ...make, id: "make-0000002", text: "  " }] })).status).toBe(400);
    expect((await act({ actions: [{ ...make, id: "make-0000003", confidence: "certain" }] })).status).toBe(400);
    expect((await act({ actions: [{ ...make, id: "make-0000004", source: "<script>" }] })).status).toBe(400);
    const stored = await env.DB.prepare("SELECT payload_enc, decision FROM decision_actions WHERE user_id=? AND client_id='make-0000001'").bind(u.id).first<any>();
    expect(stored.decision).toBe("");
    expect(stored.payload_enc).not.toContain("supplier");
    const mac = await (await call("/v2/decision-actions", { key: u.key })).json<any>();
    expect(mac.actions).toEqual([{ id: "make-0000001", decision: "", action: "make", made_at: "2026-11-15T10:00:00Z", text: "Keep the old supplier",
      why: "Cheaper", expected: "Costs flat", confidence: "medium", type: "operational", quote: "we decided to keep the old supplier", source: "phone:abc-123" }]);
  });

  it("phone_fills_the_form_with_the_shared_fill_form_job", async () => {
    const u = await user("PhoneFill");
    const { cookie } = await pairPhone(u.key);
    const fill = (body: unknown, origin = BASE) => call("/app/api/decisions/fill", { method: "POST", headers: { Cookie: cookie, Origin: origin }, body: JSON.stringify(body) });
    answers = [{ decision: "Keep the old supplier", why: "", expected: "", confidence: "", type: "operational", alternatives: "" }];
    const r = await fill({ selection: "We decided to keep the old supplier." });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ decision: "Keep the old supplier", why: "not recorded", expected: "", confidence: null, type: "operational", alternatives: "" });
    expect((await env.DB.prepare("SELECT job FROM llm_usage WHERE user_id=?").bind(u.id).first<any>()).job).toBe("fill_form");
    expect((await fill({ selection: "x" }, "https://evil.example")).status).toBe(403);
    expect((await fill({ selection: "" })).status).toBe(400);
    expect((await call("/app/api/decisions/fill", { method: "POST", headers: { Origin: BASE }, body: "{}" })).status).toBe(401);
  });

  it("phone_actions_and_copy_are_bound_to_the_signed_in_account", async () => {
    const a = await user("AcctA"), b = await user("AcctB");
    const pa = await pairPhone(a.key), pb = await pairPhone(b.key);
    await call("/v2/decisions", { method: "PUT", key: a.key, body: JSON.stringify({ decisions: [d(1)] }) });
    const ga = await (await call("/app/api/decisions", { headers: { Cookie: pa.cookie } })).json<any>();
    const gb = await (await call("/app/api/decisions", { headers: { Cookie: pb.cookie } })).json<any>();
    expect(typeof ga.account).toBe("string");
    expect(ga.account).not.toBe(gb.account);
    expect(gb.decisions).toEqual([]);
    const r = await call("/app/api/decisions/action", { method: "POST", headers: { Cookie: pb.cookie, Origin: BASE },
      body: JSON.stringify({ actions: [{ id: "act-0000b001", decision: "D-1", action: "not_decision" }] }) });
    expect((await r.json<any>()).account).toBe(gb.account);
    expect((await (await call("/v2/decision-actions", { key: a.key })).json<any>()).actions).toEqual([]);
    expect((await (await call("/v2/decision-actions", { key: b.key })).json<any>()).actions.map((x: any) => x.id)).toEqual(["act-0000b001"]);
  });

  it("phone_needs_a_session_and_copy_is_checked", async () => {
    expect((await call("/app/api/decisions")).status).toBe(401);
    const u = await user("Check");
    expect((await call("/v2/decisions", { method: "PUT", key: u.key, body: JSON.stringify({ decisions: "nope" }) })).status).toBe(400);
    expect((await call("/v2/decisions", { method: "PUT", key: u.key, body: JSON.stringify({ decisions: [{ id: "X-1" }] }) })).status).toBe(400);
    const { cookie } = await pairPhone(u.key);
    expect((await (await call("/app/api/decisions", { headers: { Cookie: cookie } })).json<any>())).toMatchObject({ decisions: [], updated: null, waiting: 0 });
  });
});
