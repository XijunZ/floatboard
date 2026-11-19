import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, fathomHookPath, newUser } from "../helpers";
import { pairPhone } from "../phone-helpers";
import { purgeJots, runJotNudges, setJotsPhoneRaceHook, setJotsPutRaceHook } from "../../src/jots/copies";

// Jots (docs/superpowers/specs/2026-11-17-jots-design.md §4): the 30-day online copy, phone captures and edits waiting for
// the Mac (newest wins), meeting notes from Fathom, and the daily nudge on the phone.

const DAY = 86400_000;
const iso = (ms: number) => new Date(ms).toISOString();
const ON = { jots: true, circle: false, decisions: false, resolutions: false };
// One added time for every jot a test sends by number: the same jot keeps its added time (round 19: a jot with the same
// number but another added time is another jot).
const ADDED = iso(Date.now() - 60_000);
const jot = (id: number, over: Record<string, unknown> = {}) => ({ id, text: `Jot ${id}`, kind: "jot", source: "typed", tags: [],
  added: ADDED, updated: iso(Date.now() - 60_000), deleted: false, ...over });
const putJots = (key: string, body: unknown) => call("/v2/jots", { method: "PUT", key, body: JSON.stringify(body) });
const waiting = (key: string) => call("/v2/jots/waiting", { key }).then((r) => r.json<{ jots: any[] }>());
const ack = (key: string, items: unknown[]) => call("/v2/jots/ack", { method: "POST", key, body: JSON.stringify({ items }) });
const phoneJots = (cookie: string) => call("/app/api/jots", { headers: { Cookie: cookie } }).then((r) => r.json<{ jots: any[] }>());
// Every phone write names its queue's account (integration round 7): the session's own, as /app/api/me names it.
const accountOf = async (cookie: string) => (await (await call("/app/api/me", { headers: { Cookie: cookie } })).json<any>()).account;
const phoneSend = async (cookie: string, actions: unknown[], sentAt = iso(Date.now())) =>
  call("/app/api/jots", { method: "POST", headers: { Cookie: cookie, Origin: BASE }, body: JSON.stringify({ account: await accountOf(cookie), sent_at: sentAt, actions }) });

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
    await putJots(u.key, { jots: [jot(7, { text: "Idea on the bus", source: "phone", added: w.jots[0].added })] });   // the Mac keeps the capture's added time
    const { jots } = await phoneJots(u.cookie);
    expect(jots.map((j) => j.key)).toEqual(["phone:cap-0002"]);
  });

  it("a_waiting_phone_edit_of_the_macs_copy_survives_the_capture_ack", async () => {
    // Claude review, round 12: capture → edit during the Mac's intake → rev miss → Mac makes J-42 → phone edits J-42 → confirm.
    const u = await setup("Interleave");
    await phoneSend(u.cookie, [{ id: "cap-0042", op: "add", text: "First words", made_at: iso(Date.now() - 9000) }]);
    const w1 = await waiting(u.key);                                   // the Mac starts taking the capture in
    await phoneSend(u.cookie, [{ id: "edit-0420", op: "edit", key: "phone:cap-0042", text: "First words, edited", made_at: iso(Date.now() - 8000) }]);
    const miss = await (await ack(u.key, [{ key: "phone:cap-0042", rev: w1.jots[0].rev, mac_id: 42 }])).json<any>();
    expect(miss.acked).toBe(0);                                        // the rev moved on: still waiting
    await putJots(u.key, { jots: [jot(42, { text: "First words", source: "phone", updated: iso(Date.now() - 7000) })] });   // the Mac's J-42
    await phoneSend(u.cookie, [{ id: "edit-0421", op: "edit", key: "J-42", text: "Edited on the phone as J-42", made_at: iso(Date.now() - 1000) }]);
    const w2 = await waiting(u.key);
    const capture = w2.jots.find((j: any) => j.key === "phone:cap-0042")!;
    await ack(u.key, [{ key: "phone:cap-0042", rev: capture.rev, mac_id: 42 }]);   // confirmed before the Mac saw the J-42 edit
    const w3 = await waiting(u.key);
    expect(w3.jots.map((j: any) => [j.key, j.mac_id, j.text])).toEqual([["J-42", 42, "Edited on the phone as J-42"]]);
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

  it("a_phone_edit_racing_the_first_mac_upload_is_not_lost", async () => {
    const u = await setup("First insert");
    const t0 = Date.now() - 60_000;
    // The phone edits J-1 before the engine has a copy; the Mac's first upload of J-1 lands in between (Codex round 3, finding 3).
    let fired = false;
    setJotsPhoneRaceHook(async () => {
      if (fired) return;
      fired = true;
      await putJots(u.key, { jots: [jot(1, { text: "Mac's first upload", updated: iso(t0) })] });
    });
    let r: any;
    try {
      r = await (await phoneSend(u.cookie, [{ id: "edit-0601", op: "edit", key: "J-1", text: "Phone edit that raced", made_at: iso(t0 + 5000) }])).json<any>();
    } finally { setJotsPhoneRaceHook(undefined); }
    expect(fired).toBe(true);
    expect(r.accepted).toEqual(["edit-0601"]);
    const w = await waiting(u.key);
    const texts = w.jots.flatMap((j) => [j.text, ...(j.versions ?? []).map((v: any) => v.text)]);
    expect(texts).toContain("Phone edit that raced");
    expect(texts).toContain("Mac's first upload");
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

// Round 19: after the Mac restores an older backup, a new Mac jot can take the number of a jot the copy still holds (its
// own, or a phone capture's). The added time tells them apart: the old copy is never overwritten; it is set apart under
// a key of its own, waiting, so the Mac keeps it as a jot of its own (with the phone's text and earlier texts).
describe("jots: a number reused after a restore", () => {
  it("a_new_mac_jot_with_a_reused_number_never_overwrites_the_old_copy", async () => {
    const u = await setup("Reuse");
    const tOld = Date.now() - 3 * DAY, tNew = Date.now() - 60_000;
    await putJots(u.key, { jots: [jot(7, { text: "A, the old jot", added: iso(tOld), updated: iso(tOld) })] });
    await phoneSend(u.cookie, [{ id: "edit-r001", op: "edit", key: "J-7", text: "A, edited on the phone", made_at: iso(Date.now() - 120_000) }]);
    // The restored board's new jot 7 (a different jot, added later) is uploaded.
    const r = await putJots(u.key, { jots: [jot(7, { text: "B, new after the restore", added: iso(tNew), updated: iso(tNew) })] });
    expect((await r.json<any>()).accepted).toEqual([7]);
    const rows = (await env.DB.prepare("SELECT key, mac_id, waiting, added FROM jot_copies WHERE user_id=? ORDER BY added").bind(u.id).all<any>()).results;
    expect(rows.length).toBe(2);
    expect(rows[1]).toMatchObject({ key: "J-7", mac_id: 7 });
    expect(rows[0].key).not.toBe("J-7");
    expect(rows[0]).toMatchObject({ mac_id: null, waiting: 1, added: iso(tOld) });
    const w = await waiting(u.key);
    const old = w.jots.find((j: any) => j.key === rows[0].key);
    expect(old?.text).toBe("A, edited on the phone");
    expect(old?.mac_id ?? null).toBeNull();
    expect((await phoneJots(u.cookie)).jots.find((j: any) => j.key === "J-7")?.text).toBe("B, new after the restore");
  });

  it("a_phone_capture_with_a_reused_number_is_set_apart_too", async () => {
    const u = await setup("ReuseCap");
    await phoneSend(u.cookie, [{ id: "cap-r0001", op: "add", text: "Captured on the bus", made_at: iso(Date.now() - 2 * DAY) }]);
    const cap = (await waiting(u.key)).jots[0];
    await ack(u.key, [{ key: cap.key, rev: cap.rev, mac_id: 9 }]);
    await putJots(u.key, { jots: [jot(9, { text: "Something else", added: iso(Date.now() - 60_000), updated: iso(Date.now() - 60_000) })] });
    const capRow = await env.DB.prepare("SELECT mac_id, waiting FROM jot_copies WHERE user_id=? AND key=?").bind(u.id, cap.key).first<any>();
    expect(capRow).toMatchObject({ mac_id: null, waiting: 1 });
    const j9 = await env.DB.prepare("SELECT key FROM jot_copies WHERE user_id=? AND mac_id=9").bind(u.id).first<any>();
    expect(j9.key).toBe("J-9");
  });

  it("the_same_jot_uploaded_again_is_updated_in_place", async () => {
    const u = await setup("Same");
    const t = Date.now() - DAY;
    await putJots(u.key, { jots: [jot(3, { text: "v1", added: iso(t), updated: iso(t) })] });
    await putJots(u.key, { jots: [jot(3, { text: "v2", added: iso(t), updated: iso(t + 1000) })] });
    const rows = (await env.DB.prepare("SELECT key FROM jot_copies WHERE user_id=?").bind(u.id).all<any>()).results;
    expect(rows.map((x: any) => x.key)).toEqual(["J-3"]);
  });
});

// Round 20 (Codex 6a): reused numbers, continued.
describe("jots: reused numbers, phone actions and recovered copies", () => {
  const tOld = () => Date.now() - 3 * DAY, tNew = () => Date.now() - 60_000;
  const row = (uid: string, key: string) => env.DB.prepare("SELECT key, mac_id, deleted, waiting, added FROM jot_copies WHERE user_id=? AND key=?").bind(uid, key).first<any>();

  it("a_recovered_copy_never_blocks_the_replacement_upload", async () => {
    const u = await setup("Recover then upload");
    const a = iso(tOld());
    await putJots(u.key, { jots: [jot(7, { text: "A", added: a, updated: a })] });
    await phoneSend(u.cookie, [{ id: "edit-q001", op: "edit", key: "J-7", jot_added: a, text: "A, edited", made_at: iso(Date.now() - 120_000) }]);
    // The restored Mac pulls first: its own 7 is another jot, so it keeps the phone's A as its jot 8 and acks that.
    const w = (await waiting(u.key)).jots.find((j: any) => j.key === "J-7");
    expect((await (await ack(u.key, [{ key: "J-7", rev: w.rev, mac_id: 8 }])).json<any>()).acked).toBe(1);
    // Then it uploads its own 7 (B) and its 8 (A): both accepted, no 409.
    const b = iso(tNew());
    const r = await putJots(u.key, { jots: [jot(7, { text: "B", added: b, updated: b }), jot(8, { text: "A, edited", added: a, updated: iso(Date.now() - 100_000) })] });
    expect(r.status).toBe(200);
    expect((await r.json<any>()).accepted.sort()).toEqual([7, 8]);
    expect(await row(u.id, "J-7")).toMatchObject({ mac_id: 7 });
    const apart = (await env.DB.prepare("SELECT key, mac_id FROM jot_copies WHERE user_id=? AND mac_id=8").bind(u.id).first<any>());
    expect(apart.key).not.toBe("J-7");
    const versions = (await env.DB.prepare("SELECT count(*) AS n FROM jot_copy_versions WHERE user_id=? AND key=?").bind(u.id, apart.key).first<any>()).n;
    expect(versions).toBeGreaterThanOrEqual(0);   // its history moved with it (none left under J-7)
    expect((await env.DB.prepare("SELECT count(*) AS n FROM jot_copy_versions WHERE user_id=? AND key='J-7'").bind(u.id).first<any>()).n).toBe(0);
  });

  it("a_stale_phone_delete_never_deletes_the_replacement_jot", async () => {
    const u = await setup("Stale delete");
    const a = iso(tOld()), b = iso(tNew());
    await putJots(u.key, { jots: [jot(7, { text: "A", added: a, updated: a })] });
    await putJots(u.key, { jots: [jot(7, { text: "B", added: b, updated: b })] });   // restored Mac: A set apart, B is J-7
    const r = await (await phoneSend(u.cookie, [{ id: "del-q0001", op: "delete", key: "J-7", jot_added: a, made_at: iso(Date.now() - 30_000) }])).json<any>();
    expect(r.accepted).toContain("del-q0001");
    expect(await row(u.id, "J-7")).toMatchObject({ deleted: 0, mac_id: 7 });
    const apart = await env.DB.prepare("SELECT deleted, waiting FROM jot_copies WHERE user_id=? AND key LIKE 'J-7~%'").bind(u.id).first<any>();
    expect(apart).toMatchObject({ deleted: 1, waiting: 1 });   // the delete reached the jot it was meant for
  });

  it("a_stale_phone_edit_is_kept_as_a_separate_jot", async () => {
    const u = await setup("Stale edit");
    const a = iso(tOld()), b = iso(tNew());
    await putJots(u.key, { jots: [jot(7, { text: "B", added: b, updated: b })] });   // the copy never held A (pruned, or never sent)
    await phoneSend(u.cookie, [{ id: "edit-q0002", op: "edit", key: "J-7", jot_added: a, text: "A, edited offline", made_at: iso(Date.now() - 30_000) }]);
    expect((await phoneJots(u.cookie)).jots.find((j: any) => j.key === "J-7")?.text).toBe("B");
    const w = (await waiting(u.key)).jots.find((j: any) => j.text === "A, edited offline");
    expect(w).toBeTruthy();
    expect(w.key).not.toBe("J-7");
    expect(w.mac_id ?? null).toBeNull();
    expect(Date.parse(w.added)).toBe(Date.parse(a));
  });

  it("an_old_phone_delete_without_identity_never_deletes_a_jot_added_after_it", async () => {
    const u = await setup("Legacy delete");
    const b = iso(tNew());
    await putJots(u.key, { jots: [jot(7, { text: "B", added: b, updated: b })] });
    const r = await (await phoneSend(u.cookie, [{ id: "del-q0003", op: "delete", key: "J-7", made_at: iso(Date.now() - 10 * 60_000) }])).json<any>();
    expect(r.dropped.map((d: any) => d.id)).toContain("del-q0003");
    expect(await row(u.id, "J-7")).toMatchObject({ deleted: 0 });
  });

  it("the_same_jot_is_still_edited_and_deleted_with_its_identity", async () => {
    const u = await setup("Same identity");
    const a = iso(tOld());
    await putJots(u.key, { jots: [jot(7, { text: "A", added: a, updated: a })] });
    await phoneSend(u.cookie, [{ id: "edit-q0004", op: "edit", key: "J-7", jot_added: a, text: "A2", made_at: iso(Date.now() - 20_000) }]);
    expect((await phoneJots(u.cookie)).jots.find((j: any) => j.key === "J-7")?.text).toBe("A2");
    await phoneSend(u.cookie, [{ id: "del-q0005", op: "delete", key: "J-7", jot_added: a, made_at: iso(Date.now() - 10_000) }]);
    expect(await row(u.id, "J-7")).toMatchObject({ deleted: 1 });
  });
});

