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
    expect(JSON.parse(b.storage.get("floatboard.capturedraft:acc-a") ?? "null")?.title).toBe("Call the venue back, again");
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
});
