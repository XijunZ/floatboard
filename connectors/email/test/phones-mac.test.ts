import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "./helpers";
import { me, pairPhone } from "./app-helpers";

/** The Mac lists and disconnects paired phones with the user key (same as the setup page's Remove). */
describe("paired phones from the Mac", () => {
  it("lists_only_this_users_phones", async () => {
    const a = await newUser("A"), b = await newUser("B");
    await pairPhone(a.key, "Pixel");
    await pairPhone(b.key, "iPhone");
    const r = await call("/v2/app/phones", { key: a.key });
    expect(r.status).toBe(200);
    const { phones } = await r.json<any>();
    expect(phones.map((p: any) => p.name)).toEqual(["Pixel"]);
    expect(Object.keys(phones[0]).sort()).toEqual(["created", "id", "last_seen", "name", "shares_passkey"]);
  });

  it("disconnect_signs_the_phone_out", async () => {
    const a = await newUser("A");
    const p = await pairPhone(a.key, "Pixel");
    const id = (await (await call("/v2/app/phones", { key: a.key })).json<any>()).phones[0].id;
    const r = await call("/v2/app/phones/remove", { key: a.key, method: "POST", body: JSON.stringify({ device_id: id }) });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true, name: "Pixel" });
    expect((await me(p.cookie)).status).toBe(401);
    expect((await (await call("/v2/app/phones", { key: a.key })).json<any>()).phones).toEqual([]);
  });

  it("cannot_disconnect_someone_elses_phone", async () => {
    const a = await newUser("A"), b = await newUser("B");
    await pairPhone(b.key, "iPhone");
    const id = (await (await call("/v2/app/phones", { key: b.key })).json<any>()).phones[0].id;
    const r = await call("/v2/app/phones/remove", { key: a.key, method: "POST", body: JSON.stringify({ device_id: id }) });
    expect(r.status).toBe(404);
    expect((await (await call("/v2/app/phones", { key: b.key })).json<any>()).phones).toHaveLength(1);
    expect((await call("/v2/app/phones", {})).status).toBe(401);
    void env;
  });
});
