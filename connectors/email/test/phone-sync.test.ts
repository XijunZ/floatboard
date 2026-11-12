import { describe, expect, it } from "vitest";
import { SYNC_EXPORTS, SYNC_JS } from "../src/app/sync-logic";
import { APP_JS } from "../src/app/client";

/** The phone's offline queue logic: the exact text embedded in /app/app.js, run here on its own. */
// eslint-disable-next-line no-new-func
const L: any = new Function(SYNC_JS + "\nreturn {" + SYNC_EXPORTS.join(",") + "};")();

const board = {
  updated: "2026-11-12T09:00:00.000Z", pending: 0,
  cards: [
    { id: 1, title: "One", status: "todo", done_at: null },
    { id: 2, title: "Two", status: "doing", done_at: null },
    { id: -5, title: "Added earlier", status: "todo", pending: true, action_id: "add-1" },
  ],
};
const at = "2026-11-12T10:00:00.000Z";

describe("phone sync logic", () => {
  it("is_embedded_in_the_app_script", () => {
    expect(APP_JS).toContain(SYNC_JS);
  });

  it("view_applies_queued_moves_and_adds_on_top_of_the_board", () => {
    const v = L.viewBoard(board, [
      { id: "a", made_at: at, card_id: 1, action: "done" },
      { id: "b", made_at: at, action: "add", title: "New", group: "Work" },
      { id: "add-1", made_at: at, action: "add", title: "Added earlier" }, // already on the engine's board
      { id: "c", made_at: at, card_id: -5, action: "doing" },             // pending cards can't move
      { id: "d", made_at: at, card_id: 99, action: "doing" },             // unknown card: nothing shown
    ]);
    expect(v.cards.find((c: any) => c.id === 1)).toMatchObject({ status: "done", done_at: at, queued: true });
    expect(v.cards.filter((c: any) => c.action_id === "add-1")).toHaveLength(1);
    expect(v.cards.find((c: any) => c.id === -5).status).toBe("todo");
    expect(v.cards.find((c: any) => c.action_id === "b")).toMatchObject({ pending: true, queued: true, status: "todo", title: "New", group: "Work" });
    expect(v.cards).toHaveLength(4);
    expect(board.cards[0].status).toBe("todo"); // the stored board is not changed
  });

  it("later_queued_moves_win_and_leaving_done_clears_done_at", () => {
    const v = L.viewBoard(board, [
      { id: "a", made_at: at, card_id: 2, action: "done" },
      { id: "b", made_at: at, card_id: 2, action: "watch" },
    ]);
    expect(v.cards.find((c: any) => c.id === 2)).toMatchObject({ status: "watch", done_at: null });
  });

  it("batch_has_sent_at_at_most_100_actions_and_stays_under_the_size_cap", () => {
    const many = Array.from({ length: 150 }, (_, i) => ({ id: "m" + i, made_at: at, card_id: 1, action: "doing" }));
    const b = L.takeBatch(many, at);
    expect(b.sent_at).toBe(at);
    expect(b.actions).toHaveLength(100);
    expect(b.actions[0]).toEqual({ id: "m0", made_at: at, action: "doing", card_id: 1 });
    // 100 adds with 200 Chinese characters each would be about 75 KB: split under 60 KB.
    const big = Array.from({ length: 100 }, (_, i) => ({ id: "x" + i, made_at: at, action: "add", title: "任务".repeat(100), group: "工作" }));
    const bb = L.takeBatch(big, at);
    expect(bb.actions.length).toBeLessThan(100);
    expect(new TextEncoder().encode(JSON.stringify(bb)).length).toBeLessThan(64 * 1024);
    expect(L.byteLength("任")).toBe(3);
    expect(L.byteLength("😀")).toBe(4);
  });

  it("after_send_drops_accepted_dropped_and_superseded_ids_only", () => {
    const q = [{ id: "a" }, { id: "b" }, { id: "c" }, { id: "d" }];
    const r = L.afterSend(q, { accepted: ["a"], dropped: [{ id: "b", reason: "card gone" }, { id: null, reason: "invalid" }], superseded: ["c", "zz"] });
    expect(r.actions).toEqual([{ id: "d" }]);
    expect(r.dropped).toBe(1);
  });

  it("superseded_is_noticed_once_per_sent_id_even_though_the_engine_repeats_it", () => {
    let sent = L.rememberSent([], ["a", "b"]);
    const first = L.noticeSuperseded(sent, ["a", "old-unknown"]);
    expect(first.count).toBe(1);
    sent = first.sentIds;
    expect(L.noticeSuperseded(sent, ["a", "old-unknown"]).count).toBe(0);
    expect(L.rememberSent(Array.from({ length: 199 }, (_, i) => "s" + i), ["x", "y"])).toHaveLength(200);
  });

  it("retry_delay_doubles_from_5_seconds_to_5_minutes", () => {
    expect([1, 2, 3, 4, 5, 6, 7, 8, 20].map(L.retryDelay)).toEqual([5000, 10000, 20000, 40000, 80000, 160000, 300000, 300000, 300000]);
  });

  it("status_line_says_how_things_stand", () => {
    const now = new Date(2026, 10, 12, 14, 30).getTime();
    const at1402 = new Date(2026, 10, 12, 14, 2).getTime();
    expect(L.statusText({ waiting: 0, offline: false, lastSync: now - 30000, now })).toBe("Synced");
    expect(L.statusText({ waiting: 0, offline: false, lastSync: at1402, now })).toBe("Last synced 14:02");
    expect(L.statusText({ waiting: 3, offline: false, lastSync: now, now })).toBe("3 changes waiting");
    expect(L.statusText({ waiting: 1, offline: false, lastSync: now, now })).toBe("1 change waiting");
    expect(L.statusText({ waiting: 3, offline: true, lastSync: at1402, now })).toBe("Offline, 3 changes waiting");
    expect(L.statusText({ waiting: 0, offline: true, lastSync: at1402, now })).toBe("Offline. Last synced 14:02");
    expect(L.statusText({ waiting: 0, offline: true, lastSync: 0, now })).toBe("Offline");
    expect(L.statusText({ waiting: 0, offline: false, lastSync: new Date(2026, 10, 11, 9, 5).getTime(), now })).toBe("Last synced yesterday 09:05");
    expect(L.statusText({ waiting: 0, offline: false, lastSync: new Date(2026, 10, 3, 9, 5).getTime(), now })).toBe("Last synced 3 Nov 09:05");
  });

  it("a_batch_refused_with_400_is_sent_again_one_action_at_a_time_and_a_still_refused_one_is_given_up", async () => {
    const q = [{ id: "a", made_at: at, card_id: 1, action: "done" }, { id: "bad", made_at: at, card_id: 2, action: "doing" },
      { id: "c", made_at: at, action: "add", title: "New" }];
    const sent: any[] = [];
    const refuse = (status: number) => Object.assign(new Error("refused"), { status });
    const send = async (body: any) => {
      sent.push(body);
      if (body.actions.some((a: any) => a.id === "bad")) throw refuse(400);
      return { accepted: body.actions.map((a: any) => a.id), dropped: [], cards: [] };
    };
    const r = await L.sendBatch(L.takeBatch(q, at), send, () => "2026-11-12T10:00:05.000Z");
    expect(sent.map((b) => b.actions.map((a: any) => a.id))).toEqual([["a", "bad", "c"], ["a"], ["bad"], ["c"]]);
    expect(sent.slice(1).every((b) => b.sent_at === "2026-11-12T10:00:05.000Z")).toBe(true);
    expect(r.rejected).toEqual(["bad"]);
    expect(r.results.map((x: any) => x.accepted)).toEqual([["a"], ["c"]]);
    // The rejected one leaves the queue (with the accepted ones) and is counted for the quiet note.
    let left = q;
    for (const x of r.results) left = L.afterSend(left, x).actions;
    expect(L.afterSend(left, { accepted: r.rejected }).actions).toEqual([]);
    expect(L.replacedText(0, 0, 1)).toBe("1 change couldn't be sent");
    expect(L.replacedText(0, 0, 3)).toBe("3 changes couldn't be sent");
  });

  it("a_batch_that_works_is_sent_once_and_other_failures_are_not_split", async () => {
    const q = [{ id: "a", made_at: at, card_id: 1, action: "done" }, { id: "b", made_at: at, card_id: 2, action: "doing" }];
    let calls = 0;
    const ok = await L.sendBatch(L.takeBatch(q, at), async (b: any) => { calls++; return { accepted: b.actions.map((a: any) => a.id), dropped: [] }; }, () => at);
    expect(calls).toBe(1);
    expect(ok).toEqual({ results: [{ accepted: ["a", "b"], dropped: [] }], rejected: [] });
    // 429, 500 and no connection keep the queue: the error goes up to the retry with back-off.
    for (const err of [Object.assign(new Error("busy"), { status: 429 }), Object.assign(new Error("boom"), { status: 500 }), new TypeError("offline")]) {
      calls = 0;
      await expect(L.sendBatch(L.takeBatch(q, at), async () => { calls++; throw err; }, () => at)).rejects.toBe(err);
      expect(calls).toBe(1);
    }
    // A single action that then fails for another reason (offline) stops the split: nothing is given up.
    let n = 0;
    const offline = new TypeError("offline");
    await expect(L.sendBatch(L.takeBatch(q, at), async () => { n++; if (n === 1) throw Object.assign(new Error("bad"), { status: 400 }); throw offline; }, () => at))
      .rejects.toBe(offline);
  });

  it("replaced_note_is_one_quiet_line", () => {
    expect(L.replacedText(1, 0)).toBe("1 change was replaced by a newer change on your Mac");
    expect(L.replacedText(2, 1)).toBe("2 changes were replaced by newer changes on your Mac. 1 change was for a task no longer on your board");
    expect(L.replacedText(0, 0)).toBe("");
  });

  it("undo_after_a_move_queues_a_reverse_move_with_a_new_id_and_a_later_time", () => {
    const card = { id: 1, status: "doing", done_at: null };
    const move = { id: "orig-1", made_at: at, card_id: 1, action: "done" };
    const u = L.undoFor(card, move, 1000);
    expect(u).toEqual({ card_id: 1, from: "doing", to: "done", made_at: at, at: 1000 });
    expect(L.undoText(u)).toBe("Moved to Done");
    expect(L.undoText({ ...u, to: "watch" })).toBe("Moved to Watch");
    // Shown for 8 seconds.
    expect(L.undoLive(u, 1000 + 7999)).toBe(true);
    expect(L.undoLive(u, 1000 + 8000)).toBe(false);
    expect(L.undoLive(null, 1000)).toBe(false);
    // Undo is a new queued move back to the previous step: its own id, made after the move it undoes.
    const back = L.undoAction(u, "undo-2", "2026-11-12T10:00:05.000Z");
    expect(back).toEqual({ id: "undo-2", made_at: "2026-11-12T10:00:05.000Z", card_id: 1, action: "doing" });
    expect(back.id).not.toBe(move.id);
    // A phone clock that went back still orders the undo after the move.
    const early = L.undoAction(u, "undo-3", "2026-11-12T09:59:00.000Z");
    expect(Date.parse(early.made_at)).toBeGreaterThan(Date.parse(move.made_at));
    // Queued after the move, the view shows the card back on its old step.
    const v = L.viewBoard({ cards: [card] }, [move, back]);
    expect(v.cards[0]).toMatchObject({ status: "doing", done_at: null });
  });

  it("adds_and_no_change_moves_cannot_be_undone", () => {
    expect(L.undoFor({ id: -5, status: "todo", pending: true }, { id: "x", made_at: at, card_id: -5, action: "doing" }, 0)).toBeNull();
    expect(L.undoFor({ id: 1, status: "done" }, { id: "x", made_at: at, card_id: 1, action: "done" }, 0)).toBeNull();
    expect(L.undoFor(null, { id: "x", made_at: at, action: "add", title: "New" }, 0)).toBeNull();
  });

  it("every_link_is_a_button_with_its_own_label_and_only_web_links", () => {
    const shown = L.cardLinks({ link: "https://mail.google.com/x", links: [
      { kind: "email", url: "https://mail.google.com/x" },
      { kind: "meeting", url: "https://acme.zoom.us/j/1" },
      { kind: "link", url: "https://calendar.google.com/e", label: "calendar" },
      { kind: "link", url: "https://docs.example.com/plan" },
      { kind: "link", url: "javascript:alert(1)" },
      { kind: "link", url: 5 },
    ] });
    expect(shown.map((l: any) => [L.linkLabel(l), l.url])).toEqual([
      ["Open email", "https://mail.google.com/x"],
      ["Join meeting", "https://acme.zoom.us/j/1"],
      ["Open calendar", "https://calendar.google.com/e"],
      ["Open link", "https://docs.example.com/plan"],
    ]);
    // A board from an older Mac has only link.
    expect(L.cardLinks({ link: "https://example.com/a" })).toEqual([{ kind: "link", url: "https://example.com/a" }]);
    expect(L.cardLinks({ link: "javascript:alert(1)" })).toEqual([]);
    expect(L.cardLinks({ link: null, links: [] })).toEqual([]);
  });
});
