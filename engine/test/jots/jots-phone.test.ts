import { describe, it, expect } from "vitest";
import { call } from "../helpers";
import { JOTS_EXPORTS, JOTS_JS } from "../../src/phone/jots-logic";
import { MANIFEST } from "../../src/phone/page";
import { APP_JS } from "../../src/phone/client";
import { SYNC_JS } from "../../src/phone/sync-logic";

// The phone's Jots screen (design §5): the same text the phone runs, tested on its own.
const L: any = new Function(SYNC_JS + JOTS_JS + "\nreturn {" + JOTS_EXPORTS.concat(["queueReconcile"]).join(",") + "};")();
const DAY = 86400_000;
const now = Date.parse("2026-11-17T12:00:00Z");
const iso = (ms: number) => new Date(ms).toISOString();
const j = (key: string, ago: number, over: Record<string, unknown> = {}) => ({ key, text: `Text ${key}`, kind: "jot", source: "typed", tags: [],
  added: iso(now - ago), updated: iso(now - ago), ...over });

describe("jots on the phone: logic", () => {
  it("list_is_the_copy_plus_queued_changes_newest_first_30_days", () => {
    const cache = [j("J-1", DAY), j("J-2", 2 * DAY), j("J-3", 31 * DAY)];
    const queue = [{ id: "a1", op: "add", text: "Waiting capture", made_at: iso(now - 1000) },
      { id: "e1", op: "edit", key: "J-2", text: "Edited here", made_at: iso(now - 500) },
      { id: "d1", op: "delete", key: "J-1", made_at: iso(now - 400) }];
    const list = L.jotsView(cache, queue, now);
    expect(list.map((x: any) => [x.key, x.text, !!x.queued])).toEqual([["phone:a1", "Waiting capture", true], ["J-2", "Edited here", true]]);
  });

  it("search_every_word_in_text_or_tags_and_tag_filter", () => {
    const list = [j("J-1", 1, { text: "Budget review with Ann", tags: ["Work"] }), j("J-2", 2, { text: "Run 5k", tags: ["Health"] }),
      j("J-3", 3, { text: "预算 计划", tags: [] })];
    expect(L.jotsFilter(list, "budget work", "").map((x: any) => x.key)).toEqual(["J-1"]);
    expect(L.jotsFilter(list, "预算", "").map((x: any) => x.key)).toEqual(["J-3"]);
    expect(L.jotsFilter(list, "", "Health").map((x: any) => x.key)).toEqual(["J-2"]);
    expect(L.jotsFilter(list, "", "untagged").map((x: any) => x.key)).toEqual(["J-3"]);
    expect(L.jotTags(list)).toEqual(["Health", "Work"]);
  });

  it("day_labels_in_the_macs_zone", () => {
    expect(L.jotDayLabel(now - 3600_000, now, "Europe/London")).toBe("Today");
    expect(L.jotDayLabel(now - DAY, now, "Europe/London")).toBe("Yesterday");
    expect(L.jotDayLabel(Date.parse("2026-11-10T09:00:00Z"), now, "Europe/London")).toBe("Tue 10 Nov");
  });

  it("queue_batches_and_drops_what_the_engine_took", () => {
    const q = [{ id: "a1", op: "add", text: "x", made_at: iso(now) }, { id: "a2", op: "add", text: "y", made_at: iso(now) }];
    const b = L.takeJotBatch(q, iso(now));
    expect(b).toEqual({ sent_at: iso(now), actions: q });
    expect(L.afterJotSend(q, { accepted: ["a1"], dropped: [{ id: "a2", reason: "text is required" }] })).toEqual([]);
    expect(L.afterJotSend(q, { accepted: ["a1"], dropped: [] })).toEqual([q[1]]);
    // Never dropped for a reason the engine may get past later (only malformed actions leave the queue).
    expect(L.afterJotSend(q, { accepted: [], dropped: [{ id: "a1", reason: "unknown jot" }, { id: "a2", reason: "bad id" }] })).toEqual([q[0]]);
    expect(L.jotWaitingText(2)).toBe("2 jots waiting to sync");
    expect(L.jotWaitingText(1)).toBe("1 jot waiting to sync");
  });

  it("undo_of_a_delete_already_sent_queues_a_restore", () => {
    const del = { id: "d1", op: "delete", key: "J-1", made_at: iso(now) };
    // Not sent yet: taken out of the queue.
    expect(L.undoJotDelete([del], del)).toEqual({ queue: [], restore: false });
    // Sent (its answer may have been lost): it stays queued (sent again, applied once) and a restore follows it.
    const sent = L.markJotsAttempted([del], ["d1"]);
    expect(sent[0].attempted).toBe(true);   // round 13 (B10): named as on the board's queue; an older queue's `sent` still counts
    expect(L.undoJotDelete(sent, sent[0])).toEqual({ queue: sent, restore: true });
    const older = [{ ...del, sent: true }];   // a queue saved before the rename
    expect(L.undoJotDelete(older, older[0])).toEqual({ queue: older, restore: true });
  });

  it("share_and_shortcuts_open_the_right_place", () => {
    expect(L.launchTarget("?go=jot")).toBe("jot");
    expect(L.launchTarget("?go=plan")).toBe("plan");
    expect(L.launchTarget("?go=nope")).toBeNull();
    expect(L.sharedText("?share_title=Article&share_text=Worth+reading&share_url=https%3A%2F%2Fexample.com%2Fa")).toBe("Article\nWorth reading\nhttps://example.com/a");
    expect(L.sharedText("?share_text=https%3A%2F%2Fexample.com%2Fa&share_url=https%3A%2F%2Fexample.com%2Fa")).toBe("https://example.com/a");
    expect(L.sharedText("?go=jot")).toBeNull();
    expect(L.selectionTitle("  Call Ann about the budget\nand the deck  ")).toBe("Call Ann about the budget");
    expect(L.selectionTitle("x".repeat(300)).length).toBe(120);
  });
});

describe("jots on the phone: account changes", () => {
  it("a_late_answer_is_never_kept_for_another_account", async () => {
    // Codex round 2, finding 4: a request still out when the account changes (or the phone is signed out) is discarded.
    const stored: Record<string, any> = {};
    let account = "A", gen = 0;
    let answer: (v: any) => void = () => {};
    const h = { $: () => null, el: () => null, toast: () => {}, newId: () => "id-00000001", offline: () => false, SignedOut: class extends Error {},
      store: (k: string, v: any) => { stored[k] = v; }, load: (k: string) => stored[k] ?? null, account: () => account, modules: () => ({ jots: true }),
      stamp: () => ({ gen, account }), sameSession: (s: any) => !!s.account && s.gen === gen && s.account === account,
      zone: () => "Europe/London", api: () => new Promise((r) => { answer = r; }) };
    const screen = L.JotsScreen(h);
    screen.restore();
    const pending = screen.sync();
    gen += 1;   // the app's dropAccountData: the session generation goes up, then each area drops its data
    screen.drop();
    account = "B";
    screen.restore();
    answer({ jots: [{ key: "J-1", text: "A's private note", kind: "jot", source: "typed", tags: [], added: iso(now), updated: iso(now) }] });
    await pending;
    expect(JSON.stringify(stored)).not.toContain("A's private note");
  });
});

describe("jots on the phone: account changes (Codex round 3)", () => {
  function phone(account: () => string) {
    const stored: Record<string, any> = {};
    const sheets: number[] = [];
    let answer: (v: any) => void = () => {};
    const h = { $: () => null, el: () => ({ appendChild() {}, addEventListener() {} }), toast: () => {}, newId: () => "id-00000002", offline: () => true,
      SignedOut: class extends Error {}, store: (k: string, v: any) => { stored[k] = v; }, load: (k: string) => stored[k] ?? null, account,
      modules: () => ({ jots: true }), zone: () => "Europe/London", openSheet: () => { sheets.push(1); }, closeSheet: () => {},
      // The app's shared session check (app.client.js): a drop raises the generation; here the account switch alone tells.
      stamp: () => ({ gen: 0, account: account() }), sameSession: (s: any) => !!s.account && s.account === account(),
      api: () => new Promise((r, rej) => { answer = r; }) };
    return { h, stored, sheets, answer: (v: any) => answer(v) };
  }

  it("an_offline_jot_after_an_account_switch_is_saved_for_the_new_account", () => {
    let account = "A";
    const p = phone(() => account);
    const screen = L.JotsScreen(p.h);
    screen.restore();
    // gotBoard(): the session now belongs to B; the app drops A's data (drop) and switches account.
    screen.drop();
    account = "B";
    screen.add("Written offline after the switch");
    expect(p.stored["floatboard.jotqueue"]?.account).toBe("B");
    expect(JSON.stringify(p.stored["floatboard.jotqueue"])).toContain("Written offline after the switch");
  });

  it("gotBoard_rebinds_jots_right_after_an_account_switch", () => {
    const body = /function gotBoard\(b\) \{([\s\S]*?)\n    board = /.exec(APP_JS)?.[1] ?? "";
    expect(body).toMatch(/dropAccountData\(\);[\s\S]*jots\.restore\(\);/);
  });

  it("a_late_cleanup_answer_is_not_shown_to_another_account", async () => {
    let account = "A";
    const p = phone(() => account);
    const screen = L.JotsScreen(p.h);
    screen.restore();
    let used: string | null = null;
    const pending = screen.cleanup("A's private draft", (c: string) => { used = c; });
    screen.drop();
    account = "B";
    screen.restore();
    p.answer({ cleaned: "A's private draft, cleaned" });
    await pending;
    expect(p.sheets).toHaveLength(0);
    expect(used).toBeNull();
  });
});

describe("jots on the phone: page and manifest", () => {
  it("jots_screen_has_a_writing_box_search_and_tag_filter", async () => {
    const html = await (await call("/app/")).text();
    for (const id of ["jot-text", "jot-save", "jot-search", "jot-tag", "jot-list"]) expect(html).toContain(`id="${id}"`);
    expect(html).not.toContain("Jots arrive here with the Jots area");
    expect(APP_JS).toContain("function jotsView(");
  });

  it("manifest_has_icon_shortcuts_and_a_share_target", () => {
    const m = JSON.parse(MANIFEST);
    expect(m.shortcuts.map((s: any) => [s.name, s.url])).toEqual([["New jot", "/app/?go=jot"], ["Plan", "/app/?go=plan"]]);
    expect(m.share_target).toEqual({ action: "/app/", method: "GET", params: { title: "share_title", text: "share_text", url: "share_url" } });
  });
});

describe("jots on the phone: the draft and the undo bar belong to one account (Claude review, round 12)", () => {
  function page(account: () => string | null) {
    const stored: Record<string, any> = {};
    const els: Record<string, any> = {};
    const el = (id: string) => (els[id] ??= { id, value: "", hidden: true, textContent: "", listeners: {} as Record<string, Function[]>,
      addEventListener(t: string, f: Function) { (this.listeners[t] ??= []).push(f); },
      removeEventListener(t: string, f: Function) { this.listeners[t] = (this.listeners[t] ?? []).filter((x: Function) => x !== f); },
      appendChild() {}, replaceChildren() {}, focus() {} });
    const h = { $: el, el: () => ({ appendChild() {}, addEventListener() {} }), toast: () => {}, newId: () => "id-" + Math.random().toString(36).slice(2, 10),
      offline: () => true, SignedOut: class extends Error {}, store: (k: string, v: any) => { if (v == null) delete stored[k]; else stored[k] = v; },
      load: (k: string) => stored[k] ?? null, account, modules: () => ({ jots: true }), zone: () => "Europe/London", openSheet: () => {}, closeSheet: () => {},
      stamp: () => ({ gen: 0, account: account() }), sameSession: (s: any) => !!s.account && s.account === account(),
      api: () => new Promise(() => {}) };
    return { h, stored, el };
  }

  it("a_save_the_phone_cannot_keep_is_not_reported_as_saved_and_keeps_the_text", () => {
    const p = page(() => "A");
    let full = false;
    const toasts: string[] = [];
    (p.h as any).toast = (t: string) => toasts.push(t);
    (p.h as any).storeDurable = (k: string, v: any) => { if (full) return false; p.h.store(k, v); return true; };
    const screen = L.JotsScreen(p.h);
    screen.restore();
    screen.wire();
    const box = p.el("jot-text");
    box.value = "a thought that must not vanish";
    box.listeners.input.forEach((f: Function) => f());
    full = true;   // storage full: the queue can't be kept
    p.el("jot-save").listeners.click.forEach((f: Function) => f());
    expect(box.value).toBe("a thought that must not vanish");
    expect(p.stored["floatboard.jotdraft"]?.text).toBe("a thought that must not vanish");
    expect(toasts).not.toContain("Saved");
    expect(p.stored["floatboard.jotqueue"]).toBeUndefined();
    expect(screen.add("shared text")).toBeNull();
    full = false;
    p.el("jot-save").listeners.click.forEach((f: Function) => f());
    expect(box.value).toBe("");
    expect(toasts).toContain("Saved");
    expect(p.stored["floatboard.jotqueue"].actions.map((a: any) => a.text)).toEqual(["a thought that must not vanish"]);
  });

  it("phone_changes_to_a_jot_carry_its_identity", () => {
    // Round 20: edits, deletes, restores and Make task name the jot's added time, so a number reused on the Mac is never hit.
    expect((JOTS_JS.match(/key: j\.key, jot_added: j\.added/g) || []).length).toBe(5);
  });

  it("a_jot_longer_than_the_engine_takes_is_never_cut_and_never_called_saved", () => {
    const p = page(() => "A");
    const toasts: string[] = [];
    (p.h as any).toast = (t: string) => toasts.push(t);
    const screen = L.JotsScreen(p.h);
    screen.restore();
    screen.wire();
    const box = p.el("jot-text");
    const long = "x".repeat(20_001);
    box.value = long;
    p.el("jot-save").listeners.click.forEach((f: Function) => f());
    expect(box.value).toBe(long);
    expect(p.stored["floatboard.jotqueue"]).toBeUndefined();
    expect(toasts.some((t) => /too long/i.test(t))).toBe(true);
    expect(toasts).not.toContain("Saved");
    expect(JOTS_JS).not.toMatch(/slice\(0, 20000\)/);   // no save, edit or share cuts the text any more
  });

  it("two_tabs_offline_keep_both_captures_and_an_ack_in_one_never_brings_a_change_back", () => {
    // Two tabs of the same phone share one storage (round 28, Codex 18).
    const p = page(() => "A");
    const durable = (k: string, v: any) => { p.h.store(k, v); return true; };
    (p.h as any).storeDurable = durable;
    const tab1 = L.JotsScreen(p.h), tab2 = L.JotsScreen(p.h);
    tab1.restore(); tab2.restore();
    expect(tab1.add("captured in tab one")).toBeTruthy();
    expect(tab2.add("captured in tab two")).toBeTruthy();
    expect(p.stored["floatboard.jotqueue"].actions.map((a: any) => a.text).sort()).toEqual(["captured in tab one", "captured in tab two"]);
  });

  it("shared_queue_reconcile_keeps_other_tabs_changes_and_this_tabs_removals", () => {
    const k = (ids: string[]) => Object.fromEntries(ids.map((i) => [i, true]));
    // stored has a (known) and c (another tab's); this tab removed a and added b.
    const out = L.queueReconcile([{ id: "a" }, { id: "c" }], [{ id: "b" }], k(["a"]));
    expect(out.map((x: any) => x.id)).toEqual(["c", "b"]);
    // another tab removed a (acked) while this tab still holds it: not brought back.
    expect(L.queueReconcile([{ id: "c" }], [{ id: "a" }, { id: "c" }], k(["a", "c"])).map((x: any) => x.id)).toEqual(["c"]);
  });

  it("a_draft_typed_under_one_account_is_never_shown_to_another", () => {
    let account: string | null = "A";
    const p = page(() => account);
    const screen = L.JotsScreen(p.h);
    screen.restore();
    screen.wire();
    const box = p.el("jot-text");
    box.value = "A's private thought";
    box.listeners.input.forEach((f: Function) => f());
    expect(p.stored["floatboard.jotdraft"]).toEqual({ account: "A", text: "A's private thought" });
    // Signed out, then B signs in on the same phone.
    screen.drop();
    expect(box.value).toBe("");
    account = "B";
    screen.restore();
    expect(box.value).toBe("");
    expect(JSON.stringify(p.stored)).not.toContain("A's private thought");
  });

  it("a_draft_comes_back_for_its_own_account_only", () => {
    const p = page(() => "A");
    p.stored["floatboard.jotdraft"] = { account: "A", text: "half a thought" };
    const screen = L.JotsScreen(p.h);
    screen.wire();
    screen.restore();
    expect(p.el("jot-text").value).toBe("half a thought");
    const q = page(() => "B");
    q.stored["floatboard.jotdraft"] = { account: "A", text: "half a thought" };
    const other = L.JotsScreen(q.h);
    other.wire();
    other.restore();
    expect(q.el("jot-text").value).toBe("");
    const r = page(() => "A");
    r.stored["floatboard.jotdraft"] = "an old draft with no account";   // from before this fix: never shown
    const old = L.JotsScreen(r.h);
    old.wire();
    old.restore();
    expect(r.el("jot-text").value).toBe("");
  });

  it("the_delete_undo_bar_is_dropped_on_an_account_switch", () => {
    let account: string | null = "A";
    const p = page(() => account);
    const screen = L.JotsScreen(p.h);
    screen.restore();
    screen.remove({ key: "J-1", text: "x", kind: "jot", tags: [], added: new Date().toISOString() });
    expect(p.el("undo").hidden).toBe(false);
    expect(p.el("undo-btn").listeners.click?.length).toBe(1);
    screen.drop();
    account = "B";
    expect(p.el("undo").hidden).toBe(true);
    expect(p.el("undo-btn").listeners.click?.length ?? 0).toBe(0);
  });
});
