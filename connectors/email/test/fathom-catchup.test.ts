import { describe, it, expect, afterEach } from "vitest";
import { env } from "cloudflare:test";
import { call, fathomHookPath, form, newUser, signIn } from "./helpers";
import { encrypt, decrypt } from "../src/crypto";
import { catchUpFathom, setFathomFetch } from "../src/sources/fathomCatchup";
import { Budget } from "../src/budget";
import { runAllUsers } from "../src/index";

const meeting = (id: string, over: Record<string, unknown> = {}) => ({
  title: `Meeting ${id}`, recording_id: id, share_url: `https://fathom.video/share/${id}`, meeting_url: `https://meet.google.com/${id}`,
  created_at: new Date(Date.now() - 3 * 3600e3).toISOString(), scheduled_start_time: new Date(Date.now() - 4 * 3600e3).toISOString(),
  default_summary: { markdown_formatted: `Notes for ${id}` }, action_items: [], ...over,
});

type Seen = { url: URL; key: string | null };
function fathomStub(pages: unknown[][], status = 200, seen: Seen[] = []): typeof fetch {
  let i = 0;
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    seen.push({ url: new URL(String(input)), key: new Headers(init?.headers).get("X-Api-Key") });
    if (status !== 200) return new Response("{}", { status });
    const items = pages[i] ?? [];
    i++;
    return Response.json({ limit: 10, items, next_cursor: i < pages.length ? `c${i}` : null });
  }) as typeof fetch;
}

async function userWithFathom(name: string, apiKey: string | null = "fk_test_key_123456789") {
  const u = await newUser(name);
  await fathomHookPath(u.id);
  if (apiKey) await env.DB.prepare("UPDATE sources SET fathom_key_enc=? WHERE user_id=? AND kind='fathom'").bind(await encrypt(env as any, apiKey), u.id).run();
  return u;
}
const summaries = async (userId: string) =>
  (await env.DB.prepare("SELECT message_id FROM items WHERE user_id=? AND kind='summary' ORDER BY message_id").bind(userId).all<{ message_id: string }>()).results.map((r) => r.message_id);
const fathomRow = (userId: string) => env.DB.prepare("SELECT cursor, last_error FROM sources WHERE user_id=? AND kind='fathom'").bind(userId).first<{ cursor: string | null; last_error: string | null }>();

afterEach(() => setFathomFetch(fetch));

describe("Fathom hourly catch-up (second layer behind the webhook)", () => {
  it("catchup_adds_meetings_the_webhook_missed", async () => {
    const u = await userWithFathom("FC1");
    const seen: Seen[] = [];
    await catchUpFathom(env as any, u.id, new Budget(), fathomStub([[meeting("aaa")], [meeting("bbb")]], 200, seen));
    expect(await summaries(u.id)).toEqual(["fathom:aaa", "fathom:bbb"]);
    expect(seen[0].key).toBe("fk_test_key_123456789");
    expect(seen[0].url.pathname).toBe("/external/v1/meetings");
    expect(seen[0].url.searchParams.get("include_summary")).toBe("true");
    expect(seen[0].url.searchParams.get("include_action_items")).toBe("true");
    expect(seen[0].url.searchParams.get("created_after")).toBeTruthy();
    expect(seen[1].url.searchParams.get("cursor")).toBe("c1");
    expect((await fathomRow(u.id))!.cursor).toBeTruthy();
    expect((await fathomRow(u.id))!.last_error).toBeNull();
  });

  it("catchup_skips_meetings_already_delivered_by_the_webhook", async () => {
    const u = await userWithFathom("FC2");
    const h = await env.DB.prepare("SELECT hook_id FROM sources WHERE user_id=? AND kind='fathom'").bind(u.id).first<{ hook_id: string }>();
    expect((await call(`/hooks/fathom/${h!.hook_id}`, { method: "POST", body: JSON.stringify(meeting("ccc")) })).status).toBe(200);
    await catchUpFathom(env as any, u.id, new Budget(), fathomStub([[meeting("ccc")]]));
    expect(await summaries(u.id)).toEqual(["fathom:ccc"]);
  });

  it("catchup_waits_for_a_meeting_fathom_is_still_processing", async () => {
    const u = await userWithFathom("FC3");
    const fresh = meeting("ddd", { created_at: new Date(Date.now() - 10 * 60e3).toISOString(), default_summary: null, action_items: null });
    await catchUpFathom(env as any, u.id, new Budget(), fathomStub([[meeting("eee"), fresh]]));
    expect(await summaries(u.id)).toEqual(["fathom:eee"]);
    // The cursor stops before the unfinished meeting, so the next hour asks for it again.
    const cursor = (await fathomRow(u.id))!.cursor!;
    expect(Date.parse(cursor)).toBeLessThan(Date.parse(fresh.created_at as string));
  });

  it("catchup_rejected_key_shows_in_needs_attention", async () => {
    const u = await userWithFathom("FC4");
    await catchUpFathom(env as any, u.id, new Budget(), fathomStub([], 401));
    expect((await fathomRow(u.id))!.last_error).toContain("Fathom API key");
    const s = await (await call("/v2/status", { key: u.key })).json<any>();
    expect(s.needs_attention.join("\n")).toContain("Fathom API key");
    // A later successful check clears it.
    await catchUpFathom(env as any, u.id, new Budget(), fathomStub([[]]));
    expect((await fathomRow(u.id))!.last_error).toBeNull();
  });

  it("catchup_without_a_key_makes_no_calls", async () => {
    const u = await userWithFathom("FC5", null);
    const seen: Seen[] = [];
    await catchUpFathom(env as any, u.id, new Budget(), fathomStub([[meeting("fff")]], 200, seen));
    expect(seen.length).toBe(0);
  });

  it("hourly_cron_runs_the_catchup", async () => {
    const u = await userWithFathom("FC6");
    setFathomFetch(fathomStub([[meeting("ggg")]]));
    await runAllUsers(env as any, async () => undefined, [u.id]);
    expect(await summaries(u.id)).toEqual(["fathom:ggg"]);
  });
});

describe("Fathom API key on the setup page", () => {
  it("fathom_key_checked_with_fathom_then_saved_encrypted", async () => {
    const u = await userWithFathom("FK1", null);
    const s = await signIn(u.key);
    setFathomFetch(fathomStub([], 401));
    expect((await form("/setup/fathom/key", { csrf: s.csrf, fathom_key: "wrong-key-123456789" }, { cookie: s.cookie })).status).toBe(400);
    expect((await env.DB.prepare("SELECT fathom_key_enc k FROM sources WHERE user_id=? AND kind='fathom'").bind(u.id).first<{ k: string | null }>())!.k).toBeNull();
    setFathomFetch(fathomStub([[]]));
    expect((await form("/setup/fathom/key", { csrf: s.csrf, fathom_key: "good-key-123456789" }, { cookie: s.cookie })).status).toBe(200);
    const row = await env.DB.prepare("SELECT fathom_key_enc k FROM sources WHERE user_id=? AND kind='fathom'").bind(u.id).first<{ k: string }>();
    expect(await decrypt(env as any, row!.k)).toBe("good-key-123456789");
    const page = await (await call("/setup", { headers: { Cookie: s.cookie } })).text();
    expect(page).toContain("API key: <span class=\"ok\">saved ✓</span>");
    expect(page).not.toContain("good-key-123456789");
  });
});

describe("Fathom catch-up bookmark and meetings without notes", () => {
  it("catchup_bookmark_moves_forward_when_nothing_is_new", async () => {
    const u = await userWithFathom("FB1");
    await catchUpFathom(env as any, u.id, new Budget(), fathomStub([[]]));
    const cursor = Date.parse((await fathomRow(u.id))!.cursor!);
    expect(cursor).toBeGreaterThan(Date.now() - 7 * 3600e3); // not stuck at the 2-day first look-back
  });

  it("catchup_skips_a_meeting_that_never_got_notes", async () => {
    const u = await userWithFathom("FB2");
    const empty = meeting("hhh", { created_at: new Date(Date.now() - 8 * 3600e3).toISOString(), default_summary: null, action_items: [] });
    await catchUpFathom(env as any, u.id, new Budget(), fathomStub([[empty, meeting("iii")]]));
    expect(await summaries(u.id)).toEqual(["fathom:iii"]);
  });
});
