import { describe, expect, it } from "vitest";
import { readPage } from "../src/parse";
import { docFrom, NOW, sampleHtml } from "./helpers";

// A scrubbed sample of a real Outlook on the web inbox (outlook.cloud.microsoft, November 2026).
const REAL = "outlook-sample-2026-11-08.html";
const REAL_URL = "https://outlook.cloud.microsoft/mail/";

describe("real Outlook sample", () => {
  it("parses_unread_rows_from_sample", () => {
    const read = readPage(docFrom(sampleHtml(REAL), REAL_URL), NOW);
    expect(read.kind).toBe("inbox");
    if (read.kind !== "inbox") return;
    expect(read.mailbox).toBe("person1@example.invalid");
    expect(read.rows).toHaveLength(6);
    for (const r of read.rows) {
      expect(r.unread).toBe(true);
      expect(r.rowId).not.toBe("");
      expect(r.fromName).not.toBe("");
      expect(r.fromAddr).toMatch(/@example\.invalid$/);
      expect(r.subject).not.toBe("");
      expect(r.preview).not.toBe("");
      expect(r.received).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
    }
    // Newest first, as the inbox shows them.
    const times = read.rows.map((r) => r.received);
    expect([...times].sort().reverse()).toEqual(times);
  });
});
