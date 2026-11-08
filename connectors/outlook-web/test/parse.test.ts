import { describe, expect, it } from "vitest";
import { newRows, parseReceived, readPage, rowKey, type Row } from "../src/parse";
import { docFrom, INBOX_URL, NOW, sampleHtml } from "./helpers";

function inboxRows(): Row[] {
  const read = readPage(docFrom(sampleHtml()), NOW);
  if (read.kind !== "inbox") throw new Error(`expected inbox, got ${JSON.stringify(read)}`);
  return read.rows;
}

describe("readPage", () => {
  it("parses_unread_rows_from_sample", () => {
    const read = readPage(docFrom(sampleHtml()), NOW);
    expect(read.kind).toBe("inbox");
    if (read.kind !== "inbox") return;
    expect(read.mailbox).toBe("casey.reader@example.org");
    // The sample has 3 unread and 2 read rows: only the unread ones come back.
    expect(read.rows.map((r) => r.rowId)).toEqual([
      "AAQkAGI2TG93AAAQAJ4kZ1pQ0001",
      "AAQkAGI2TG93AAAQAJ4kZ1pQ0003",
      "AAQkAGI2TG93AAAQAJ4kZ1pQ0004",
    ]);
    for (const r of read.rows) {
      expect(r.unread).toBe(true);
      expect(r.fromName).not.toBe("");
      expect(r.subject).not.toBe("");
      expect(r.preview).not.toBe("");
      expect(r.received).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
    }
    expect(read.rows[0]).toEqual({
      rowId: "AAQkAGI2TG93AAAQAJ4kZ1pQ0001",
      fromName: "Juniper Quill",
      fromAddr: "juniper.quill@example.com",
      subject: "Budget sign-off needed by Friday",
      preview:
        "Hi Casey, could you approve the revised figures before the board pack goes out? The totals moved after the last review.",
      received: "2026-11-08T01:42:00.000Z",
      unread: true,
    });
    // Display name only when the page exposes no address.
    expect(read.rows[1].fromName).toBe("Facilities Desk");
    expect(read.rows[1].fromAddr).toBeUndefined();
  });

  it("received_time_parsed_to_iso", () => {
    expect(new Date(NOW).getTimezoneOffset()).toBe(-540); // the fixed test zone is in force
    // Today: a time of day.
    expect(parseReceived("10:42", NOW, "en-GB")).toBe("2026-11-08T01:42:00.000Z");
    expect(parseReceived("2:05 PM", NOW, "en-US")).toBe("2026-11-08T05:05:00.000Z");
    // This week: a weekday, read as the start of that day (the most recent past one).
    expect(parseReceived("Mon", NOW, "en-GB")).toBe("2026-11-01T15:00:00.000Z");
    expect(parseReceived("Sun", NOW, "en-GB")).toBe("2026-10-31T15:00:00.000Z");
    expect(parseReceived("Yesterday", NOW, "en-GB")).toBe("2026-11-06T15:00:00.000Z");
    // Older: a date, day first unless the page is US English.
    expect(parseReceived("03/11/2026", NOW, "en-GB")).toBe("2026-11-02T15:00:00.000Z");
    expect(parseReceived("11/03/2026", NOW, "en-US")).toBe("2026-11-02T15:00:00.000Z");
    // A full tooltip ("Sun 08/11/2026 10:42") gives the exact time.
    expect(parseReceived("Sun 08/11/2026 10:42", NOW, "en-GB")).toBe("2026-11-08T01:42:00.000Z");
    expect(parseReceived("not a time", NOW, "en-GB")).toBeUndefined();
  });

  it("rereading_same_rows_queues_nothing_new", () => {
    const first = inboxRows();
    const sent = new Set(first.map(rowKey));
    expect(newRows(first, sent)).toEqual([]);
    // Outlook re-rendered the list: a fresh read of the same page gives nothing new either.
    expect(newRows(inboxRows(), sent)).toEqual([]);

    // The next day Outlook shows yesterday's "10:42" as "Sun": still the same email.
    const precise: Row = { ...first[0], received: "2026-11-08T01:42:00.000Z" };
    const dayOnly: Row = { ...first[0], received: "2026-11-07T15:00:00.000Z" };
    expect(newRows([dayOnly], new Set([rowKey(precise)]))).toEqual([]);

    // A new message in the same conversation has a new received time: it is new.
    const reply: Row = { ...first[0], received: "2026-11-08T02:30:00.000Z" };
    expect(newRows([reply], new Set([rowKey(precise)]))).toEqual([reply]);
    expect(rowKey(precise)).toBe("owa:AAQkAGI2TG93AAAQAJ4kZ1pQ0001:2026-11-08T01:42:00.000Z");
  });

  it("non_inbox_pages_read_nothing", () => {
    const html = sampleHtml(); // even with a message list on screen
    for (const url of [
      "https://outlook.office.com/calendar/view/week",
      "https://outlook.office.com/mail/options/general/appearance",
      "https://outlook.office.com/mail/sentitems",
      "https://outlook.live.com/people/",
    ]) {
      expect(readPage(docFrom(html, url), NOW)).toEqual({ kind: "notInbox" });
    }
    // Inbox address but no message list: not recognised, with a reason, and no rows.
    const empty = readPage(docFrom("<html><body><div id='app'></div></body></html>", INBOX_URL), NOW);
    expect(empty.kind).toBe("unrecognised");
    expect(empty).toHaveProperty("reason");
    expect(empty).not.toHaveProperty("rows");
  });

  it("signed_out_page_detected", () => {
    const marketing = `<html><body><header><a href="https://login.live.com/login.srf?wa=wsignin1.0">Sign in</a></header>
      <main><h1>Outlook</h1></main></body></html>`;
    expect(readPage(docFrom(marketing, "https://outlook.live.com/owa/"), NOW)).toEqual({ kind: "signedOut" });
    const form = `<html><body><form><input type="email" name="loginfmt"><input type="submit" value="Next"></form></body></html>`;
    expect(readPage(docFrom(form, "https://outlook.office.com/mail/"), NOW)).toEqual({ kind: "signedOut" });
  });
});
