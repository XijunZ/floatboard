import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "../helpers";
import { decrypt, encrypt } from "../../src/lib/crypto";

const j = (key: string, path: string, body?: unknown) =>
  call(path, { key, method: body === undefined ? "GET" : "POST", headers: { "Content-Type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });

describe("handing state between a person's two engines", () => {
  it("everything set up moves: inputs with their access and position, what was judged, the claude key", async () => {
    const a = await newUser("A");
    await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-a"), a.id).run();
    await env.DB.prepare(`INSERT INTO sources(id,user_id,kind,address,refresh_enc,client_id,client_secret_enc,enabled,cursor,created)
        VALUES('s1',?,'gmail','me@x.com',?,'cid',?,1,'hist-42',?)`).bind(a.id, await encrypt(env as any, "rt-a"), await encrypt(env as any, "cs"), new Date().toISOString()).run();
    await env.DB.prepare("INSERT INTO seen(user_id,message_id,at) VALUES(?,?,?)").bind(a.id, "<m1@x>", new Date().toISOString()).run();
    const state = await (await j(a.key, "/v2/handover")).json<any>();
    expect(state.sources[0]).toMatchObject({ kind: "gmail", address: "me@x.com", cursor: "hist-42", refresh_token: "rt-a", enabled: true });
    expect(state.seen).toEqual(["<m1@x>"]);

    // The other engine (another user row stands in for it), on standby: arrives switched off, nothing lost.
    const b = await newUser("B");
    expect((await j(b.key, "/v2/handover", { ...state, apply_enabled: false })).status).toBe(200);
    let row = await env.DB.prepare("SELECT enabled, cursor, refresh_enc FROM sources WHERE user_id=? AND address='me@x.com'").bind(b.id).first<any>();
    expect(row.enabled).toBe(0);
    expect(row.cursor).toBe("hist-42");
    expect(await decrypt(env as any, row.refresh_enc)).toBe("rt-a");
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM seen WHERE user_id=? AND message_id='<m1@x>'").bind(b.id).first<any>()).n).toBe(1);
    const k = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(b.id).first<any>();
    expect(await decrypt(env as any, k.anthropic_key_enc)).toBe("sk-a");

    // At a switch: on as it was there, from the newer position.
    await j(b.key, "/v2/handover", { ...state, sources: [{ ...state.sources[0], cursor: "hist-50" }], apply_enabled: true });
    row = await env.DB.prepare("SELECT enabled, cursor FROM sources WHERE user_id=? AND address='me@x.com'").bind(b.id).first<any>();
    expect(row).toEqual({ enabled: 1, cursor: "hist-50" });
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM sources WHERE user_id=?").bind(b.id).first<any>()).n).toBe(1);
  });

  it("needs the user key and well-formed state", async () => {
    const a = await newUser("C");
    expect((await call("/v2/handover")).status).toBe(401);
    expect((await j(a.key, "/v2/handover", { nope: 1 })).status).toBe(400);
  });
});
