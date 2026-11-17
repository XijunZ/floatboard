/**
 * Fathom meeting metadata for the Mac (`GET /v2/meetings?since=<ISO>`, user key): the meetings received since then, oldest
 * first, at most 200. Links, title, scheduled start and invitees' addresses only, never the summary text. Jots uses them to
 * attach meeting notes to their calendar event by code (docs/superpowers/specs/2026-11-17-foundation-design.md §4).
 */
import { json } from "../env";
import { route } from "../lib/router";

const LIMIT = 200;

route("GET", "/v2/meetings", async (req, env, user) => {
  const since = new URL(req.url).searchParams.get("since") ?? "1970-01-01T00:00:00.000Z";
  if (Number.isNaN(Date.parse(since))) return json({ error: "since must be an ISO date" }, 400);
  const rows = await env.DB.prepare(`SELECT recap_key, fathom_url, meeting_url, title, scheduled_start, invitees, received_at FROM meetings
      WHERE user_id=? AND received_at>? ORDER BY received_at LIMIT ${LIMIT}`).bind(user.id, new Date(since).toISOString())
    .all<{ recap_key: string; fathom_url: string; meeting_url: string; title: string; scheduled_start: string | null; invitees: string; received_at: string }>();
  return json({ meetings: rows.results.map((r) => ({ ...r, invitees: JSON.parse(r.invitees) as string[] })) });
});
