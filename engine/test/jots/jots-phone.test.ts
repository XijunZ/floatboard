import { describe, it, expect } from "vitest";
import { call } from "../helpers";
import { JOTS_EXPORTS, JOTS_JS } from "../../src/phone/jots-logic";
import { MANIFEST } from "../../src/phone/page";
import { APP_JS } from "../../src/phone/client";

// The phone's Jots screen (design §5): the same text the phone runs, tested on its own.
const L: any = new Function(JOTS_JS + "\nreturn {" + JOTS_EXPORTS.join(",") + "};")();
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
    expect(sent[0].sent).toBe(true);
    expect(L.undoJotDelete(sent, sent[0])).toEqual({ queue: sent, restore: true });
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
