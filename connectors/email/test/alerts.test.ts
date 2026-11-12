import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { form, get, newUser, signIn } from "./helpers";
import { alertFor, setNtfyFetch } from "../src/alerts";
import { setTelegramFetch } from "../src/telegram";

let ntfy: { url: string; headers: Record<string, string>; body: string }[] = [];
let tg: unknown[] = [];
let ntfyStatus = 200, tgStatus = 200;
beforeEach(() => {
  ntfy = []; tg = []; ntfyStatus = 200; tgStatus = 200;
  setNtfyFetch((async (url: RequestInfo | URL, init?: RequestInit) => {
    ntfy.push({ url: String(url), headers: init?.headers as Record<string, string>, body: String(init?.body) });
    return new Response("{}", { status: ntfyStatus });
  }) as typeof fetch);
  setTelegramFetch((async (_u: RequestInfo | URL, init?: RequestInit) => {
    tg.push(JSON.parse(String(init?.body)));
    return tgStatus === 200 ? Response.json({ ok: true, result: {} }) : new Response("{}", { status: tgStatus });
  }) as typeof fetch);
});

const item = { id: "i1", title: "Pay invoice", why: "Due tomorrow", sender: "Acme <ap@acme.com>", due: "2026-11-08", link: "https://mail/1" };
const setTopic = (id: string, topic: string | null) => env.DB.prepare("UPDATE users SET ntfy_topic=? WHERE id=?").bind(topic, id).run();
const link = (id: string) => env.DB.prepare("UPDATE users SET telegram_chat_id='555' WHERE id=?").bind(id).run();

describe("alerts", () => {
  it("ntfy_alert_sends_title_priority_click", async () => {
    const u = await newUser("N1");
    await setTopic(u.id, "topic-abc");
    await alertFor(env as any, u.id)(item);
    expect(ntfy).toHaveLength(1);
    expect(ntfy[0].url).toBe("https://ntfy.sh/topic-abc");
    expect(ntfy[0].headers.Title).toBe("Pay invoice");
    expect(ntfy[0].headers.Priority).toBe("5");
    expect(ntfy[0].headers.Click).toBe("https://mail/1");
    expect(ntfy[0].headers.Tags).toBe("warning");
    expect(ntfy[0].body).toContain("Due: 2026-11-08");
    expect(ntfy[0].body).toContain("From: Acme <ap@acme.com>");
  });

  it("ntfy_title_is_capped_and_click_omitted_without_link", async () => {
    const u = await newUser("N2");
    await setTopic(u.id, "topic-abc");
    await alertFor(env as any, u.id)({ ...item, title: "x".repeat(300), link: "" });
    expect(ntfy[0].headers.Title).toHaveLength(120);
    expect(ntfy[0].headers.Click).toBeUndefined();
  });

  it("alert_fanout_one_channel_failing_still_sends_others", async () => {
    const u = await newUser("N3");
    await setTopic(u.id, "topic-abc"); await link(u.id);
    ntfyStatus = 500;
    await alertFor(env as any, u.id)(item); // telegram still works, so no throw
    expect(tg).toHaveLength(1);
    expect(ntfy).toHaveLength(1);
    ntfyStatus = 200; tgStatus = 500; ntfy = []; tg = [];
    await alertFor(env as any, u.id)(item);
    expect(ntfy).toHaveLength(1);
  });

  it("alert_throws_when_every_channel_fails", async () => {
    const u = await newUser("N4");
    await setTopic(u.id, "topic-abc"); await link(u.id);
    ntfyStatus = 500; tgStatus = 500;
    await expect(alertFor(env as any, u.id)(item)).rejects.toThrow();
  });

  it("ntfy_off_sends_nothing", async () => {
    const u = await newUser("N5");
    await alertFor(env as any, u.id)(item);
    expect(ntfy).toHaveLength(0);
    await setTopic(u.id, "topic-abc");
    await env.DB.prepare("UPDATE settings SET alerts_on=0 WHERE user_id=?").bind(u.id).run();
    await alertFor(env as any, u.id)(item);
    expect(ntfy).toHaveLength(0);
  });
});

describe("setup page ntfy", () => {
  it("setup_turns_ntfy_on_and_shows_topic", async () => {
    const u = await newUser("N6");
    const s = await signIn(u.key);
    expect(await (await get("/setup", s.cookie)).text()).toContain('action="/setup/ntfy/on"');
    const r = await form("/setup/ntfy/on", { csrf: s.csrf }, { cookie: s.cookie });
    expect(r.status).toBe(200);
    const row = await env.DB.prepare("SELECT ntfy_topic t FROM users WHERE id=?").bind(u.id).first<{ t: string }>();
    expect(row!.t).toMatch(/^[A-Za-z0-9_-]{24}$/);
    const html = await (await get("/setup", s.cookie)).text();
    expect(html).toContain(`https://ntfy.sh/${row!.t}`);
    expect(html).toContain('action="/setup/ntfy/test"');
    expect(html).toContain('action="/setup/ntfy/new"');
    expect(html).toContain('action="/setup/ntfy/off"');

    expect((await form("/setup/ntfy/test", { csrf: s.csrf }, { cookie: s.cookie })).status).toBe(200);
    expect(ntfy).toHaveLength(1);
    expect(ntfy[0].url).toBe(`https://ntfy.sh/${row!.t}`);

    await form("/setup/ntfy/new", { csrf: s.csrf }, { cookie: s.cookie });
    const row2 = await env.DB.prepare("SELECT ntfy_topic t FROM users WHERE id=?").bind(u.id).first<{ t: string }>();
    expect(row2!.t).not.toBe(row!.t);

    await form("/setup/ntfy/off", { csrf: s.csrf }, { cookie: s.cookie });
    expect((await env.DB.prepare("SELECT ntfy_topic t FROM users WHERE id=?").bind(u.id).first<any>()).t).toBeNull();
  });

  it("ntfy_post_needs_csrf", async () => {
    const u = await newUser("N7");
    const s = await signIn(u.key);
    const r = await form("/setup/ntfy/on", { csrf: "wrong" }, { cookie: s.cookie });
    expect(r.status).toBeGreaterThanOrEqual(400);
    expect((await env.DB.prepare("SELECT ntfy_topic t FROM users WHERE id=?").bind(u.id).first<any>()).t).toBeNull();
  });
});
