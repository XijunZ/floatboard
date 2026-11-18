import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "../helpers";
import { me, pairPhone } from "../phone-helpers";

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

// Round 14 (6): the Mac shows a late reminder itself unless the engine can reach a phone: a paired phone with a push
// subscription, or an ntfy topic, with alerts on.
describe("can the engine reach a phone", () => {
  it("reachable_only_with_a_push_subscription_or_ntfy_and_alerts_on", async () => {
    const a = await newUser("Reach");
    const reach = async () => (await (await call("/v2/app/phones", { key: a.key })).json<any>()).reachable;
    expect(await reach()).toBe(false);
    await pairPhone(a.key, "Pixel");
    expect(await reach()).toBe(false);   // paired, but no notifications
    const dev = (await env.DB.prepare("SELECT id FROM app_devices WHERE user_id=?").bind(a.id).first<{ id: string }>())!.id;
    await env.DB.prepare("INSERT INTO app_push(device_id,user_id,endpoint,p256dh,auth,origin,created) VALUES(?,?,?,?,?,?,?)")
      .bind(dev, a.id, "https://fcm.googleapis.com/x", "k", "a", "https://engine.test", "2026-11-18T00:00:00Z").run();
    expect(await reach()).toBe(true);
    await env.DB.prepare("UPDATE settings SET alerts_on=0 WHERE user_id=?").bind(a.id).run();
    expect(await reach()).toBe(false);
    const b = await newUser("Reach2", { ntfyTopic: "t-1" });
    expect((await (await call("/v2/app/phones", { key: b.key })).json<any>()).reachable).toBe(true);
  });
});

