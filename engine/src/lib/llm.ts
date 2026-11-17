import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import type { z } from "zod";

import type { Env } from "../env";

export const HAIKU = "claude-haiku-5-5";
export const SONNET = "claude-sonnet-5-5";

/** The models a person can choose for each job (Settings › Rules & learning › AI model). */
export const ON_DEVICE = "on-device";
export const MODELS: Record<string, string> = { haiku: HAIKU, sonnet: SONNET, "on this mac": ON_DEVICE };
/** "On this Mac" (Apple's on-device model) exists only in the engine inside the Mac app, and only for judging. */
export const onDeviceAllowed = (env: Env, job: Job) => env.ON_DEVICE === "1" && job === "judge";
/** List prices in US dollars per million tokens (prompts under 100K tokens), for the app's cost estimate. */
export const PRICES: Record<string, { input: number; output: number }> = { [HAIKU]: { input: 0.10, output: 0.50 }, [SONNET]: { input: 2, output: 10 },
  [ON_DEVICE]: { input: 0, output: 0 } };
export type Job = "judge" | "recap" | "learn" | "reply" | "compare" | "jot_tags" | "jot_cleanup" | "fill_form";
export const DEFAULT_MODEL: Record<Job, "haiku" | "sonnet"> = { judge: "haiku", recap: "haiku", learn: "haiku", reply: "sonnet", compare: "haiku",
  jot_tags: "haiku", jot_cleanup: "haiku", fill_form: "haiku" };
// The assistant's jobs (Jots: jot_tags, jot_cleanup, fill_form) are fixed on Haiku (owner's rule): no model setting.
const COLUMN: Record<Job, string | null> = { judge: "model_judge", recap: "model_recap", learn: "model_judge", reply: "model_reply", compare: null,
  jot_tags: null, jot_cleanup: null, fill_form: null };

/** The model id the person chose for `job` (or its default). */
export async function chosenModel(env: Env, userId: string, job: Job): Promise<string> {
  const col = COLUMN[job];
  const v = col ? (await env.DB.prepare(`SELECT ${col} AS m FROM settings WHERE user_id=?`).bind(userId).first<{ m: string | null }>())?.m : null;
  const id = MODELS[(v ?? DEFAULT_MODEL[job]).toLowerCase()];
  if (!id || (id === ON_DEVICE && !onDeviceAllowed(env, job))) return MODELS[DEFAULT_MODEL[job]];
  return id;
}

export type Meter = { env: Env; userId: string; job: Job; model: string };

/**
 * One client per user's API key; `fetchFn` lets tests stand in for the API. With a `meter`, every request uses the
 * model chosen for that job, and each answer's token counts are added to llm_usage (for the cost estimate).
 */
export function makeClient(apiKey: string, fetchFn?: typeof fetch, meter?: Meter): Anthropic {
  const base: typeof fetch = fetchFn ?? ((...a) => fetch(...a));
  const metered: typeof fetch = !meter ? base : (async (input: RequestInfo | URL, init?: RequestInit) => {
    let i = init;
    if (typeof init?.body === "string") {
      try {
        const b = JSON.parse(init.body);
        if (b && typeof b.model === "string" && b.model !== meter.model) i = { ...init, body: JSON.stringify({ ...b, model: meter.model }) };
      } catch { /* not JSON: sent as it is */ }
    }
    const res = await base(input, i);
    if (res.ok) {
      try {
        const out = await res.clone().json<{ model?: string; usage?: { input_tokens?: number; output_tokens?: number } }>();
        await recordUsage(meter, out.model ?? meter.model, out.usage?.input_tokens ?? 0, out.usage?.output_tokens ?? 0);
      } catch { /* an answer without usage costs nothing to record */ }
    }
    return res;
  }) as typeof fetch;
  return new Anthropic({ apiKey, fetch: metered, maxRetries: 0 }); // a retry would spend another call; failed messages are retried next run
}

async function recordUsage(m: Meter, model: string, input: number, output: number) {
  await m.env.DB.prepare(`INSERT INTO llm_usage(user_id,day,job,model,calls,input_tokens,output_tokens) VALUES(?,?,?,?,1,?,?)
      ON CONFLICT(user_id,day,job,model) DO UPDATE SET calls=calls+1, input_tokens=input_tokens+excluded.input_tokens,
      output_tokens=output_tokens+excluded.output_tokens`)
    .bind(m.userId, new Date().toISOString().slice(0, 10), m.job, model, input, output).run();
}

/** Last 30 days of use per job, priced at each model's list price, as a monthly estimate in US dollars. */
export async function costEstimate(env: Env, userId: string) {
  const since = new Date(Date.now() - 30 * 86400e3).toISOString().slice(0, 10);
  const { results } = await env.DB.prepare(`SELECT job, model, SUM(calls) calls, SUM(input_tokens) i, SUM(output_tokens) o FROM llm_usage
      WHERE user_id=? AND day>=? GROUP BY job, model`).bind(userId, since).all<{ job: string; model: string; calls: number; i: number; o: number }>();
  const price = (model: string, i: number, o: number) => {
    const p = PRICES[model] ?? PRICES[SONNET];
    return (i * p.input + o * p.output) / 1e6;
  };
  const jobs: Record<string, { calls: number; usd: number; usd_if: Record<string, number> }> = {};
  for (const r of results) {
    const j = (jobs[r.job] ??= { calls: 0, usd: 0, usd_if: {} });
    j.calls += r.calls;
    j.usd += price(r.model, r.i, r.o);
    for (const [k, id] of Object.entries(MODELS)) {
      if (id === ON_DEVICE && !onDeviceAllowed(env, r.job as Job)) continue;
      j.usd_if[k] = (j.usd_if[k] ?? 0) + price(id, r.i, r.o);
    }
  }
  const round = (n: number) => Math.round(n * 100) / 100;
  return Object.fromEntries(Object.entries(jobs).map(([k, v]) => [k, { calls: v.calls, usd: round(v.usd),
    usd_if: Object.fromEntries(Object.entries(v.usd_if).map(([m, u]) => [m, round(u)])) }]));
}

export type Structured<T> = { ok: true; value: T } | { ok: false; reason: "refusal" | "unparseable" };

/**
 * One Haiku call with a structured (schema-checked) answer. A refusal or an answer that doesn't parse comes back as
 * `{ ok: false, reason }`: callers must treat that as "couldn't read the answer" (record it, retry), never as "no action".
 */
export async function askStructured<S extends z.ZodType>(
  client: Anthropic, opts: { system: string; user: string; schema: S; maxTokens?: number },
): Promise<Structured<z.infer<S>>> {
  try {
    const r = await client.messages.parse({
      model: HAIKU,
      max_tokens: opts.maxTokens ?? 2000,
      system: opts.system,
      messages: [{ role: "user", content: opts.user }],
      output_config: { effort: "low", format: zodOutputFormat(opts.schema) },
    });
    if (r.stop_reason === "refusal") return { ok: false, reason: "refusal" };
    const v = r.parsed_output as z.infer<S> | null;
    return v == null ? { ok: false, reason: "unparseable" } : { ok: true, value: v };
  } catch (e) {
    // Auth, rate-limit and server errors must surface to the run log; bad output is returned as unusable.
    if (e instanceof Anthropic.APIError) throw e;
    console.warn("haiku output unusable:", (e as Error).message);
    return { ok: false, reason: "unparseable" };
  }
}
