import { describe, expect, it } from "vitest";
import { CIRCLE_EXPORTS, CIRCLE_JS, CIRCLE_LOGIC_JS } from "../../src/phone/circle-client";
import { APP_JS } from "../../src/phone/client";
import { SW_JS } from "../../src/phone/sw";
import { PAGE_HTML } from "../../src/phone/page";

/** The phone's Circle logic: the exact text embedded in /app/app.js, run here on its own. */
// eslint-disable-next-line no-new-func
const L: any = new Function(CIRCLE_LOGIC_JS + "\nreturn {" + CIRCLE_EXPORTS.join(",") + "};")();
const NOW = Date.parse("2026-11-18T12:00:00Z");

const copy = { due: ["P-1", "P-2"], people: [
  { id: "P-1", name: "Kim Example", company: "Northwind", tags: ["Investor"], due: true, wa: "447700900777" },
  { id: "P-2", name: "José Example", company: "", tags: [], due: true, email: "jose@example.com" },
  { id: "P-3", name: "王美玲", company: "华夏科技", tags: [], due: false },
  { name: "no id" },
] };

describe("phone Circle", () => {
  it("is_embedded_in_the_app_script_and_page", () => {
    expect(APP_JS).toContain(CIRCLE_JS);
    expect(APP_JS).not.toContain("/*@CIRCLE_JS@*/");
    expect(PAGE_HTML).toContain('id="circle-list"');
    expect(PAGE_HTML).toContain('id="plan-circle"');
  });

  it("view_takes_queued_taps_off_the_due_list_at_once", () => {
    const v = L.circleView(copy, [L.circleAction("P-1", "contacted", "a1", "2026-11-18T12:00:00Z")], NOW);
    expect(v.due.map((p: any) => p.id)).toEqual(["P-2"]);
    expect(v.people).toHaveLength(3);
    expect(v.people[0]).toMatchObject({ id: "P-1", due: false, waiting: "contacted" });
    expect(L.circleView(null, [], NOW)).toEqual({ people: [], due: [] });
  });

  it("search_matches_names_companies_tags_accents_and_chinese", () => {
    expect(L.circleSearch(copy.people.slice(0, 3), "jose").map((p: any) => p.id)).toEqual(["P-2"]);
    expect(L.circleSearch(copy.people.slice(0, 3), "north investor").map((p: any) => p.id)).toEqual(["P-1"]);
    expect(L.circleSearch(copy.people.slice(0, 3), "华夏").map((p: any) => p.id)).toEqual(["P-3"]);
  });

  it("badge_counts_overdue_tasks_and_due_people", () => {
    const cards = [
      { status: "todo", due: "2026-11-10", has_time: false },
      { status: "todo", due: "2026-11-18T09:00:00Z", has_time: true },
      { status: "done", due: "2026-11-01", has_time: false },
      { status: "todo", due: "2026-12-01", has_time: false },
    ];
    expect(L.badgeCount(cards, 2, NOW)).toBe(4);
    expect(L.badgeCount([], 0, NOW)).toBe(0);
  });

  it("draft_opens_whatsapp_or_gmail_with_the_text", () => {
    expect(L.draftLink(copy.people[0], "Hi Kim & co")).toBe("https://wa.me/447700900777?text=Hi%20Kim%20%26%20co");
    expect(L.draftLink(copy.people[1], "Hola")).toBe("https://mail.google.com/mail/?view=cm&to=jose%40example.com&body=Hola");
    expect(L.draftLink(copy.people[2], "x")).toBeNull();
  });

  it("notification_button_fallback_and_ages", () => {
    expect(L.circleHash("#circle=contacted:P-12")).toEqual({ action: "contacted", person: "P-12" });
    expect(L.circleHash("#circle=dance:P-12")).toBeNull();
    expect(L.circleAgo(null, NOW)).toBe("never");
    expect(L.circleAgo("2026-11-15T12:00:00Z", NOW)).toBe("3 days ago");
  });

  it("a_late_answer_from_another_session_or_account_is_dropped", () => {
    // Circle uses the app's shared session check (sessionAccepts, tested in test/phone/foundation.test.ts).
    expect(CIRCLE_JS).toContain("var asked = sessionStamp();");
    expect(CIRCLE_JS).toContain("return sameSession(asked, respAccount);");
    expect(CIRCLE_JS).not.toMatch(/circleEpoch|circleSnap|circleAccept/);
  });

  it("sign_out_clears_circles_phone_cache", () => {
    expect(CIRCLE_JS).toMatch(/function circleDrop\(\)[\s\S]*?store\(CIRCLE_KEY, null\)/);
    expect(APP_JS).toMatch(/function dropAccountData\(\) \{\s*sessionGen \+= 1;[\s\S]*?circleDrop\(\)/);
  });

  it("a_link_never_marks_anyone_by_itself_it_asks_first", () => {
    const people = copy.people.slice(0, 3);
    expect(L.circleConfirm({ action: "talked", person: "P-1" }, people)).toEqual({ action: "talked", person: "P-1", text: "Mark talked to Kim Example?" });
    expect(L.circleConfirm({ action: "contacted", person: "P-2" }, people).text).toBe("Mark José Example as contacted?");
    expect(L.circleConfirm({ action: "snooze", person: "P-3" }, people).text).toBe("Snooze 王美玲?");
    expect(L.circleConfirm({ action: "talked", person: "P-99" }, people)).toBeNull();   // someone not on this phone: nothing shown
    const body = /function circleFromHash\(\) \{([\s\S]*?)\n  \}\n/.exec(CIRCLE_JS)![1];
    expect(body).toContain("openSheet");
    expect(body.indexOf("circleAct(")).toBeGreaterThan(body.indexOf('addEventListener("click"'));
  });

  it("a_link_waits_for_the_copy_and_account_before_it_is_cleared", () => {
    // Round 7 (J): on first launch or right after a switch the copy (or the account) isn't there yet: the link waits.
    const acc = "a".repeat(32), hash = "#circle=talked:P-1:" + acc;
    expect(L.circleLinkStep("", copy, acc)).toEqual({ step: "none" });
    expect(L.circleLinkStep(hash, null, acc)).toEqual({ step: "wait" });
    expect(L.circleLinkStep(hash, copy, null)).toEqual({ step: "wait" });
    expect(L.circleLinkStep(hash, copy, acc)).toMatchObject({ step: "ask", confirm: { person: "P-1", action: "talked" } });
    expect(L.circleLinkStep("#circle=talked:P-99:" + acc, copy, acc)).toEqual({ step: "drop" });          // nobody on this phone
    expect(L.circleLinkStep(hash, copy, "b".repeat(32))).toEqual({ step: "drop" });                        // another account's alert
    // The app clears the address only once the sheet is shown (or the link can never be shown), and tries again after
    // each copy it loads.
    const fn = (name: string) => new RegExp("function " + name + "\\([^)]*\\) \\{([\\s\\S]*?)\\n  \\}\\n").exec(CIRCLE_JS)![1];
    const body = fn("circleFromHash");
    expect(body.indexOf("history.replaceState")).toBeGreaterThan(body.indexOf("circleLinkStep("));
    expect(body).toMatch(/step === "wait"\) return;/);
    expect(fn("circleSync")).toMatch(/circleCopy = got\.copy;[\s\S]*circleFromHash\(\)/);
  });

  it("a_link_from_another_accounts_notification_shows_nothing", () => {
    const acc = "a".repeat(32), other = "b".repeat(32);
    const h = L.circleHash("#circle=talked:P-1:" + acc);
    expect(h).toEqual({ action: "talked", person: "P-1", account: acc });
    expect(L.circleConfirm(h, copy.people.slice(0, 3), acc)?.person).toBe("P-1");
    expect(L.circleConfirm(h, copy.people.slice(0, 3), other)).toBeNull();
    expect(SW_JS).toContain("account");
    expect(SW_JS).toMatch(/r\.status === 409/);
    expect(SW_JS).toMatch(/#circle=" \+ action \+ ":" \+ person \+ \(account \? ":" \+ account : ""\)/);   // none for an old alert
  });

  it("a_circle_sheet_never_acts_for_another_account_and_closes_on_sign_out", () => {
    const fn = (name: string) => new RegExp("function " + name + "\\([^)]*\\) \\{([\\s\\S]*?)\\n  \\}\\n").exec(CIRCLE_JS)![1];
    // Every tap is checked against the session and account the screen or sheet was opened under.
    // The app's shared session check (sessionStamp / sameSession in app.client.js), as for sync.
    expect(fn("circleAct")).toMatch(/sameSession\(asked\)/);
    for (const name of ["circleFromHash", "personSheet", "draftSheet", "circlePlan"]) {
      const body = fn(name);
      expect(body, name).toMatch(/var asked = sessionStamp\(\)/);
      for (const call of body.match(/circleAct\([^)]*\)/g) ?? []) expect(call, name).toMatch(/asked\)$/);
    }
    expect(fn("draftSheet")).toMatch(/if \(!sameSession\(asked\)\)/);   // a late draft for the old account is dropped
    expect(fn("circleDrop")).toMatch(/\.sheet\[data-circle\][\s\S]*closeSheet\(\)/);
    expect((CIRCLE_JS.match(/sheet\.dataset\.circle = "1"/g) ?? []).length).toBe(3);
  });

  it("service_worker_adds_contacted_and_snooze_to_circle_alerts", () => {
    expect(SW_JS).toContain('action: "contacted", title: "Contacted"');
    expect(SW_JS).toContain('action: "snooze", title: "Snooze"');
    expect(SW_JS).toContain("/app/api/circle/action");
  });
});
