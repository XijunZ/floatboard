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
  const messages: ((m: any, sender: any, respond: (r: any) => void) => boolean | void)[] = [];
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
    runtime: { onMessage: { addListener: (f: any) => messages.push(f) }, onInstalled: { addListener: (f: any) => installed.push(f) }, onStartup: noop },
  };
  let offline = false;
  (globalThis as any).fetch = async (url: string, init: RequestInit) => {
    posts.push({ url, body: JSON.parse(String(init.body)) });
    return new Response(JSON.stringify({ ok: true }), { status: offline ? 503 : 200 });
  };
  const message = (m: any, tab?: number) => new Promise<any>((resolve) => {
    let answered = false;
    const respond = (r: any) => { answered = true; resolve(r); };
    for (const f of messages) f(m, tab === undefined ? {} : { tab: { id: tab } }, respond);
    setTimeout(() => { if (!answered) resolve(undefined); }, 200);
  });
  const sentTo = (engine: string) => posts.filter((p) => p.url.startsWith(engine)).flatMap((p) => (p.body.items ?? []).map((r: Row) => r.rowId));
  return { local, changed, installed, posts, sentTo, message, goOffline: () => { offline = true; }, fire: (c: any) => changed.forEach((f) => f(c, "local")) };
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

  // Round 44 (Codex 34): the options page never writes the queue; the worker saves settings inside the queue's lock.
  it("a_settings_save_through_the_worker_loses_no_row_ack_or_parked_queue_and_binds_an_older_queue", async () => {
    const store: Record<string, unknown> = { settings: A, queue: legacyQueue() };
    const c = fakeChrome(store);
    c.goOffline();
    await import("../src/background");
    // A page read and a settings save arrive together.
    const read = c.message({ type: "pageRead", read: { kind: "inbox", rows: [row("r2")], mailbox: "a@example.org" } }, 1);
    const saved = c.message({ type: "saveSettings", settings: B });
    expect(await saved).toEqual({ ok: true });
    await read;
    await settle();
    expect((store.settings as any).engine).toBe(B.engine);
    // Nothing lost: a1 (the older queue's) and r2 are both kept for A, never for B.
    const q = store.queue as any;
    const forA = Object.entries(q.parked ?? {}).filter(([k]) => k.startsWith(A.engine)).flatMap(([, v]: any) => v.items.map((i: any) => i.row.rowId));
    const here = q.engine?.startsWith(A.engine) ? q.items.map((i: any) => i.row.rowId) : [];
    expect([...forA, ...here].sort()).toEqual(["a1", "r2"]);
    expect(c.sentTo(B.engine)).toEqual([]);
  });

  it("acks_and_parked_queues_survive_a_save_interleaved_with_a_read", async () => {
    const { engineIdentity } = await import("../src/queue");
    const idA = await engineIdentity(A);
    const x = { items: [{ key: rowKey(row("x1")), mailbox: "x@example.org", row: row("x1") }], acked: {}, refused: [] };
    const store: Record<string, unknown> = { settings: A, queue: { v: 2, engine: idA, items: [], acked: { k0: new Date().toISOString() },
      refused: [], failures: 0, mailbox: "a@example.org", parked: { "https://x.example.test#000": x } } };
    const c = fakeChrome(store);
    c.goOffline();
    await import("../src/background");
    const read = c.message({ type: "pageRead", read: { kind: "inbox", rows: [row("r3")], mailbox: "a@example.org" } }, 1);
    expect(await c.message({ type: "saveSettings", settings: B })).toEqual({ ok: true });
    await read;
    await settle();
    const q = store.queue as any;
    const a = q.engine === idA ? q : q.parked[idA];
    expect(Object.keys(a.acked)).toContain("k0");
    expect(a.items.map((i: any) => i.row.rowId)).toContain("r3");
    expect(q.parked["https://x.example.test#000"].items.map((i: any) => i.row.rowId)).toEqual(["x1"]);
  });

  it("the_options_page_never_writes_the_queue", async () => {
    const { readFileSync } = await import("node:fs");
    const src = readFileSync(new URL("../src/options.ts", import.meta.url), "utf8");
    expect(src).not.toMatch(/storage\.local\.set\(/);
    expect(src).toMatch(/type: "saveSettings"/);
  });
});
