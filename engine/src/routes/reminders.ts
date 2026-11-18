/**
 * One notification id, shown once across the Mac and the phone (docs/superpowers/specs/2026-11-17-foundation-design.md §3,
 * reminder budget). Before showing a budget reminder, the Mac claims its id: `POST /v2/reminders/claim { id }` (user key)
 * answers `{ owner: "mac" }` (show it; asking again keeps answering mac) or `{ owner: "phone" }` (the engine already sent it to
 * the phone: don't). The claim is the same `due_alerts_sent` row the engine's own send takes (`card_id` 0, `due` =
 * `budget:<id>`), so whichever comes first wins and the other never sends, even when the Mac's board update (which drops a
 * shown reminder from the copy) never arrives. A second row (`card_id` -1, same key) marks the Mac as the claimant.
 */
import { type Env, json, nowISO } from "../env";
import { readCappedJSON } from "../lib/http";
import { route } from "../lib/router";

let fault: "claim" | "release" | null = null;
/** Tests: fail between the two writes of a claim or a release (as a crash or a lost connection would). */
export function setReminderFault(f: "claim" | "release" | null) { fault = f; }
/** The failing statement a test asks for (a missing table), placed between the two writes of one batch. */
function faultStep(env: Env, at: "claim" | "release"): D1PreparedStatement[] {
  return fault === at ? [env.DB.prepare("INSERT INTO reminder_fault_test_no_such_table VALUES (1)")] : [];
}

/** The same ids the board copy accepts (parseReminders). */
const REMINDER_ID = /^[A-Za-z0-9_:.-]{1,120}$/;

route("POST", "/v2/reminders/claim", async (req, env, user) => {
  const rb = await readCappedJSON(req, 2_000);
  if (!rb.ok) return rb.tooLarge ? json({ error: "too large" }, 413) : json({ error: "Invalid JSON" }, 400);
  const id = rb.body?.id;
  if (typeof id !== "string" || !REMINDER_ID.test(id)) return json({ error: "id must be a reminder id" }, 400);
  const key = `budget:${id}`, now = nowISO();
  // One transaction (D1 batch): the Mac's marker is written only while nobody holds the send, then the send itself; a crash
  // or lost connection between them leaves neither. The answer is read in the same batch.
  const out = await env.DB.batch([
    env.DB.prepare(`INSERT OR IGNORE INTO due_alerts_sent(user_id,card_id,due,sent_at) SELECT ?,-1,?,?
        WHERE NOT EXISTS (SELECT 1 FROM due_alerts_sent WHERE user_id=? AND card_id=0 AND due=?)`).bind(user.id, key, now, user.id, key),
    ...faultStep(env, "claim"),
    env.DB.prepare("INSERT OR IGNORE INTO due_alerts_sent(user_id,card_id,due,sent_at) VALUES(?,0,?,?)").bind(user.id, key, now),
    env.DB.prepare("SELECT 1 AS x FROM due_alerts_sent WHERE user_id=? AND card_id=-1 AND due=?").bind(user.id, key),
  ]);
  return json({ owner: out[out.length - 1].results.length ? "mac" : "phone" });
});

/**
 * `POST /v2/reminders/release { id }` (user key): the Mac claimed this reminder but macOS never showed it, so it hands the
 * claim back and the engine's next run sends it to the phone (if still in the Mac's copy, within a day). Only the Mac's own
 * claim is handed back: `{ released: true }`; one the phone already got, or none, is left as it is: `{ released: false }`.
 */
route("POST", "/v2/reminders/release", async (req, env, user) => {
  const rb = await readCappedJSON(req, 2_000);
  if (!rb.ok) return rb.tooLarge ? json({ error: "too large" }, 413) : json({ error: "Invalid JSON" }, 400);
  const id = rb.body?.id;
  if (typeof id !== "string" || !REMINDER_ID.test(id)) return json({ error: "id must be a reminder id" }, 400);
  const key = `budget:${id}`;
  // One transaction: the send is handed back only together with the Mac's marker, and only when the marker is there (the
  // phone's own send is never touched).
  const out = await env.DB.batch([
    env.DB.prepare(`DELETE FROM due_alerts_sent WHERE user_id=? AND card_id=0 AND due=?
        AND EXISTS (SELECT 1 FROM due_alerts_sent WHERE user_id=? AND card_id=-1 AND due=?)`).bind(user.id, key, user.id, key),
    ...faultStep(env, "release"),
    env.DB.prepare("DELETE FROM due_alerts_sent WHERE user_id=? AND card_id=-1 AND due=?").bind(user.id, key),
  ]);
  return json({ released: (out[out.length - 1].meta.changes ?? 0) > 0 });
});
