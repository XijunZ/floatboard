/**
 * Jots' Claude jobs (docs/superpowers/specs/2026-11-17-jots-design.md §3), all Haiku, each skipped while Jots is off:
 * - `jot_tags`: tags for a batch of new jots (one call for up to 20), chosen only from the owner's tags; shown as ✓/✗.
 * - `jot_cleanup`: grammar and structure only, never substance; the owner compares before and after.
 * - `fill_form`: a short task title and the due date a selection mentions; the owner edits the form.
 */
import { z } from "zod";
import { type Env, json } from "../env";
import { decrypt } from "../lib/crypto";
import { readCappedJSON } from "../lib/http";
import { askStructured, chosenModel, makeClient, type Job } from "../lib/llm";
import { route } from "../lib/router";
import { appJSON, requireAppSession, sameOrigin } from "../phone/auth";
import { jotsOn } from "./copies";

const MAX_BATCH = 20;
const MAX_JOT = 4000;
const MAX_CLEANUP = 20_000;
const MAX_SELECTION = 4000;
const DUE = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$/;

let claudeFetch: typeof fetch | undefined;
/** Tests stand in for Claude here (never a live call). */
export function setJotsClaudeFetch(f: typeof fetch | undefined) { claudeFetch = f; }

type Gate = { ok: true; client: ReturnType<typeof makeClient> } | { ok: false; error: string };

async function claude(env: Env, userId: string, job: Job): Promise<Gate> {
  if (!(await jotsOn(env, userId))) return { ok: false, error: "jots_off" };
  const u = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(userId).first<{ anthropic_key_enc: string | null }>();
  if (!u?.anthropic_key_enc) return { ok: false, error: "no_claude_key" };
  return { ok: true, client: makeClient(await decrypt(env, u.anthropic_key_enc), claudeFetch, { env, userId, job, model: await chosenModel(env, userId, job) }) };
}

const TAGS_SYSTEM = `You suggest tags for short personal notes ("jots"). For each jot, choose 0 to 3 tags from the owner's tag list that
clearly fit what the jot is about. Use the exact names from the list; never invent a tag. When nothing fits, give no tags.`;
const TagsSchema = z.object({ jots: z.array(z.object({ id: z.number().int(), tags: z.array(z.string()) })) });

const CLEANUP_SYSTEM = `You tidy up a personal note. Fix spelling, grammar and punctuation, and make the structure clearer (sentences,
line breaks, short lists) where that helps. You must never add, change or remove any fact, name, number, amount, date, time, id
(like T-12 or J-7), link, @name or #tag, and never change what is meant. Keep the owner's words and tone where you can, keep the
same language (never translate), and keep it about the same length. Return only the cleaned note.`;
const CleanupSchema = z.object({ cleaned: z.string() });

const FILL_SYSTEM = `From text the owner selected in a note, fill in a task: a short imperative title (at most 80 characters, in the
text's language), and the due date only if the text states one (as "YYYY-MM-DD", or "YYYY-MM-DDTHH:mm" with has_time true when a
time is stated), worked out from today's date given below. When no date is stated, due is null.`;
const FillSchema = z.object({ title: z.string(), due: z.string().nullable(), has_time: z.boolean() });

async function tags(env: Env, userId: string, body: any): Promise<Response> {
  const names = body.tags, jots = body.jots;
  if (!Array.isArray(names) || names.length > 200 || !names.every((t: unknown) => typeof t === "string" && t.length <= 60)) return json({ error: "tags must be a list of names" }, 400);
  if (!Array.isArray(jots) || jots.length < 1 || jots.length > MAX_BATCH) return json({ error: `jots must be a list of 1 to ${MAX_BATCH}` }, 400);
  if (!jots.every((j: any) => Number.isInteger(j?.id) && typeof j?.text === "string")) return json({ error: "each jot needs id and text" }, 400);
  if (!names.length) return json({ suggestions: jots.map((j: any) => ({ id: j.id, tags: [] })) });
  const g = await claude(env, userId, "jot_tags");
  if (!g.ok) return json({ error: g.error }, 409);
  const user = `The owner's tags:\n${names.map((n: string) => `- ${n}`).join("\n")}\n\nJots:\n` +
    jots.map((j: any) => `<jot id="${j.id}">\n${j.text.slice(0, MAX_JOT)}\n</jot>`).join("\n");
  const r = await askStructured(g.client, { system: TAGS_SYSTEM, user, schema: TagsSchema });
  if (!r.ok) return json({ error: `Claude's answer could not be used (${r.reason})` }, 502);
  const canonical = new Map(names.map((n: string) => [n.toLowerCase(), n]));
  const by = new Map(r.value.jots.map((j) => [j.id, j.tags]));
  return json({ suggestions: jots.map((j: any) => ({ id: j.id,
    tags: [...new Set((by.get(j.id) ?? []).map((t) => canonical.get(t.trim().toLowerCase())).filter((t): t is string => !!t))].slice(0, 3) })) });
}

async function cleanup(env: Env, userId: string, body: any): Promise<{ status: number; data: unknown }> {
  if (typeof body.text !== "string" || !body.text.trim() || body.text.length > MAX_CLEANUP) return { status: 400, data: { error: `text must be 1 to ${MAX_CLEANUP} characters` } };
  const g = await claude(env, userId, "jot_cleanup");
  if (!g.ok) return { status: 409, data: { error: g.error } };
  const r = await askStructured(g.client, { system: CLEANUP_SYSTEM, user: body.text, schema: CleanupSchema, maxTokens: 8000 });
  if (!r.ok || !r.value.cleaned.trim()) return { status: 502, data: { error: "Claude's answer could not be used" } };
  return { status: 200, data: { cleaned: r.value.cleaned } };
}

async function fill(env: Env, userId: string, body: any): Promise<Response> {
  const sel = body.selection;
  if (typeof sel !== "string" || !sel.trim() || sel.length > MAX_SELECTION) return json({ error: `selection must be 1 to ${MAX_SELECTION} characters` }, 400);
  const today = typeof body.today === "string" && /^\d{4}-\d{2}-\d{2}$/.test(body.today) ? body.today : new Date().toISOString().slice(0, 10);
  const g = await claude(env, userId, "fill_form");
  if (!g.ok) return json({ error: g.error }, 409);
  const context = typeof body.context === "string" ? body.context.slice(0, MAX_SELECTION) : "";
  const user = `Today is ${today}${typeof body.zone === "string" ? ` (${body.zone.slice(0, 64)})` : ""}.\n\nSelected text:\n${sel}` +
    (context ? `\n\nThe note it comes from:\n${context}` : "");
  const r = await askStructured(g.client, { system: FILL_SYSTEM, user, schema: FillSchema, maxTokens: 400 });
  if (!r.ok) return json({ error: `Claude's answer could not be used (${r.reason})` }, 502);
  const due = r.value.due && DUE.test(r.value.due) ? r.value.due : null;
  return json({ title: r.value.title.trim().slice(0, 120), due, has_time: !!due && due.includes("T") && r.value.has_time });
}

const body = async (req: Request) => readCappedJSON(req, 200_000);

route("POST", "/v2/jots/tags", async (req, env, user) => {
  const rb = await body(req);
  return rb.ok ? tags(env, user.id, rb.body) : json({ error: "Invalid JSON" }, 400);
});
route("POST", "/v2/jots/cleanup", async (req, env, user) => {
  const rb = await body(req);
  if (!rb.ok) return json({ error: rb.tooLarge ? "too large" : "Invalid JSON" }, rb.tooLarge ? 413 : 400);
  const r = await cleanup(env, user.id, rb.body);
  return json(r.data, r.status);
});
route("POST", "/v2/jots/fill", async (req, env, user) => {
  const rb = await body(req);
  return rb.ok ? fill(env, user.id, rb.body) : json({ error: "Invalid JSON" }, 400);
});

/** The phone's cleanup (session cookie, same origin): the same job, before/after shown on the phone. */
export async function handleJotsCleanupApp(req: Request, env: Env): Promise<Response | null> {
  if (new URL(req.url).pathname !== "/app/api/jots/cleanup") return null;
  if (req.method !== "POST") return appJSON({ error: "not found" }, 404);
  if (!sameOrigin(req)) return appJSON({ error: "refused" }, 403);
  const s = await requireAppSession(req, env);
  if (!s) return appJSON({ error: "not signed in" }, 401);
  const rb = await body(req);
  if (!rb.ok) return appJSON({ error: "Invalid JSON" }, 400, s.setCookie);
  const r = await cleanup(env, s.userId, rb.body);
  return appJSON(r.data, r.status, s.setCookie);
}
