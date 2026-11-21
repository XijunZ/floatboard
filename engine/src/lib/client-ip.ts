import type { Env } from "../env";

/**
 * The client's address as the platform reports it (round 29, security review M2), for rate limits. On Cloudflare,
 * CF-Connecting-IP is set by Cloudflare. On Vercel (`env.PLATFORM === "vercel"`, set by vercel/engine.js) that header is
 * the client's to invent, so Vercel's own x-real-ip is used (or the first x-forwarded-for entry, which Vercel's edge
 * sets). null when the platform gives none: callers never count such requests in one shared bucket.
 */
export function clientIP(req: Request, env: Env): string | null {
  const h = (n: string) => req.headers.get(n)?.trim() || null;
  if (env.PLATFORM === "vercel") return h("x-real-ip") ?? h("x-forwarded-for")?.split(",")[0]?.trim() ?? null;
  return h("CF-Connecting-IP");
}
