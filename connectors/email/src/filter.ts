import type { Message } from "./sources/types";

export type Route = "drop" | "classify" | "recap";

export const DEFAULT_RECAP_SENDERS = ["no-reply@fathom.video", "gemini-notes@google.com"];

// Not CATEGORY_UPDATES: Gmail shows much of it in the Primary tab, and the Gmail query already limits mail to Primary.
const BULK_LABELS = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"];
/** "Joe Bloggs via LinkedIn": a real person's message relayed by a service. */
const RELAYED_PERSON = /^\s*"?[^"<]+\svia\s(LinkedIn|Slack|Teams|Google Chat)"?\s*</i;
/** Account-security and fraud notices: worth Claude's look even from automated senders. */
const SECURITY = /\b(password (has been )?(reset|changed)|security alert|fraud|unusual (sign-in|activity)|suspicious|account (has been )?(locked|unlocked|suspended)|verify (a|your) (recent )?(transaction|payment))\b/i;
const AUTOMATED_LOCAL = /^(no-?reply|do-?not-?reply|notifications?|mailer-daemon|newsletters?|marketing)\b/i;

/** "Anna <Anna@Acme.com>" → "anna@acme.com". */
export function senderAddress(from: string): string {
  const m = /<([^>]+)>/.exec(from);
  return (m ? m[1] : from).trim().toLowerCase();
}

/** A rule entry matches the full address, or a domain when it starts with "@". */
const matches = (addr: string, list: string[]) =>
  list.some((r) => (r.startsWith("@") ? addr.endsWith(r.toLowerCase()) : addr === r.toLowerCase()));

/** Free, rule-based triage before any AI call. Order matters: allow → recap → ignore → bulk signals. */
export function prefilter(m: Message, rules: { ignore: string[]; allow: string[]; recapSenders: string[]; unreadOnly?: boolean }): Route {
  const addr = senderAddress(m.from);
  if (matches(addr, rules.allow)) return "classify";
  if (matches(addr, rules.recapSenders)) return "recap";
  if (/^notes:\s/i.test(m.subject) && addr.endsWith("@google.com")) return "recap";
  if (rules.unreadOnly && !m.labels.includes("UNREAD")) return "drop"; // already read: the user has seen it
  if (matches(addr, rules.ignore)) return "drop";
  if (m.labels.some((l) => BULK_LABELS.includes(l))) return "drop";
  if (RELAYED_PERSON.test(m.from) || SECURITY.test(m.subject)) return "classify";
  if (m.headers["list-unsubscribe"]) return "drop";
  if (AUTOMATED_LOCAL.test(addr.split("@")[0])) return "drop";
  return "classify";
}
