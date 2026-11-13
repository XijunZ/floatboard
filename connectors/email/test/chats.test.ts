import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "./helpers";
import { encrypt } from "../src/crypto";
import { HAIKU } from "../src/llm";
import { runUser } from "../src/run";
import { chatLink, readChat } from "../src/chats";

const chat = (over: Record<string, unknown> = {}) => ({
  key: "wa:447700900123@s.whatsapp.net:ABC1", name: "Anna", group: false, senders: ["Anna"],
  transcript: "[2026-11-13 09:12] Anna: Can you send me the flat contract by tonight?", link: "whatsapp://send?phone=447700900123",
  received: "2026-11-13T09:12:00Z", ...over,
});
const send = (key: string, chats: unknown[], app = "whatsapp") =>
  call("/v2/chats", { key, method: "POST", body: JSON.stringify({ app, chats }) });

function claude(answer: Record<string, unknown>, seen: any[] = []) {
  return (async (_u: RequestInfo | URL, init?: RequestInit) => {
    seen.push(JSON.parse(String(init?.body)));
    return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
      content: [{ type: "text", text: JSON.stringify({ action_required: false, title: "", why: "", due: null, has_time: false, importance: 1,
        group: null, urgent: false, ...answer }) }], usage: { input_tokens: 1, output_tokens: 1 } });
  }) as typeof fetch;
}

async function keyed(name: string) {
  const u = await newUser(name);
  await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
  await env.DB.prepare("INSERT OR IGNORE INTO settings(user_id) VALUES(?)").bind(u.id).run();
  await env.DB.prepare("UPDATE settings SET groups=?, chat_rules=? WHERE user_id=?").bind(JSON.stringify(["Personal", "Work"]), "Family asks are high importance", u.id).run();
  return u;
}

describe("chats from the Mac", () => {
  it("stores_each_chat_once_and_skips_bad_ones", async () => {
    const u = await newUser("C1");
    const r = await send(u.key, [chat(), chat({ key: "bad" }), chat({ transcript: "" })]);
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true, stored: 1, duplicates: 0, skipped: 2 });
    expect(await (await send(u.key, [chat()])).json()).toMatchObject({ stored: 0, duplicates: 1 });
    const src = await env.DB.prepare("SELECT kind, address FROM sources WHERE user_id=?").bind(u.id).all<any>();
    expect(src.results).toEqual([{ kind: "whatsapp", address: "WhatsApp" }]);
  });

  it("refuses_unknown_apps_and_needs_the_key", async () => {
    const u = await newUser("C2");
    expect((await send(u.key, [chat()], "wechat")).status).toBe(400);
    expect((await call("/v2/chats", { method: "POST", body: JSON.stringify({ app: "whatsapp", chats: [] }) })).status).toBe(401);
  });

  it("only_chat_app_links_are_kept", () => {
    expect(chatLink("whatsapp://send?phone=447700900123")).toBe("whatsapp://send?phone=447700900123");
    expect(chatLink("whatsapp://")).toBe("whatsapp://");
    expect(chatLink("https://evil.example/x")).toBe("");
    expect(chatLink("javascript:alert(1)")).toBe("");
    expect(readChat(chat({ link: "https://evil.example" }))!.link).toBe("");
  });

  it("an_ask_becomes_a_task_judged_with_the_chat_rulebook", async () => {
    const u = await keyed("C3");
    await send(u.key, [chat()]);
    const seen: any[] = [];
    await runUser(env as any, u.id, { kinds: ["whatsapp"], fetchFn: claude({ action_required: true, title: "Send Anna the flat contract",
      why: "Anna asked for the contract by tonight", group: "Personal", importance: 2 }, seen) });
    expect(seen).toHaveLength(1);
    expect(seen[0].system).toMatch(/# Chat triage/);
    expect(seen[0].system).not.toMatch(/# Email triage/);
    const user = seen[0].messages[0].content as string;
    expect(user).toContain("The person: C3");
    expect(user).toContain("Chat: Anna (one-to-one chat)");
    expect(user).toContain("Family asks are high importance");
    expect(user).toContain("Anna: Can you send me the flat contract by tonight?");
    const it = await env.DB.prepare("SELECT kind, title, group_name, link, importance FROM items WHERE user_id=?").bind(u.id).first<any>();
    expect(it).toEqual({ kind: "action", title: "Send Anna the flat contract", group_name: "Personal", link: "whatsapp://send?phone=447700900123", importance: 2 });
    expect((await env.DB.prepare("SELECT processed FROM chat_rows WHERE user_id=?").bind(u.id).first<any>()).processed).toBe(1);
  });

  it("chatter_is_not_a_task_and_is_not_judged_twice", async () => {
    const u = await keyed("C4");
    await send(u.key, [chat({ key: "wa:g1@g.us:Z9", name: "Book club", group: true, transcript: "[09:00] Sam: haha that's great", link: "whatsapp://" })]);
    const seen: any[] = [];
    await runUser(env as any, u.id, { kinds: ["whatsapp"], fetchFn: claude({}, seen) });
    await runUser(env as any, u.id, { kinds: ["whatsapp"], fetchFn: claude({}, seen) });
    expect(seen).toHaveLength(1);
    expect(seen[0].messages[0].content).toContain("Chat: Book club (group chat)");
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM items WHERE user_id=?").bind(u.id).first<any>()).n).toBe(0);
  });

  it("chat_rules_setting_round_trips", async () => {
    const u = await newUser("C5");
    const r = await call("/v2/settings", { key: u.key, method: "PUT", body: JSON.stringify({ version: 5, values: { chat_rules: "  Ignore the school group  " } }) });
    expect(r.status).toBeLessThan(300);
    expect((await env.DB.prepare("SELECT chat_rules FROM settings WHERE user_id=?").bind(u.id).first<any>()).chat_rules).toBe("Ignore the school group");
  });

  it("muted_chats_are_judged_with_the_stricter_rule", async () => {
    const u = await keyed("C6");
    await send(u.key, [chat({ key: "wa:g2@g.us:M1", name: "School parents", group: true, muted: true, transcript: "[09:00] Kim: RSVP for the fair by Friday" })]);
    const seen: any[] = [];
    await runUser(env as any, u.id, { kinds: ["whatsapp"], fetchFn: claude({}, seen) });
    expect(seen[0].messages[0].content).toContain("Chat: School parents (group chat, MUTED by the person: apply the muted-chat rule)");
    expect(seen[0].system).toContain("## Muted chats (stricter)");
    expect((await env.DB.prepare("SELECT muted FROM chat_rows WHERE user_id=?").bind(u.id).first<any>()).muted).toBe(1);
  });
});
