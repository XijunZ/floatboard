import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { addItem, call, newUser } from "./helpers";

describe("auth", () => {
  it("rejects_missing_key", async () => {
    const r = await call("/v2/status");
    expect(r.status).toBe(401);
  });

  it("accepts_valid_key", async () => {
    const u = await newUser("Alex");
    expect((await call("/v2/status", { key: u.key })).status).toBe(200);
  });

  it("admin_creates_user_returns_key_once", async () => {
    const r = await call("/admin/users", { method: "POST", body: JSON.stringify({ name: "Nope" }) });
    expect(r.status).toBe(401); // no admin key
    const u = await newUser("Sam");
    expect(u.key.length).toBeGreaterThanOrEqual(32);
    const row = await env.DB.prepare("SELECT key_hash FROM users WHERE id=?").bind(u.id).first<{ key_hash: string }>();
    expect(row!.key_hash).not.toBe(u.key); // only a hash is stored
  });

  it("users_isolated", async () => {
    const a = await newUser("A");
    const b = await newUser("B");
    await addItem(b.id);
    const r = await call("/v2/proposals", { key: a.key });
    expect(r.status).toBe(200);
    expect((await r.json<any>()).items).toEqual([]);
  });
});
