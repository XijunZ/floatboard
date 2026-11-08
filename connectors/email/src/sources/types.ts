export type Message = {
  messageId: string;        // RFC822 Message-ID (dedupe key across accounts)
  sourceId: string;
  from: string;
  to: string[];
  cc: string[];
  subject: string;
  date: string;
  /** When it was sent: the Date header as ISO-8601 UTC (same in every inbox); part of the source key. */
  sentAt?: string;
  labels: string[];
  headers: Record<string, string>; // lower-cased names
  text: string;              // plain text, truncated for the classifier
  link: string;              // opens the original message
  /** Gmail's own id of the message (to read it again directly). */
  gmailId?: string;
  /** Gmail's historyId for the message when it was read (changes whenever the message is modified, e.g. read/unread). */
  historyId?: string;
  /** Conversation context (Gmail): a newer message in the thread makes this one stale; the user's own later reply is shown to Claude. */
  thread?: { superseded: boolean; myReply?: { date: string; text: string } };
};

/** Something odd the source worked around; the run records it in the run log (trace = messageId). */
export type SourceNote = { messageId?: string; decision: string; detail?: string };

export interface Source {
  /** Read one message again by its provider id (used to retry a message Claude could not judge). */
  fetchFull?(id: string): Promise<Message>;
  fetchBatch(cursor: string | null, limit: number): Promise<{ messages: Message[]; cursor: string | null; done: boolean; notes?: SourceNote[] }>;
}

export class SourceAuthError extends Error {}

export type SourceRow = {
  id: string; user_id: string; kind: string; address: string;
  refresh_enc: string | null; client_id: string | null; client_secret_enc: string | null; cursor: string | null;
};
