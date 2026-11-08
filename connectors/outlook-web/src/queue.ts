// The one send queue, owned by the service worker and kept in chrome.storage.local so nothing read is lost when Chrome
// stops the worker or the engine is offline. Content scripts only report rows; rows leave the queue only when the
// engine acknowledges them, and the engine stores them idempotently, so a send interrupted before the ack is simply
// sent again once.
import { newRows, rowKey, type PageRead, type Row } from "./parse";

/** The part of chrome.storage.local the queue uses (faked in tests). */
export interface StorageArea {
  get(key: string): Promise<unknown>;
  set(key: string, value: unknown): Promise<void>;
}

export type QueueItem = { key: string; mailbox?: string; row: Row };
export type QueueStatus = { waiting: number; lastOk?: string; problem?: string; notice?: string };
export type PageKind = PageRead["kind"] | "none";

export const MAX_QUEUED = 500;
export const MAX_ACKED = 5_000;
const ACK_KEEP_MS = 30 * 24 * 3600 * 1000;
const FIRST_RUN_MS = 7 * 24 * 3600 * 1000;
const BACKOFF_START_MS = 30_000;
const BACKOFF_MAX_MS = 5 * 60_000;

export const WRONG_MAILBOX = "This isn't the connected mailbox";
export const PAGE_NOT_RECOGNISED = "Outlook page not recognised";
export const ENGINE_UNREACHABLE = "Engine unreachable";
export const KEY_REJECTED = "Key rejected";
export const NOT_SET_UP = "Engine not set up: open the extension options";
const QUEUE_FULL = `Queue full: ${MAX_QUEUED} emails waiting to send`;
const ACKED_TRIMMED = "Over 5,000 sent emails remembered: the oldest are forgotten and may be sent again";

type ProblemReport = { mailbox?: string; problem: string };

type State = {
  items: QueueItem[];
  acked: Record<string, string>; // key -> acknowledged at (ISO)
  cutoff?: string; // set on the first run: rows received before it are never taken
  mailbox?: string; // the connected mailbox, set by the first acknowledged send
  refused: string[]; // mailboxes the engine refused
  wrongMailbox?: string;
  failures: number;
  nextAttempt?: string;
  lastOk?: string;
  engineProblem?: string;
  pageProblem?: string;
  queueFull?: boolean;
  ackedTrimmed?: boolean;
  report?: ProblemReport; // a problem the engine has not been told about yet
  reported?: string;
};

const STORAGE_KEY = "queue";
const lower = (s?: string) => s?.toLowerCase();

function fresh(): State {
  return { items: [], acked: {}, refused: [], failures: 0 };
}

export class Queue {
  private chain: Promise<unknown> = Promise.resolve();

  constructor(private storage: StorageArea) {}

  /** Runs one read-modify-write at a time, so reports from several tabs never overwrite each other. */
  private locked<T>(fn: (s: State) => T, write = true): Promise<T> {
    const run = this.chain.then(async () => {
      const s = { ...fresh(), ...((await this.storage.get(STORAGE_KEY)) as Partial<State> | undefined) };
      const out = fn(s);
      if (write) await this.storage.set(STORAGE_KEY, s);
      return out;
    });
    this.chain = run.catch(() => undefined);
    return run;
  }

  /** Queues new unread rows; returns how many were added. */
  add(rows: Row[], now: Date, mailbox?: string): Promise<number> {
    return this.locked((s) => {
      const mb = lower(mailbox);
      if (mb && ((s.mailbox && mb !== s.mailbox) || s.refused.includes(mb))) {
        setWrongMailbox(s, mb);
        return 0;
      }
      if (s.wrongMailbox) {
        s.wrongMailbox = undefined;
        clearReport(s);
      }
      pruneAcked(s, now);
      if (!s.cutoff) s.cutoff = new Date(now.getTime() - FIRST_RUN_MS).toISOString();
      const cutoff = s.cutoff;
      const known = [...Object.keys(s.acked), ...s.items.map((i) => i.key)];
      const incoming = newRows(rows, known).filter((r) => r.received >= cutoff);
      const room = Math.max(0, MAX_QUEUED - s.items.length);
      const taken = incoming.slice(0, room);
      s.queueFull = incoming.length > room;
      for (const row of taken) s.items.push({ key: rowKey(row), mailbox: mb ?? s.mailbox, row });
      return taken.length;
    });
  }

  /** The next rows to send (all for one mailbox), in the order they were queued. They stay queued until acknowledged. */
  takeBatch(max = 50): Promise<QueueItem[]> {
    return this.locked((s) => {
      if (s.items.length === 0) return [];
      const mb = s.items[0].mailbox;
      return s.items.filter((i) => i.mailbox === mb).slice(0, max);
    }, false);
  }

  /** The engine acknowledged these keys (an empty list acknowledges a connection test). */
  ack(keys: string[], now: Date, mailbox?: string): Promise<void> {
    return this.locked((s) => {
      const done = new Set(keys);
      s.items = s.items.filter((i) => !done.has(i.key));
      for (const k of keys) s.acked[k] = now.toISOString();
      pruneAcked(s, now);
      const mb = lower(mailbox);
      if (mb && !s.mailbox) s.mailbox = mb;
      s.failures = 0;
      s.nextAttempt = undefined;
      s.engineProblem = undefined;
      s.lastOk = now.toISOString();
    });
  }

  /** A send failed: back off 30 s, doubling to at most 5 minutes. */
  fail(now: Date, problem: string = ENGINE_UNREACHABLE): Promise<void> {
    return this.locked((s) => {
      s.failures += 1;
      const delay = Math.min(BACKOFF_START_MS * 2 ** (s.failures - 1), BACKOFF_MAX_MS);
      s.nextAttempt = new Date(now.getTime() + delay).toISOString();
      s.engineProblem = problem;
    });
  }

  /** The engine refused this mailbox: its rows are dropped and never queued again. */
  refuse(mailbox: string | undefined): Promise<void> {
    return this.locked((s) => {
      const mb = lower(mailbox) ?? "";
      s.items = s.items.filter((i) => (i.mailbox ?? "") !== mb);
      if (!s.refused.includes(mb)) s.refused.push(mb);
      s.wrongMailbox = mb;
      s.report = undefined;
      s.reported = reportId({ mailbox: mb, problem: WRONG_MAILBOX });
    });
  }

  /** What the open Outlook page looks like: a reason when it can't be read, else undefined. */
  setPageProblem(reason: string | undefined, mailbox?: string): Promise<void> {
    return this.locked((s) => {
      if (!reason) {
        if (s.pageProblem) {
          s.pageProblem = undefined;
          clearReport(s);
        }
        return;
      }
      s.pageProblem = PAGE_NOT_RECOGNISED;
      queueReport(s, { mailbox: lower(mailbox) ?? s.mailbox, problem: `${PAGE_NOT_RECOGNISED}: ${reason}` });
    });
  }

  /** New engine settings: forget the connected mailbox and any refusals. */
  resetMailbox(): Promise<void> {
    return this.locked((s) => {
      s.mailbox = undefined;
      s.refused = [];
      s.wrongMailbox = undefined;
      s.engineProblem = undefined;
      s.failures = 0;
      s.nextAttempt = undefined;
      clearReport(s);
    });
  }

  pendingReport(): Promise<ProblemReport | undefined> {
    return this.locked((s) => s.report, false);
  }

  reportSent(report: ProblemReport): Promise<void> {
    return this.locked((s) => {
      if (s.report && reportId(s.report) === reportId(report)) {
        s.reported = reportId(report);
        s.report = undefined;
      }
    });
  }

  canSend(now: Date): Promise<boolean> {
    return this.locked((s) => !s.nextAttempt || now.getTime() >= Date.parse(s.nextAttempt), false);
  }

  nextAttempt(): Promise<Date | undefined> {
    return this.locked((s) => (s.nextAttempt ? new Date(s.nextAttempt) : undefined), false);
  }

  status(): Promise<QueueStatus> {
    return this.locked((s) => {
      const problem =
        (s.wrongMailbox !== undefined ? WRONG_MAILBOX : undefined) ??
        s.engineProblem ??
        s.pageProblem ??
        (s.queueFull ? QUEUE_FULL : undefined);
      const out: QueueStatus = { waiting: s.items.length };
      if (s.lastOk) out.lastOk = s.lastOk;
      if (problem) out.problem = problem;
      if (s.ackedTrimmed) out.notice = ACKED_TRIMMED;
      return out;
    }, false);
  }
}

function reportId(r: ProblemReport): string {
  return `${r.mailbox ?? ""}\n${r.problem}`;
}

function queueReport(s: State, r: ProblemReport): void {
  if (s.reported === reportId(r)) return;
  s.report = r;
}

function clearReport(s: State): void {
  s.report = undefined;
  s.reported = undefined;
}

function setWrongMailbox(s: State, mb: string): void {
  s.wrongMailbox = mb;
  queueReport(s, { mailbox: mb, problem: WRONG_MAILBOX });
}

function pruneAcked(s: State, now: Date): void {
  const oldest = now.getTime() - ACK_KEEP_MS;
  const entries = Object.entries(s.acked).filter(([, at]) => Date.parse(at) >= oldest);
  let trimmed = false;
  if (entries.length > MAX_ACKED) {
    entries.sort((a, b) => a[1].localeCompare(b[1]));
    entries.splice(0, entries.length - MAX_ACKED);
    trimmed = true;
  }
  s.acked = Object.fromEntries(entries);
  s.ackedTrimmed = trimmed || (!!s.ackedTrimmed && entries.length >= MAX_ACKED);
}

// ---- Sending ----

export type IngestConfig = { engine: string; token: string };
export type FetchFn = (url: string, init: RequestInit) => Promise<Response>;
export type IngestResult = "ok" | "rejected" | "wrongMailbox" | "unreachable";

/** POST <engine>/ingest/outlook with the ingest token. An empty batch is a connection test. */
export async function postIngest(
  cfg: IngestConfig,
  body: { mailbox?: string; items?: Row[]; problem?: string },
  fetchFn: FetchFn,
): Promise<IngestResult> {
  try {
    const res = await fetchFn(`${cfg.engine.replace(/\/+$/, "")}/ingest/outlook`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${cfg.token}` },
      body: JSON.stringify(body),
    });
    if (res.ok) return "ok";
    if (res.status === 401 || res.status === 403) return "rejected";
    if (res.status === 409) return "wrongMailbox";
    return "unreachable";
  } catch {
    return "unreachable";
  }
}

const inFlight = new WeakMap<Queue, Promise<void>>();

/**
 * Sends waiting rows in batches until the queue is empty or a send fails, then any problem report. Concurrent calls
 * share one run, so two tabs reporting at once never send a row twice.
 */
export function flush(q: Queue, cfg: IngestConfig, fetchFn: FetchFn, now: () => Date): Promise<void> {
  const running = inFlight.get(q);
  if (running) return running;
  const run = (async () => {
    for (let i = 0; i < Math.ceil(MAX_QUEUED / 50) + 1; i++) {
      const batch = await q.takeBatch(50);
      if (batch.length === 0) break;
      const mailbox = batch[0].mailbox;
      const result = await postIngest(cfg, { ...(mailbox ? { mailbox } : {}), items: batch.map((b) => b.row) }, fetchFn);
      if (result === "ok") await q.ack(batch.map((b) => b.key), now(), mailbox);
      else if (result === "wrongMailbox") await q.refuse(mailbox);
      else return q.fail(now(), result === "rejected" ? KEY_REJECTED : ENGINE_UNREACHABLE);
    }
    const report = await q.pendingReport();
    if (report) {
      const result = await postIngest(cfg, { ...(report.mailbox ? { mailbox: report.mailbox } : {}), problem: report.problem }, fetchFn);
      if (result === "ok") await q.reportSent(report);
      else if (result === "rejected") await q.fail(now(), KEY_REJECTED);
    }
  })().finally(() => inFlight.delete(q));
  inFlight.set(q, run);
  return run;
}

// ---- Badge ----

export type Badge = { text: string; color: "green" | "blue" | "grey" | "red"; title: string };

export function badgeFor(status: QueueStatus, page: PageKind): Badge {
  const withNotice = (t: string) => (status.notice ? `${t}\n${status.notice}` : t);
  if (status.problem) return { text: "!", color: "red", title: withNotice(`FloatBoard: ${status.problem}`) };
  if (page === "signedOut") return { text: "!", color: "grey", title: withNotice("Sign in to Outlook to pick up new email") };
  if (status.waiting > 0) {
    const n = status.waiting;
    return { text: String(n), color: "blue", title: withNotice(`${n} email${n === 1 ? "" : "s"} waiting to send to FloatBoard`) };
  }
  if (page === "notInbox") return { text: "!", color: "grey", title: withNotice("Open your Outlook inbox to pick up new email") };
  if (page === "none") return { text: "!", color: "grey", title: withNotice("Open Outlook in Chrome to pick up new email") };
  const last = status.lastOk ? ` (last sent ${new Date(status.lastOk).toLocaleString()})` : "";
  return { text: "●", color: "green", title: withNotice(`FloatBoard for Outlook is up to date${last}`) };
}
