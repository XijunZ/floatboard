// Round 34 (Codex 24): the phone app run whole (test/phone/app-harness.ts), two tabs sharing one browser's storage.
import { describe, expect, it } from "vitest";
import { fakeChannels, fakeLocks, runApp } from "./app-harness";

const flush = async (n = 20) => { for (let i = 0; i < n; i++) await new Promise((r) => setTimeout(r, 0)); };
const ok = (body: any) => ({ status: 200, body });
const board = (account: string) => ok({ account, cards: [], updated: "2026-11-21T10:00:00.000Z", pending: 0 });
const me = (account: string) => ok({ account, device: "phone", user: "owner" });
const never = () => new Promise<any>(() => {});

function browser(account = "acc-a") {
  const storage = new Map<string, string>();
  storage.set("floatboard.queue", JSON.stringify({ account, actions: [{ id: "a1", made_at: "2026-11-21T09:00:00.000Z", action: "add", title: "first" }] }));
  storage.set("floatboard.board", JSON.stringify({ account, board: { cards: [], updated: null, pending: 0 }, at: Date.now() }));
  return { storage, locks: fakeLocks(), Channel: fakeChannels() };
}

describe("phone app run whole: tabs and accounts (round 34)", () => {
  it("a_delayed_me_answer_after_handover_never_touches_storage", async () => {
    const b = browser();
    let answerMe: (r: any) => void = () => {};
    const one = runApp({ ...b, reply: (p) => (p === "/app/api/me" ? new Promise((r) => { answerMe = r; }) : board("acc-a")) });
    await flush();
    const two = runApp({ ...b, reply: (p) => (p === "/app/api/me" ? me("acc-a") : p === "/app/api/action" ? never() : board("acc-a")) });
    await flush();
    two.byId("use-here").fire("click"); await flush();
    expect(two.byId("elsewhere").hidden).toBe(true);
    // The new active tab has kept a capture of its own.
    b.storage.set("floatboard.queue", JSON.stringify({ account: "acc-a", actions: [{ id: "a1" }, { id: "new-capture" }] }));
    const before = new Map(b.storage);
    answerMe(me("acc-b"));   // the old tab's /me finally answers, naming another account
    await flush();
    expect(new Map(b.storage)).toEqual(before);
    one.stop(); two.stop();
  });

  it("an_unsaved_capture_form_survives_handover_and_an_account_switch", async () => {
    const b = browser();
    let full = false;
    let boardAccount = "acc-a";
    const one = runApp({ ...b, storageFails: () => full, reply: (p) => (p === "/app/api/me" ? me("acc-a") : p === "/app/api/action" ? never() : board(boardAccount)) });
    await flush();
    one.byId("add").fire("click");
    one.find("add-title").value = "Call the venue back";
    full = true;
    [...one.created].reverse().find((e) => e.tagName === "FORM").fire("submit");
    expect(one.toasts).toContain("Couldn't save on this phone: storage full");
    full = false;
    // Handover: the words go with it.
    const sent = (init: any) => ok({ ...board(boardAccount).body, accepted: JSON.parse(init.body).actions.map((a: any) => a.id) });
    const two = runApp({ ...b, reply: (p, init) => (p === "/app/api/me" ? me("acc-a") : p === "/app/api/action" ? sent(init) : board(boardAccount)) });
    await flush();
    two.byId("use-here").fire("click"); await flush();
    expect(two.byId("elsewhere").hidden).toBe(true);
    expect(two.find("add-title")?.value).toBe("Call the venue back");
    expect(two.toasts).toContain("Unsaved capture recovered");
    // Account switch: the open form's words are kept for the account they were written under.
    two.find("add-title").value = "Call the venue back, again";
    boardAccount = "acc-b";
    two.byId("refresh").fire("click"); await flush();
    expect(JSON.parse(b.storage.get("floatboard.capturedraft:acc-a") ?? "[]").map((d: any) => d.title)).toEqual(["Call the venue back, again"]);
    one.stop(); two.stop();
  });

  it("the_old_owner_record_is_kept_until_this_tab_holds_the_lock", async () => {
    const b = browser();
    let releaseOld: () => void = () => {};
    b.locks.request("floatboard-active", {}, () => new Promise<void>((r) => { releaseOld = r; }));   // a tab of the older version
    b.storage.set("floatboard.activeTab", JSON.stringify({ id: "old-tab", at: Date.now() }));
    const two = runApp({ ...b, reply: (p) => (p === "/app/api/me" ? me("acc-a") : p === "/app/api/action" ? never() : board("acc-a")) });
    await flush();
    expect(b.storage.has("floatboard.activeTab")).toBe(true);
    two.byId("use-here").fire("click"); await flush();
    releaseOld(); await flush();
    expect(two.byId("elsewhere").hidden).toBe(true);
    expect(b.storage.has("floatboard.activeTab")).toBe(false);
    two.stop();
  });

  // Round 35 (Codex 25).
  const draftOf = (b: { storage: Map<string, string> }, account: string) => b.storage.get("floatboard.capturedraft:" + account) ?? "";

  // Tab one has words in its Add form when tab two takes over: they become a draft for tab two.
  async function handOverWithDraft(b: ReturnType<typeof browser>, twoReply: (p: string, init: any) => any) {
    const one = runApp({ ...b, reply: (p) => (p === "/app/api/me" ? me("acc-a") : p === "/app/api/action" ? never() : board("acc-a")) });
    await flush();
    one.byId("add").fire("click");
    one.find("add-title").value = "Recovered words";
    const two = runApp({ ...b, reply: twoReply });
    await flush();
    two.byId("use-here").fire("click"); await flush();
    return { one, two };
  }

  it("a_draft_never_replaces_an_add_form_already_open_and_stays_stored", async () => {
    const b = browser();
    let answerMe: (r: any) => void = () => {};
    const { one, two } = await handOverWithDraft(b, (p) => (p === "/app/api/me" ? new Promise((r) => { answerMe = r; }) : p === "/app/api/action" ? never() : board("acc-a")));
    expect(two.byId("elsewhere").hidden).toBe(true);
    expect(draftOf(b, "acc-a")).toContain("Recovered words");
    two.byId("add").fire("click");                              // the cached board is up: a new capture while /me is slow
    const typing = two.find("add-title");
    typing.value = "Fresh words";
    answerMe(me("acc-a")); await flush();
    expect(two.find("add-title")).toBe(typing);                  // the open form is left alone
    expect(typing.value).toBe("Fresh words");
    expect(draftOf(b, "acc-a")).toContain("Recovered words");   // and the draft waits
    one.stop(); two.stop();
  });

  it("a_recovered_draft_is_kept_with_its_edits_when_the_form_closes_on_its_own", async () => {
    const b = browser();
    let answerBoard: (r: any) => void = () => {};
    const { one, two } = await handOverWithDraft(b, (p) => (p === "/app/api/me" ? me("acc-a") : new Promise((r) => { answerBoard = r; })));
    expect(two.find("add-title")?.value).toBe("Recovered words");
    two.find("add-title").value = "Recovered words, edited";
    answerBoard({ status: 401, body: { error: "signed out" } }); await flush();   // the sign-in screen closes the form
    expect(JSON.parse(draftOf(b, "acc-a")).map((d: any) => d.title)).toEqual(["Recovered words, edited"]);
    one.stop(); two.stop();
  });

  it("a_tab_that_stepped_down_mid_sign_out_never_signs_the_browser_out", async () => {
    const b = browser();
    const calls: string[] = [];
    let giveReg: (r: any) => void = () => {};
    let unsubscribed = false;
    const sub = { unsubscribe: async () => { unsubscribed = true; } };
    const ready = new Promise((r) => { giveReg = r; });
    const one = runApp({ ...b, push: { ready }, reply: (p, init) => { calls.push((init?.method ?? "GET") + " " + p); return p === "/app/api/me" ? me("acc-a") : p === "/app/api/action" ? never() : board("acc-a"); } });
    await flush();
    one.byId("signout").fire("click"); await flush();
    const two = runApp({ ...b, reply: (p) => (p === "/app/api/me" ? me("acc-a") : p === "/app/api/action" ? never() : board("acc-a")) });
    await flush();
    two.byId("use-here").fire("click"); await flush();
    expect(two.byId("elsewhere").hidden).toBe(true);
    calls.length = 0;
    giveReg({ pushManager: { getSubscription: async () => sub } }); await flush();
    expect(calls).toEqual([]);
    expect(unsubscribed).toBe(false);
    one.stop(); two.stop();
  });

  it("a_round_34_single_draft_is_read_as_a_list_and_comes_back", async () => {
    const b = browser();
    b.storage.set("floatboard.capturedraft:acc-a", JSON.stringify({ title: "Words from the older version", group: "" }));
    const one = runApp({ ...b, reply: (p, init) => (p === "/app/api/me" ? me("acc-a") : p === "/app/api/action" ? never() : board("acc-a")) });
    await flush();
    expect(one.find("add-title")?.value).toBe("Words from the older version");
    expect(JSON.parse(draftOf(b, "acc-a")).map((d: any) => d.title)).toEqual(["Words from the older version"]);   // now a list
    [...one.created].reverse().find((e) => e.tagName === "FORM").fire("submit");   // queued: the draft goes
    expect(JSON.parse(draftOf(b, "acc-a") || "null")).toBeNull();
    expect(one.toasts).toContain("Unsaved capture recovered");
    one.stop();
  });

  // Round 36 (Codex 26).
  it("an_add_form_whose_words_cannot_be_kept_is_never_removed_on_a_sign_in_prompt", async () => {
    const b = browser();
    let full = false, signedOut = false;
    const accept = (init: any) => ok({ ...board("acc-a").body, accepted: JSON.parse(init.body).actions.map((a: any) => a.id) });
    const one = runApp({ ...b, storageFails: () => full, reply: (p, init) => (signedOut ? { status: 401, body: {} } : p === "/app/api/me" ? me("acc-a") : p === "/app/api/action" ? accept(init) : board("acc-a")) });
    await flush();
    one.byId("add").fire("click");
    one.find("add-title").value = "Words the phone can't keep yet";
    full = true; signedOut = true;
    one.byId("refresh").fire("click"); await flush();          // 401: the sign-in screen, while storage is full
    expect(one.toasts).toContain("Couldn't save on this phone: storage full");
    full = false;
    // The form (and its words) is still there: a later handover keeps them as a draft.
    const two = runApp({ ...b, reply: (p) => (p === "/app/api/me" ? me("acc-a") : p === "/app/api/action" ? never() : board("acc-a")) });
    await flush();
    two.byId("use-here").fire("click"); await flush();
    expect(draftOf(b, "acc-a")).toContain("Words the phone can't keep yet");
    one.stop(); two.stop();
  });

  it("a_tab_that_stepped_down_while_turning_notifications_off_leaves_the_subscription", async () => {
    const b = browser();
    let giveReg: (r: any) => void = () => {};
    let unsubscribed = false;
    const sub = { unsubscribe: async () => { unsubscribed = true; } };
    const ready = new Promise((r) => { giveReg = r; });
    const one = runApp({ ...b, push: { ready }, reply: (p) => (p === "/app/api/me" ? me("acc-a") : p === "/app/api/action" ? never() : board("acc-a")) });
    await flush();
    one.byId("notif-off").fire("click"); await flush();
    const two = runApp({ ...b, reply: (p) => (p === "/app/api/me" ? me("acc-a") : p === "/app/api/action" ? never() : board("acc-a")) });
    await flush();
    two.byId("use-here").fire("click"); await flush();
    expect(two.byId("elsewhere").hidden).toBe(true);
    giveReg({ pushManager: { getSubscription: async () => sub, subscribe: async () => sub } }); await flush();
    expect(unsubscribed).toBe(false);
    one.stop(); two.stop();
  });
});
