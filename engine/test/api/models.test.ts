import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "../helpers";
import { encrypt } from "../../src/lib/crypto";
import { HAIKU, SONNET } from "../../src/lib/llm";
import { runUser } from "../../src/triage/run";

const chat = { key: "wa:447700900123@s.whatsapp.net:M1", name: "Anna", group: false, senders: ["Anna"],
  transcript: "[2026-11-13 09:12] Anna: Can you send me the contract?", link: "", received: "2026-11-13T09:12:00Z" };

function claude(seen: any[]) {
  return (async (_u: RequestInfo | URL, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body));
    seen.push(body);
    return Response.json({ id: "m", type: "message", role: "assistant", model: body.model, stop_reason: "end_turn", stop_sequence: null,
      content: [{ type: "text", text: JSON.stringify({ action_required: false, title: "", why: "", due: null, has_time: false, importance: 1, group: null, urgent: false }) }],
      usage: { input_tokens: 1_000_000, output_tokens: 100_000 } });
  }) as typeof fetch;
}

async function keyed(name: string) {
  const u = await newUser(name);
  await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
  await env.DB.prepare("INSERT OR IGNORE INTO settings(user_id) VALUES(?)").bind(u.id).run();
  return u;
}

describe("model choice and cost", () => {
  it("haiku_by_default_and_usage_is_counted", async () => {
    const u = await keyed("M1");
    await call("/v2/chats", { key: u.key, method: "POST", body: JSON.stringify({ app: "whatsapp", chats: [chat] }) });
    const seen: any[] = [];
    await runUser(env as any, u.id, { kinds: ["whatsapp"], fetchFn: claude(seen) });
    expect(seen[0].model).toBe(HAIKU);
    const st = await (await call("/v2/status", { key: u.key })).json<any>();
    // 1M input + 0.1M output on Haiku: $0.10 + $0.05; the same on Sonnet: $2 + $1.
    expect(st.ai_cost.judge).toEqual({ calls: 1, usd: 0.15, usd_if: { haiku: 0.15, sonnet: 3 } });
  });

  it("choosing_sonnet_changes_the_model_used", async () => {
    const u = await keyed("M2");
    const exported = await (await call("/v2/export", { key: u.key })).json<any>();
    expect(exported.settings.model_judge).toBe("Haiku");
    expect(exported.settings.model_reply).toBe("Sonnet");
    const put = await call("/v2/settings", { key: u.key, method: "PUT", body: JSON.stringify({ version: 1, values: { model_judge: "Sonnet" } }) });
    expect(put.status).toBe(200);
    await call("/v2/chats", { key: u.key, method: "POST", body: JSON.stringify({ app: "whatsapp", chats: [chat] }) });
    const seen: any[] = [];
    await runUser(env as any, u.id, { kinds: ["whatsapp"], fetchFn: claude(seen) });
    expect(seen[0].model).toBe(SONNET);
    const bad = await call("/v2/settings", { key: u.key, method: "PUT", body: JSON.stringify({ version: 2, values: { model_judge: "Opus" } }) });
    expect(bad.status).toBe(400);
  });
});

describe("on this mac", () => {
  it("only_offered_by_the_engine_inside_the_mac_app_and_only_for_judging", async () => {
    const { schemaFor } = await import("../../src/routes/v2");
    const { chosenModel, ON_DEVICE } = await import("../../src/lib/llm");
    const online = schemaFor(env as any).find((f) => f.key === "model_judge")!;
    expect(online.options).toEqual(["Haiku", "Sonnet"]);
    const mac = { ...(env as any), ON_DEVICE: "1" };
    expect(schemaFor(mac).find((f) => f.key === "model_judge")!.options).toEqual(["Haiku", "Sonnet", "On this Mac"]);
    const u = await keyed("OD");
    await env.DB.prepare("UPDATE settings SET model_judge='on this mac', model_reply='on this mac' WHERE user_id=?").bind(u.id).run();
    expect(await chosenModel(mac, u.id, "judge")).toBe(ON_DEVICE);
    expect(await chosenModel(mac, u.id, "reply")).toBe(SONNET); // never for drafts
    expect(await chosenModel(env as any, u.id, "judge")).toBe(HAIKU); // online: falls back
    const r = await call("/v2/models/compare", { key: u.key, method: "POST", body: "{}" });
    expect(r.status).toBe(400);
  });
});
