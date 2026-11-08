import { type Env, nowISO } from "../env";
import type { Message, Source, SourceRow } from "./types";

type Stored = { row_key: string; from_name: string; from_addr: string | null; subject: string; preview: string; received: string };
/** Position in one sweep through the waiting rows (oldest first); null = start again from the oldest. */
type Cursor = { received: string; key: string };

/** Outlook's own item ids (EWS / REST style, e.g. "AAQkAD..." or "AAMkAG...") can be opened directly. */
const OUTLOOK_ID = /^AA[A-Za-z0-9+/=_-]{20,}$/;

/** Opens the email in Outlook on the web: by its id when the row id is an Outlook id, else a search for its subject. */
export function outlookLink(rowId: string, subject: string): string {
  return OUTLOOK_ID.test(rowId)
    ? `https://outlook.office.com/mail/inbox/id/${encodeURIComponent(rowId)}`
    : `https://outlook.office.com/mail/search?q=${encodeURIComponent(subject)}`;
}

/** The row id inside a key "owa:<rowId>:<receivedISO>" (the received part is always 24 characters). */
const rowIdOf = (key: string) => key.slice(4, -25);

/** Formats a display name and address as a From line ("Lee, Anna" is quoted). */
function fromLine(name: string, addr: string | null): string {
  if (!addr) return name || "(unknown sender)";
  if (!name) return addr;
  return /[",;:<>@()[\]\\]/.test(name) ? `"${name.replace(/["\\]/g, "")}" <${addr}>` : `${name} <${addr}>`;
}

/**
 * The rows the Outlook Chrome extension sent (outlook_rows), as messages for the triage run. Nothing here calls Outlook:
 * the text is the list preview the extension read. A row is marked processed only once the run has stored its decision,
 * so a row the run couldn't finish is read again on the next sweep.
 */
export class OutlookSource implements Source {
  constructor(private env: Env, private row: SourceRow) {}

  async fetchBatch(cursor: string | null, limit: number) {
    const c: Cursor | null = cursor ? JSON.parse(cursor) : null;
    const { results } = await this.env.DB.prepare(`SELECT row_key, from_name, from_addr, subject, preview, received FROM outlook_rows
        WHERE user_id=? AND source_id=? AND processed=0 AND (received > ?3 OR (received = ?3 AND row_key > ?4))
        ORDER BY received, row_key LIMIT ?5`)
      .bind(this.row.user_id, this.row.id, c?.received ?? "", c?.key ?? "", limit).all<Stored>();
    const done = results.length < limit;
    const last = results[results.length - 1];
    return {
      messages: results.map((r) => this.toMessage(r)),
      cursor: done || !last ? null : JSON.stringify({ received: last.received, key: last.row_key } satisfies Cursor),
      done,
    };
  }

  async settled(messageId: string): Promise<void> {
    await this.env.DB.prepare("UPDATE outlook_rows SET processed=1, processed_at=? WHERE user_id=? AND row_key=?")
      .bind(nowISO(), this.row.user_id, messageId).run();
  }

  private toMessage(r: Stored): Message {
    return {
      messageId: r.row_key,
      sourceId: this.row.id,
      from: fromLine(r.from_name, r.from_addr),
      fromName: r.from_name || undefined,
      to: this.row.address ? [this.row.address] : [],
      cc: [],
      subject: r.subject,
      date: r.received,
      sentAt: r.received,
      labels: ["UNREAD"],
      headers: {},
      text: r.preview,
      preview: true,
      link: outlookLink(rowIdOf(r.row_key), r.subject),
    };
  }
}
