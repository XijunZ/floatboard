import { describe, expect, it } from "vitest";
import { readPage } from "../src/parse";
import { scrubSample } from "../src/scrub";
import { docFrom, NOW, sampleHtml } from "./helpers";

const TIME_ONLY = /^(\s*(\d{1,2}:\d{2}(\s?[AP]M)?|\d{1,2}\/\d{1,2}\/\d{2,4}|Mon|Tue|Wed|Thu|Fri|Sat|Sun|Yesterday)\s*)+$/i;
const EMAIL = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi;

function textNodes(doc: Document): string[] {
  const out: string[] = [];
  const walker = doc.createTreeWalker(doc.documentElement, 4 /* SHOW_TEXT */);
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const t = (n.nodeValue ?? "").trim();
    if (t) out.push(t);
  }
  return out;
}

describe("scrubSample", () => {
  it("scrub_removes_all_personal_text", () => {
    const original = docFrom(sampleHtml());
    const before = original.documentElement.outerHTML;
    const html = scrubSample(original);
    // The live page is never changed.
    expect(original.documentElement.outerHTML).toBe(before);

    const scrubbed = docFrom(html);
    // Structure kept: same elements, same class names.
    expect(scrubbed.querySelectorAll("*").length).toBe(original.querySelectorAll("*").length);
    expect(scrubbed.querySelectorAll(".OZZZK").length).toBe(original.querySelectorAll(".OZZZK").length);

    // No original text node survives, except bare times and dates.
    const scrubbedText = new Set(textNodes(scrubbed));
    for (const t of textNodes(original)) {
      if (TIME_ONLY.test(t)) continue;
      expect(scrubbedText.has(t), `text survived: ${t}`).toBe(false);
    }
    // No original address, name or id survives anywhere (text or attributes).
    const originalEmails = new Set(before.match(EMAIL) ?? []);
    expect(originalEmails.size).toBeGreaterThan(0);
    for (const e of originalEmails) expect(html).not.toContain(e);
    for (const secret of ["Juniper", "Quill", "Casey", "Marisol", "AAQkAGI2TG93AAAQAJ4kZ1pQ0001", "Budget"]) {
      expect(html).not.toContain(secret);
    }

    // Still a useful sample: it parses the same shape (same unread count, times kept, addresses as placeholders).
    const a = readPage(original, NOW);
    const b = readPage(scrubbed, NOW);
    expect(a.kind).toBe("inbox");
    expect(b.kind).toBe("inbox");
    if (a.kind !== "inbox" || b.kind !== "inbox") return;
    expect(b.rows.length).toBe(a.rows.length);
    expect(b.rows.map((r) => r.received)).toEqual(a.rows.map((r) => r.received));
    expect(b.mailbox).toMatch(EMAIL);
    expect(new Set(b.rows.map((r) => r.rowId)).size).toBe(b.rows.length);
  });
  it("scrub_keeps_svg_geometry", () => {
    // Icons hold no personal data; replacing their shape attributes made Chrome log "Expected moveto path command".
    const html = `<html><body><svg viewBox="0 0 20 20" aria-label="Casey Reader"><title>Casey Reader</title>
      <defs><linearGradient id="g1" x1="0" x2="1" y1="0" y2="1"><stop offset="0.5" stop-color="#fff"/></linearGradient></defs>
      <path d="M10 2a8 8 0 1 0 0 16" fill="url(#g1)" transform="rotate(45)"/><circle cx="5" cy="5" r="2"/></svg></body></html>`;
    const doc = docFrom(scrubSample(docFrom(html)));
    expect(doc.querySelector("svg")!.getAttribute("viewBox")).toBe("0 0 20 20");
    expect(doc.querySelector("path")!.getAttribute("d")).toBe("M10 2a8 8 0 1 0 0 16");
    expect(doc.querySelector("path")!.getAttribute("transform")).toBe("rotate(45)");
    const g = doc.querySelector("linearGradient")!;
    expect([g.getAttribute("x1"), g.getAttribute("x2"), g.getAttribute("y1"), g.getAttribute("y2")]).toEqual(["0", "1", "0", "1"]);
    expect(doc.querySelector("stop")!.getAttribute("offset")).toBe("0.5");
    expect(doc.querySelector("circle")!.getAttribute("r")).toBe("2");
    // Names on an icon are still scrubbed.
    expect(doc.documentElement.outerHTML).not.toContain("Casey");
  });
});
