import { describe, it, expect } from "vitest";
import { call, newUser } from "./helpers";
import { pairPhone } from "./app-helpers";
import { parseCards } from "../src/app/board";

/** Every link on a task reaches the phone: `links: [{ kind, url, label? }]` on each pushed card. */
const card = (id: number, over: Record<string, unknown> = {}) => ({ id, title: `Task ${id}`, group: "Work", color: "#aabbcc", importance: 1,
  due: null, has_time: false, status: "todo", link: "https://mail.google.com/mail/u/0/#all/abc", done_at: null, ...over });
const links = [
  { kind: "email", url: "https://mail.google.com/mail/u/0/#all/abc" },
  { kind: "meeting", url: "https://acme.zoom.us/j/123" },
  { kind: "link", url: "https://calendar.google.com/event?eid=1", label: "calendar" },
  { kind: "link", url: "https://docs.example.com/plan" },
];
const put = (key: string, body: unknown) => call("/v2/board", { method: "PUT", key, body: JSON.stringify(body) });

describe("phone links", () => {
  it("links_are_stored_and_returned_to_the_phone", async () => {
    const u = await newUser("Links user");
    const { cookie } = await pairPhone(u.key);
    expect((await put(u.key, { cards: [card(1, { links }), card(2, { link: null })] })).status).toBe(200);
    const b = await (await call("/app/api/board", { headers: { Cookie: cookie } })).json<any>();
    expect(b.cards.find((c: any) => c.id === 1).links).toEqual(links);
    expect(b.cards.find((c: any) => c.id === 2).links).toBeUndefined(); // an older Mac sends none: the phone uses `link`
  });

  it("links_are_optional_and_may_be_empty", () => {
    expect(parseCards({ cards: [card(1)] })[0].links).toBeUndefined();
    expect(parseCards({ cards: [card(1, { links: [] })] })[0].links).toEqual([]);
  });

  it("bad_links_are_refused_with_400", async () => {
    const u = await newUser("Bad links");
    const bad: unknown[] = [
      "x", {}, [1], [null],
      [{ kind: "link", url: "javascript:alert(1)" }],
      [{ kind: "link", url: "file:///etc/passwd" }],
      [{ kind: "link", url: "not a url" }],
      [{ kind: "link", url: "https://example.com/" + "x".repeat(2000) }],
      [{ kind: "phone", url: "https://example.com" }],
      [{ kind: "link" }],
      [{ url: "https://example.com" }],
      [{ kind: "link", url: "https://example.com", label: "other" }],
      [{ kind: "link", url: "https://example.com", extra: 1 }],
      Array.from({ length: 7 }, (_, i) => ({ kind: "link", url: `https://example.com/${i}` })),
    ];
    for (const l of bad) {
      const r = await put(u.key, { cards: [card(1, { links: l })] });
      expect(r.status, JSON.stringify(l).slice(0, 80)).toBe(400);
    }
    expect(() => parseCards({ cards: [card(1, { links: [{ kind: "link", url: "javascript:alert(1)" }] })] })).toThrow(/cards\[0\]\.links\[0\]/);
  });
});
