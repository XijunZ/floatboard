import { type Env, nowISO } from "../env";
import type { Message, Source, SourceRow } from "./types";

type Stored = { row_key: string; app: string; chat_name: string; is_group: number; senders: string; transcript: string; link: string; received: string };
type Cursor = { received: string; key: string };

const APP_NAMES: Record<string, string> = { whatsapp: "WhatsApp" };

/**
 * The chats the Mac sent (chat_rows), as messages for the triage run. Nothing here calls the chat app. A row is marked
 * processed once the run has stored its decision, so a row the run couldn't finish is read again on the next sweep.
 */
export class ChatSource implements Source {
  constructor(private env: Env, private row: SourceRow) {}

  async fetchBatch(cursor: string | null, limit: number) {
    const c: Cursor | null = cursor ? JSON.parse(cursor) : null;
    const { results } = await this.env.DB.prepare(`SELECT row_key, app, chat_name, is_group, senders, transcript, link, received FROM chat_rows
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
    await this.env.DB.prepare("UPDATE chat_rows SET processed=1, processed_at=? WHERE user_id=? AND row_key=?")
      .bind(nowISO(), this.row.user_id, messageId).run();
  }

  private toMessage(r: Stored): Message {
    const app = APP_NAMES[r.app] ?? r.app;
    return {
      messageId: r.row_key,
      sourceId: this.row.id,
      from: r.is_group ? `${r.chat_name} (${app} group)` : `${r.chat_name} (${app})`,
      fromName: r.chat_name,
      to: [], cc: [],
      subject: `${app}${r.is_group ? " group" : ""}: ${r.chat_name}`,
      date: r.received,
      sentAt: r.received,
      labels: ["UNREAD"],
      headers: {},
      text: r.transcript,
      link: r.link,
      chat: { app, group: !!r.is_group, name: r.chat_name, senders: r.senders },
    };
  }
}
