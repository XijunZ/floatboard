// Round 43 (Codex 33): the service worker run under a stand-in `chrome`, woken by a settings change while a queue from
// an older version (no engine recorded) waits.
import { afterEach, describe, expect, it, vi } from "vitest";
import { rowKey, type Row } from "../src/parse";

const A = { engine: "https://a.example.test", token: "token-a" };
const B = { engine: "https://b.example.test", token: "token-b" };
const row = (id: string): Row => ({ rowId: id, fromName: `Sender ${id}`, subject: `Subject ${id}`, preview: `Preview ${id}`,
  received: new Date(Date.now() - 60_000).toISOString(), unread: true });
const legacyQueue = () => ({ items: [{ key: rowKey(row("a1")), mailbox: "a@example.org", row: row("a1") }], acked: {}, refused: [], failures: 0 });

function fakeChrome(store: Record<string, unknown>) {
  const changed: ((c: Record<string, { oldValue?: unknown; newValue?: unknown }>, area: string) => void)[] = [];
  const installed: ((d: { reason: string }) => void)[] = [];
  const posts: { url: string; body: any }[] = [];
  const clone = <T>(v: T): T => (v === undefined ? v : structuredClone(v));
  const local = {
    async get(k: string | string[]) { const ks = Array.isArray(k) ? k : [k]; return Object.fromEntries(ks.map((x) => [x, clone(store[x])])); },
    async set(o: Record<string, unknown>) {
      const changes = Object.fromEntries(Object.keys(o).map((k) => [k, { oldValue: clone(store[k]), newValue: clone(o[k]) }]));
      Object.assign(store, clone(o));
      for (const f of changed) f(changes, "local");   // as Chrome does, after the write
    },
  };
  const noop = { addListener() {} };
  (globalThis as any).chrome = {
    storage: { local, session: { get: async () => ({}), set: async () => {} }, onChanged: { addListener: (f: any) => changed.push(f) } },
    permissions: { contains: async () => true },
    action: { setBadgeText: async () => {}, setBadgeBackgroundColor: async () => {}, setTitle: async () => {} },
    alarms: { get: async () => ({}), create: async () => {}, onAlarm: noop },
    tabs: { query: async () => [], sendMessage: async () => {}, onRemoved: noop },
    runtime: { onMessage: noop, onInstalled: { addListener: (f: any) => installed.push(f) }, onStartup: noop },
  };
  (globalThis as any).fetch = async (url: string, init: RequestInit) => {
    posts.push({ url, body: JSON.parse(String(init.body)) });
    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  };
  const sentTo = (engine: string) => posts.filter((p) => p.url.startsWith(engine)).flatMap((p) => (p.body.items ?? []).map((r: Row) => r.rowId));
  return { local, changed, installed, posts, sentTo, fire: (c: any) => changed.forEach((f) => f(c, "local")) };
}
const settle = async () => { for (let i = 0; i < 30; i++) await new Promise((r) => setTimeout(r, 0)); };

describe("service worker: an older queue and a settings change", () => {
  afterEach(() => { vi.resetModules(); delete (globalThis as any).chrome; });

  it("a_worker_woken_by_a_switch_to_b_never_sends_as_older_queue_to_b_and_a_gets_it_back", async () => {
    // Settings were A when the older version queued a1; the switch to B is what wakes the worker.
    const store: Record<string, unknown> = { settings: B, queue: legacyQueue() };
    const c = fakeChrome(store);
    await import("../src/background");
    c.fire({ settings: { oldValue: A, newValue: B } });
    await settle();
    expect(c.sentTo(B.engine)).toEqual([]);
    // Back to A: its email goes to A.
    await c.local.set({ settings: A });
    await settle();
    expect(c.sentTo(A.engine)).toEqual(["a1"]);
    expect(c.sentTo(B.engine)).toEqual([]);
  });

  it("saving_new_settings_binds_an_older_queue_to_the_engine_saved_before", async () => {
    const { saveSettings } = await import("../src/settings-store");
    const store: Record<string, unknown> = { settings: A, queue: legacyQueue() };
    const c = fakeChrome(store);
    await saveSettings(c.local, B);   // the options page: the older queue is A's, in the same write as B
    expect((store.queue as any).engine).toContain("https://a.example.test#");
    await import("../src/background");   // the worker wakes afterwards (it missed the change)
    await settle();
    await c.local.set({ settings: B });
    await settle();
    expect(c.sentTo(B.engine)).toEqual([]);
  });
});
