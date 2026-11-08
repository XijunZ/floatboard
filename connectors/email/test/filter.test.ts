import { describe, it, expect } from "vitest";
import { prefilter, senderAddress, DEFAULT_RECAP_SENDERS } from "../src/filter";
import type { Message } from "../src/sources/types";

const m = (over: Partial<Message> = {}): Message => ({
  messageId: "<1@x>", sourceId: "s", from: "Anna Smith <anna@acme.com>", to: ["me@gmail.com"], cc: [],
  subject: "Can you review?", date: "", labels: ["INBOX", "CATEGORY_PERSONAL"], headers: {}, text: "please review", link: "", ...over,
});
const rules = { ignore: [] as string[], allow: [] as string[], recapSenders: DEFAULT_RECAP_SENDERS };

describe("prefilter", () => {
  it.each([
    ["personal email is classified", m(), "classify"],
    ["promotions dropped", m({ labels: ["CATEGORY_PROMOTIONS"] }), "drop"],
    ["social dropped", m({ labels: ["CATEGORY_SOCIAL"] }), "drop"],
    // Gmail shows "Updates" mail in the Primary tab for many accounts; the Gmail query already limits to Primary.
    ["updates in primary is classified", m({ labels: ["CATEGORY_UPDATES"] }), "classify"],
    ["updates newsletter still dropped", m({ labels: ["CATEGORY_UPDATES"], headers: { "list-unsubscribe": "<mailto:u@x>" } }), "drop"],
    ["person via linkedin is classified", m({ from: "Joe Bloggs via LinkedIn <messaging-digest-noreply@linkedin.com>",
      labels: ["CATEGORY_UPDATES"], headers: { "list-unsubscribe": "<https://linkedin.com/u>" } }), "classify"],
    ["linkedin notifications dropped", m({ from: "LinkedIn <notifications-noreply@linkedin.com>", headers: { "list-unsubscribe": "<x>" } }), "drop"],
    ["security alert from noreply is classified", m({ from: "Example ID <no-reply@id.example.com>", subject: "Your account password has been reset" }), "classify"],
    ["fraud alert with unsubscribe is classified", m({ from: "alerts@welcome.examplebank.com",
      subject: "Fraud alert: please verify a recent transaction", headers: { "list-unsubscribe": "<x>" } }), "classify"],
    ["security alert in promotions still dropped", m({ from: "Google <no-reply@accounts.google.com>", subject: "Security alert", labels: ["CATEGORY_PROMOTIONS"] }), "drop"],
    ["forums dropped", m({ labels: ["CATEGORY_FORUMS"] }), "drop"],
    ["list-unsubscribe dropped", m({ headers: { "list-unsubscribe": "<mailto:u@x>" } }), "drop"],
    ["noreply dropped", m({ from: "Shop <no-reply@shop.com>" }), "drop"],
    ["notifications dropped", m({ from: "notifications@github.com" }), "drop"],
    ["newsletter dropped", m({ from: "Weekly <newsletter@news.com>" }), "drop"],
    ["fathom recap", m({ from: "Fathom <no-reply@fathom.video>", labels: ["CATEGORY_UPDATES"] }), "recap"],
    ["gemini recap", m({ from: "Gemini <gemini-notes@google.com>" }), "recap"],
    ["google Notes: subject recap", m({ from: "Google Meet <meetings-noreply@google.com>", subject: "Notes: Weekly planning" }), "recap"],
  ])("%s", (_name, msg, want) => {
    expect(prefilter(msg as Message, rules)).toBe(want);
  });

  it("ignore_list_drops", () => {
    expect(prefilter(m(), { ...rules, ignore: ["anna@acme.com"] })).toBe("drop");
  });

  it("ignore_list_matches_domain", () => {
    expect(prefilter(m(), { ...rules, ignore: ["@acme.com"] })).toBe("drop");
  });

  it("allow_beats_promotions", () => {
    expect(prefilter(m({ labels: ["CATEGORY_PROMOTIONS"], headers: { "list-unsubscribe": "x" } }), { ...rules, allow: ["anna@acme.com"] }))
      .toBe("classify");
  });

  it("recap_beats_noreply", () => {
    expect(prefilter(m({ from: "no-reply@fathom.video" }), rules)).toBe("recap");
  });

  it("sender_address_parsing", () => {
    expect(senderAddress("Anna Smith <Anna@Acme.com>")).toBe("anna@acme.com");
    expect(senderAddress("bob@x.com")).toBe("bob@x.com");
  });
});
