/** Building the RFC 2822 reply that goes into a Gmail draft. */

const utf8 = (s: string) => new TextEncoder().encode(s);
const b64 = (bytes: Uint8Array) => { let bin = ""; for (const b of bytes) bin += String.fromCharCode(b); return btoa(bin); };
const b64url = (bytes: Uint8Array) => b64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const oneLine = (s: string) => s.replace(/[\r\n]+/g, " ").trim();
const ascii = (s: string) => /^[\x20-\x7e]*$/.test(s);

/** Header text as RFC 2047 encoded words (each at most 75 characters) when it is not plain ASCII. */
function encodeWords(s: string): string {
  if (ascii(s)) return s;
  const words: string[] = [];
  let chunk = "";
  for (const ch of s) {
    if (utf8(chunk + ch).length > 45) { words.push(chunk); chunk = ""; }
    chunk += ch;
  }
  if (chunk) words.push(chunk);
  return words.map((w) => `=?UTF-8?B?${b64(utf8(w))}?=`).join("\r\n ");
}

/** "Name <a@x>" with a non-ASCII name gets the name encoded; bare addresses pass through. */
function encodeAddress(a: string): string {
  const m = oneLine(a).match(/^(.*?)\s*<([^>]*)>$/);
  if (!m || !m[1]) return oneLine(a);
  const name = m[1].replace(/^"|"$/g, "");
  return `${ascii(name) ? (/[",;:<>()@]/.test(name) ? `"${name.replace(/"/g, '\\"')}"` : name) : encodeWords(name)} <${m[2]}>`;
}

/** The reply's subject as FloatBoard writes it: one line, with "Re: " unless it already has it. */
export function replySubject(subject: string): string {
  const s = oneLine(subject);
  return /^re:/i.test(s) ? s : `Re: ${s}`;
}

/** Header text with any RFC 2047 encoded words (UTF-8, B or Q) decoded; anything else passes through. */
export function decodeWords(s: string): string {
  return s.replace(/=\?UTF-8\?([BQ])\?([^?]*)\?=(?:\s+(?==\?UTF-8\?))?/gi, (_, enc: string, text: string) => {
    try {
      const bin = enc.toUpperCase() === "B" ? atob(text)
        : text.replace(/_/g, " ").replace(/=([0-9A-F]{2})/gi, (_m, h: string) => String.fromCharCode(parseInt(h, 16)));
      return new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
    } catch { return text; } // not really encoded: leave it as it was
  });
}

const AI_LINE = "Assisted by AI";

/** The plain-text body FloatBoard writes: the reply, plus the Assisted by AI line when asked for. */
export function draftText(reply: string, aiLine: boolean): string {
  return aiLine ? `${reply.trimEnd()}\n\n${AI_LINE}` : reply;
}

const escapeHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const b64Lines = (s: string) => (b64(utf8(s.replace(/\r\n|\r|\n/g, "\r\n"))).match(/.{1,76}/g) ?? []).join("\r\n");

export function replyMime(m: { from: string; to: string; cc: string[]; subject: string; inReplyTo: string; references: string; body: string; aiLine?: boolean }): string {
  const headers = [
    `From: ${encodeAddress(m.from)}`,
    `To: ${encodeAddress(m.to)}`,
    ...(m.cc.length ? [`Cc: ${m.cc.map(encodeAddress).join(", ")}`] : []),
    `Subject: ${encodeWords(replySubject(m.subject))}`,
    `In-Reply-To: ${oneLine(m.inReplyTo)}`,
    `References: ${oneLine(m.references)}`,
    "MIME-Version: 1.0",
  ];
  if (!m.aiLine) {
    headers.push('Content-Type: text/plain; charset="UTF-8"', "Content-Transfer-Encoding: base64");
    return b64url(utf8(`${headers.join("\r\n")}\r\n\r\n${b64Lines(m.body)}\r\n`));
  }
  // Italics need an HTML part; the plain part carries the same line for clients that show text only.
  const boundary = `fb-${crypto.randomUUID()}`;
  const html = `<div>${escapeHtml(m.body.trimEnd()).replace(/\r?\n/g, "<br>")}<br><br><i>${AI_LINE}</i></div>`;
  headers.push(`Content-Type: multipart/alternative; boundary="${boundary}"`);
  const part = (type: string, text: string) =>
    `--${boundary}\r\nContent-Type: ${type}; charset="UTF-8"\r\nContent-Transfer-Encoding: base64\r\n\r\n${b64Lines(text)}\r\n`;
  return b64url(utf8(`${headers.join("\r\n")}\r\n\r\n${part("text/plain", draftText(m.body, true))}${part("text/html", html)}--${boundary}--\r\n`));
}

export function draftLink(inbox: string, messageId: string): string {
  return `https://mail.google.com/mail/u/${inbox}/#drafts?compose=${messageId}`;
}
