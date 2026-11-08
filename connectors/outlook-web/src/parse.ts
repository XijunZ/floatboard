import { SEL } from "./selectors";

export type Row = {
  rowId: string;
  fromName: string;
  fromAddr?: string;
  subject: string;
  preview: string;
  received: string; // ISO UTC
  unread: boolean;
};

export type PageRead =
  | { kind: "inbox"; mailbox?: string; rows: Row[] }
  | { kind: "signedOut" }
  | { kind: "notInbox" }
  | { kind: "unrecognised"; reason: string };

const EMAIL = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i;

/** Engine item id for a row: `owa:<rowId>:<receivedISO>`. */
export function rowKey(row: Pick<Row, "rowId" | "received">): string {
  return `owa:${row.rowId}:${row.received}`;
}

function splitKey(key: string): { rowId: string; received: string } | undefined {
  // The received part is always a 24-character ISO string (toISOString).
  if (!key.startsWith("owa:") || key.length < 4 + 1 + 24) return undefined;
  return { rowId: key.slice(4, -25), received: key.slice(-24) };
}

function isLocalMidnight(iso: string): boolean {
  const d = new Date(iso);
  return d.getHours() === 0 && d.getMinutes() === 0 && d.getSeconds() === 0 && d.getMilliseconds() === 0;
}

function sameLocalDay(a: string, b: string): boolean {
  return new Date(a).toDateString() === new Date(b).toDateString();
}

/**
 * Rows not already known. A row is known when its key is, or when the same row id is known on the same local day and
 * one of the two times is day-only (Outlook shows yesterday's "10:42" as "Sat" the next day).
 */
export function newRows(rows: Row[], known: Iterable<string>): Row[] {
  const keys = new Set(known);
  const byRow = new Map<string, string[]>();
  for (const k of keys) {
    const p = splitKey(k);
    if (p) byRow.set(p.rowId, [...(byRow.get(p.rowId) ?? []), p.received]);
  }
  const out: Row[] = [];
  for (const row of rows) {
    const key = rowKey(row);
    if (keys.has(key)) continue;
    const seen = byRow.get(row.rowId) ?? [];
    const coarseMatch = seen.some(
      (r) => sameLocalDay(r, row.received) && (isLocalMidnight(r) || isLocalMidnight(row.received)),
    );
    if (coarseMatch) continue;
    out.push(row);
    keys.add(key);
    byRow.set(row.rowId, [...seen, row.received]);
  }
  return out;
}

const WEEKDAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

function hm(h?: string, m?: string, ampm?: string): [number, number] | undefined {
  if (h === undefined) return [0, 0];
  let hour = Number(h);
  const min = Number(m);
  if (ampm) {
    const pm = ampm.toLowerCase() === "pm";
    if (hour < 1 || hour > 12) return undefined;
    hour = (hour % 12) + (pm ? 12 : 0);
  }
  if (hour > 23 || min > 59) return undefined;
  return [hour, min];
}

function local(y: number, mo: number, d: number, t: [number, number]): Date | undefined {
  const date = new Date(y, mo - 1, d, t[0], t[1], 0, 0);
  if (date.getFullYear() !== y || date.getMonth() !== mo - 1 || date.getDate() !== d) return undefined;
  return date;
}

/**
 * Reads a received time as Outlook shows it ("10:42", "2:05 PM", "Mon", "Yesterday", "03/11/2026", or a tooltip such
 * as "Sun 08/11/2026 10:42") in the browser's time zone, and returns ISO UTC. Dates are day first unless the page
 * language is US English; a reading that lands in the future is swapped.
 */
export function parseReceived(text: string, now: Date, locale: string): string | undefined {
  const s = text.replace(/[‎‏]/g, "").replace(/\s+/g, " ").trim();
  const TIME = String.raw`(\d{1,2}):(\d{2})(?:\s?([AaPp][Mm]))?`;

  let m = new RegExp(`^${TIME}$`).exec(s);
  if (m) {
    const t = hm(m[1], m[2], m[3]);
    return t && local(now.getFullYear(), now.getMonth() + 1, now.getDate(), t)?.toISOString();
  }

  m = new RegExp(String.raw`^(today|yesterday|[a-z]{3,9}\.?)(?:,?\s+${TIME})?$`, "i").exec(s);
  if (m) {
    const word = m[1].toLowerCase().replace(".", "");
    let back: number;
    if (word === "today") back = 0;
    else if (word === "yesterday") back = 1;
    else {
      const wd = WEEKDAYS.indexOf(word.slice(0, 3));
      if (wd < 0) return undefined;
      back = (now.getDay() - wd + 7) % 7 || 7;
    }
    const t = hm(m[2], m[3], m[4]);
    const day = new Date(now.getFullYear(), now.getMonth(), now.getDate() - back);
    return t && local(day.getFullYear(), day.getMonth() + 1, day.getDate(), t)?.toISOString();
  }

  m = new RegExp(String.raw`^(?:[a-z]{3,9}\.?,?\s+)?(\d{1,2})[/.-](\d{1,2})[/.-](\d{2}|\d{4})(?:,?\s+${TIME})?$`, "i").exec(s);
  if (m) {
    const a = Number(m[1]);
    const b = Number(m[2]);
    const y = m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3]);
    const t = hm(m[4], m[5], m[6]);
    if (!t) return undefined;
    const monthFirst = /-US$/i.test(locale);
    const first = monthFirst ? local(y, a, b, t) : local(y, b, a, t);
    const second = monthFirst ? local(y, b, a, t) : local(y, a, b, t);
    const soon = now.getTime() + 24 * 3600 * 1000;
    const pick = first && first.getTime() <= soon ? first : second && second.getTime() <= soon ? second : first;
    return pick?.toISOString();
  }
  return undefined;
}

function text(el: Element | null | undefined): string {
  return (el?.textContent ?? "").replace(/\s+/g, " ").trim();
}

function emailIn(el: Element | null | undefined): string | undefined {
  if (!el) return undefined;
  for (const attr of Array.from(el.attributes)) {
    const m = EMAIL.exec(attr.value);
    if (m) return m[0].toLowerCase();
  }
  return undefined;
}

function readMailbox(doc: Document): string | undefined {
  const t = EMAIL.exec(text(doc.querySelector(SEL.mailboxText)));
  if (t) return t[0].toLowerCase();
  for (const el of Array.from(doc.querySelectorAll(SEL.mailboxLabelled))) {
    const e = emailIn(el);
    if (e) return e;
  }
  return undefined;
}

/** Reads the Outlook page without changing it. Returns only unread rows. */
export function readPage(doc: Document, now: Date): PageRead {
  const list = doc.querySelector(SEL.messageList);
  if (!list && !doc.querySelector(SEL.signedInHeader) && doc.querySelector(SEL.signedOutMarkers)) {
    return { kind: "signedOut" };
  }
  const path = doc.location ? doc.location.pathname : "";
  if (!SEL.inboxPath.test(path)) return { kind: "notInbox" };
  if (!list) return { kind: "unrecognised", reason: "Message list not found" };

  const rowEls = Array.from(list.querySelectorAll(SEL.row));
  if (rowEls.length === 0 && list.querySelector(SEL.anyRow)) {
    return { kind: "unrecognised", reason: "Message rows not recognised" };
  }
  const locale = doc.documentElement.lang || doc.defaultView?.navigator?.language || "en-GB";
  const rows: Row[] = [];
  for (const el of rowEls) {
    if (!SEL.unreadLabel.test(el.getAttribute("aria-label") ?? "")) continue;
    const rowId = SEL.rowIdAttrs.map((a) => el.getAttribute(a)).find((v) => v);
    const senderEl = el.querySelector(SEL.sender);
    const fromName = text(senderEl);
    const timeEl = el.querySelector(SEL.time);
    const received =
      parseReceived(timeEl?.getAttribute("title") ?? "", now, locale) ??
      parseReceived(timeEl?.getAttribute("datetime") ?? "", now, locale) ??
      parseReceived(text(timeEl), now, locale);
    if (!rowId) return { kind: "unrecognised", reason: "Message id not found in a row" };
    if (!fromName) return { kind: "unrecognised", reason: "Sender not found in a row" };
    if (!received) return { kind: "unrecognised", reason: "Received time not readable in a row" };
    const row: Row = {
      rowId,
      fromName,
      subject: text(el.querySelector(SEL.subject)),
      preview: text(el.querySelector(SEL.preview)),
      received,
      unread: true,
    };
    const fromAddr = emailIn(senderEl);
    if (fromAddr) row.fromAddr = fromAddr;
    rows.push(row);
  }
  const mailbox = readMailbox(doc);
  return mailbox ? { kind: "inbox", mailbox, rows } : { kind: "inbox", rows };
}
