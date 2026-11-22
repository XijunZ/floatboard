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

/**
 * `mailbox` is the one shown in the same read as the row. A row read before any mailbox showed waits without one, and
 * gets one only when it is seen again in a read that shows the mailbox (round 41: the tab alone never decides).
 */
export type QueueItem = { key: string; mailbox?: string; at?: string; row: Row };
export type QueueStatus = { waiting: number; lastOk?: string; problem?: string; notice?: string; setAside?: number };
export type PageKind = PageRead["kind"] | "none";

export const MAX_QUEUED = 500;
export const MAX_ACKED = 5_000;
const ACK_KEEP_MS = 30 * 24 * 3600 * 1000;
const FIRST_RUN_MS = 7 * 24 * 3600 * 1000;
/** How long a row without a mailbox may wait to be read again with one before it is set aside (round 41). */
const HOLD_MS = 2 * 3600 * 1000;
const MAX_SET_ASIDE = 2_000;
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

/** What one engine's queue holds; kept aside (parked) while another engine or key is in use (round 41). */
type Parked = Pick<State, "items" | "setAside" | "acked" | "cutoff" | "mailbox" | "seenMailbox" | "refused">;

type State = {
  engine?: string; // the engine identity (address and a hash of its key) the queue belongs to
  parked?: Record<string, Parked>;
  items: QueueItem[];
  setAside?: string[]; // keys of rows never read again with a mailbox (not sent; picked up if read with one later)
  acked: Record<string, string>; // key -> acknowledged at (ISO)
  cutoff?: string; // set on the first run: rows received before it are never taken
  mailbox?: string; // the connected mailbox, set by the first acknowledged send
  seenMailbox?: string; // a mailbox the page showed before one was connected: told to the engine even without new rows
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

/** Binds `s` to `engine`, parking the queue of the engine it held (see `Queue.bindEngine`). */
function rebind(s: State, engine: string): void {
  if (s.engine === engine) return;
  if (s.engine === undefined) { s.engine = engine; return; }   // a queue from before engines were told apart
  const parked = { ...(s.parked ?? {}) };
  parked[s.engine] = { items: s.items, setAside: s.setAside, acked: s.acked, cutoff: s.cutoff, mailbox: s.mailbox, seenMailbox: s.seenMailbox, refused: s.refused };
  const back = parked[engine];
  delete parked[engine];
  const next: State = { ...fresh(), ...(back ?? {}), engine, parked };
  for (const k of Object.keys(s)) delete (s as Record<string, unknown>)[k];   // nothing of the other account's state stays
  Object.assign(s, next);
}

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

  /**
   * Queues new unread rows from one read; returns how many were added. A row read before its mailbox showed waits, and
   * is labelled only when it is seen again in a read that shows the mailbox (dropped if that is someone else's).
   */
  add(rows: Row[], now: Date, mailbox?: string, engine?: string): Promise<number> {
    return this.locked((s) => {
      if (engine !== undefined) rebind(s, engine);   // rows read under another engine or key belong to that one's queue
      const mb = lower(mailbox);
      const inThisRead = new Set(rows.map(rowKey));
      const heldHere = (i: QueueItem) => !i.mailbox && inThisRead.has(i.key);
      if (mb && ((s.mailbox && mb !== s.mailbox) || s.refused.includes(mb))) {
        s.items = s.items.filter((i) => !heldHere(i));
        setWrongMailbox(s, mb);
        return 0;
      }
      if (mb) for (const i of s.items) if (heldHere(i)) { i.mailbox = mb; delete i.at; }
      // Rows still without a mailbox after HOLD_MS are set aside: they free the queue and are counted (round 41).
      const expired = (i: QueueItem) => !i.mailbox && now.getTime() - Date.parse(i.at ?? now.toISOString()) >= HOLD_MS;
      for (const i of s.items) if (!i.mailbox && !i.at) i.at = now.toISOString();   // rows from older versions get a window too
      const aside = s.items.filter(expired).map((i) => i.key);
      if (aside.length) {
        s.items = s.items.filter((i) => !expired(i));
        s.setAside = [...new Set([...(s.setAside ?? []), ...aside])].slice(-MAX_SET_ASIDE);
      }
      if (mb && s.setAside?.length) s.setAside = s.setAside.filter((k) => !inThisRead.has(k));   // read with the mailbox now: back
      if (s.wrongMailbox) {
        s.wrongMailbox = undefined;
        clearReport(s);
      }
      if (mb && !s.mailbox) s.seenMailbox = mb;
      pruneAcked(s, now);
      if (!s.cutoff) s.cutoff = new Date(now.getTime() - FIRST_RUN_MS).toISOString();
      const cutoff = s.cutoff;
      // Set-aside rows come back only with a mailbox (read again without one, they stay aside).
      const known = [...Object.keys(s.acked), ...s.items.map((i) => i.key), ...(mb ? [] : s.setAside ?? [])];
      const incoming = newRows(rows, known).filter((r) => r.received >= cutoff);
      const room = Math.max(0, MAX_QUEUED - s.items.length);
      const taken = incoming.slice(0, room);
      s.queueFull = incoming.length > room;
      for (const row of taken) s.items.push(mb ? { key: rowKey(row), mailbox: mb, row } : { key: rowKey(row), at: now.toISOString(), row });
      return taken.length;
    });
  }

  /**
   * Binds the queue to the engine in use (round 41). Another engine or key: the current queue is parked under its own
   * engine (never sent to the new one) and that engine's parked queue, if any, comes back.
   */
  bindEngine(engine: string): Promise<void> {
    return this.locked((s) => rebind(s, engine));
  }

  /** The next rows to send (all for one mailbox), in the order they were queued. They stay queued until acknowledged. */
  takeBatch(max = 50, engine?: string): Promise<QueueItem[]> {
    return this.locked((s) => {
      if (engine !== undefined && s.engine !== engine) return [];   // the queue now belongs to another engine
      const ready = s.items.filter((i) => i.mailbox);   // rows still waiting for their tab's mailbox are never sent
      if (ready.length === 0) return [];
      const mb = ready[0].mailbox;
      return ready.filter((i) => i.mailbox === mb).slice(0, max);
    }, false);
  }

  /**
   * A mailbox the page showed that the engine hasn't been told yet (Outlook can draw the message list before the
   * account, so the rows may already have gone without it). Sent once, with no rows, when nothing else is waiting.
   */
  mailboxToAnnounce(engine?: string): Promise<string | undefined> {
    return this.locked((s) => engine !== undefined && s.engine !== engine ? undefined : (!s.mailbox && !s.items.some((i) => i.mailbox) ? s.seenMailbox : undefined), false);
  }

  /** The engine acknowledged these keys (an empty list acknowledges a connection test). */
  ack(keys: string[], now: Date, mailbox?: string, engine?: string): Promise<void> {
    return this.locked((s) => {
      if (engine !== undefined && s.engine !== engine) return;   // an answer from the engine used before a switch
      const done = new Set(keys);
      s.items = s.items.filter((i) => !done.has(i.key));
      for (const k of keys) s.acked[k] = now.toISOString();
      pruneAcked(s, now);
      const mb = lower(mailbox);
      if (mb && !s.mailbox) s.mailbox = mb;
      if (s.mailbox) s.seenMailbox = undefined;
      s.failures = 0;
      s.nextAttempt = undefined;
      s.engineProblem = undefined;
      s.lastOk = now.toISOString();
    });
  }

  /** A send failed: back off 30 s, doubling to at most 5 minutes. */
  fail(now: Date, problem: string = ENGINE_UNREACHABLE, engine?: string): Promise<void> {
    return this.locked((s) => {
      if (engine !== undefined && s.engine !== engine) return;   // the engine used before a switch
      s.failures += 1;
      const delay = Math.min(BACKOFF_START_MS * 2 ** (s.failures - 1), BACKOFF_MAX_MS);
      s.nextAttempt = new Date(now.getTime() + delay).toISOString();
      s.engineProblem = problem;
    });
  }

  /** The engine refused this mailbox: its rows are dropped and never queued again. */
  refuse(mailbox: string | undefined, engine?: string): Promise<void> {
    return this.locked((s) => {
      if (engine !== undefined && s.engine !== engine) return;
      const mb = lower(mailbox) ?? "";
      s.items = s.items.filter((i) => (i.mailbox ?? "") !== mb);
      if (!s.refused.includes(mb)) s.refused.push(mb);
      if (s.seenMailbox === mb) s.seenMailbox = undefined;
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

  pendingReport(engine?: string): Promise<ProblemReport | undefined> {
    return this.locked((s) => (engine !== undefined && s.engine !== engine ? undefined : s.report), false);
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
      const notices = s.ackedTrimmed ? [ACKED_TRIMMED] : [];
      const aside = s.setAside?.length ?? 0;
      if (aside) {
        out.setAside = aside;
        notices.push(`${aside} email${aside === 1 ? " was" : "s were"} read before Outlook showed whose mailbox ${aside === 1 ? "it is" : "they are"} in, so ${aside === 1 ? "it is" : "they are"} set aside: open your inbox to pick ${aside === 1 ? "it" : "them"} up`);
      }
      if (notices.length) out.notice = notices.join("\n");
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

/** The send running for each queue, and the engine it sends to. */
const inFlight = new WeakMap<Queue, { engine: string; run: Promise<void> }>();

/**
 * Who the queue's emails are for (round 41): the engine's address and a hash of its key (the key itself is never
 * stored). Another address or key is another account.
 */
export async function engineIdentity(cfg: IngestConfig): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(cfg.token));
  const hex = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("").slice(0, 24);
  return `${cfg.engine.replace(/\/+$/, "")}#${hex}`;
}

/**
 * Sends the queue to the engine in `cfg`. The queue is bound to that engine first: emails queued for another engine or
 * key stay parked under it and are never sent here, and a send still running for the previous engine can neither take
 * nor acknowledge the new engine's rows (round 41).
 */
export function flush(q: Queue, cfg: IngestConfig, fetchFn: FetchFn, now: () => Date): Promise<void> {
  return engineIdentity(cfg).then((engine) => {
    const running = inFlight.get(q);
    if (running && running.engine === engine) return running.run;
    const run: Promise<void> = (async () => {
      await q.bindEngine(engine);
      for (let i = 0; i < Math.ceil(MAX_QUEUED / 50) + 1; i++) {
        const batch = await q.takeBatch(50, engine);
        if (batch.length === 0) break;
        const mailbox = batch[0].mailbox;
        const result = await postIngest(cfg, { ...(mailbox ? { mailbox } : {}), items: batch.map((b) => b.row) }, fetchFn);
        if (result === "ok") await q.ack(batch.map((b) => b.key), now(), mailbox, engine);
        else if (result === "wrongMailbox") await q.refuse(mailbox, engine);
        else return q.fail(now(), result === "rejected" ? KEY_REJECTED : ENGINE_UNREACHABLE, engine);
      }
      const announce = await q.mailboxToAnnounce(engine);
      if (announce) {
        const result = await postIngest(cfg, { mailbox: announce, items: [] }, fetchFn);
        if (result === "ok") await q.ack([], now(), announce, engine);
        else if (result === "wrongMailbox") await q.refuse(announce, engine);
        else return q.fail(now(), result === "rejected" ? KEY_REJECTED : ENGINE_UNREACHABLE, engine);
      }
      const report = await q.pendingReport(engine);
      if (report) {
        const result = await postIngest(cfg, { ...(report.mailbox ? { mailbox: report.mailbox } : {}), problem: report.problem }, fetchFn);
        if (result === "ok") await q.reportSent(report);
        else if (result === "rejected") await q.fail(now(), KEY_REJECTED, engine);
      }
    })().finally(() => { if (inFlight.get(q)?.run === run) inFlight.delete(q); });
    inFlight.set(q, { engine, run });
    return run;
  });
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
