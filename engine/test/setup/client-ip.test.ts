import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import worker from "../../src/index";
import { BASE, freshIP, newUser } from "../helpers";

// Round 29 (security review M2, L1): the address a rate limit counts is the platform's own (Cloudflare's
// CF-Connecting-IP there; Vercel's x-real-ip on Vercel, where a CF-Connecting-IP header is the client's to invent), and
// /admin/users counts bad admin keys like the setup sign-in.
const ctx = { waitUntil() {}, passThroughOnException() {} } as any;
const vercel = { ...(env as any), PLATFORM: "vercel" };
const signin = (e: any, key: string, headers: Record<string, string>) =>
  worker.fetch(new Request(BASE + "/setup/signin", { method: "POST", redirect: "manual",
    headers: { "Content-Type": "application/x-www-form-urlencoded", ...headers }, body: new URLSearchParams({ key }).toString() }), e, ctx);

describe("rate limits count the platform's own client address", () => {
  it("on_vercel_a_made_up_cf_connecting_ip_never_resets_the_count", async () => {
    const real = freshIP();
    for (let i = 0; i < 10; i++) {
      expect((await signin(vercel, `bad-${i}`, { "x-real-ip": real, "CF-Connecting-IP": `198.51.100.${i}` })).status).toBe(401);
    }
    expect((await signin(vercel, "bad-x", { "x-real-ip": real, "CF-Connecting-IP": "198.51.100.200" })).status).toBe(429);
  });

  it("on_vercel_someone_else_failing_never_locks_the_owner_out", async () => {
    const u = await newUser("Owner on Vercel");
    const attacker = freshIP(), owner = freshIP();
    for (let i = 0; i < 12; i++) await signin(vercel, `bad-${i}`, { "x-real-ip": attacker });
    expect((await signin(vercel, u.key, { "x-real-ip": owner })).status).toBe(303);
  });

  it("with_no_address_failures_are_never_counted_in_a_shared_bucket_of_ten", async () => {
    const u = await newUser("No address");
    for (let i = 0; i < 12; i++) await signin(vercel, `bad-${i}`, {});
    expect((await signin(vercel, u.key, { "x-real-ip": freshIP() })).status).toBe(303);
  });

  it("admin_users_counts_bad_admin_keys", async () => {
    const ip = freshIP();
    const post = (key: string) => worker.fetch(new Request(BASE + "/admin/users", { method: "POST",
      headers: { "X-Admin-Key": key, "CF-Connecting-IP": ip }, body: JSON.stringify({ name: "x" }) }), env as any, ctx);
    for (let i = 0; i < 10; i++) expect((await post(`wrong-${i}`)).status).toBe(401);
    expect((await post("admin-test-key")).status).toBe(429);   // even the right key, until the window passes
  });
});
