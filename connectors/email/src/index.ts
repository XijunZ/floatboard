import { authUser, insertUser, isAdmin } from "./auth";
import { type Env, json, nowISO } from "./env";
import { logEvent } from "./runlog";
import { routes } from "./router";
import { readJSON } from "./http";
import { decrypt } from "./crypto";
import { processRecap } from "./recap";
import { fathomSignatureProblem, fathomToMessage } from "./sources/fathom";
import { catchUpFathom } from "./sources/fathomCatchup";
import "./routes/sources";
import "./routes/v2";
import { handleSetup, purgeExpiredSetup } from "./routes/setup";
import { log, recordCrash, runRounds, type RunOptions } from "./run";
import { Budget } from "./budget";
import { alertFor } from "./alerts";
import { telegramWebhook, userBotWebhook } from "./telegram";
import { ingestOutlook, judgeOutlookNow } from "./outlook";
import { appJSON, handleAppAuth, purgeExpiredApp } from "./app/auth";
import { handleBoard, purgePhoneActions } from "./app/board";

async function createUser(req: Request, env: Env): Promise<Response> {
  const rb = await readJSON(req);
  if (!rb.ok) return rb.res;
  const body: { name?: string } = rb.body;
  const name = (body.name ?? "").trim();
  if (!name) return json({ error: "name required" }, 400);
  return json(await insertUser(env, name)); // the key is only ever returned here (and on the /setup/admin invite page)
}

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/admin/users" && req.method === "POST") {
      return isAdmin(req, env) ? createUser(req, env) : json({ error: "unauthorized" }, 401);
    }
    if (url.pathname === "/setup" || url.pathname.startsWith("/setup/")) return handleSetup(req, env);
    if (url.pathname === "/telegram/webhook" && req.method === "POST") return telegramWebhook(req, env);
    const ownBot = /^\/telegram\/webhook\/u\/([A-Za-z0-9_-]{1,64})$/.exec(url.pathname);
    if (ownBot && req.method === "POST") return userBotWebhook(req, env, ownBot[1]);
    if (url.pathname === "/ingest/outlook" && req.method === "POST") {
      return ingestOutlook(req, env, (userId) => ctx.waitUntil(judgeOutlookNow(env, userId)));
    }
    const hook = /^\/hooks\/fathom\/([A-Za-z0-9_-]+)$/.exec(url.pathname);
    if (hook && req.method === "POST") {
      const src = await env.DB.prepare("SELECT id, user_id, hook_secret_enc FROM sources WHERE kind='fathom' AND hook_id=? AND enabled=1")
        .bind(hook[1]).first<{ id: string; user_id: string; hook_secret_enc: string | null }>();
      if (!src) return json({ error: "not found" }, 404);
      const raw = await req.text();
      if (src.hook_secret_enc) {
        const problem = await fathomSignatureProblem(await decrypt(env, src.hook_secret_enc), req.headers, raw);
        if (problem) {
          await logEvent(env, { run_id: "fathom", user_id: src.user_id, decision: "Fathom delivery rejected", detail: problem,
            trace: req.headers.get("webhook-id") ?? "" }).run();
          return json({ error: "invalid signature" }, 401);
        }
      }
      const trace = req.headers.get("webhook-id") ?? "";
      const rp = await readJSON(new Request(req.url, { method: "POST", body: raw }));
      if (!rp.ok || !Object.keys(rp.body).length) {
        await logEvent(env, { run_id: "fathom", user_id: src.user_id, decision: "Fathom delivery unreadable", detail: raw.slice(0, 200), trace }).run();
        return json({ error: "bad payload" }, 400);
      }
      try {
        await processRecap(env, src.user_id, fathomToMessage(rp.body, src.id), undefined, { rawOnUnusable: true });
      } catch (e) {
        // A 500 makes Fathom retry; the hourly catch-up is the second chance.
        const msg = `Fathom notes couldn't be saved: ${(e as Error)?.message ?? e}`.slice(0, 300);
        await env.DB.batch([
          logEvent(env, { run_id: "fathom", user_id: src.user_id, decision: "Fathom delivery failed", detail: msg, trace }),
          env.DB.prepare("UPDATE sources SET last_error=? WHERE id=?").bind(msg, src.id),
        ]);
        return json({ error: "could not save" }, 500);
      }
      await env.DB.prepare("UPDATE sources SET last_run=?, last_error=NULL WHERE id=?").bind(nowISO(), src.id).run();
      return json({ ok: true });
    }
    if (url.pathname.startsWith("/app/api/")) {
      // Phone app: signed in by the fb_session cookie only (never the user key).
      return (await handleAppAuth(req, env)) ?? (await handleBoard(req, env)) ?? appJSON({ error: "not found" }, 404);
    }
    if (url.pathname.startsWith("/v2/")) {
      const user = await authUser(req, env);
      if (!user) return json({ error: "unauthorized" }, 401);
      for (const r of routes) {
        const m = r.method === req.method ? r.pattern.exec(url.pathname) : null;
        if (m) return r.handler(req, env, user, Object.fromEntries(r.keys.map((k, i) => [k, m[i + 1]])), ctx);
      }
    }
    return json({ error: "not found" }, 404);
  },

  /** Hourly: every user with an enabled source gets a few passes; backlogs continue next hour. */
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runAllUsers(env));
  },
} satisfies ExportedHandler<Env>;

const cronProblem = (env: Env, decision: string, detail: string) =>
  logEvent(env, { run_id: "cron", user_id: "", decision, detail, trace: "cron" });

/**
 * One cron invocation: users take turns sharing one call budget. A crash in one user's run is recorded as a `runs` row
 * (stopped='crashed' + the error) and never stops the next user.
 */
export async function runAllUsers(
  env: Env,
  runner: (env: Env, userId: string, opts: RunOptions) => Promise<unknown> = runRounds,
  userIds?: string[],
): Promise<void> {
  const cronStart = nowISO();
  // Setup-page hygiene rides on the hourly cron (no extra cron): expired sessions (with their encrypted keys) and states go.
  try {
    await purgeExpiredSetup(env);
    await purgeExpiredApp(env);
    await purgePhoneActions(env);
  } catch (e) {
    const msg = `Could not purge expired setup sessions: ${(e as Error)?.message ?? e}`.slice(0, 500);
    log("setup_purge_failed", { error: msg });
    try {
      await cronProblem(env, "setup purge failed", msg).run();
    } catch (e2) { console.warn("could not record setup purge failure:", (e2 as Error).message); }
  }
  let ids: string[];
  try {
    ids = userIds ?? (await env.DB.prepare("SELECT DISTINCT user_id FROM sources WHERE enabled=1 AND kind IN ('gmail','outlook_web')").all<{ user_id: string }>()).results.map((r) => r.user_id);
  } catch (e) {
    // Without the user list nobody can be read: make that visible (system rows, user_id '') rather than only in the console.
    const msg = `Cron could not list users: ${(e as Error)?.message ?? e}`.slice(0, 500);
    log("cron_lookup_failed", { error: msg });
    try {
      const now = nowISO();
      await env.DB.batch([
        env.DB.prepare("INSERT INTO runs(id,user_id,started,finished,processed,error,stopped) VALUES(?,'',?,?,0,?,'crashed')").bind(crypto.randomUUID(), now, now, msg),
        cronProblem(env, "cron could not list users", msg),
      ]);
    } catch (e2) { console.warn("could not record cron failure:", (e2 as Error).message); }
    return;
  }
  const calls = new Budget();
  for (const user_id of ids) {
    if (calls.remaining < 4) { log("cron_out_of_calls", { skippedUser: user_id }); continue; }
    const share = new Budget(Math.max(4, Math.floor(calls.remaining / Math.max(1, ids.length))));
    try {
      await runner(env, user_id, { calls: share, alert: alertFor(env, user_id) });
    } catch (e) {
      await recordCrash(env, user_id, cronStart, e, share.used);
    }
    await catchUpFathom(env, user_id, share); // never throws; problems show in needs attention
    calls.used += share.used;
  }
}
