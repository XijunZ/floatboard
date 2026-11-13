import type Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import { askStructured } from "./llm";
import { describe } from "./learn";
import type { Message } from "./sources/types";
import { zonedParts, zoneOrDefault } from "./time";

export type Action = {
  title: string; why: string; due: string | null; hasTime: boolean;
  importance: 0 | 1 | 2; group: string | null; urgent: boolean;
  /** Links from the email the task needs (only ones that really appear in it), at most 3. */
  links?: string[];
};

/** `action: null` = Claude read the email and it needs no action; `ok: false` = we couldn't read Claude's answer (retry). */
export type ClassifyResult = { ok: true; action: Action | null } | { ok: false; reason: "refusal" | "unparseable" };

export type FeedbackExample = { subject: string; sender: string; verdict: "not_action" | "wrong_details" | "changed" | "missed_action"; detail?: string | null };

const Verdict = z.object({
  action_required: z.boolean(),
  title: z.string(),
  why: z.string(),
  due: z.string().nullable(),
  has_time: z.boolean(),
  importance: z.number().int(),
  group: z.string().nullable(),
  urgent: z.boolean(),
  links: z.array(z.string()).optional(),
});

import SKILL_TEXT from "./skills/email-triage.md";
import CHAT_SKILL_TEXT from "./skills/chat-triage.md";

/** The shared email-triage skill (src/skills/email-triage.md): how to judge any email, for every user. */
export const SKILL: string = SKILL_TEXT;

/** The skill's rules, one per bullet — listed on the setup page exactly as Claude gets them. */
export const RULES: string[] = SKILL.split("\n").filter((l) => l.startsWith("- ")).map((l) => l.slice(2).trim());

/** Checks done before Claude sees anything (no cost). Listed on the setup page alongside RULES. */
export const PRE_RULES: string[] = [
  "Only unread emails are read (when \"Only unread emails\" is on).",
  "Only your Primary tab is read (as Gmail shows it). Newsletters with an unsubscribe link and automated senders are skipped, except messages from a person (e.g. \"… via LinkedIn\") and security or fraud alerts. Your include list always gets through.",
  "In a conversation, only the newest message is judged, together with your latest reply.",
  "Outlook emails (from the Chrome extension) are judged from the preview Outlook shows in the list, not the whole email.",
  "Meeting-note emails (Fathom, Gemini) are summarised onto the matching meeting task instead of becoming tasks.",
  "Critical = urgent, or due within your alert window; anything overdue by more than a day doesn't alert.",
];

const SYSTEM = `${SKILL.trim()}

## Output
If action_required: title and why as above; due as "YYYY-MM-DD" or "YYYY-MM-DDTHH:mm" (24h) or null; has_time true only when a
time is given; importance 2 = high, 1 = normal, 0 = low; group exactly as one of the person's group names, or null;
links: up to 3 web addresses from the email that the person needs to do the task (a form, document, booking, payment or
sign-up page), copied exactly; [] when none. Never unsubscribe, tracking, logo, social-profile or plain homepage links.
If not an action, set action_required false and leave the other fields empty/neutral.`;

/** The shared chat rulebook (src/skills/chat-triage.md): how to judge one chat's unread messages. */
export const CHAT_SKILL: string = CHAT_SKILL_TEXT;
export const CHAT_RULES: string[] = CHAT_SKILL.split("\n").filter((l) => l.startsWith("- ")).map((l) => l.slice(2).trim());

const CHAT_SYSTEM = `${CHAT_SKILL.trim()}

## Output
If action_required: title and why as above; due as "YYYY-MM-DD" or "YYYY-MM-DDTHH:mm" (24h) or null; has_time true only when a
time is given; importance 2 = high, 1 = normal, 0 = low; group exactly as one of the person's group names, or null;
links: []. If not an action, set action_required false and leave the other fields empty/neutral.`;

/** Put before the text of an email the source only shows in part (Outlook's list preview). */
export const PREVIEW_NOTE = "(This is the preview Outlook shows, not the full email.)";

/** `timeZone`: the user's IANA zone; relative dates and times in the email are read in it. */
export type ClassifyContext = { groupNotes?: Record<string, string>; myRules?: string; inbox?: string; learned?: string; timeZone?: string;
  /** Chats only: the person's own chat rules, and their name (to spot messages addressed to them in groups). */
  chatRules?: string; userName?: string };

export async function classify(
  m: Message, me: string[], examples: FeedbackExample[], client: Anthropic, groups: string[] = [], ctx: ClassifyContext = {},
): Promise<ClassifyResult> {
  const lessons = examples.length
    ? "\n\nRecent corrections from this person (follow them):\n" + examples.map((e) => `- "${e.subject}" from ${e.sender}: ${describe(e)}`).join("\n")
    : "";
  const learned = ctx.learned?.trim() ? `\n\nThis person's learned preferences (from their past corrections):\n${ctx.learned.trim()}` : "";
  const groupList = groups.length
    ? groups.map((g) => `- ${g}${ctx.groupNotes?.[g] ? `: ${ctx.groupNotes[g]}` : ""}`).join("\n") : "(none given)";
  const mine = ctx.myRules?.trim() ? `\n\nThe user's own rules (these override the general rules):\n${ctx.myRules.trim()}` : "";
  const zone = zoneOrDefault(ctx.timeZone);
  const user = `User's addresses: ${me.join(", ")}
User's groups:
${groupList}
Now (${zone}): ${nowIn(zone)}${mine}${learned}${lessons}
${ctx.inbox ? `Received in: ${ctx.inbox}\n` : ""}
From: ${m.from}
To: ${m.to.join(", ")}${m.cc.length ? `\nCc: ${m.cc.join(", ")}` : ""}
Date: ${m.date}
Subject: ${m.subject}

${m.preview ? `${PREVIEW_NOTE}\n` : ""}${m.text}${linkList(m)}${m.thread?.myReply ? `

--- The user already replied after this email (${m.thread.myReply.date}): ---
${m.thread.myReply.text}` : ""}`;
  const chatUser = m.chat ? `${ctx.userName?.trim() ? `The person: ${ctx.userName.trim()}\n` : ""}User's groups:
${groupList}
Now (${zone}): ${nowIn(zone)}${mine}${ctx.chatRules?.trim() ? `\n\nThe person's own chat rules (these override the rulebook):\n${ctx.chatRules.trim()}` : ""}${learned}${lessons}

App: ${m.chat.app}
Chat: ${m.chat.name} (${m.chat.group ? "group chat" : "one-to-one chat"})
Unread messages, oldest first (lines marked "earlier" were already read and are only context):
${m.text}` : "";
  const r = await askStructured(client, { system: m.chat ? CHAT_SYSTEM : SYSTEM, user: m.chat ? chatUser : user, schema: Verdict });
  if (!r.ok) return r;
  const v = r.value;
  if (!v.action_required || !v.title.trim()) return { ok: true, action: null };
  const importance = (Math.min(2, Math.max(0, v.importance)) as 0 | 1 | 2);
  return { ok: true, action: { title: shortTitle(v.title), why: v.why.trim(), due: v.due, hasTime: v.has_time,
    importance, group: v.group && groups.includes(v.group) ? v.group : null, urgent: v.urgent, links: m.chat ? [] : realLinks(v.links ?? [], m) } };
}

const UNWANTED_LINK = /unsubscribe|optout|opt-out|preferences|list-manage/i;

/** The email's HTML-only links, shown to Claude after the text (unsubscribe and similar left out). */
function linkList(m: Message): string {
  const ls = (m.links ?? []).filter((l) => !UNWANTED_LINK.test(l) && !m.text.includes(l)).slice(0, 30);
  return ls.length ? `\n\nLinks in the email:\n${ls.map((l) => `- ${l}`).join("\n")}` : "";
}

/** Only links that really appear in the email (text or HTML), never invented ones; at most 3. */
export function realLinks(picked: string[], m: Message): string[] {
  const known = new Set(m.links ?? []);
  const out: string[] = [];
  for (const raw of picked) {
    const l = raw.trim().replace(/[).,;:!?>\]]+$/, "");
    if (!/^https?:\/\//i.test(l) || UNWANTED_LINK.test(l) || out.includes(l)) continue;
    if (known.has(l) || m.text.includes(l)) out.push(l);
    if (out.length === 3) break;
  }
  return out;
}

/** Keep titles to ~80 characters, cutting at a word boundary (never mid-word). */
export function shortTitle(t: string, max = 80): string {
  const s = t.trim().replace(/\s+/g, " ");
  if (s.length <= max) return s;
  const cut = s.slice(0, max - 1);
  const at = cut.lastIndexOf(" ");
  return (at > max * 0.5 ? cut.slice(0, at) : cut).replace(/[\s,;:.-]+$/, "") + "…";
}

/** "Saturday 2026-11-07 20:41" in `zone`. */
export function nowIn(zone: string, d = new Date()): string {
  const p = zonedParts(d, zone);
  return `${p.weekday} ${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}`;
}
