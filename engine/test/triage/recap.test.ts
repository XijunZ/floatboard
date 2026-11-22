import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { summariseRecap, storeRecap } from "../../src/triage/recap";
import { makeClient, HAIKU } from "../../src/lib/llm";
import { newUser } from "../helpers";
import type { Message } from "../../src/sources/types";

const recap = (over: Partial<Message> = {}): Message => ({
  messageId: "<r1@fathom>", sourceId: "s", from: "Fathom <no-reply@fathom.video>", to: ["me@gmail.com"], cc: [],
  subject: "Recap: Weekly planning with Sam", date: "Sun, 08 Nov 2026 13:10:00 +0000",
  labels: [], headers: {}, text: "Meeting summary... https://meet.google.com/abc-defg-hij ...", link: "https://fathom.video/r/1", ...over,
});
let lastBody: any = null;
function fakeClaude(obj: unknown) {
  const f = async (_u: unknown, init?: RequestInit) => { lastBody = JSON.parse(String(init?.body)); return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn",
    stop_sequence: null, content: [{ type: "text", text: JSON.stringify(obj) }], usage: { input_tokens: 1, output_tokens: 1 } }); };
  return makeClient("sk-test", f as typeof fetch);
}

describe("meeting recaps", () => {
  it("follow_ups_become_actions", async () => {
    const u = await newUser("X");
    const client = fakeClaude({ decisions: ["Start in spring"], next_steps: ["Sam shares the budget"],
      my_actions: [{ title: "Draft the project one-pager for Sam", due: "2026-11-12", has_time: false, importance: 2 }] });
    const res = await summariseRecap(recap(), client);
    const r = res.ok ? res.recap : null;
    expect(r!.summary).toContain("Decisions: Start in spring");
    expect(r!.summary).toContain("Next steps: Sam shares the budget");
    expect(r!.summary.length).toBeLessThanOrEqual(700);
    await storeRecap(env as any, u.id, recap(), r!);
    const rows = await env.DB.prepare("SELECT kind, title, task_ref, summary FROM items WHERE user_id=? ORDER BY kind").bind(u.id).all<any>();
    expect(rows.results.map((x) => x.kind)).toEqual(["action", "summary"]);
    expect(rows.results[0].title).toBe("Draft the project one-pager for Sam");
    expect(rows.results[1].task_ref).toBeNull();
  });

  it("follow_ups_carry_the_meeting_notes", async () => {
    const u = await newUser("X");
    const client = fakeClaude({ decisions: ["Start in spring"], next_steps: [],
      my_actions: [{ title: "Draft the one-pager", due: null, has_time: false, importance: 1 }] });
    const res = await summariseRecap(recap(), client);
    await storeRecap(env as any, u.id, recap(), res.ok ? res.recap : null!);
    const a = await env.DB.prepare("SELECT summary FROM items WHERE user_id=? AND kind='action'").bind(u.id).first<any>();
    expect(a.summary).toContain("Decisions: Start in spring");
    expect(a.summary).toContain("Full notes: https://fathom.video/r/1");
  });

  it("follow_ups_get_a_group_and_only_the_users_own_actions", async () => {
    const u = await newUser("X");
    const client = fakeClaude({ decisions: [], next_steps: [], my_actions: [
      { title: "Send the target list to John", due: null, has_time: false, importance: 1, group: "Entrepreneurship" },
      { title: "Book the dentist", due: null, has_time: false, importance: 0, group: "Not a group" },
    ] });
    const ctx = { name: "Robin", groups: ["Entrepreneurship", "Personal"], groupNotes: { Entrepreneurship: "search fund ideas" }, myRules: "" };
    const res = await summariseRecap(recap(), client, ctx);
    const prompt = lastBody.system + JSON.stringify(lastBody.messages);
    expect(prompt).toContain("The attendee is Robin.");
    expect(prompt).toContain("Entrepreneurship: search fund ideas");
    expect(prompt).toMatch(/owned by other people are not my_actions/);
    await storeRecap(env as any, u.id, recap(), res.ok ? res.recap : null!);
    const rows = await env.DB.prepare("SELECT title, group_name FROM items WHERE user_id=? AND kind='action' ORDER BY title").bind(u.id).all<any>();
    expect(rows.results).toEqual([
      { title: "Book the dentist", group_name: null },
      { title: "Send the target list to John", group_name: "Entrepreneurship" },
    ]);
  });
});

// Round 40 (Codex 28): a webhook and the recap email for the same meeting arriving together are judged once; the
// second waits on the first's claim instead of making a second set of follow-ups.
describe("recaps delivered twice at once", () => {
  it("a_webhook_and_an_email_for_one_meeting_are_judged_once_and_store_one_set_of_follow_ups", async () => {
    const { processRecap } = await import("../../src/triage/recap");
    const { encrypt } = await import("../../src/lib/crypto");
    const u = await newUser("RC2");
    await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
    let judged = 0;
    const slow = (async () => {
      judged++;
      await new Promise((r) => setTimeout(r, 40));   // both deliveries are past the "already known?" test by now
      return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
        content: [{ type: "text", text: JSON.stringify({ decisions: [], next_steps: [], my_actions: [{ title: "Send Sam the deck", due: null, has_time: false, importance: 1 }] }) }],
        usage: { input_tokens: 1, output_tokens: 1 } });
    }) as typeof fetch;
    const share = "Full notes https://fathom.video/share/AbCdEf123456";
    const [a, b] = await Promise.all([
      processRecap(env as any, u.id, recap({ messageId: "fathom-webhook-1", text: share, link: "https://fathom.video/share/AbCdEf123456" }), slow),
      processRecap(env as any, u.id, recap({ messageId: "<email-1@fathom>", text: share, link: "https://fathom.video/share/AbCdEf123456" }), slow),
    ]);
    expect([a.status, b.status].sort()).toEqual(["busy", "stored"]);   // round 41: the second is told to try again
    expect(judged).toBe(1);
    const again = await processRecap(env as any, u.id, recap({ messageId: "<email-1@fathom>", text: share, link: "https://fathom.video/share/AbCdEf123456" }), slow);
    expect(again.status).toBe("duplicate");
    const actions = await env.DB.prepare("SELECT title FROM items WHERE user_id=? AND kind='action'").bind(u.id).all();
    expect(actions.results.length).toBe(1);
  });
});

// Round 41 (Codex 31): a meeting claimed by a delivery that hasn't finished is "busy" (retried), never "already handled";
// a claim left by a delivery that died is taken over once it is stale.
describe("a recap claimed by a delivery that died", () => {
  it("is_busy_while_the_claim_is_fresh_and_stored_by_a_retry_once_it_is_stale", async () => {
    const { processRecap, claimRecap, recapKnown } = await import("../../src/triage/recap");
    const { recapKeys } = await import("../../src/sources/fathom");
    const u = await newUser("RC3");
    const m = recap({ messageId: "fathom-webhook-9", text: "https://fathom.video/share/Zz99Yy88", link: "https://fathom.video/share/Zz99Yy88" });
    const keys = recapKeys(m);
    expect(await claimRecap(env as any, u.id, keys)).not.toBeNull();   // the first delivery claimed it, then died
    expect(await recapKnown(env as any, u.id, keys)).toBe(false);
    expect((await processRecap(env as any, u.id, m)).status).toBe("busy");
    // Ten minutes later the claim is stale: a retry stores the notes.
    await env.DB.prepare("UPDATE recap_keys SET created=? WHERE user_id=?").bind(new Date(Date.now() - 11 * 60e3).toISOString(), u.id).run();
    expect((await processRecap(env as any, u.id, m)).status).toBe("stored");
    expect((await processRecap(env as any, u.id, m)).status).toBe("duplicate");
  });
});

// Round 42 (Codex 32): "duplicate" only when the meeting is really stored.
describe("a claim released while another delivery checks it", () => {
  it("a_release_between_the_claim_and_the_busy_check_never_reads_as_duplicate", async () => {
    const { processRecap, claimRecap, releaseRecap } = await import("../../src/triage/recap");
    const { recapKeys } = await import("../../src/sources/fathom");
    const u = await newUser("RC4");
    const m = recap({ messageId: "fathom-webhook-r42", text: "https://fathom.video/share/Rr42Qq", link: "https://fathom.video/share/Rr42Qq" });
    const other = await claimRecap(env as any, u.id, recapKeys(m));   // another delivery holds it
    const out = await processRecap(env as any, u.id, m, undefined, { afterClaimMiss: async () => { await releaseRecap(env as any, u.id, other!); } });
    expect(out.status).not.toBe("duplicate");
    const stored = await env.DB.prepare("SELECT count(*) AS n FROM items WHERE user_id=? AND kind='summary'").bind(u.id).first<{ n: number }>();
    expect(out.status === "stored" ? stored?.n : 1).toBe(1);
  });
});
