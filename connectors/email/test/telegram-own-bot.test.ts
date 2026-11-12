import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, form, get, newUser, signIn } from "./helpers";
import { decrypt } from "../src/crypto";
import { sha256Hex } from "../src/auth";
import { newTelegramLink, setTelegramFetch } from "../src/telegram";
import { alertFor } from "../src/alerts";

// A user's own Telegram bot: everything Telegram is faked here. Calls are recorded with the bot token they used.
const ENGINE = "123:test-token";
const OWN = "777001:AAOwnBotTokenAbcdefghijklmnopqrstuv";
const OTHER = "888002:AAOtherBotTokenAbcdefghijklmnopqrs";
const BOTS: Record<string, { id: number; username: string }> = {
  [ENGINE]: { id: 123, username: "FloatBoardTestBot" },
  [OWN]: { id: 777001, username: "MyOwnFloatBot" },
  [OTHER]: { id: 888002, username: "OtherFloatBot" },
};

type Sent = { token: string; method: string; body: any };
let sent: Sent[] = [];
let setWebhookFails = false;
beforeEach(async () => {
  sent = []; setWebhookFails = false;
  // D1 is shared by the tests in this file: each test starts with no own bots saved (so a bot is never "already used").
  await env.DB.prepare("UPDATE users SET tg_bot_token_enc=NULL, tg_bot_name=NULL, tg_hook_id=NULL, tg_hook_secret_hash=NULL").run();
  setTelegramFetch((async (url: RequestInfo | URL, init?: RequestInit) => {
    const m = /^https:\/\/api\.telegram\.org\/bot([^/]+)\/(\w+)$/.exec(String(url))!;
    const token = decodeURIComponent(m[1]), method = m[2];
    sent.push({ token, method, body: init?.body ? JSON.parse(String(init.body)) : {} });
    const bot = BOTS[token];
    if (!bot) return Response.json({ ok: false, error_code: 401, description: "Unauthorized" }, { status: 401 });
    if (method === "getMe") return Response.json({ ok: true, result: { id: bot.id, is_bot: true, first_name: "Bot", username: bot.username } });
    if (method === "setWebhook" && setWebhookFails) return Response.json({ ok: false, description: "Bad Request: bad webhook" }, { status: 400 });
    return Response.json({ ok: true, result: true });
  }) as typeof fetch);
});

const update = (text: string, chatId = 555, id = Math.floor(Math.random() * 1e9)) =>
  ({ update_id: id, message: { message_id: 1, chat: { id: chatId, type: "private" }, from: { id: chatId }, text } });
const row = (id: string) => env.DB.prepare("SELECT * FROM users WHERE id=?").bind(id).first<any>();

async function withOwnBot(token = OWN) {
  const u = await newUser("Own");
  const s = await signIn(u.key);
  const r = await form("/setup/telegram/bot", { csrf: s.csrf, bot_token: token }, { cookie: s.cookie });
  const set = sent.find((c) => c.method === "setWebhook");
  return { u, s, r, page: await r.text(), set };
}

const postHook = (path: string, secret: string, body: unknown) =>
  call(path, { method: "POST", headers: { "X-Telegram-Bot-Api-Secret-Token": secret }, body: JSON.stringify(body) });

/** Save an own bot and link chat 555 through it; returns the per-user webhook path and secret. */
async function linkedOwn(chat = 555) {
  const o = await withOwnBot();
  const path = new URL(o.set!.body.url).pathname, secret = o.set!.body.secret_token;
  const code = new URL((await newTelegramLink(env as any, o.u.id))!).searchParams.get("start")!;
  expect((await postHook(path, secret, update(`/start ${code}`, chat))).status).toBe(200);
  return { ...o, path, secret };
}

describe("own telegram bot: setup", () => {
  it("own_bot_section_on_setup_page", async () => {
    const u = await newUser("X");
    const s = await signIn(u.key);
    expect(s.page).toContain("Your own bot token (optional)");
    expect(s.page).toContain('action="/setup/telegram/bot"');
    expect(s.page).toMatch(/name="bot_token"[^>]*type="password"|type="password"[^>]*name="bot_token"/);
    expect(s.page).toContain("@BotFather");
    expect(s.page).not.toContain("Remove my bot");
  });

  it("invalid_token_rejected", async () => {
    const u = await newUser("X");
    const s = await signIn(u.key);
    const bad = await form("/setup/telegram/bot", { csrf: s.csrf, bot_token: "999:AAUnknownTokenAbcdefghijklmnopqrstu" }, { cookie: s.cookie });
    expect(bad.status).toBe(400);
    expect(await bad.text()).toContain("Telegram didn&#39;t accept that bot token");
    expect(sent.map((c) => c.method)).toEqual(["getMe"]);
    const malformed = await form("/setup/telegram/bot", { csrf: s.csrf, bot_token: "not a token/../x" }, { cookie: s.cookie });
    expect(malformed.status).toBe(400);
    expect(sent).toHaveLength(1); // never sent to Telegram
    const r = await row(u.id);
    expect([r.tg_bot_token_enc, r.tg_bot_name, r.tg_hook_id, r.tg_hook_secret_hash]).toEqual([null, null, null, null]);
  });

  it("engine_bot_token_cannot_be_used_as_own_bot", async () => {
    const { u, r, set } = await withOwnBot(ENGINE);
    expect(r.status).toBe(400);
    expect(set).toBeUndefined(); // the shared bot's webhook is never moved
    expect((await row(u.id)).tg_bot_token_enc).toBeNull();
  });

  it("bot_already_used_by_another_user_rejected", async () => {
    await withOwnBot(OWN);
    sent = [];
    const { u, r, set } = await withOwnBot(OWN);
    expect(r.status).toBe(400);
    expect(set).toBeUndefined();
    expect((await row(u.id)).tg_bot_token_enc).toBeNull();
  });

  it("save_stores_encrypted_and_sets_webhook_with_secret", async () => {
    const { u, s, r, page, set } = await withOwnBot();
    expect(r.status).toBe(200);
    expect(page).toContain("@MyOwnFloatBot");
    expect(page).toContain("Remove my bot");
    expect(page).not.toContain(OWN);
    const db = await row(u.id);
    expect(db.tg_bot_name).toBe("MyOwnFloatBot");
    expect(db.tg_bot_token_enc).not.toContain(OWN);
    expect(await decrypt(env as any, db.tg_bot_token_enc)).toBe(OWN);
    expect(db.tg_hook_id).toMatch(/^[A-Za-z0-9_-]{20,}$/);
    expect(set!.token).toBe(OWN);
    expect(set!.body.url).toBe(`${BASE}/telegram/webhook/u/${db.tg_hook_id}`);
    expect(set!.body.secret_token).toMatch(/^[A-Za-z0-9_-]{32,256}$/);
    expect(db.tg_hook_secret_hash).toBe(await sha256Hex(set!.body.secret_token));
    expect(JSON.stringify(db)).not.toContain(set!.body.secret_token);
    expect(sent.some((c) => c.token === ENGINE)).toBe(false);
    const log = await env.DB.prepare("SELECT action, ok, detail FROM setup_log WHERE user_id=? AND action='telegram_bot'").bind(u.id).all<any>();
    expect(log.results.map((l) => l.ok)).toEqual([1]);
    expect(JSON.stringify(log.results)).not.toContain(OWN);
    // Shown again on a later page load, the token never is.
    const again = await (await get("/setup", s.cookie)).text();
    expect(again).toContain("@MyOwnFloatBot");
    expect(again).not.toContain(OWN);
  });

  it("failed_set_webhook_saves_nothing", async () => {
    setWebhookFails = true;
    const { u, r } = await withOwnBot();
    expect(r.status).toBe(502);
    expect((await row(u.id)).tg_bot_token_enc).toBeNull();
  });

  it("link_uses_own_bot", async () => {
    const { s } = await withOwnBot();
    const t = await form("/setup/telegram", { csrf: s.csrf }, { cookie: s.cookie });
    expect(t.status).toBe(200);
    expect(await t.text()).toMatch(/https:\/\/t\.me\/MyOwnFloatBot\?start=[A-Za-z0-9_-]{16,}/);
  });
});

describe("own telegram bot: webhook", () => {
  it("per_user_webhook_rejects_wrong_secret_and_unknown_path", async () => {
    const { u, set } = await withOwnBot();
    const path = new URL(set!.body.url).pathname;
    const code = new URL((await newTelegramLink(env as any, u.id))!).searchParams.get("start")!;
    expect((await postHook(path, "nope", update(`/start ${code}`))).status).toBe(401);
    expect((await postHook(path, "tg-secret", update(`/start ${code}`))).status).toBe(401); // the shared secret is not this bot's
    expect((await postHook("/telegram/webhook/u/doesnotexist000000000", set!.body.secret_token, update(`/start ${code}`))).status).toBe(401);
    expect((await row(u.id)).telegram_chat_id).toBeNull();
  });

  it("per_user_webhook_links_on_start_and_replies_with_own_bot", async () => {
    const { u } = await linkedOwn();
    const db = await row(u.id);
    expect([db.telegram_chat_id, db.link_code]).toEqual(["555", null]);
    const reply = sent.filter((c) => c.method === "sendMessage").at(-1)!;
    expect(reply.token).toBe(OWN);
    expect(reply.body.text).toContain("Linked");
  });

  it("codes_never_cross_bots_or_users", async () => {
    // A user-bot code sent to the shared bot does not link.
    const own = await withOwnBot();
    const ownPath = new URL(own.set!.body.url).pathname, ownSecret = own.set!.body.secret_token;
    const ownCode = new URL((await newTelegramLink(env as any, own.u.id))!).searchParams.get("start")!;
    await postHook("/telegram/webhook", "tg-secret", update(`/start ${ownCode}`, 901));
    expect((await row(own.u.id)).telegram_chat_id).toBeNull();
    // A shared-bot user's code sent to someone's own bot does not link either user.
    const plain = await newUser("Plain");
    const plainCode = new URL((await newTelegramLink(env as any, plain.id))!).searchParams.get("start")!;
    expect(plainCode).toBeTruthy();
    await postHook(ownPath, ownSecret, update(`/start ${plainCode}`, 902));
    expect((await row(plain.id)).telegram_chat_id).toBeNull();
    expect((await row(own.u.id)).telegram_chat_id).toBeNull();
    // Another own-bot user's code sent to this user's bot does not link.
    const other = await withOwnBot(OTHER);
    const otherCode = new URL((await newTelegramLink(env as any, other.u.id))!).searchParams.get("start")!;
    await postHook(ownPath, ownSecret, update(`/start ${otherCode}`, 903));
    expect((await row(other.u.id)).telegram_chat_id).toBeNull();
    // Each code still works on its own bot.
    await postHook("/telegram/webhook", "tg-secret", update(`/start ${plainCode}`, 904));
    expect((await row(plain.id)).telegram_chat_id).toBe("904");
    await postHook(ownPath, ownSecret, update(`/start ${ownCode}`, 905));
    expect((await row(own.u.id)).telegram_chat_id).toBe("905");
  });

  it("chat_messages_on_own_bot_are_answered_by_own_bot", async () => {
    const { path, secret } = await linkedOwn(4242); // a chat no other test links
    sent = [];
    expect((await postHook(path, secret, update("3", 4242))).status).toBe(200); // a number with no pending choice gets a reply
    const msgs = sent.filter((c) => c.method === "sendMessage");
    expect(msgs.length).toBe(1);
    expect(msgs[0].token).toBe(OWN);
    // The same chat writing to the shared bot is not treated as this user's chat.
    sent = [];
    await postHook("/telegram/webhook", "tg-secret", update("3", 4242));
    const shared = sent.filter((c) => c.method === "sendMessage");
    expect(shared.map((c) => c.token)).toEqual([ENGINE]);
    expect(shared[0].body.text).toContain("isn't linked");
  });
});

describe("own telegram bot: sending", () => {
  const item = { id: "i1", title: "Pay invoice", why: "Due tomorrow", sender: "a@b.c", due: null, link: "" };

  it("alerts_go_through_own_bot", async () => {
    const { u } = await linkedOwn();
    sent = [];
    await alertFor(env as any, u.id)(item);
    expect(sent.map((c) => [c.token, c.method, c.body.chat_id])).toEqual([[OWN, "sendMessage", "555"]]);
  });

  it("users_without_own_bot_unchanged", async () => {
    const u = await newUser("Plain");
    const code = new URL((await newTelegramLink(env as any, u.id))!).searchParams.get("start")!;
    expect(code).toBeTruthy();
    expect(await newTelegramLink(env as any, u.id)).toMatch(/^https:\/\/t\.me\/FloatBoardTestBot\?start=/);
    const code2 = (await row(u.id)).link_code;
    await postHook("/telegram/webhook", "tg-secret", update(`/start ${code2}`, 556));
    expect((await row(u.id)).telegram_chat_id).toBe("556");
    sent = [];
    await alertFor(env as any, u.id)(item);
    expect(sent.map((c) => [c.token, c.body.chat_id])).toEqual([[ENGINE, "556"]]);
  });
});

describe("own telegram bot: replace and remove", () => {
  it("removing_bot_deletes_webhook_and_unlinks", async () => {
    const { u, s, path, secret } = await linkedOwn();
    sent = [];
    const r = await form("/setup/telegram/bot/remove", { csrf: s.csrf }, { cookie: s.cookie });
    expect(r.status).toBe(200);
    expect(await r.text()).not.toContain("Remove my bot");
    expect(sent.map((c) => [c.token, c.method])).toEqual([[OWN, "deleteWebhook"]]);
    const db = await row(u.id);
    expect([db.tg_bot_token_enc, db.tg_bot_name, db.tg_hook_id, db.tg_hook_secret_hash, db.telegram_chat_id, db.link_code])
      .toEqual([null, null, null, null, null, null]);
    expect((await postHook(path, secret, update("/start x"))).status).toBe(401);
    expect(await newTelegramLink(env as any, u.id)).toMatch(/^https:\/\/t\.me\/FloatBoardTestBot\?start=/);
    sent = [];
    await alertFor(env as any, u.id)(anItem());
    expect(sent).toHaveLength(0); // unlinked: no alert from either bot
  });

  it("remove_still_works_when_delete_webhook_fails", async () => {
    const { u, s } = await linkedOwn();
    setTelegramFetch((async () => new Response("{}", { status: 500 })) as unknown as typeof fetch);
    const r = await form("/setup/telegram/bot/remove", { csrf: s.csrf }, { cookie: s.cookie });
    expect(r.status).toBe(200);
    expect((await row(u.id)).tg_bot_token_enc).toBeNull();
  });

  it("replacing_bot_deletes_old_webhook_and_unlinks", async () => {
    const { u, s } = await linkedOwn();
    const oldHook = (await row(u.id)).tg_hook_id;
    sent = [];
    const r = await form("/setup/telegram/bot", { csrf: s.csrf, bot_token: OTHER }, { cookie: s.cookie });
    expect(r.status).toBe(200);
    expect(sent.filter((c) => c.method === "deleteWebhook").map((c) => c.token)).toEqual([OWN]);
    expect(sent.filter((c) => c.method === "setWebhook").map((c) => c.token)).toEqual([OTHER]);
    const db = await row(u.id);
    expect(db.tg_bot_name).toBe("OtherFloatBot");
    expect(db.tg_hook_id).not.toBe(oldHook);
    expect([db.telegram_chat_id, db.link_code]).toEqual([null, null]);
  });

  it("resaving_same_bot_keeps_its_new_webhook", async () => {
    const { u, s } = await linkedOwn();
    sent = [];
    const r = await form("/setup/telegram/bot", { csrf: s.csrf, bot_token: OWN }, { cookie: s.cookie });
    expect(r.status).toBe(200);
    expect(sent.filter((c) => c.method === "deleteWebhook")).toEqual([]);
    expect((await row(u.id)).telegram_chat_id).toBe("555"); // same bot: the chat still works, no need to link again
  });

  it("switching_from_shared_bot_to_own_unlinks_chat", async () => {
    const u = await newUser("Switch");
    const code = new URL((await newTelegramLink(env as any, u.id))!).searchParams.get("start")!;
    await postHook("/telegram/webhook", "tg-secret", update(`/start ${code}`, 560));
    expect((await row(u.id)).telegram_chat_id).toBe("560");
    const s = await signIn(u.key);
    sent = [];
    expect((await form("/setup/telegram/bot", { csrf: s.csrf, bot_token: OWN }, { cookie: s.cookie })).status).toBe(200);
    expect(sent.some((c) => c.token === ENGINE && c.method === "deleteWebhook")).toBe(false); // never touch the shared bot
    expect((await row(u.id)).telegram_chat_id).toBeNull();
  });
});

function anItem() { return { id: "i1", title: "Pay invoice", why: "", sender: "", due: null, link: "" }; }
