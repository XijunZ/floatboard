import { decrypt } from "../crypto";
import type { Env } from "../env";
import { type Message, type Source, type SourceNote, SourceAuthError, type SourceRow } from "./types";
import { DEFAULT_RECAP_SENDERS } from "../filter";
import type { ThreadMsg } from "../reply";
import { decodeWords } from "../mime";

export type DraftSnapshot = { to: string[]; cc: string[]; subject: string; body: string; attachments: boolean };

export { SourceAuthError };

const API = "https://gmail.googleapis.com/gmail/v1/users/me";
const MAX_TEXT = 8000;

type Cursor = { after: number; pageToken?: string; nextAfter?: number };

/** Reads new mail from one Gmail account, in pages, resuming from a cursor. */
export class GmailSource implements Source {
  private token: string | null = null;

  // Wrap the global fetch: Workers throw "Illegal invocation" if it's called as a method of this object.
  constructor(private env: Env, private row: SourceRow, private fetchFn: typeof fetch = (i, init) => fetch(i, init),
              private lookbackDays = 7, private alwaysInclude: string[] = DEFAULT_RECAP_SENDERS, private unreadOnly = true) {}

  async fetchBatch(cursor: string | null, limit: number) {
    const c: Cursor = cursor ? JSON.parse(cursor) : { after: Math.floor(Date.now() / 1000 - this.lookbackDays * 86400) };
    // Time this pass started; becomes the next pass's "after" once all pages are read.
    const nextAfter = c.nextAfter ?? Math.floor(Date.now() / 1000) - 60;
    // Bulk categories are filtered by Gmail itself (saves a call per newsletter); recap and allow-listed senders always pass.
    const keep = this.alwaysInclude.map((a) => `from:${a.startsWith("@") ? a.slice(1) : a}`).join(" ");
    const unread = this.unreadOnly ? "is:unread " : "";
    // category:primary = exactly what Gmail shows in the Primary tab (which may include "Updates" mail).
    const q = `after:${c.after} -in:sent -in:chats -in:drafts {${keep} (${unread}category:primary)}`;
    const params = new URLSearchParams({ q, maxResults: String(limit) });
    if (c.pageToken) params.set("pageToken", c.pageToken);
    const list = await this.api<{ messages?: { id: string; threadId?: string }[]; nextPageToken?: string }>(`${API}/messages?${params}`);
    const messages: Message[] = [];
    const notes: SourceNote[] = [];
    // Fetch the whole conversation instead of the single message (same one call), so we know whether the
    // user already replied and whether a newer message makes this one stale. Threads are fetched once per page.
    const threads = new Map<string, any[]>();
    for (const { id, threadId } of list.messages ?? []) {
      if (!threadId) { messages.push(this.parse(await this.api(`${API}/messages/${id}?format=full`))); continue; }
      if (!threads.has(threadId)) threads.set(threadId, (await this.api<{ messages?: any[] }>(`${API}/threads/${threadId}?format=full`)).messages ?? []);
      const all = threads.get(threadId)!;
      const m = all.find((x) => x.id === id);
      if (m) messages.push({ ...this.parse(m), thread: threadContext(m, all, (x) => this.parse(x)) });
      else {
        // Gmail listed it but its thread doesn't contain it: record that and read the message itself (no thread context).
        const direct = this.parse(await this.api(`${API}/messages/${id}?format=full`));
        notes.push({ messageId: direct.messageId, decision: "message missing from its thread; fetched directly", detail: `Gmail id ${id}, thread ${threadId}` });
        messages.push(direct);
      }
    }
    const done = !list.nextPageToken;
    const next: Cursor = done ? { after: nextAfter } : { after: c.after, pageToken: list.nextPageToken, nextAfter };
    return { messages, cursor: JSON.stringify(next), done, ...(notes.length ? { notes } : {}) };
  }

  /** Subject and plain text of one message (one token call the first time, then one read). */
  async readText(gmailId: string): Promise<{ subject: string; text: string }> {
    const m = this.parse(await this.api(`${API}/messages/${gmailId}?format=full`));
    return { subject: m.subject, text: stripQuoted(m.text) };
  }

  /** Messages matching a plain Gmail query: one list call, then one headers-only read per hit (newest first). */
  async search(q: string, max = 5): Promise<Message[]> {
    const params = new URLSearchParams({ q, maxResults: String(max) });
    const list = await this.api<{ messages?: { id: string }[] }>(`${API}/messages?${params}`);
    const out: Message[] = [];
    for (const { id } of (list.messages ?? []).slice(0, max)) {
      const h = new URLSearchParams({ format: "metadata" });
      for (const n of ["Message-ID", "Subject", "From", "To", "Date"]) h.append("metadataHeaders", n);
      out.push(this.parse(await this.api(`${API}/messages/${id}?${h}`)));
    }
    return out;
  }

  /** One message in full (one read). */
  async fetchFull(gmailId: string): Promise<Message> {
    return this.parse(await this.api(`${API}/messages/${gmailId}?format=full`));
  }

  /** Remove the UNREAD label (needs the gmail.modify permission). */
  async markRead(gmailId: string): Promise<void> {
    const r = await this.fetchFn(`${API}/messages/${gmailId}/modify`, {
      method: "POST", headers: { Authorization: `Bearer ${await this.accessToken()}`, "Content-Type": "application/json" },
      body: JSON.stringify({ removeLabelIds: ["UNREAD"] }),
    });
    if (r.status === 403) throw new SourceAuthError(`Reconnect ${this.row.address} to let FloatBoard mark emails as read.`);
    if (!r.ok) throw new Error(`Gmail ${r.status} marking ${gmailId} read`);
  }

  /** The whole Gmail thread that contains this RFC 822 Message-ID (two reads: search, then the thread). Drafts are left out. */
  async findThread(messageId: string): Promise<{ threadId: string; messages: ThreadMsg[] } | null> {
    const id = messageId.trim().replace(/^<|>$/g, "");
    const params = new URLSearchParams({ q: `rfc822msgid:${id}`, maxResults: "1" });
    const list = await this.api<{ messages?: { id: string; threadId?: string }[] }>(`${API}/messages?${params}`);
    const threadId = list.messages?.[0]?.threadId;
    if (!threadId) return null;
    const t = await this.api<{ messages?: any[] }>(`${API}/threads/${threadId}?format=full`);
    const messages = (t.messages ?? []).filter((x) => !(x.labelIds ?? []).includes("DRAFT")).map((x) => {
      const p = this.parse(x);
      const replyTo = p.headers["reply-to"]?.trim();
      return { messageId: p.messageId, from: p.from, ...(replyTo ? { replyTo } : {}), to: p.to, cc: p.cc, subject: p.subject, date: p.date, text: stripQuoted(p.text) };
    });
    return { threadId, messages };
  }

  /** The user's own send-from addresses (lower-case) and the primary display name. */
  async ownAddresses(): Promise<{ addresses: string[]; displayName?: string }> {
    const j = await this.api<{ sendAs?: { sendAsEmail?: string; displayName?: string; isPrimary?: boolean }[] }>(`${API}/settings/sendAs`);
    const list = j.sendAs ?? [];
    const addresses = list.map((s) => (s.sendAsEmail ?? "").trim().toLowerCase()).filter(Boolean);
    const name = (list.find((s) => s.isPrimary) ?? list[0])?.displayName?.trim();
    return { addresses, ...(name ? { displayName: name } : {}) };
  }

  async createDraft(raw: string, threadId: string): Promise<{ draftId: string; messageId: string }> {
    return this.saveDraft("POST", `${API}/drafts`, raw, threadId);
  }

  async updateDraft(draftId: string, raw: string, threadId: string): Promise<{ draftId: string; messageId: string }> {
    return this.saveDraft("PUT", `${API}/drafts/${encodeURIComponent(draftId)}`, raw, threadId);
  }

  /** A draft as it is now (recipients, subject, plain text, whether it has attachments), or null when it no longer
   *  exists (sent or deleted). */
  async draftSnapshot(draftId: string): Promise<DraftSnapshot | null> {
    const r = await this.authed(`${API}/drafts/${encodeURIComponent(draftId)}?format=full`);
    if (r.status === 404) return null;
    if (!r.ok) throw new Error(`Gmail ${r.status} reading draft`);
    const j = await r.json<{ message?: any }>();
    if (!j.message) return { to: [], cc: [], subject: "", body: "", attachments: false };
    const p = this.parse(j.message);
    return { to: p.to, cc: p.cc, subject: decodeWords(p.subject), body: p.text, attachments: hasAttachment(j.message.payload) };
  }

  private async saveDraft(method: "POST" | "PUT", url: string, raw: string, threadId: string) {
    const r = await this.fetchFn(url, {
      method, headers: { Authorization: `Bearer ${await this.accessToken()}`, "Content-Type": "application/json" },
      body: JSON.stringify({ message: { raw, threadId } }),
    });
    if (r.status === 403) throw new SourceAuthError(`Reconnect ${this.row.address} to let FloatBoard create drafts.`);
    if (r.status === 401) throw new SourceAuthError(`Gmail refused access for ${this.row.address}. Reconnect it.`);
    if (!r.ok) throw new Error(`Gmail ${r.status} saving draft`);
    const j = await r.json<{ id: string; message?: { id?: string } }>();
    return { draftId: j.id, messageId: j.message?.id ?? "" };
  }

  /** True once the access token for this inbox has been fetched (later calls cost no token call). */
  get hasToken(): boolean { return this.token !== null; }

  /**
   * Mark read unless the user changed this email's read state since FloatBoard read it (e.g. read it, then marked it
   * unread again on another device). Other changes (labels, categories, IMPORTANT) don't count.
   * 1. GET ?format=minimal: 404 -> "gone"; not UNREAD -> "already_read"; historyId unchanged (or none stored) -> mark read.
   * 2. Otherwise read the UNREAD label history since the stored historyId and look for this message:
   *    a change -> "marked_unread_again"; none -> mark read; history 404 (start too old) -> "unconfirmed".
   * `canSpend(n)` says whether n more calls fit the run's budget; a history page is only fetched if it and the final
   * modify fit, else "wait" (nothing changed; retry next run).
   */
  async markReadIfUnchanged(gmailId: string, expectedHistoryId: string | null, canSpend: (n: number) => boolean = () => true):
      Promise<"gone" | "already_read" | "marked" | "marked_unread_again" | "unconfirmed" | "wait"> {
    const r = await this.authed(`${API}/messages/${gmailId}?format=minimal`);
    if (r.status === 404) return "gone";
    if (!r.ok) throw new Error(`Gmail ${r.status} checking ${gmailId}`);
    const m = await r.json<{ labelIds?: string[]; historyId?: string | number }>();
    if (!(m.labelIds ?? []).includes("UNREAD")) return "already_read";
    if (expectedHistoryId !== null && String(m.historyId ?? "") !== expectedHistoryId) {
      let pageToken: string | undefined;
      do {
        if (!canSpend(2)) return "wait"; // this page + the modify
        const q = new URLSearchParams({ startHistoryId: expectedHistoryId, labelId: "UNREAD" });
        q.append("historyTypes", "labelAdded");
        q.append("historyTypes", "labelRemoved");
        if (pageToken) q.set("pageToken", pageToken);
        const h = await this.authed(`${API}/history?${q}`);
        if (h.status === 404) return "unconfirmed";
        if (!h.ok) throw new Error(`Gmail ${h.status} reading history for ${gmailId}`);
        const j = await h.json<{ history?: any[]; nextPageToken?: string }>();
        const touched = (j.history ?? []).some((rec) => [...(rec.labelsAdded ?? []), ...(rec.labelsRemoved ?? [])]
          .some((x: any) => x?.message?.id === gmailId && (x.labelIds ?? []).includes("UNREAD")));
        if (touched) return "marked_unread_again";
        pageToken = j.nextPageToken;
      } while (pageToken);
    }
    await this.markRead(gmailId);
    return "marked";
  }

  /** GET with the access token; 401 means the inbox must be reconnected. */
  private async authed(url: string): Promise<Response> {
    const r = await this.fetchFn(url, { headers: { Authorization: `Bearer ${await this.accessToken()}` } });
    if (r.status === 401) throw new SourceAuthError(`Gmail refused access for ${this.row.address}. Reconnect it.`);
    return r;
  }

  private async accessToken(): Promise<string> {
    if (this.token) return this.token;
    const body = new URLSearchParams({
      client_id: this.row.client_id ?? "",
      client_secret: await decrypt(this.env, this.row.client_secret_enc ?? ""),
      refresh_token: await decrypt(this.env, this.row.refresh_enc ?? ""),
      grant_type: "refresh_token",
    });
    const r = await this.fetchFn("https://oauth2.googleapis.com/token", {
      method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body,
    });
    const j = await r.json<{ access_token?: string; error?: string; error_description?: string }>();
    if (!r.ok || !j.access_token) {
      throw new SourceAuthError(`Google sign-in for ${this.row.address} expired or was revoked (${j.error ?? r.status}). Reconnect it.`);
    }
    this.token = j.access_token;
    return this.token;
  }

  private async api<T = any>(url: string): Promise<T> {
    const r = await this.fetchFn(url, { headers: { Authorization: `Bearer ${await this.accessToken()}` } });
    if (r.status === 401) throw new SourceAuthError(`Gmail refused access for ${this.row.address}. Reconnect it.`);
    if (!r.ok) throw new Error(`Gmail ${r.status} for ${url}`);
    return r.json<T>();
  }

  private parse(m: any): Message {
    const headers: Record<string, string> = {};
    for (const h of m.payload?.headers ?? []) headers[String(h.name).toLowerCase()] = String(h.value);
    const addrs = splitAddresses;
    const plain = findPart(m.payload, "text/plain");
    const html = plain ? null : findPart(m.payload, "text/html");
    const text = plain ? decodeB64(plain) : html ? htmlToText(decodeB64(html)) : "";
    return {
      messageId: headers["message-id"] ?? `gmail:${this.row.address}:${m.id}`,
      sourceId: this.row.id,
      from: headers["from"] ?? "",
      to: addrs(headers["to"]),
      cc: addrs(headers["cc"]),
      subject: headers["subject"] ?? "",
      date: headers["date"] ?? "",
      sentAt: sentAtISO(headers["date"], m.internalDate),
      labels: m.labelIds ?? [],
      headers,
      text: text.trim().slice(0, MAX_TEXT),
      link: `https://mail.google.com/mail/u/${this.row.address}/#all/${m.id}`,
      gmailId: m.id != null ? String(m.id) : undefined,
      historyId: m.historyId != null ? String(m.historyId) : undefined,
    };
  }
}

/** Split an address list on commas that are outside double quotes and angle brackets. */
export function splitAddresses(v?: string): string[] {
  if (!v) return [];
  const out: string[] = [];
  let cur = "", quoted = false, angle = false;
  for (let i = 0; i < v.length; i++) {
    const c = v[i];
    if (quoted && c === "\\") { cur += c + (v[++i] ?? ""); continue; }
    if (c === '"') quoted = !quoted;
    else if (!quoted && c === "<") angle = true;
    else if (!quoted && c === ">") angle = false;
    if (c === "," && !quoted && !angle) { out.push(cur); cur = ""; } else cur += c;
  }
  out.push(cur);
  return out.map((s) => s.trim()).filter(Boolean);
}

/** The Date header as ISO-8601 UTC; falls back to Gmail's receive time when the header is missing or unreadable. */
export function sentAtISO(dateHeader: string | undefined, internalDate?: string | number): string | undefined {
  const t = dateHeader ? Date.parse(dateHeader) : NaN;
  if (!isNaN(t)) return new Date(t).toISOString();
  const n = Number(internalDate);
  return n > 0 ? new Date(n).toISOString() : undefined;
}

/** Is there a newer incoming message in the thread, and did the user reply after this one? */
export function threadContext(m: any, all: any[], parse: (x: any) => Message): NonNullable<Message["thread"]> {
  const at = (x: any) => Number(x.internalDate ?? 0);
  const sent = (x: any) => (x.labelIds ?? []).includes("SENT");
  const later = all.filter((x) => x.id !== m.id && at(x) > at(m) && !(x.labelIds ?? []).includes("DRAFT"));
  const superseded = later.some((x) => !sent(x));
  const reply = later.filter(sent).sort((a, b) => at(b) - at(a))[0];
  if (!reply) return { superseded };
  const p = parse(reply);
  return { superseded, myReply: { date: p.date, text: stripQuoted(p.text).slice(0, 1500) } };
}

/** Drop the quoted original from a reply ("On … wrote:" and "> " lines). */
export function stripQuoted(t: string): string {
  const cut = t.search(/\n\s*On .{5,200}wrote:\s*\n|\n-{2,}\s*Original Message|\nFrom: .+\nSent: /i);
  return (cut > 0 ? t.slice(0, cut) : t).split("\n").filter((l) => !l.startsWith(">")).join("\n").trim();
}

/** True when any part of the message is a file (a filename or an attachment id). */
function hasAttachment(p: any): boolean {
  if (!p) return false;
  if (p.filename || p.body?.attachmentId) return true;
  return (p.parts ?? []).some(hasAttachment);
}

function findPart(p: any, mime: string): string | null {
  if (!p) return null;
  if (p.mimeType === mime && p.body?.data) return p.body.data;
  for (const c of p.parts ?? []) {
    const f = findPart(c, mime);
    if (f) return f;
  }
  return null;
}

function decodeB64(data: string): string {
  const bin = atob(data.replace(/-/g, "+").replace(/_/g, "/"));
  return new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
}

export function htmlToText(html: string): string {
  return html
    .replace(/<(style|script)[^>]*>[\s\S]*?<\/\1>/gi, " ")
    .replace(/<br\s*\/?>|<\/(p|div|li|tr|h\d)>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, " ").replace(/\n\s*\n+/g, "\n").trim();
}

/** Gmail message id from the link we store ("…/#all/<id>"). */
export function gmailIdFromLink(link: string | null | undefined): string | null {
  return link ? (/mail\.google\.com\/.*#all\/([A-Za-z0-9]+)$/.exec(link)?.[1] ?? null) : null;
}

export function gmailSource(env: Env, row: SourceRow, fetchFn?: typeof fetch): GmailSource {
  return new GmailSource(env, row, fetchFn);
}
