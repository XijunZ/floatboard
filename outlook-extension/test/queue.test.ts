import { describe, expect, it } from "vitest";
import type { Row } from "../src/parse";
import { rowKey } from "../src/parse";
import { badgeFor, flush, Queue, type IngestConfig, type StorageArea } from "../src/queue";

const NOW = new Date("2026-11-08T03:00:00Z");
const MIN = 60_000;
const DAY = 24 * 60 * MIN;
const at = (ms: number) => new Date(NOW.getTime() + ms);
const CFG: IngestConfig = { engine: "https://engine.example.test", token: "ingest-test-token" };

function row(id: string, receivedMsAgo: number): Row {
  return {
    rowId: id,
    fromName: `Sender ${id}`,
    fromAddr: `sender-${id}@example.com`,
    subject: `Subject ${id}`,
    preview: `Preview ${id}`,
    received: new Date(NOW.getTime() - receivedMsAgo).toISOString(),
    unread: true,
  };
}

/** chrome.storage.local stand-in: async, copies values, and yields between get and set so races show up. */
class FakeStorage implements StorageArea {
  data: Record<string, unknown> = {};
  async get(key: string): Promise<unknown> {
    await new Promise((r) => setTimeout(r, 0));
    const v = this.data[key];
    return v === undefined ? undefined : structuredClone(v);
  }
  async set(key: string, value: unknown): Promise<void> {
    await new Promise((r) => setTimeout(r, 0));
    this.data[key] = structuredClone(value);
  }
}

type Posted = { mailbox?: string; items?: Row[]; problem?: string };

/** An idempotent engine: stores rows by key; can fail in the ways the network does. */
function fakeEngine(opts: { status?: number; dropAckOnce?: boolean } = {}) {
  const stored = new Map<string, Row>();
  const posts: Posted[] = [];
  let dropAck = opts.dropAckOnce ?? false;
  const fetchFn = async (url: string, init: RequestInit): Promise<Response> => {
    expect(url).toBe("https://engine.example.test/ingest/outlook");
    expect((init.headers as Record<string, string>).Authorization).toBe("Bearer ingest-test-token");
    const body = JSON.parse(String(init.body)) as Posted;
    posts.push(body);
    if (opts.status && opts.status !== 200) return new Response("{}", { status: opts.status });
    for (const r of body.items ?? []) stored.set(rowKey(r), r);
    if (dropAck) {
      dropAck = false;
      throw new TypeError("Failed to fetch"); // the engine stored the rows but the reply never arrived
    }
    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  };
  return { stored, posts, fetchFn };
}

describe("Queue", () => {
  it("first_run_takes_last_7_days_only", async () => {
    const q = new Queue(new FakeStorage());
    const n = await q.add([row("a", 1 * DAY), row("b", 6 * DAY), row("c", 8 * DAY)], NOW, "me@example.org");
    expect(n).toBe(2);
    expect((await q.takeBatch()).map((i) => i.row.rowId)).toEqual(["a", "b"]);
    // Later reads: new rows are taken, rows from before the first-run window never are.
    const later = at(1 * DAY);
    const m = await q.add([row("c", 8 * DAY), row("d", -12 * 60 * MIN), row("e", 10 * DAY)], later, "me@example.org");
    expect(m).toBe(1);
    expect((await q.status()).waiting).toBe(3);
  });

  it("ack_removes_and_remembers", async () => {
    const storage = new FakeStorage();
    const q = new Queue(storage);
    const rows = [row("a", MIN), row("b", 2 * MIN), row("c", 3 * MIN)];
    await q.add(rows, NOW, "me@example.org");
    const batch = await q.takeBatch(2);
    expect(batch.map((i) => i.key)).toEqual([rowKey(rows[0]), rowKey(rows[1])]);
    await q.ack(batch.map((i) => i.key), NOW, "me@example.org");
    const s = await q.status();
    expect(s.waiting).toBe(1);
    expect(s.lastOk).toBe(NOW.toISOString());
    // Reading the same rows again adds nothing: acknowledged ones are remembered, waiting ones already queued.
    expect(await q.add(rows, at(MIN), "me@example.org")).toBe(0);
    // Acknowledged ids are kept for 30 days, then forgotten.
    const acked = () => Object.keys((storage.data.queue as { acked: Record<string, string> }).acked);
    expect(acked()).toHaveLength(2);
    await q.ack([rowKey(rows[2])], at(31 * DAY), "me@example.org");
    expect(acked()).toEqual([rowKey(rows[2])]);
  });

  it("backoff_doubles_to_5_minutes", async () => {
    const q = new Queue(new FakeStorage());
    const delays: number[] = [];
    let t = NOW;
    for (let i = 0; i < 7; i++) {
      await q.fail(t, "Engine unreachable");
      const next = await q.nextAttempt();
      delays.push((next!.getTime() - t.getTime()) / 1000);
      expect(await q.canSend(new Date(next!.getTime() - 1))).toBe(false);
      expect(await q.canSend(next!)).toBe(true);
      t = next!;
    }
    expect(delays).toEqual([30, 60, 120, 240, 300, 300, 300]);
    expect((await q.status()).problem).toBe("Engine unreachable");
    // A success resets the back-off.
    await q.ack([], t, undefined);
    expect(await q.canSend(t)).toBe(true);
    await q.fail(t, "Engine unreachable");
    expect(((await q.nextAttempt())!.getTime() - t.getTime()) / 1000).toBe(30);
  });

  it("two_tabs_share_one_queue", async () => {
    const q = new Queue(new FakeStorage());
    const rows = [row("a", MIN), row("b", 2 * MIN), row("c", 3 * MIN)];
    // Two Outlook tabs report the same rows at the same moment.
    const [n1, n2] = await Promise.all([q.add(rows, NOW, "me@example.org"), q.add(rows, NOW, "me@example.org")]);
    expect(n1 + n2).toBe(3);
    expect((await q.status()).waiting).toBe(3);
    // Both tabs' reads trigger a send at once: each row goes out once.
    const engine = fakeEngine();
    await Promise.all([flush(q, CFG, engine.fetchFn, () => NOW), flush(q, CFG, engine.fetchFn, () => NOW)]);
    const sent = engine.posts.flatMap((p) => p.items ?? []).map(rowKey);
    expect(sent.sort()).toEqual(rows.map(rowKey).sort());
    expect((await q.status()).waiting).toBe(0);
  });

  it("send_interrupted_resends_once", async () => {
    const storage = new FakeStorage();
    const rows = [row("a", MIN), row("b", 2 * MIN)];
    const first = new Queue(storage);
    await first.add(rows, NOW, "me@example.org");
    // The engine stores the batch but the service worker dies before the acknowledgement arrives.
    const engine = fakeEngine({ dropAckOnce: true });
    await flush(first, CFG, engine.fetchFn, () => NOW);
    expect((await first.status()).waiting).toBe(2);

    // Chrome starts a new service worker: the queue survived in storage.
    const second = new Queue(storage);
    expect((await second.status()).waiting).toBe(2);
    await flush(second, CFG, engine.fetchFn, () => at(MIN));
    await flush(second, CFG, engine.fetchFn, () => at(2 * MIN));
    expect(await second.add(rows, at(3 * MIN), "me@example.org")).toBe(0);
    await flush(second, CFG, engine.fetchFn, () => at(4 * MIN));

    // Each row was sent once more after the interruption and never again; the engine kept one copy.
    const sends = engine.posts.flatMap((p) => p.items ?? []).map(rowKey);
    for (const r of rows) expect(sends.filter((k) => k === rowKey(r))).toHaveLength(2);
    expect(engine.stored.size).toBe(2);
    expect((await second.status()).waiting).toBe(0);
  });

  it("caps_are_reported_not_silent", async () => {
    const q = new Queue(new FakeStorage());
    const many = Array.from({ length: 510 }, (_, i) => row(`r${i}`, i * MIN));
    expect(await q.add(many, NOW, "me@example.org")).toBe(500);
    let s = await q.status();
    expect(s.waiting).toBe(500);
    expect(s.problem).toMatch(/full/i);
    const badge = badgeFor(s, "inbox");
    expect(badge.text).toBe("!");
    expect(badge.color).toBe("red");
    expect(badge.title).toContain(s.problem);

    // Sending frees room and clears the problem; the 10 rows left out are taken on the next read.
    const engine = fakeEngine();
    await flush(q, CFG, engine.fetchFn, () => NOW);
    expect(await q.add(many, at(MIN), "me@example.org")).toBe(10);
    s = await q.status();
    expect(s.problem).toBeUndefined();

    // More than 5,000 acknowledged ids: the oldest are forgotten, and the badge says so.
    const q2 = new Queue(new FakeStorage());
    const keys = Array.from({ length: 5001 }, (_, i) => `owa:k${i}:${NOW.toISOString()}`);
    await q2.ack(keys, NOW, "me@example.org");
    const s2 = await q2.status();
    expect(s2.notice).toMatch(/5,000/);
    expect(badgeFor(s2, "inbox").title).toContain(s2.notice);
  });

  it("mailbox_found_after_rows_is_announced_once", async () => {
    // Outlook draws the message list before the folder list, so the first read can have rows but no mailbox.
    const q = new Queue(new FakeStorage());
    const engine = fakeEngine();
    await q.add([row("a", MIN)], NOW);
    await flush(q, CFG, engine.fetchFn, () => NOW);
    expect(engine.posts).toEqual([{ items: [row("a", MIN)] }]);

    // A later read shows the mailbox but no new rows: the engine is told the mailbox once, with no rows.
    expect(await q.add([row("a", MIN)], at(MIN), "Me@Example.org")).toBe(0);
    await flush(q, CFG, engine.fetchFn, () => at(MIN));
    expect(engine.posts.slice(1)).toEqual([{ mailbox: "me@example.org", items: [] }]);
    await q.add([row("a", MIN)], at(2 * MIN), "me@example.org");
    await flush(q, CFG, engine.fetchFn, () => at(2 * MIN));
    expect(engine.posts.length).toBe(2);

    // From then on it is the connected mailbox: another one is not queued.
    expect(await q.add([row("x", MIN)], at(3 * MIN), "someone.else@example.org")).toBe(0);

    // If the engine refuses the announced mailbox (409), the badge says why and it isn't announced again.
    const q2 = new Queue(new FakeStorage());
    const refusing = fakeEngine({ status: 409 });
    await q2.add([], NOW, "other@example.org");
    await flush(q2, CFG, refusing.fetchFn, () => NOW);
    expect(refusing.posts).toEqual([{ mailbox: "other@example.org", items: [] }]);
    expect((await q2.status()).problem).toBe("This isn't the connected mailbox");
    await flush(q2, CFG, refusing.fetchFn, () => at(MIN));
    expect(refusing.posts.filter((p) => p.items).length).toBe(1);
  });

  it("wrong_mailbox_rows_not_sent", async () => {
    const q = new Queue(new FakeStorage());
    const engine = fakeEngine();
    await q.add([row("a", MIN)], NOW, "me@example.org");
    await flush(q, CFG, engine.fetchFn, () => NOW);
    expect(engine.posts[0]).toEqual({ mailbox: "me@example.org", items: [row("a", MIN)] });

    // Someone else's mailbox is open in Outlook: its rows are not queued or sent.
    expect(await q.add([row("x", MIN)], at(MIN), "someone.else@example.org")).toBe(0);
    const s = await q.status();
    expect(s.problem).toBe("This isn't the connected mailbox");
    expect(badgeFor(s, "inbox")).toMatchObject({ text: "!", color: "red", title: expect.stringContaining("This isn't the connected mailbox") });
    expect(await q.takeBatch()).toEqual([]);
    await flush(q, CFG, engine.fetchFn, () => at(MIN));
    const after = engine.posts.slice(1);
    expect(after.flatMap((p) => p.items ?? [])).toEqual([]);
    // The engine is told about the problem (once), without any rows.
    expect(after).toEqual([{ mailbox: "someone.else@example.org", problem: "This isn't the connected mailbox" }]);
    await flush(q, CFG, engine.fetchFn, () => at(2 * MIN));
    expect(engine.posts.length).toBe(2);

    // Back on the connected mailbox: the problem clears.
    await q.add([row("b", MIN)], at(3 * MIN), "me@example.org");
    expect((await q.status()).problem).toBeUndefined();

    // The engine refuses a mailbox (409): rows are dropped and the badge says why.
    const q2 = new Queue(new FakeStorage());
    await q2.add([row("y", MIN)], NOW, "other@example.org");
    await flush(q2, CFG, fakeEngine({ status: 409 }).fetchFn, () => NOW);
    expect(await q2.status()).toMatchObject({ waiting: 0, problem: "This isn't the connected mailbox" });
  });

  it("badge_shows_signed_out_waiting_and_idle", () => {
    expect(badgeFor({ waiting: 0 }, "signedOut")).toEqual({ text: "!", color: "grey", title: "Sign in to Outlook to pick up new email" });
    expect(badgeFor({ waiting: 4 }, "inbox").text).toBe("4");
    expect(badgeFor({ waiting: 0, lastOk: NOW.toISOString() }, "inbox")).toMatchObject({ text: "●", color: "green" });
    expect(badgeFor({ waiting: 0 }, "notInbox")).toMatchObject({ text: "!", color: "grey" });
    expect(badgeFor({ waiting: 0, problem: "Key rejected" }, "inbox")).toMatchObject({ text: "!", color: "red", title: expect.stringContaining("Key rejected") });
  });
});
