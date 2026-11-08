import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import type { z } from "zod";

export const HAIKU = "claude-haiku-5-5";
export const SONNET = "claude-sonnet-5-5";

/** One client per user's API key; `fetchFn` lets tests stand in for the API. */
export function makeClient(apiKey: string, fetchFn?: typeof fetch): Anthropic {
  return new Anthropic({ apiKey, ...(fetchFn ? { fetch: fetchFn } : {}), maxRetries: 0 }); // a retry would spend another call; failed messages are retried next run
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
