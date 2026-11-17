import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, fathomHookPath, newUser } from "../helpers";
import { pairPhone } from "../phone-helpers";
import { setNtfyFetch } from "../../src/reminders/alerts";
import { runDueAlerts } from "../../src/reminders/due";

// The assistant foundation (docs/superpowers/specs/2026-11-17-foundation-design.md §4): tags and modules in the board copy,
// the phone's set_tags, budget reminders sent to the phone only when the Mac did not show them, and Fathom meeting metadata.

const iso = (ms: number) => new Date(ms).toISOString();
const card = (id: number, over: Record<string, unknown> = {}) => ({ id, title: `Task ${id}`, group: "Work", color: "#aabbcc", importance: 1,
  due: null, has_time: false, status: "todo", link: null, done_at: null, ...over });
const put = (key: string, body: unknown) => call("/v2/board", { method: "PUT", key, body: JSON.stringify(body) });
const board = (cookie: string) => call("/app/api/board", { headers: { Cookie: cookie } }).then((r) => r.json<any>());
const send = (cookie: string, body: unknown) =>
  call("/app/api/action", { method: "POST", headers: { Cookie: cookie, Origin: BASE }, body: JSON.stringify(body) });
const macActions = (key: string) => call("/v2/phone-actions", { key }).then((r) => r.json<{ actions: any[] }>());
const ALL_ON = { jots: true, circle: true, decisions: true, resolutions: true };

async function setup(name: string) {
  const u = await newUser(name);
  const { cookie } = await pairPhone(u.key);
  return { ...u, cookie };
}

let ntfy: { headers: Record<string, string>; body: string }[] = [];
beforeEach(() => {
  ntfy = [];
  setNtfyFetch((async (_u: RequestInfo | URL, init?: RequestInit) => {
    ntfy.push({ headers: init?.headers as Record<string, string>, body: String(init?.body) });
    return new Response("{}");
  }) as typeof fetch);
});

describe("foundation: tags and modules in the board copy", () => {
  it("board_carries_tags_and_modules_to_the_phone", async () => {
    const u = await setup("Tags");
    const r = await put(u.key, { cards: [card(1, { tags: ["Work", "Investor"], tags_at: iso(Date.now()) }), card(2)],
      modules: { ...ALL_ON, circle: false } });
    expect(r.status).toBe(200);
    const b = await board(u.cookie);
    expect(b.cards[0].tags).toEqual(["Work", "Investor"]);
    expect(b.cards[1].tags).toBeUndefined();
    expect(b.modules).toEqual({ ...ALL_ON, circle: false });
    const s = await env.DB.prepare("SELECT modules FROM settings WHERE user_id=?").bind(u.id).first<{ modules: string }>();
    expect(JSON.parse(s!.modules)).toEqual({ ...ALL_ON, circle: false });
  });

  it("bad_tags_or_modules_are_refused", async () => {
    const u = await setup("Bad tags");
    expect((await put(u.key, { cards: [card(1, { tags: "Work" })] })).status).toBe(400);
    expect((await put(u.key, { cards: [card(1, { tags: ["x".repeat(61)] })] })).status).toBe(400);
    expect((await put(u.key, { cards: [card(1, { tags: [] })] })).status).toBe(400);
    expect((await put(u.key, { cards: [card(1)], modules: { jots: "yes" } })).status).toBe(400);
  });

  it("an_older_mac_without_modules_leaves_them_unset", async () => {
    const u = await setup("No modules");
    await put(u.key, { cards: [card(1)] });
    expect((await board(u.cookie)).modules).toBeUndefined();
  });

  it("phone_set_tags_shows_at_once_and_reaches_the_mac", async () => {
    const u = await setup("Set tags");
    const now = Date.now();
    await put(u.key, { sent_at: iso(now), cards: [card(1, { tags: ["Work"], tags_at: iso(now - 60_000) })] });
    const r = await send(u.cookie, { sent_at: iso(now), actions: [{ id: "ptag-0001", made_at: iso(now), card_id: 1, action: "set_tags", tags: ["Personal", "Work"] }] });
    const body = await r.json<any>();
    expect(body.accepted).toEqual(["ptag-0001"]);
    expect(body.cards[0]).toMatchObject({ tags: ["Personal", "Work"], group: "Personal" });
    const a = (await macActions(u.key)).actions;
    expect(a).toHaveLength(1);
    expect(a[0]).toMatchObject({ client_id: "ptag-0001", card_id: 1, action: "set_tags", tags: ["Personal", "Work"] });
  });

  it("phone_set_tags_older_than_the_macs_change_loses_and_bad_ones_are_dropped", async () => {
    const u = await setup("Old tags");
    const now = Date.now();
    await put(u.key, { sent_at: iso(now), cards: [card(1, { tags: ["Work"], tags_at: iso(now - 60_000) })] });
    const old = await (await send(u.cookie, { sent_at: iso(now), actions: [{ id: "ptag-0old", made_at: iso(now - 5 * 60_000), card_id: 1,
      action: "set_tags", tags: ["Personal"] }] })).json<any>();
    expect(old.superseded).toContain("ptag-0old");
    expect(old.cards[0].tags).toEqual(["Work"]);
    const bad = await (await send(u.cookie, { actions: [{ id: "ptag-0bad", card_id: 1, action: "set_tags", tags: [] }] })).json<any>();
    expect(bad.dropped).toEqual([{ id: "ptag-0bad", reason: "invalid" }]);
  });
});

describe("foundation: budget reminders", () => {
  async function user(name: string) {
    const u = await newUser(name);
    await env.DB.prepare("UPDATE users SET ntfy_topic='budget-topic' WHERE id=?").bind(u.id).run();
    return u;
  }

  it("sent_once_only_after_the_macs_grace_and_only_while_still_in_the_copy", async () => {
    const u = await user("Budget");
    const fire = Date.parse("2026-11-18T09:00:00Z");
    const reminders = [{ id: "rb-circle_due-P-3-2026-11-18", title: "Sam Example", text: "Message P-3", fire_at: iso(fire) }];
    await put(u.key, { cards: [card(1)], reminders });
    expect(await runDueAlerts(env as any, fire + 5 * 60_000)).toBe(0);   // the Mac may still show it
    expect(ntfy).toHaveLength(0);
    expect(await runDueAlerts(env as any, fire + 11 * 60_000)).toBe(1);
    expect(ntfy[0].headers.Title).toBe("Sam Example");
    expect(await runDueAlerts(env as any, fire + 30 * 60_000)).toBe(0);  // once
    // One the Mac showed is no longer in its copy: never sent.
    const v = await user("Budget shown");
    await put(v.key, { cards: [card(1)], reminders });
    await put(v.key, { cards: [card(1)], reminders: [] });
    ntfy = [];
    expect(await runDueAlerts(env as any, fire + 11 * 60_000)).toBe(0);
  });

  it("bad_reminders_are_refused", async () => {
    const u = await user("Bad budget");
    expect((await put(u.key, { cards: [], reminders: [{ id: "x", title: "t", text: "t" }] })).status).toBe(400);
    expect((await put(u.key, { cards: [], reminders: "no" })).status).toBe(400);
  });
});

describe("foundation: Fathom meeting metadata", () => {
  const payload = {
    title: "Weekly planning", recording_id: 98765, share_url: "https://fathom.video/share/MeetMeta1",
    meeting_url: "https://meet.google.com/abc-defg-hij", scheduled_start_time: "2026-11-08T12:30:00Z",
    calendar_invitees: [{ name: "Sam", email: "Sam@Example.com" }, { name: "Alex", email: "alex@example.org" }, { name: "No email" }],
    default_summary: { markdown_formatted: "## Summary\nAgreed." },
  };

  it("kept_from_the_webhook_and_read_by_the_mac", async () => {
    const u = await newUser("Meetings");
    const path = await fathomHookPath(u.id);
    expect((await call(path, { method: "POST", body: JSON.stringify(payload) })).status).toBe(200);
    const r = await call("/v2/meetings?since=2026-01-01T00:00:00Z", { key: u.key });
    expect(r.status).toBe(200);
    const { meetings } = await r.json<any>();
    expect(meetings).toHaveLength(1);
    expect(meetings[0]).toMatchObject({ recap_key: "fathom:MeetMeta1", fathom_url: "https://fathom.video/share/MeetMeta1",
      meeting_url: "https://meet.google.com/abc-defg-hij", title: "Weekly planning", scheduled_start: "2026-11-08T12:30:00Z",
      invitees: ["sam@example.com", "alex@example.org"] });
    expect(JSON.stringify(meetings[0])).not.toContain("Agreed");   // no summary text
    // Since a later time: none. Another user: none.
    expect((await (await call(`/v2/meetings?since=${encodeURIComponent(iso(Date.now() + 60_000))}`, { key: u.key })).json<any>()).meetings).toHaveLength(0);
    const other = await newUser("Other");
    expect((await (await call("/v2/meetings", { key: other.key })).json<any>()).meetings).toHaveLength(0);
  });
});

describe("foundation: phone shell", () => {
  it("bottom_bar_has_five_screens_in_order_and_area_placeholders", async () => {
    const html = await (await call("/app/")).text();
    const views = [...html.matchAll(/data-view="([a-z]+)"/g)].map((m) => m[1]);
    expect(views).toEqual(["board", "plan", "jots", "circle", "more"]);
    for (const id of ["jots", "circle", "more", "more-decisions", "more-resolutions", "more-settings"]) expect(html).toContain(`id="${id}"`);
  });
});

import { SYNC_EXPORTS, SYNC_JS } from "../../src/phone/sync-logic";
const L: any = new Function(SYNC_JS + "\nreturn {" + SYNC_EXPORTS.join(",") + "};")();

describe("foundation: phone logic", () => {
  it("screens_follow_the_modules_board_and_plan_always", () => {
    expect(L.visibleViews(undefined)).toEqual(["board", "plan", "more"]);
    expect(L.visibleViews({ jots: true, circle: false, decisions: true, resolutions: false })).toEqual(["board", "plan", "jots", "more"]);
    expect(L.moreEntries({ jots: true, circle: true, decisions: true, resolutions: false })).toEqual(["decisions", "settings"]);
    expect(L.moreEntries(undefined)).toEqual(["settings"]);
  });

  it("queued_set_tags_shows_at_once_with_its_group", () => {
    const board = { cards: [{ id: 1, title: "A", group: "Work", color: "#111111", tags: ["Work"], status: "todo" },
      { id: 2, title: "B", group: "Home", color: "#222222", status: "todo" }] };
    const a = L.tagsAction({ id: 1 }, "Home", ["Investor", "Home"], "t1", "2026-11-17T10:00:00.000Z");
    expect(a).toEqual({ id: "t1", made_at: "2026-11-17T10:00:00.000Z", card_id: 1, action: "set_tags", tags: ["Home", "Investor"] });
    const v = L.viewBoard(board, [a]);
    expect(v.cards[0]).toMatchObject({ tags: ["Home", "Investor"], group: "Home", color: "#222222", status: "todo", queued: true });
    expect(L.tagChoices(board.cards)).toEqual({ groups: ["Home", "Work"], tags: ["Home", "Work"] });
    expect(L.tagChoices(v.cards)).toEqual({ groups: ["Home"], tags: ["Home", "Investor"] });
  });
});

describe("foundation: phone keeps the modules", () => {
  it("the_board_from_the_engine_keeps_modules_for_the_bottom_bar", async () => {
    const { APP_JS } = await import("../../src/phone/client");
    expect(APP_JS).toMatch(/if \(b\.modules && typeof b\.modules === "object"\) board\.modules = b\.modules;/);
    expect(APP_JS).toMatch(/var views = visibleViews\(board\.modules\);/);
  });
});
