import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "../helpers";
import { decrypt } from "../../src/lib/crypto";
import { setKeysGoogleFetch } from "../../src/routes/keys";

const put = (key: string, body: unknown) => call("/v2/keys", { method: "PUT", key, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
const gmail = (key: string, body: unknown) => call("/v2/gmail", { method: "POST", key, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
let googleOK = true;
const seen: string[] = [];

beforeEach(() => {
  googleOK = true; seen.length = 0;
  setKeysGoogleFetch((async (u: RequestInfo | URL, init?: RequestInit) => {
    seen.push(String(init?.body));
    return googleOK ? Response.json({ access_token: "at", expires_in: 3600 }) : new Response("bad", { status: 400 });
  }) as typeof fetch);
});

describe("gmail and fathom from the Mac", () => {
  it("gmail_signed_in_on_the_mac_becomes_an_input", async () => {
    const u = await newUser("G1");
    const body = { address: "Me@Example.com", refresh_token: "rt-1", client_id: "desk.apps", client_secret: "ds" };
    const r = await gmail(u.key, body);
    expect(r.status).toBe(200);
    expect(seen[0]).toContain("refresh_token=rt-1");
    const row = await env.DB.prepare("SELECT address, client_id, refresh_enc, enabled FROM sources WHERE user_id=? AND kind='gmail'").bind(u.id).first<any>();
    expect(row).toMatchObject({ address: "me@example.com", client_id: "desk.apps", enabled: 1 });
    expect(await decrypt(env as any, row.refresh_enc)).toBe("rt-1");
    // Again: the same inbox is updated, not added twice.
    await gmail(u.key, { ...body, refresh_token: "rt-2" });
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM sources WHERE user_id=? AND kind='gmail'").bind(u.id).first<any>()).n).toBe(1);
  });

  it("gmail_refused_when_google_rejects_or_fields_missing", async () => {
    const u = await newUser("G2");
    googleOK = false;
    expect((await gmail(u.key, { address: "a@b.co", refresh_token: "x", client_id: "c", client_secret: "s" })).status).toBe(400);
    expect((await gmail(u.key, { address: "nope", refresh_token: "x", client_id: "c", client_secret: "s" })).status).toBe(400);
    expect((await gmail(u.key, { address: "a@b.co" })).status).toBe(400);
    expect((await call("/v2/gmail", { method: "POST", body: "{}" })).status).toBe(401);
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM sources WHERE user_id=?").bind(u.id).first<any>()).n).toBe(0);
  });

  it("fathom_key_from_the_mac_makes_the_input_and_is_never_returned", async () => {
    const u = await newUser("F1");
    const r = await put(u.key, { fathom_key: "fk-1234567890" });
    expect(r.status).toBe(200);
    const out = await r.json<any>();
    expect(out.keys.fathom).toBe(true);
    expect(JSON.stringify(out)).not.toContain("fk-1234567890");
    const row = await env.DB.prepare("SELECT fathom_key_enc FROM sources WHERE user_id=? AND kind='fathom'").bind(u.id).first<any>();
    expect(await decrypt(env as any, row.fathom_key_enc)).toBe("fk-1234567890");
    expect((await put(u.key, { fathom_key: "short" })).status).toBe(400);
    expect((await (await put(u.key, { fathom_key: "" })).json<any>()).keys.fathom).toBe(false);
  });
});
