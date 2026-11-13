import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "./helpers";

const add = (userId: string, id: string, kind: string, address: string) =>
  env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,enabled,created) VALUES(?,?,?,?,1,?)").bind(id, userId, kind, address, new Date().toISOString()).run();

describe("inputs in the status", () => {
  it("lists_this_users_inputs_without_secrets", async () => {
    const a = await newUser("A"), b = await newUser("B");
    await add(a.id, "s1", "gmail", "a@gmail.com");
    await add(a.id, "s2", "whatsapp", "WhatsApp");
    await add(b.id, "s3", "gmail", "b@gmail.com");
    const st = await (await call("/v2/status", { key: a.key })).json<any>();
    expect(st.sources.map((s: any) => [s.kind, s.address, s.enabled])).toEqual([["gmail", "a@gmail.com", true], ["whatsapp", "WhatsApp", true]]);
    expect(Object.keys(st.sources[0]).sort()).toEqual(["address", "enabled", "id", "kind", "last_error", "last_run"]);
  });

  it("an_input_can_be_turned_off_only_by_its_owner", async () => {
    const a = await newUser("A"), b = await newUser("B");
    await add(a.id, "s9", "gmail", "a@gmail.com");
    const off = (key: string) => call("/v2/sources/s9/enabled", { key, method: "POST", body: JSON.stringify({ enabled: false }) });
    expect((await off(b.key)).status).toBe(404);
    expect((await off(a.key)).status).toBe(200);
    expect((await env.DB.prepare("SELECT enabled FROM sources WHERE id='s9'").first<any>()).enabled).toBe(0);
    expect((await call("/v2/sources/s9/enabled", { key: a.key, method: "POST", body: JSON.stringify({ enabled: "no" }) })).status).toBe(400);
  });
});
