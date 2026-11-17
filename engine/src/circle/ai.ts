/**
 * Circle's on-request Haiku jobs (features §7): filling the add-contact form from header data, and drafting a message.
 * Neither keeps anything: the answer goes back to the caller; only token counts are metered (llm_usage).
 */
import { z } from "zod";
import type Anthropic from "@anthropic-ai/sdk";
import { askStructured } from "../lib/llm";
import { line } from "./common";

/** One header seen for the person: a display name, an address, a phone number. Nothing else is accepted. */
export type HeaderBits = { name: string; address: string; phone: string };

export function headerBits(v: unknown): HeaderBits[] {
  if (!Array.isArray(v)) return [];
  return v.slice(0, 20).map((h: any) => ({ name: line(h?.name, 120), address: line(h?.address, 200), phone: line(h?.phone, 30) }))
    .filter((h) => h.name || h.address || h.phone);
}

const Form = z.object({ name: z.string(), emails: z.array(z.string()), phones: z.array(z.string()), company: z.string() });
export type FormFill = z.infer<typeof Form>;

/** contact_form (low flag: the owner confirms the form). */
export async function fillContact(client: Anthropic, headers: HeaderBits[]): Promise<FormFill | null> {
  const r = await askStructured(client, {
    system: "You fill a contact form from message header data only (display names, email addresses, phone numbers). Give the person's " +
      "name as they would write it (\"SMITH, John\" becomes \"John Smith\"), their distinct email addresses and phone numbers as given, and " +
      "a company only when an email domain clearly names one (not gmail, outlook, icloud and the like); otherwise an empty string. Never guess.",
    user: JSON.stringify(headers), schema: Form, maxTokens: 400,
  });
  return r.ok ? r.value : null;
}

export type DraftInput = { owner: string; name: string; language: string; notes: string; howKnown: string; channel: string;
  messages: { direction: string; at: string; text: string }[] };

/** The Mac's or the phone's draft request, checked and trimmed (at most 5 messages of 1,000 characters). */
export function draftInput(b: any, owner: string): DraftInput | string {
  const name = line(b?.name, 120);
  if (!name) return "name is required";
  const messages = (Array.isArray(b?.messages) ? b.messages : []).slice(-5).map((m: any) => ({
    direction: m?.direction === "out" ? "out" : "in", at: line(m?.at, 40), text: typeof m?.text === "string" ? m.text.slice(0, 1000) : "",
  })).filter((m: { text: string }) => m.text.trim());
  return { owner: line(owner, 80), name, language: line(b?.language, 40), notes: typeof b?.notes === "string" ? b.notes.slice(0, 1500) : "",
    howKnown: line(b?.how_known, 200), channel: line(b?.channel, 20) || "whatsapp", messages };
}

const Draft = z.object({ draft: z.string() });

/** draft_message (low flag: never sent automatically). */
export async function draftMessage(client: Anthropic, d: DraftInput): Promise<string | null> {
  const r = await askStructured(client, {
    system: "You draft a short personal message for the owner of a contacts app to send to someone they know. Write as the owner, " +
      "in their usual tone as seen in their own recent messages (direction \"out\"), in the language of the recent messages, else " +
      "the person's language, else English. One to three sentences, no subject line, no signature. Never invent a reason, an event, " +
      "news or a shared memory that is not in the notes or the messages; when there is no reason, write a simple, warm check-in. " +
      "Answer with the message only.",
    user: JSON.stringify({ owner: d.owner, person: d.name, language: d.language, how_they_know_each_other: d.howKnown, notes: d.notes,
      channel: d.channel, recent_messages: d.messages }),
    schema: Draft, maxTokens: 400,
  });
  return r.ok ? r.value.draft.trim().slice(0, 2000) : null;
}
