import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, fathomHookPath, newUser } from "../helpers";
import { pairPhone } from "../phone-helpers";
import { purgeJots, runJotNudges, setJotsPutRaceHook } from "../../src/jots/copies";

// Jots (docs/superpowers/specs/2026-11-17-jots-design.md §4): the 30-day online copy, phone captures and edits waiting for
// the Mac (newest wins), meeting notes from Fathom, and the daily nudge on the phone.

const DAY = 86400_000;
const iso = (ms: number) => new Date(ms).toISOString();
const ON = { jots: true, circle: false, decisions: false, resolutions: false };
const jot = (id: number, over: Record<string, unknown> = {}) => ({ id, text: `Jot ${id}`, kind: "jot", source: "typed", tags: [],
  added: iso(Date.now() - 60_000), updated: iso(Date.now() - 60_000), deleted: false, ...over });
const putJots = (key: string, body: unknown) => call("/v2/jots", { method: "PUT", key, body: JSON.stringify(body) });
const waiting = (key: string) => call("/v2/jots/waiting", { key }).then((r) => r.json<{ jots: any[] }>());
const ack = (key: string, items: unknown[]) => call("/v2/jots/ack", { method: "POST", key, body: JSON.stringify({ items }) });
const phoneJots = (cookie: string) => call("/app/api/jots", { headers: { Cookie: cookie } }).then((r) => r.json<{ jots: any[] }>());
const phoneSend = (cookie: string, actions: unknown[], sentAt = iso(Date.now())) =>
  call("/app/api/jots", { method: "POST", headers: { Cookie: cookie, Origin: BASE }, body: JSON.stringify({ sent_at: sentAt, actions }) });

async function setup(name: string, modules = ON) {
  const u = await newUser(name);
  const { cookie } = await pairPhone(u.key);
  await call("/v2/board", { method: "PUT", key: u.key, body: JSON.stringify({ cards: [], modules }) });
  return { ...u, cookie };
}

describe("jots: the 30-day online copy", () => {
  it("mac_jots_reach_the_phone_last_30_days_only", async () => {
    const u = await setup("Copy");
    const r = await putJots(u.key, { jots: [jot(1, { text: "Recent idea", tags: ["Work"] }), jot(2, { added: iso(Date.now() - 40 * DAY) }),
      jot(3, { deleted: true })] });
    expect(r.status).toBe(200);
    expect((await r.json<any>()).accepted).toEqual([1, 2, 3]);
    const { jots } = await phoneJots(u.cookie);
    expect(jots.map((j) => j.key)).toEqual(["J-1"]);
    expect(jots[0]).toMatchObject({ text: "Recent idea", tags: ["Work"], kind: "jot" });
    const row = await env.DB.prepare("SELECT text_enc FROM jot_copies WHERE user_id=? AND key='J-1'").bind(u.id).first<{ text_enc: string }>();
    expect(row!.text_enc).not.toContain("Recent");   // encrypted at rest
  });

  it("bad_jots_are_refused", async () => {
    const u = await setup("Bad");
    expect((await putJots(u.key, { jots: [jot(0)] })).status).toBe(400);
    expect((await putJots(u.key, { jots: [jot(1, { text: 5 })] })).status).toBe(400);
    expect((await putJots(u.key, { jots: [jot(1, { kind: "poem" })] })).status).toBe(400);
    expect((await putJots(u.key, { jots: "x" })).status).toBe(400);
  });

  it("a_jot_is_kept_30_days_after_the_mac_saved_it_and_never_while_waiting", async () => {
    const u = await setup("Prune");
    await putJots(u.key, { jots: [jot(1), jot(2)] });
    await phoneSend(u.cookie, [{ id: "cap-0001", op: "add", text: "Never taken by the Mac", made_at: iso(Date.now()) }]);
    await env.DB.prepare("UPDATE jot_copies SET mac_saved_at=? WHERE user_id=?").bind(iso(Date.now() - 31 * DAY), u.id).run();
    await env.DB.prepare("UPDATE jot_copies SET added=?, updated=? WHERE user_id=? AND key LIKE 'phone:%'").bind(iso(Date.now() - 90 * DAY), iso(Date.now() - 90 * DAY), u.id).run();
    // J-2 has a phone edit the Mac has not saved yet.
    await env.DB.prepare("UPDATE jot_copies SET waiting=1 WHERE user_id=? AND key='J-2'").bind(u.id).run();
    await purgeJots(env);
    const keys = (await env.DB.prepare("SELECT key FROM jot_copies WHERE user_id=? ORDER BY key").bind(u.id).all<{ key: string }>()).results.map((r) => r.key);
    expect(keys).toEqual(["J-2", "phone:cap-0001"]);
  });
});

describe("jots: phone captures and edits reach the Mac", () => {
  it("phone_capture_waits_then_becomes_the_macs_jot_once", async () => {
    const u = await setup("Capture");
    const r = await phoneSend(u.cookie, [{ id: "cap-0002", op: "add", text: "Idea on the bus", made_at: iso(Date.now() - 5000) }]);
    expect(r.status).toBe(200);
    expect((await r.json<any>()).accepted).toEqual(["cap-0002"]);
    // Sent twice (lost answer): applied once.
    await phoneSend(u.cookie, [{ id: "cap-0002", op: "add", text: "Idea on the bus", made_at: iso(Date.now() - 5000) }]);
    const w = await waiting(u.key);
    expect(w.jots).toHaveLength(1);
    expect(w.jots[0]).toMatchObject({ key: "phone:cap-0002", mac_id: null, text: "Idea on the bus", source: "phone", kind: "jot", deleted: false });
    expect((await (await ack(u.key, [{ key: "phone:cap-0002", rev: w.jots[0].rev, mac_id: 7 }])).json<any>()).acked).toBe(1);
    expect((await waiting(u.key)).jots).toHaveLength(0);
    // The Mac then sends J-7: the same copy, not a second one.
    await putJots(u.key, { jots: [jot(7, { text: "Idea on the bus", source: "phone" })] });
    const { jots } = await phoneJots(u.cookie);
    expect(jots.map((j) => j.key)).toEqual(["phone:cap-0002"]);
  });

  it("newest_change_wins_between_phone_and_mac", async () => {
    const u = await setup("Newest");
    const t0 = Date.now() - 60_000;
    await putJots(u.key, { jots: [jot(1, { text: "Mac text", updated: iso(t0) })] });
    // An edit made before the Mac's version does not replace it, but is never thrown away: it goes to the Mac for the history.
    const old = await phoneSend(u.cookie, [{ id: "edit-0001", op: "edit", key: "J-1", text: "Stale", made_at: iso(t0 - 1000) }]);
    const oldBody = await old.json<any>();
    expect(oldBody.accepted).toEqual(["edit-0001"]);
    expect(oldBody.superseded).toEqual(["edit-0001"]);
    let w = await waiting(u.key);
    expect(w.jots).toEqual([expect.objectContaining({ key: "J-1", text: "Mac text", versions: [expect.objectContaining({ text: "Stale" })] })]);
    await ack(u.key, [{ key: "J-1", rev: w.jots[0].rev, mac_id: 1 }]);
    // A newer one waits for the Mac; a Mac push with an older version keeps the phone's text.
    await phoneSend(u.cookie, [{ id: "edit-0002", op: "edit", key: "J-1", text: "Phone text", made_at: iso(t0 + 20_000) }]);
    await putJots(u.key, { jots: [jot(1, { text: "Mac text again", updated: iso(t0 + 10_000) })] });
    w = await waiting(u.key);
    expect(w.jots).toEqual([expect.objectContaining({ key: "J-1", mac_id: 1, text: "Phone text" })]);
    expect((await phoneJots(u.cookie)).jots[0].text).toBe("Phone text");
    // A stale ack (the phone changed it again meanwhile) leaves it waiting.
    const rev = w.jots[0].rev;
    await phoneSend(u.cookie, [{ id: "edit-0003", op: "edit", key: "J-1", text: "Phone text 2", made_at: iso(t0 + 30_000) }]);
    await ack(u.key, [{ key: "J-1", rev, mac_id: 1 }]);
    w = await waiting(u.key);
    expect(w.jots.map((j) => j.text)).toEqual(["Phone text 2"]);
    await ack(u.key, [{ key: "J-1", rev: w.jots[0].rev, mac_id: 1 }]);
    expect((await waiting(u.key)).jots).toHaveLength(0);
    // A newer Mac version replaces the copy.
    await putJots(u.key, { jots: [jot(1, { text: "Mac final", updated: iso(t0 + 40_000) })] });
    expect((await phoneJots(u.cookie)).jots[0].text).toBe("Mac final");
  });

  it("phone_edits_keep_the_earlier_texts_until_the_mac_saved_them", async () => {
    const u = await setup("Versions");
    const t0 = Date.now() - 60_000;
    await putJots(u.key, { jots: [jot(1, { text: "Mac text", updated: iso(t0) })] });
    await phoneSend(u.cookie, [{ id: "edit-0101", op: "edit", key: "J-1", text: "P1", made_at: iso(t0 + 1000) },
      { id: "edit-0102", op: "edit", key: "J-1", text: "P2", made_at: iso(t0 + 2000) }]);
    const w = await waiting(u.key);
    expect(w.jots[0].text).toBe("P2");
    expect(w.jots[0].versions.map((v: any) => v.text)).toEqual(["Mac text", "P1"]);
    const kept = () => env.DB.prepare("SELECT count(*) n FROM jot_copy_versions WHERE user_id=?").bind(u.id).first<number>("n");
    expect(await kept()).toBe(2);
    await ack(u.key, [{ key: "J-1", rev: w.jots[0].rev, mac_id: 1 }]);
    expect(await kept()).toBe(0);
  });

  it("a_newer_mac_version_keeps_a_waiting_phone_edit_for_the_history", async () => {
    const u = await setup("Mac newer");
    const t0 = Date.now() - 60_000;
    await putJots(u.key, { jots: [jot(1, { text: "Mac text", updated: iso(t0) })] });
    await phoneSend(u.cookie, [{ id: "edit-0201", op: "edit", key: "J-1", text: "Phone words", made_at: iso(t0 + 10_000) }]);
    await putJots(u.key, { jots: [jot(1, { text: "Mac newer", updated: iso(t0 + 20_000) })] });
    expect((await phoneJots(u.cookie)).jots[0].text).toBe("Mac newer");
    const w = await waiting(u.key);
    expect(w.jots).toEqual([expect.objectContaining({ key: "J-1", text: "Mac newer" })]);
    expect(w.jots[0].versions.map((v: any) => v.text)).toContain("Phone words");
  });

  it("changes_to_a_jot_the_copy_no_longer_holds_wait_for_the_mac", async () => {
    const u = await setup("Expired");
    await putJots(u.key, { jots: [jot(1, { text: "Old jot" }), jot(2, { text: "Other" })] });
    await env.DB.prepare("UPDATE jot_copies SET mac_saved_at=? WHERE user_id=?").bind(iso(Date.now() - 31 * DAY), u.id).run();
    await purgeJots(env);
    const r = await (await phoneSend(u.cookie, [{ id: "edit-0301", op: "edit", key: "J-1", text: "Edited after expiry", made_at: iso(Date.now()) },
      { id: "del-00302", op: "delete", key: "J-2", made_at: iso(Date.now()) },
      { id: "edit-0303", op: "edit", key: "phone:gone-0001", text: "Edit of a capture the engine never had", made_at: iso(Date.now()) },
      { id: "mk-000304", op: "make_task", key: "J-1", text: "Call Ann", made_at: iso(Date.now()) }])).json<any>();
    expect(r.dropped).toEqual([]);
    expect(r.accepted).toHaveLength(4);
    const w = await waiting(u.key);
    const by = Object.fromEntries(w.jots.map((j) => [j.key, j]));
    expect(by["J-1"]).toMatchObject({ mac_id: 1, text: "Edited after expiry", deleted: false });
    expect(by["J-2"]).toMatchObject({ mac_id: 2, deleted: true });
    expect(by["phone:gone-0001"]).toMatchObject({ mac_id: null, text: "Edit of a capture the engine never had" });
    expect(by["action:mk-000304"]).toMatchObject({ ref: "J-1", text: "Call Ann" });
  });

  it("a_phone_edit_landing_during_a_mac_upload_is_not_lost", async () => {
    const u = await setup("Race");
    const t0 = Date.now() - 60_000;
    await putJots(u.key, { jots: [jot(1, { text: "Mac text", updated: iso(t0) })] });
    // The phone's edit lands after the upload read the row and before it writes (Codex round 2, finding 1).
    let fired = false;
    setJotsPutRaceHook(async () => {
      if (fired) return;
      fired = true;
      await phoneSend(u.cookie, [{ id: "edit-0401", op: "edit", key: "J-1", text: "Phone words in between", made_at: iso(t0 + 5000) }]);
    });
    try {
      await putJots(u.key, { jots: [jot(1, { text: "Mac newer", updated: iso(t0 + 10_000) })] });
    } finally { setJotsPutRaceHook(undefined); }
    expect(fired).toBe(true);
    const w = await waiting(u.key);
    const texts = w.jots.flatMap((j) => [j.text, ...(j.versions ?? []).map((v: any) => v.text)]);
    expect(texts).toContain("Phone words in between");
    expect((await phoneJots(u.cookie)).jots[0].text).toBe("Mac newer");
  });

  it("an_upload_with_the_same_text_keeps_unacked_history_waiting", async () => {
    const u = await setup("Same text");
    const t0 = Date.now() - 60_000;
    await putJots(u.key, { jots: [jot(1, { text: "Mac text", updated: iso(t0) })] });
    // An older phone edit is kept only as a version (finding 2); the Mac then uploads the same text with a newer stamp.
    await phoneSend(u.cookie, [{ id: "edit-0501", op: "edit", key: "J-1", text: "Older phone words", made_at: iso(t0 - 5000) }]);
    await putJots(u.key, { jots: [jot(1, { text: "Mac text", updated: iso(t0 + 10_000) })] });
    const w = await waiting(u.key);
    expect(w.jots).toHaveLength(1);
    expect(w.jots[0].versions.map((v: any) => v.text)).toContain("Older phone words");
    await purgeJots(env, Date.now() + 40 * DAY);
    expect(await env.DB.prepare("SELECT count(*) n FROM jot_copy_versions WHERE user_id=?").bind(u.id).first<number>("n")).toBe(1);
  });

  it("phone_delete_and_make_task_wait_for_the_mac", async () => {
    const u = await setup("Delete");
    await putJots(u.key, { jots: [jot(1, { text: "Call Ann about the budget" })] });
    await phoneSend(u.cookie, [{ id: "del-0001", op: "delete", key: "J-1", made_at: iso(Date.now()) },
      { id: "mk-00001", op: "make_task", key: "J-1", text: "Call Ann", made_at: iso(Date.now()) }]);
    expect((await phoneJots(u.cookie)).jots).toHaveLength(0);
    const w = await waiting(u.key);
    expect(w.jots.map((j) => [j.key, j.kind, j.deleted, j.text, j.ref ?? null])).toEqual([
      ["J-1", "jot", true, "Call Ann about the budget", null], ["action:mk-00001", "action:make_task", false, "Call Ann", "J-1"]]);
    await ack(u.key, w.jots.map((j) => ({ key: j.key, rev: j.rev, mac_id: j.mac_id })));
    expect((await waiting(u.key)).jots).toHaveLength(0);
    expect(await env.DB.prepare("SELECT count(*) n FROM jot_copies WHERE user_id=? AND key LIKE 'action:%'").bind(u.id).first<number>("n")).toBe(0);
  });

  it("phone_refuses_bad_jot_actions_and_other_origins", async () => {
    const u = await setup("Refuse");
    const bad = await phoneSend(u.cookie, [{ id: "x", op: "add", text: "short id", made_at: iso(Date.now()) },
      { id: "add-00009", op: "add", text: "", made_at: iso(Date.now()) }, { id: "add-00010", op: "fly", made_at: iso(Date.now()) }]);
    expect((await bad.json<any>()).dropped.map((d: any) => d.reason)).toEqual(["bad id", "text is required", "unknown op"]);
    const r = await call("/app/api/jots", { method: "POST", headers: { Cookie: u.cookie, Origin: "https://evil.example" }, body: "{}" });
    expect(r.status).toBe(403);
    expect((await call("/app/api/jots")).status).toBe(401);
  });

  it("jots_off_hides_the_phone_copy", async () => {
    const u = await setup("Off", { ...ON, jots: false });
    await putJots(u.key, { jots: [jot(1)] });
    expect((await call("/app/api/jots", { headers: { Cookie: u.cookie } })).status).toBe(409);
  });
});

describe("jots: meeting notes from Fathom", () => {
  const payload = {
    title: "Weekly planning", recording_id: 4242, share_url: "https://fathom.video/share/JotNotes1",
    meeting_url: "https://meet.google.com/abc-defg-hij", scheduled_start_time: "2026-11-08T12:30:00Z",
    calendar_invitees: [{ email: "Sam@Example.com" }], default_summary: { markdown_formatted: "## Summary\nAgreed the plan." },
    action_items: [{ description: "Send the deck", assignee: { name: "Sam" } }],
  };

  it("each_recap_is_kept_once_as_meeting_notes_for_the_mac", async () => {
    const u = await setup("Notes");
    const path = await fathomHookPath(u.id);
    expect((await call(path, { method: "POST", body: JSON.stringify(payload) })).status).toBe(200);
    expect((await call(path, { method: "POST", body: JSON.stringify(payload) })).status).toBe(200);
    const w = await waiting(u.key);
    expect(w.jots).toHaveLength(1);
    expect(w.jots[0]).toMatchObject({ key: "fathom:JotNotes1", kind: "meeting_notes", source: "meeting", mac_id: null,
      meeting: { recap_key: "fathom:JotNotes1", fathom_url: "https://fathom.video/share/JotNotes1", meeting_url: "https://meet.google.com/abc-defg-hij",
        title: "Weekly planning", scheduled_start: "2026-11-08T12:30:00Z", invitees: ["sam@example.com"] } });
    expect(w.jots[0].text).toContain("Agreed the plan.");
    expect(w.jots[0].text).toContain("Send the deck");
    expect(w.jots[0].text).toContain("https://fathom.video/share/JotNotes1");
  });

  it("not_kept_while_jots_is_off", async () => {
    const u = await setup("Notes off", { ...ON, jots: false });
    const path = await fathomHookPath(u.id);
    await call(path, { method: "POST", body: JSON.stringify({ ...payload, share_url: "https://fathom.video/share/JotNotes2" }) });
    expect((await waiting(u.key)).jots).toHaveLength(0);
  });
});

describe("jots: the daily nudge on the phone", () => {
  const zone = "Europe/London";
  const at = (h: number, m: number) => Date.parse(`2026-11-17T${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:00Z`);
  const nudge = (over: Record<string, unknown> = {}) => ({ minutes: 21 * 60, zone, shown_day: null, jotted_day: null, done_today: ["Ship it"], ...over });

  it("sent_once_after_the_mac_had_ten_minutes", async () => {
    const u = await setup("Nudge");
    await putJots(u.key, { jots: [], nudge: nudge() });
    const sent: any[] = [];
    const sender = () => async (item: any) => { sent.push(item); };
    expect(await runJotNudges(env, at(21, 5), sender)).toBe(0);
    expect(await runJotNudges(env, at(21, 11), sender)).toBe(1);
    expect(await runJotNudges(env, at(21, 16), sender)).toBe(0);
    expect(sent.filter((s) => s.id.startsWith("jotnudge:"))[0]).toMatchObject({ title: "Anything to jot today?", why: "Done today: Ship it.",
      link: "/app/?go=jot" });
  });

  it("not_sent_when_shown_on_the_mac_or_already_jotted", async () => {
    for (const [name, over, phoneJot] of [["Shown", { shown_day: "2026-11-17" }, false], ["Jotted", { jotted_day: "2026-11-17" }, false],
      ["Phone jotted", {}, true], ["Off", { minutes: null }, false]] as const) {
      const u = await setup(name);
      await putJots(u.key, { jots: [], nudge: nudge(over) });
      if (phoneJot) {
        await phoneSend(u.cookie, [{ id: "cap-0100", op: "add", text: "Wrote today", made_at: iso(at(12, 0)) }], iso(at(12, 0)));
        await env.DB.prepare("UPDATE jot_copies SET added=? WHERE user_id=?").bind(iso(at(12, 0)), u.id).run();
      }
      const sent: any[] = [];
      await runJotNudges(env, at(21, 30), () => async (item: any) => { sent.push(item); });
      expect(sent.length, name).toBe(0);
    }
  });
});
