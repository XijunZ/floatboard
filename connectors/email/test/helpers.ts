import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { ensureFathomHook } from "../src/routes/sources";

export const BASE = "https://engine.test";

export function call(path: string, init: RequestInit & { key?: string } = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  if (init.key) headers.set("Authorization", `Bearer ${init.key}`);
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  return (exports as any).default.fetch(new Request(BASE + path, { ...init, headers }));
}

/** Create a user through the admin endpoint and return their key. */
export async function newUser(name: string): Promise<{ id: string; key: string }> {
  const r = await call("/admin/users", {
    method: "POST",
    headers: { "X-Admin-Key": "admin-test-key" },
    body: JSON.stringify({ name }),
  });
  return r.json();
}

/** The user's private Fathom webhook path (created on first use). */
export async function fathomHookPath(userId: string): Promise<string> {
  const { hook_url } = await ensureFathomHook(env as any, new Request(BASE + "/"), userId);
  return new URL(hook_url).pathname;
}

let ipSeq = 0;
/** Each sign-in comes from its own address so the sign-in rate limit never leaks between tests. */
export const freshIP = () => `10.0.${Math.floor(++ipSeq / 250)}.${ipSeq % 250}`;

export function form(path: string, fields: Record<string, string>, opts: { cookie?: string; ip?: string; origin?: string } = {}) {
  const headers: Record<string, string> = { "Content-Type": "application/x-www-form-urlencoded" };
  if (opts.cookie) headers.Cookie = opts.cookie;
  if (opts.ip) headers["CF-Connecting-IP"] = opts.ip;
  if (opts.origin) headers.Origin = opts.origin;
  return call(path, { method: "POST", headers, body: new URLSearchParams(fields).toString(), redirect: "manual" });
}

export const get = (path: string, cookie?: string) => call(path, { headers: cookie ? { Cookie: cookie } : {}, redirect: "manual" });

/** Sign in on /setup; returns the cookie pair, the page's CSRF token and the page. */
export async function signIn(key: string, path = "/setup/signin") {
  const r = await form(path, { key }, { ip: freshIP() });
  if (r.status !== 303) throw new Error(`sign-in returned ${r.status}`);
  const cookie = /fb_setup=([^;]+)/.exec(r.headers.get("Set-Cookie") ?? "")![0];
  const page = await (await get(path.startsWith("/setup/admin") ? "/setup/admin" : "/setup", cookie)).text();
  const csrf = /name="csrf" value="([^"]+)"/.exec(page)![1];
  return { cookie, csrf, page };
}

/** Insert an items row directly; `over` overrides any column. */
export async function addItem(userId: string, over: Record<string, unknown> = {}) {
  const row = { id: crypto.randomUUID(), message_id: `<${crypto.randomUUID()}@x>`, kind: "action", title: "Reply to Anna",
    why: "asked", sender: "anna@acme.com", subject: "Deck", link: "https://mail/1", due: "2026-11-10T17:00", has_time: 1,
    importance: 2, group_name: null, task_ref: null as string | null, summary: null, critical: 0,
    created: new Date().toISOString(), sent_at: "2026-11-07T10:00:00.000Z" as string | null, ...over };
  await env.DB.prepare(`INSERT INTO items(id,user_id,message_id,kind,title,why,sender,subject,link,due,has_time,importance,group_name,task_ref,summary,critical,created,sent_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).bind(row.id, userId, row.message_id, row.kind, row.title, row.why, row.sender, row.subject,
      row.link, row.due, row.has_time, row.importance, row.group_name, row.task_ref, row.summary, row.critical, row.created, row.sent_at).run();
  return row;
}
