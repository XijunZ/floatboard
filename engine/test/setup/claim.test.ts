import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { form, freshIP, get, newUser } from "../helpers";

describe("making a new engine yours", () => {
  it("a_new_engine_shows_make_it_yours_and_needs_the_admin_key", async () => {
    await env.DB.prepare("DELETE FROM users").run();
    const page = await (await get("/setup")).text();
    expect(page).toContain("Make this engine yours");
    const bad = await form("/setup/claim", { name: "Robin", key: "wrong" }, { ip: freshIP() });
    expect(bad.status).toBe(401);
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM users").first<any>()).n).toBe(0);
    const ok = await form("/setup/claim", { name: "Robin", key: "admin-test-key" }, { ip: freshIP() });
    expect(ok.status).toBe(303);
    const cookie = ok.headers.get("Set-Cookie")!.split(";")[0];
    const dash = await (await get("/setup", cookie)).text();
    expect(dash).toContain("floatboard://connect");
    expect(dash).toContain("Robin");
  });

  it("only_while_it_has_no_owner", async () => {
    await newUser("Owner");
    expect(await (await get("/setup")).text()).not.toContain("Make this engine yours");
    const r = await form("/setup/claim", { name: "Intruder", key: "admin-test-key" }, { ip: freshIP() });
    expect(r.status).toBe(403);
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM users WHERE name='Intruder'").first<any>()).n).toBe(0);
  });

  it("refuses_cross_site_claims", async () => {
    await env.DB.prepare("DELETE FROM users").run();
    const r = await form("/setup/claim", { name: "X", key: "admin-test-key" }, { ip: freshIP(), origin: "https://evil.example" });
    expect(r.status).toBe(403);
  });
});
