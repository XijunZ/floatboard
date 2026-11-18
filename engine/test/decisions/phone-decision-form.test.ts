import { describe, expect, it } from "vitest";
import { DECISIONS_LOGIC_JS, DECISIONS_UI_JS } from "../../src/phone/decisions-client";
import { SYNC_JS } from "../../src/phone/sync-logic";
import { APP_JS } from "../../src/phone/client";

// Codex review 3, findings 1-2: the phone's Make decision form, run for real (its script with a tiny fake page around it).

type Fake = { tag: string; children: Fake[]; listeners: Record<string, Function[]>; value: string; isConnected: boolean; textContent: string;
  appendChild(c: Fake): Fake; addEventListener(t: string, f: Function): void; setAttribute(): void; replaceChildren(): void; hidden?: boolean;
  style: Record<string, string>; id?: string; type?: string };

function harness(opts: { me?: { account: string } | null; shown?: string | null; storageFails?: boolean } = {}) {
  const made: Fake[] = [];
  const el = (tag: string, _cls?: string, text?: string): Fake => {
    const e: Fake = { tag, children: [], listeners: {}, value: "", isConnected: true, textContent: text ?? "", style: {},
      appendChild(c) { this.children.push(c); return c; }, addEventListener(t, f) { (this.listeners[t] ??= []).push(f); },
      setAttribute() {}, replaceChildren() { this.children = []; } };
    made.push(e);
    return e;
  };
  const storage: Record<string, string> = {};
  const toasts: string[] = [];
  let sheetOpen = false;
  const h = {
    el, $: () => el("div"), toasts, storage, made,
    load: (k: string) => (storage[k] ? JSON.parse(storage[k]) : null),
    store: (k: string, v: unknown) => { if (opts.storageFails) return; if (v == null) delete storage[k]; else storage[k] = JSON.stringify(v); },
    toast: (t: string) => { toasts.push(t); },
    openSheet: (fill: (s: Fake) => void) => { sheetOpen = true; fill(el("div")); },
    closeSheet: () => { sheetOpen = false; made.forEach((m) => { m.isConnected = false; }); },
    isOpen: () => sheetOpen,
    api: () => new Promise(() => {}),   // offline: nothing ever answers
    newId: () => "make-" + Math.random().toString(36).slice(2, 12),
    render: () => {}, showSignIn: () => {},
  };
  const src = `
    var me = H.me, shownAccount = H.shown, sessionGen = 0;
    var el = H.el, $ = H.$, load = H.load, store = H.store, toast = H.toast, openSheet = H.openSheet, closeSheet = H.closeSheet,
        api = H.api, newId = H.newId, render = H.render, showSignIn = H.showSignIn;
    var window = { addEventListener: function () {}, scrollTo: function () {} };
    var document = { addEventListener: function () {}, visibilityState: "visible" };
    var SignedOut = function () {};
    ${SYNC_JS}
    ${DECISIONS_LOGIC_JS}
    function sessionAccount() { return me ? me.account : shownAccount; }
    function sessionStamp() { return { gen: sessionGen, account: sessionAccount() }; }
    function sameSession(stamp, respAccount) { return sessionAccepts(stamp, sessionStamp(), respAccount); }
    ${APP_JS.includes("function storeDurable(") ? APP_JS.slice(APP_JS.indexOf("  function storeDurable("), APP_JS.indexOf("\n  }\n", APP_JS.indexOf("  function storeDurable(")) + 4) : ""}
    ${DECISIONS_UI_JS}
    return { decisionForm: decisionForm,
      switchAccount: function (a) { sessionGen += 1; dropDecisions(); me = a ? { account: a } : null; shownAccount = a; } };`;
  // eslint-disable-next-line no-new-func
  const app = new Function("H", "localStorage", src)({ ...h, me: opts.me ?? null, shown: opts.shown ?? null },
    { setItem: (k: string, v: string) => { if (opts.storageFails) throw new Error("full"); storage[k] = v; }, getItem: (k: string) => storage[k] ?? null,
      removeItem: (k: string) => { delete storage[k]; } });
  const submit = (text: string) => {
    const form = [...made].reverse().find((m) => m.tag === "form")!;
    const area = made.find((m) => m.tag === "textarea")!;
    area.value = text;
    if (!area.isConnected) return;   // the sheet is gone: nothing to press
    form.listeners.submit.forEach((f) => f({ preventDefault() {} }));
  };
  return { ...h, app, submit };
}

const queued = (storage: Record<string, string>) => (storage["floatboard.decisions.queue"] ? JSON.parse(storage["floatboard.decisions.queue"]) : null);

describe("phone Make decision form (Codex review 3)", () => {
  it("a_form_opened_under_one_account_never_queues_under_another", () => {
    const t = harness({ me: { account: "acc-a" }, shown: "acc-a" });
    t.app.decisionForm("We keep the old supplier", "J-1", "notes");
    // A background sync confirms another account while the form is open.
    t.app.switchAccount("acc-b");
    t.submit("Keep the old supplier");
    const q = queued(t.storage);
    expect(q === null || !(q.actions || []).some((a: any) => a.source === "J-1")).toBe(true);
    expect(t.toasts.some((x) => x.startsWith("Decision saved"))).toBe(false);
  });

  it("an_offline_save_is_queued_under_the_forms_account_and_only_then_reported", () => {
    // Launched offline: /me never answered (me is null) and Decisions' cache was never loaded; the board names the account.
    const t = harness({ me: null, shown: "acc-a" });
    t.app.decisionForm("We keep the old supplier", "J-1", "notes");
    t.submit("Keep the old supplier");
    const q = queued(t.storage);
    expect(q?.account).toBe("acc-a");
    expect(q?.actions.map((a: any) => [a.action, a.text, a.source])).toEqual([["make", "Keep the old supplier", "J-1"]]);
    expect(t.toasts).toContain("Decision saved. Your Mac records it on its next sync.");
    expect(t.isOpen()).toBe(false);
  });

  it("when_the_phone_cannot_keep_it_the_form_stays_open_with_its_words", () => {
    const t = harness({ me: { account: "acc-a" }, shown: "acc-a", storageFails: true });
    t.app.decisionForm("We keep the old supplier", "J-1", "notes");
    t.submit("Keep the old supplier");
    expect(t.isOpen()).toBe(true);
    expect(t.made.find((m) => m.tag === "textarea")!.value).toBe("Keep the old supplier");
    expect(t.toasts.some((x) => x.startsWith("Decision saved"))).toBe(false);
  });

  it("a_queue_never_mixes_or_overwrites_accounts", async () => {
    const { DECISIONS_EXPORTS } = await import("../../src/phone/decisions-client");
    // eslint-disable-next-line no-new-func
    const L: any = new Function(DECISIONS_LOGIC_JS + "\nreturn {" + DECISIONS_EXPORTS.join(",") + "};")();
    const a = { id: "x" }, b = { id: "y" };
    expect(L.decisionEnqueue({ account: null, actions: [] }, a, "acc-a")).toEqual({ account: "acc-a", actions: [a] });
    expect(L.decisionEnqueue({ account: "acc-a", actions: [a] }, b, "acc-a")).toEqual({ account: "acc-a", actions: [a, b] });
    expect(L.decisionEnqueue({ account: "acc-a", actions: [a] }, b, "acc-b")).toBeNull();
    expect(L.decisionEnqueue({ account: "acc-a", actions: [] }, b, "acc-b")).toEqual({ account: "acc-b", actions: [b] });
    expect(L.decisionEnqueue(null, a, null)).toBeNull();
  });

  it("dropping_account_data_closes_open_sheets", () => {
    const drop = APP_JS.slice(APP_JS.indexOf("function dropAccountData()"));
    expect(drop.slice(0, drop.indexOf("\n  }\n"))).toContain("closeSheet();");
  });
});
