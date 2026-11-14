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
import "./archive";
import "./chats";
import { handleEmailSearch } from "./emails";
import { handleSetup, purgeExpiredSetup } from "./routes/setup";
import { log, recordCrash, runRounds, type RunOptions } from "./run";
import { Budget } from "./budget";
import { alertFor } from "./alerts";
import { purgeDueAlerts, runDueAlerts } from "./due";
import { checkWatchReplies } from "./watch";
import { ingestOutlook, judgeOutlookNow } from "./outlook";
import { appJSON, handleAppAuth, purgeExpiredApp } from "./app/auth";
import { handleBoard, purgeBoardLog, purgePhoneActions } from "./app/board";
import { handlePush } from "./app/webpush";
import { handleAppStatic } from "./app/static";

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
      return (await handleAppAuth(req, env)) ?? (await handleBoard(req, env)) ?? (await handlePush(req, env)) ?? (await handleEmailSearch(req, env)) ?? appJSON({ error: "not found" }, 404);
    }
    // Phone app page, script, service worker, manifest and icons (no sign-in needed).
    const appFile = handleAppStatic(req);
    if (appFile) return appFile;
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

  /** Every 5 minutes: due reminders, and every user with an enabled source gets a few passes (backlogs continue on the
   *  next run). On the hour also: cleanup and the Fathom catch-up. */
  async scheduled(event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    const jobs = cronJobs(event.cron, event.scheduledTime);
    if (jobs.due) ctx.waitUntil(runDueAlerts(env));
    if (jobs.read) ctx.waitUntil(runAllUsers(env, runRounds, undefined, { hourly: jobs.hourly, watch: jobs.watch }));
  },
} satisfies ExportedHandler<Env>;

/** The one schedule (wrangler.toml): every 5 minutes. One trigger only, because free accounts allow 5 for all Workers. */
export const CRON = "*/5 * * * *";
/** The schedule before 13 Nov 2026 (a config not yet updated): reminders and reading every 15 minutes. */
export const OLD_CRON = "*/15 * * * *";

/**
 * What a cron run does: due reminders and reading email/chats on every run; the hourly work (cleanup, Fathom catch-up)
 * on the run whose time falls in the first minutes of the hour (UTC). Any other schedule (an old hourly cron) does it all.
 */
export function cronJobs(cron: string, scheduledTime: number): { due: boolean; read: boolean; hourly: boolean; watch: boolean } {
  const minute = new Date(scheduledTime).getUTCMinutes();
  // Replies to Watch tasks are looked for every 15 minutes (each costs a Gmail search per inbox).
  if (cron === CRON) return { due: true, read: true, hourly: minute < 5, watch: minute % 15 < 5 };
  if (cron === OLD_CRON) return { due: true, read: true, hourly: minute < 15, watch: true };
  return { due: false, read: true, hourly: true, watch: true };
}

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
  opts: { hourly?: boolean; watch?: boolean } = {},
): Promise<void> {
  const cronStart = nowISO();
  const hourly = opts.hourly ?? true;
  const watch = opts.watch ?? true;
  // Setup-page hygiene rides on the hourly run (no extra cron): expired sessions (with their encrypted keys) and states go.
  if (hourly) try {
    await purgeExpiredSetup(env);
    await purgeExpiredApp(env);
    await purgePhoneActions(env);
    await purgeBoardLog(env);
    await purgeDueAlerts(env);
  } catch (e) {
    const msg = `Could not purge expired setup sessions: ${(e as Error)?.message ?? e}`.slice(0, 500);
    log("setup_purge_failed", { error: msg });
    try {
      await cronProblem(env, "setup purge failed", msg).run();
    } catch (e2) { console.warn("could not record setup purge failure:", (e2 as Error).message); }
  }
  let ids: string[];
  try {
    ids = userIds ?? (await env.DB.prepare("SELECT DISTINCT user_id FROM sources WHERE enabled=1 AND kind IN ('gmail','outlook_web','whatsapp')").all<{ user_id: string }>()).results.map((r) => r.user_id);
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
    if (watch) await checkWatchReplies(env, user_id, share); // never throws
    if (hourly) await catchUpFathom(env, user_id, share); // never throws; problems show in needs attention
    calls.used += share.used;
  }
}
