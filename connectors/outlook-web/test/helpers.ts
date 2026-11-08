import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

export const INBOX_URL = "https://outlook.office.com/mail/inbox";
// Sunday 8 November 2026, 12:00 in the test zone (Asia/Tokyo, UTC+9).
export const NOW = new Date("2026-11-08T03:00:00Z");

export function sampleHtml(name = "guess-inbox.html"): string {
  return readFileSync(new URL(`./samples/${name}`, import.meta.url), "utf8");
}

export function docFrom(html: string, url = INBOX_URL): Document {
  return new JSDOM(html, { url }).window.document;
}
