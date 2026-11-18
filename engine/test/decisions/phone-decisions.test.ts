import { describe, expect, it } from "vitest";
import { DECISIONS_EXPORTS, DECISIONS_LOGIC_JS, DECISIONS_UI_JS } from "../../src/phone/decisions-client";
import { APP_JS } from "../../src/phone/client";
import { PAGE_HTML } from "../../src/phone/page";

/** More › Decisions on the phone: the pure parts, run here on their own (the same text the phone runs). */
// eslint-disable-next-line no-new-func
const L: any = new Function(DECISIONS_LOGIC_JS + "\nreturn {" + DECISIONS_EXPORTS.join(",") + "};")();

const d = (n: number, over: Record<string, unknown> = {}) => ({ id: `D-${n}`, text: `Decision ${n}`, quote: "", source: "J-1", recorded: "2026-11-10",
  decided: "", type: "operational", status: "decided", found_by: "claude", why: "", expected: "", expected_later: false, confidence: "",
  confidence_later: false, tags: [], people: [], review_due: "2026-12-10", review: "scheduled", this_week: false, ...over });
const at = "2026-11-15T10:00:00.000Z";

describe("phone decisions", () => {
  it("is_embedded_in_the_app_script_and_page", () => {
    expect(APP_JS).toContain(DECISIONS_LOGIC_JS);
    expect(APP_JS).toContain(DECISIONS_UI_JS);
    expect(APP_JS).not.toContain("@DECISIONS_");
    expect(PAGE_HTML).toContain('id="decisions"');
    expect(APP_JS).not.toContain("Decisions arrive here with the Decisions area.");
  });

  it("sections_due_this_week_maybe_earlier", () => {
    const s = L.decisionSections([d(1, { review: "due" }), d(2, { this_week: true }), d(3, { status: "maybe", this_week: true }), d(4)], []);
    expect([s.due, s.week, s.maybe, s.earlier].map((x: any[]) => x.map((y) => y.id))).toEqual([["D-1"], ["D-2"], ["D-3"], ["D-4"]]);
  });

  it("queued_actions_show_at_once", () => {
    const q = [L.reviewAction(d(1), "It worked", "", "act-00000001", at), L.notDecisionAction(d(2), "act-00000002", at)];
    const s = L.decisionSections([d(1, { review: "due" }), d(2, { this_week: true })], q);
    expect(s.due).toEqual([]);
    expect(s.week).toEqual([]);
    expect(s.earlier.map((x: any) => [x.id, x.review])).toEqual([["D-1", "done"]]);
  });

  it("actions_have_their_own_id_and_time_and_need_an_answer", () => {
    expect(L.reviewAction(d(1), "  ", "", "act-00000001", at)).toBeNull();
    expect(L.reviewAction(d(1), "Went well", "Mostly", "act-00000001", at))
      .toEqual({ id: "act-00000001", decision: "D-1", action: "review", happened: "Went well", sound: "Mostly", made_at: at });
    expect(L.notDecisionAction(d(2), "act-00000002", at)).toEqual({ id: "act-00000002", decision: "D-2", action: "not_decision", made_at: at });
    expect(L.canDismiss(d(2, { this_week: true }))).toBe(true);
    expect(L.canDismiss(d(3, { status: "maybe" }))).toBe(true);
    expect(L.canDismiss(d(4))).toBe(false);
  });

  it("queue_drops_accepted_and_lines_read_well", () => {
    const q = [{ id: "a" }, { id: "b" }];
    expect(L.decisionQueueAfter(q, ["a"])).toEqual([{ id: "b" }]);
    expect(L.decisionDetail(d(1, { type: "strategic", found_by: "you" }))).toBe("Strategic · recorded 2026-11-10");
    expect(L.decisionDetail(d(1))).toBe("Operational · recorded 2026-11-10 · found by Claude");
    expect(L.decisionPrediction(d(1))).toBe("Expected outcome: not recorded");
    expect(L.decisionPrediction(d(1, { expected: "More sales", expected_later: true, confidence: "high", confidence_later: true })))
      .toBe("Expected outcome: More sales (added later) · Confidence: high (added later)");
    expect(L.decisionsWaiting(0)).toBe("");
    expect(L.decisionsWaiting(2)).toBe("2 changes waiting for your Mac");
  });

  it("make_decision_form_is_filled_by_code_then_claude_in_untouched_fields", () => {
    const f = L.decisionFormStart("\n  We decided to keep the old supplier.\nMore text");
    expect(f).toEqual({ text: "We decided to keep the old supplier.", why: "not recorded", expected: "", confidence: "", type: "operational" });
    const answer = { decision: "Keep the old supplier", why: "Cheaper", expected: "Costs flat", confidence: "medium", type: "strategic" };
    expect(L.decisionFormFill({ ...f, why: "My own reason" }, { why: true }, answer))
      .toEqual({ text: "Keep the old supplier", why: "My own reason", expected: "Costs flat", confidence: "medium", type: "strategic" });
    expect(L.decisionFormFill(f, {}, { decision: "", confidence: "certain", type: "other" })).toEqual(f);
  });

  it("make_decision_action_carries_the_form_quote_and_jot", () => {
    const f = { text: " Keep the old supplier ", why: "not recorded", expected: "Costs flat", confidence: "low", type: "investment" };
    expect(L.makeDecisionAction(f, "we keep the old supplier", "phone:abc-1", "make-0000001", at)).toEqual({ id: "make-0000001", action: "make",
      text: "Keep the old supplier", why: "", expected: "Costs flat", confidence: "low", type: "investment", quote: "we keep the old supplier",
      source: "phone:abc-1", made_at: at });
    expect(L.makeDecisionAction({ ...f, text: "  " }, "q", "J-1", "make-0000002", at)).toBeNull();
    expect(L.makeDecisionAction({ ...f, confidence: "sure", type: "x" }, "q", "<bad>", "make-0000003", at))
      .toMatchObject({ confidence: "", type: "operational", source: "" });
  });

  it("jots_make_decision_opens_the_phone_form_not_a_mac_action", () => {
    expect(APP_JS).toContain("function decisionForm(");
    expect(APP_JS).toContain("h.makeDecision(");
    expect(APP_JS).toContain("/app/api/decisions/fill");
    expect(APP_JS).not.toContain('op: "make_decision"');
  });

  it("queue_sent_only_for_the_confirmed_account_it_was_made_under", () => {
    const q = { account: "acc-a", actions: [{ id: "x" }] };
    expect(L.decisionQueueSendable(q, null)).toBe(false);          // /app/api/me has not answered yet
    expect(L.decisionQueueSendable(q, "acc-b")).toBe(false);       // another account signed in
    expect(L.decisionQueueSendable({ account: null, actions: [{ id: "x" }] }, "acc-a")).toBe(false);
    expect(L.decisionQueueSendable({ account: "acc-a", actions: [] }, "acc-a")).toBe(false);
    expect(L.decisionQueueSendable(q, "acc-a")).toBe(true);
  });

  it("ui_sends_only_through_the_check_and_caches_under_the_engines_account", () => {
    expect(DECISIONS_UI_JS).toContain("decisionSendBody(decQueue, confirmedAccount())");
    expect(DECISIONS_UI_JS).not.toContain("shownAccount");
    // Signing out (and a change of account) drops the cached copy and the queue with the rest of the account's data.
    const drop = APP_JS.slice(APP_JS.indexOf("function dropAccountData()"));
    expect(drop.slice(0, drop.indexOf("\n  }\n"))).toContain("dropDecisions();");
  });

  it("send_body_carries_the_queue_account_and_at_most_50", () => {
    const actions = Array.from({ length: 60 }, (_, i) => ({ id: "a" + i }));
    expect(L.decisionSendBody({ account: "acc-a", actions }, null)).toBeNull();
    expect(L.decisionSendBody({ account: "acc-a", actions }, "acc-b")).toBeNull();
    const b = L.decisionSendBody({ account: "acc-a", actions }, "acc-a");
    expect(b.account).toBe("acc-a");
    expect(b.actions.length).toBe(50);
  });

  it("queue_retried_on_reconnect_and_sync_resume", () => {
    expect(DECISIONS_UI_JS).toContain('window.addEventListener("online", retryDecisionQueue)');
    expect(DECISIONS_UI_JS).toContain("decisionSendBody(decQueue, confirmedAccount())");
    const got = APP_JS.slice(APP_JS.indexOf("function gotBoard("));
    expect(got.slice(0, got.indexOf("\n  }\n"))).toContain("retryDecisionQueue();");
  });
});
