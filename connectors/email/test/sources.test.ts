import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { newUser } from "./helpers";
import { decrypt } from "../src/crypto";
import { upsertGmail } from "../src/routes/sources";

const gmail = (address: string, refresh_token = "refresh-secret-123") =>
  ({ address, refresh_token, client_id: "cid.apps.googleusercontent.com", client_secret: "csecret" });

describe("gmail sources", () => {
  it("refresh_token_stored_encrypted", async () => {
    const u = await newUser("X");
    await upsertGmail(env as any, u.id, gmail("b@gmail.com"));
    const row = await env.DB.prepare("SELECT refresh_enc, client_secret_enc FROM sources WHERE user_id=?").bind(u.id)
      .first<{ refresh_enc: string; client_secret_enc: string }>();
    expect(row!.refresh_enc).not.toContain("refresh-secret-123");
    expect(await decrypt(env as any, row!.refresh_enc)).toBe("refresh-secret-123");
    expect(await decrypt(env as any, row!.client_secret_enc)).toBe("csecret");
  });

  it("upsert_same_address", async () => {
    const u = await newUser("X");
    await upsertGmail(env as any, u.id, gmail("c@gmail.com", "r1"));
    await upsertGmail(env as any, u.id, gmail("c@gmail.com", "r2"));
    const rows = await env.DB.prepare("SELECT refresh_enc FROM sources WHERE user_id=?").bind(u.id).all<{ refresh_enc: string }>();
    expect(rows.results).toHaveLength(1);
    expect(await decrypt(env as any, rows.results[0].refresh_enc)).toBe("r2");
  });
});
