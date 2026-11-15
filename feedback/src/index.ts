/**
 * FloatBoard feedback (docs/architecture.md, Edition 2, C10). Run by the maintainer, separate from anyone's engine.
 *
 * POST /feedback  {install_id, text, app_version, os, diagnostics?} from Help › Send Feedback… in the Mac app.
 *   Every message is stored first, then filed as an issue in a PRIVATE GitHub repository, and announced on ntfy.
 *   At most 5 messages a day per install, 5,000 characters each. Nothing a person writes is made public.
 * Messages not filed yet are tried again on every new message, and hourly when the account has a free cron slot
 * (Cloudflare's free plan allows 5 per account). Three failures in a row send one ntfy alert, so feedback never sits unseen.
 */

export interface Env {
  DB: D1Database;
  /** owner/name of the private repository that receives the issues. */
  GITHUB_REPO: string;
  /** Fine-grained token: Issues read/write on GITHUB_REPO only. */
  GITHUB_TOKEN: string;
  /** Optional: the maintainer's ntfy topic. */
  NTFY_TOPIC?: string;
}

export const MAX_TEXT = 5000;
export const MAX_DIAGNOSTICS = 50_000;
export const MAX_BODY = 64 * 1024;
export const PER_DAY = 5;
export const ALERT_AFTER = 3;

let githubFetch: typeof fetch = (...a) => fetch(...a);
let ntfyFetch: typeof fetch = (...a) => fetch(...a);
/** Tests replace GitHub and ntfy. */
export function setFetches(github: typeof fetch, ntfy: typeof fetch) { githubFetch = github; ntfyFetch = ntfy; }

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });

type Row = { id: string; install_id: string; received: string; text: string; app_version: string | null; os: string | null;
  diagnostics: string | null; attempts: number };

const ID = /^[a-z0-9-]{8,64}$/;
const short = (s: unknown, n: number) => (typeof s === "string" ? s.trim().slice(0, n) : null);

/** Reads and checks a message; returns the problem as text when it can't be accepted. */
export function readMessage(b: unknown): { ok: true; m: Omit<Row, "id" | "received" | "attempts"> } | { ok: false; error: string } {
  if (!b || typeof b !== "object" || Array.isArray(b)) return { ok: false, error: "send a JSON object" };
  const o = b as Record<string, unknown>;
  const install = typeof o.install_id === "string" ? o.install_id.trim().toLowerCase() : "";
  if (!ID.test(install)) return { ok: false, error: "install_id is missing or not valid" };
  const text = typeof o.text === "string" ? o.text.trim() : "";
  if (!text) return { ok: false, error: "the message is empty" };
  if (text.length > MAX_TEXT) return { ok: false, error: `the message is longer than ${MAX_TEXT} characters` };
  const diagnostics = o.diagnostics == null ? null : typeof o.diagnostics === "string" ? o.diagnostics : null;
  if (diagnostics && diagnostics.length > MAX_DIAGNOSTICS) return { ok: false, error: "the diagnostics are too long" };
  return { ok: true, m: { install_id: install, text, app_version: short(o.app_version, 40), os: short(o.os, 200), diagnostics } };
}

/** The GitHub issue for one message. The title is the message's first line. */
export function issueFor(r: Row): { title: string; body: string } {
  const first = r.text.split("\n")[0].trim();
  const title = "Feedback: " + (first.length > 70 ? first.slice(0, 67) + "…" : first);
  let body = `${r.text}\n\n---\nApp ${r.app_version ?? "?"} · ${r.os ?? "?"} · install ${r.install_id.slice(0, 8)} · received ${r.received} · id ${r.id}`;
  if (r.diagnostics) body += `\n\n<details><summary>Diagnostics</summary>\n\n\`\`\`json\n${r.diagnostics}\n\`\`\`\n</details>`;
  return { title, body };
}

async function meta(env: Env, key: string): Promise<string | null> {
  return (await env.DB.prepare("SELECT value FROM meta WHERE key=?").bind(key).first<{ value: string }>())?.value ?? null;
}
const setMeta = (env: Env, key: string, value: string) =>
  env.DB.prepare("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)").bind(key, value).run();

async function ntfy(env: Env, title: string, message: string): Promise<void> {
  if (!env.NTFY_TOPIC) return;
  try {
    await ntfyFetch(`https://ntfy.sh/${encodeURIComponent(env.NTFY_TOPIC)}`, {
      method: "POST", headers: { Title: title, Tags: "speech_balloon" }, body: message.slice(0, 400),
    });
  } catch (e) {
    console.warn(JSON.stringify({ event: "ntfy_failed", error: (e as Error)?.message }));
  }
}

/** Files one message on GitHub. Records the outcome; three failures in a row alert the maintainer once. */
export async function file(env: Env, r: Row): Promise<boolean> {
  let error: string;
  try {
    const res = await githubFetch(`https://api.github.com/repos/${env.GITHUB_REPO}/issues`, {
      method: "POST",
      headers: { Authorization: `Bearer ${env.GITHUB_TOKEN}`, Accept: "application/vnd.github+json", "User-Agent": "floatboard-feedback",
        "Content-Type": "application/json" },
      body: JSON.stringify({ ...issueFor(r), labels: ["feedback"] }),
    });
    if (res.ok) {
      const out = await res.json<{ html_url?: string }>();
      await env.DB.batch([
        env.DB.prepare("UPDATE feedback SET issue_url=?, attempts=attempts+1, last_error=NULL WHERE id=?").bind(out.html_url ?? "filed", r.id),
        env.DB.prepare("INSERT OR REPLACE INTO meta(key,value) VALUES('github_failures','0')"),
        env.DB.prepare("DELETE FROM meta WHERE key='alerted'"),
      ]);
      return true;
    }
    error = `GitHub answered ${res.status}: ${(await res.text()).slice(0, 200)}`;
  } catch (e) {
    error = `GitHub unreachable: ${(e as Error)?.message ?? e}`;
  }
  const failures = Number(await meta(env, "github_failures") ?? "0") + 1;
  await env.DB.batch([
    env.DB.prepare("UPDATE feedback SET attempts=attempts+1, last_error=? WHERE id=?").bind(error, r.id),
    env.DB.prepare("INSERT OR REPLACE INTO meta(key,value) VALUES('github_failures',?)").bind(String(failures)),
  ]);
  if (failures >= ALERT_AFTER && !(await meta(env, "alerted"))) {
    await ntfy(env, "FloatBoard feedback can't reach GitHub", `${failures} tries in a row failed. Messages are kept and retried hourly. Last: ${error}`);
    await setMeta(env, "alerted", new Date().toISOString());
  }
  return false;
}

async function receive(req: Request, env: Env, ctx?: ExecutionContext): Promise<Response> {
  const len = Number(req.headers.get("Content-Length") ?? "0");
  if (len > MAX_BODY) return json({ error: "the message is too large" }, 413);
  const raw = await req.text();
  if (raw.length > MAX_BODY) return json({ error: "the message is too large" }, 413);
  let body: unknown;
  try { body = JSON.parse(raw); } catch { return json({ error: "send a JSON object" }, 400); }
  const read = readMessage(body);
  if (!read.ok) return json({ error: read.error }, 400);
  const since = new Date(Date.now() - 86_400_000).toISOString();
  const n = (await env.DB.prepare("SELECT COUNT(*) n FROM feedback WHERE install_id=? AND received>?").bind(read.m.install_id, since)
    .first<{ n: number }>())?.n ?? 0;
  if (n >= PER_DAY) return json({ error: `at most ${PER_DAY} messages a day; please try again tomorrow` }, 429);
  const row: Row = { id: crypto.randomUUID(), received: new Date().toISOString(), attempts: 0, ...read.m };
  await env.DB.prepare("INSERT INTO feedback(id,install_id,received,text,app_version,os,diagnostics) VALUES(?,?,?,?,?,?,?)")
    .bind(row.id, row.install_id, row.received, row.text, row.app_version, row.os, row.diagnostics).run();
  // Stored: the person gets "sent" even if GitHub is down (the hourly run files it later).
  await Promise.all([file(env, row), ntfy(env, "FloatBoard feedback", row.text)]);
  // Older messages still waiting for GitHub get another try (in the background).
  ctx?.waitUntil(retry(env, row.id));
  return json({ ok: true, id: row.id });
}

/** Files what is still waiting, oldest first (`skip`: a message just tried). */
export async function retry(env: Env, skip = ""): Promise<number> {
  const { results } = await env.DB.prepare("SELECT * FROM feedback WHERE issue_url IS NULL AND id<>? ORDER BY received LIMIT 20").bind(skip).all<Row>();
  let filed = 0;
  for (const r of results) if (await file(env, r)) filed++;
  return filed;
}

export default {
  async fetch(req: Request, env: Env, ctx?: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/feedback") {
      if (req.method !== "POST") return json({ error: "use POST" }, 405);
      return receive(req, env, ctx);
    }
    if (url.pathname === "/") return json({ ok: true, service: "floatboard-feedback" });
    return json({ error: "not found" }, 404);
  },
  async scheduled(_c: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(retry(env));
  },
};
