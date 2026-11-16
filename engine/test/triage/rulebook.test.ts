import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "../helpers";
import { encrypt } from "../../src/lib/crypto";
import { CHAT_SKILL, FIXED_RULES, SKILL, chatSystem, emailSystem } from "../../src/triage/classify";
import { runUser } from "../../src/triage/run";

describe("your own copy of a rulebook", () => {
  it("replaces the built-in one, the fixed rules always stay", () => {
    expect(emailSystem("")).toContain(SKILL.trim());
    expect(emailSystem("")).toContain(FIXED_RULES);
    const mine = emailSystem("- Only invoices are tasks");
    expect(mine).toContain("- Only invoices are tasks");
    expect(mine).not.toContain(SKILL.trim());
    expect(mine).toContain(FIXED_RULES);
    expect(chatSystem("- Only my sister")).not.toContain(CHAT_SKILL.trim());
    expect(chatSystem("")).toContain(CHAT_SKILL.trim());
  });

  it("the chat rulebook saved in settings is the one Claude gets; empty means built-in", async () => {
    const u = await newUser("RB");
    await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk"), u.id).run();
    const put = (rulebook: string, version: number) => call("/v2/settings", { key: u.key, method: "PUT", body: JSON.stringify({ version, values: { rulebook_chat: rulebook } }) });
    expect((await put("- Only my sister's asks are tasks", 1)).status).toBe(200);
    const chat = (k: string) => ({ key: `wa:4477:${k}`, name: "Anna", group: false, senders: ["Anna"], transcript: "[2026-11-13 09:12] Anna: Call me?", link: "", received: "2026-11-13T09:12:00Z" });
    await call("/v2/chats", { key: u.key, method: "POST", body: JSON.stringify({ app: "whatsapp", chats: [chat("A")] }) });
    const seen: any[] = [];
    const claude = (async (_u: RequestInfo | URL, init?: RequestInit) => {
      seen.push(JSON.parse(String(init?.body)));
      return Response.json({ id: "m", type: "message", role: "assistant", model: "claude-haiku-5-5", stop_reason: "end_turn", stop_sequence: null,
        content: [{ type: "text", text: JSON.stringify({ action_required: false, title: "", why: "", due: null, has_time: false, importance: 1, group: null, urgent: false }) }],
        usage: { input_tokens: 1, output_tokens: 1 } });
    }) as typeof fetch;
    await runUser(env as any, u.id, { kinds: ["whatsapp"], fetchFn: claude });
    expect(seen[0].system).toContain("- Only my sister's asks are tasks");
    expect(seen[0].system).toContain("Fixed rules");
    expect((await put("", 2)).status).toBe(200);
    await call("/v2/chats", { key: u.key, method: "POST", body: JSON.stringify({ app: "whatsapp", chats: [chat("B")] }) });
    await runUser(env as any, u.id, { kinds: ["whatsapp"], fetchFn: claude });
    expect(seen[1].system).toContain(CHAT_SKILL.trim());
    expect((await put("x".repeat(20001), 3)).status).toBe(400);
  });
});
