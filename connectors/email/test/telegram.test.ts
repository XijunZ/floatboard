import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "./helpers";
import { alertFor, newTelegramLink, setTelegramFetch } from "../src/telegram";

let sent: { method: string; body: any }[] = [];
beforeEach(() => {
  sent = [];
  setTelegramFetch((async (url: RequestInfo | URL, init?: RequestInit) => {
    sent.push({ method: String(url).split("/").pop()!, body: JSON.parse(String(init?.body)) });
    return Response.json({ ok: true, result: {} });
  }) as typeof fetch);
});

const update = (text: string, chatId = 555) => ({ update_id: 1, message: { message_id: 1, chat: { id: chatId, type: "private" }, text } });

async function linkedUser() {
  const u = await newUser("X");
  const code = new URL((await newTelegramLink(env as any, u.id))!).searchParams.get("start")!;
  await call("/telegram/webhook", { method: "POST", headers: { "X-Telegram-Bot-Api-Secret-Token": "tg-secret" },
    body: JSON.stringify(update(`/start ${code}`)) });
  return u;
}

describe("telegram", () => {
  it("link_url_points_at_bot", async () => {
    const u = await newUser("X");
    const url = await newTelegramLink(env as any, u.id);
    expect(url).toMatch(/^https:\/\/t\.me\/FloatBoardTestBot\?start=[A-Za-z0-9_-]{16,}$/);
  });

  it("start_code_links_chat", async () => {
    const u = await linkedUser();
    const row = await env.DB.prepare("SELECT telegram_chat_id, link_code FROM users WHERE id=?").bind(u.id).first<any>();
    expect(row).toEqual({ telegram_chat_id: "555", link_code: null });
    expect(sent.at(-1)!.body.text).toContain("Linked");
  });

  it("wrong_secret_rejected", async () => {
    const r = await call("/telegram/webhook", { method: "POST", headers: { "X-Telegram-Bot-Api-Secret-Token": "nope" },
      body: JSON.stringify(update("/start x")) });
    expect(r.status).toBe(401);
  });

  it("unknown_code_does_not_link", async () => {
    await call("/telegram/webhook", { method: "POST", headers: { "X-Telegram-Bot-Api-Secret-Token": "tg-secret" },
      body: JSON.stringify(update("/start not-a-code", 777)) });
    const n = await env.DB.prepare("SELECT count(*) AS n FROM users WHERE telegram_chat_id='777'").first<{ n: number }>();
    expect(n!.n).toBe(0);
  });

  it("alert_sent_with_open_email_button", async () => {
    const u = await linkedUser();
    sent = [];
    await alertFor(env as any, u.id)!({ id: "i1", title: "Pay invoice", why: "Due tomorrow", sender: "Acme <ap@acme.com>",
      due: "2026-11-08", link: "https://mail/1" });
    expect(sent).toHaveLength(1);
    expect(sent[0].body.chat_id).toBe("555");
    expect(sent[0].body.text).toContain("Pay invoice");
    expect(sent[0].body.reply_markup.inline_keyboard[0][0]).toEqual({ text: "Open email", url: "https://mail/1" });
  });

  it("no_alert_when_disabled_or_unlinked", async () => {
    const u = await linkedUser();
    expect((await call("/v2/settings", { key: u.key, method: "PUT", body: JSON.stringify({ version: 1, values: { alerts_on: false } }) })).status).toBe(200);
    sent = [];
    await alertFor(env as any, u.id)!({ id: "i", title: "t", why: "", sender: "", due: null, link: "" });
    const other = await newUser("Y");
    await alertFor(env as any, other.id)!({ id: "i", title: "t", why: "", sender: "", due: null, link: "" });
    expect(sent).toHaveLength(0);
  });
});
