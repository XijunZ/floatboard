import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { addItem, call, newUser, signIn } from "./helpers";
import { encrypt } from "../src/crypto";
import { ARCHIVE_MAX_ROWS, archiveText, canonLine, dbSizeBytes, sha256Hex } from "../src/archive";
import { dashboardPage } from "../src/setup/page";

// Database size and "Archive old data to this Mac" (docs/phone-app.md, last section).

const DAY = 86400_000;
const iso = (ms: number) => new Date(ms).toISOString();
const ago = (days: number) => iso(Date.now() - days * DAY);

const getPage = (key: string, before: string, cursor?: string | null) =>
  call(`/v2/archive?before=${encodeURIComponent(before)}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`, { key });
const confirm = (key: string, body: unknown) => call("/v2/archive/confirm", { method: "POST", key, body: JSON.stringify(body) });

/** Every row of one archive run, page by page, as the Mac collects them. */
async function collect(key: string, before: string) {
  const all: { table: "board_log" | "items"; row: any }[] = [];
  let cursor: string | null = null, pages = 0;
  do {
    const r = await getPage(key, before, cursor);
    expect(r.status).toBe(200);
    const b = await r.json<any>();
    for (const row of b.rows.board_log) all.push({ table: "board_log", row });
    for (const row of b.rows.items) all.push({ table: "items", row });
    cursor = b.cursor;
    pages++;
  } while (cursor && pages < 50);
  return { all, pages };
}

/** What the Mac sends to confirm a run: counts and the sha256 of the canonical lines, computed here on our side. */
async function proof(before: string, all: { table: "board_log" | "items"; row: any }[]) {
  const text = all.map((x) => canonLine(x.table, x.row) + "\n").join("");
  return { before, counts: { board_log: all.filter((x) => x.table === "board_log").length, items: all.filter((x) => x.table === "items").length },
    sha256: await sha256Hex(text) };
}

async function logRow(userId: string, receivedAt: string, over: Record<string, unknown> = {}) {
  const r = { id: crypto.randomUUID(), device: "mac", card_id: 1, kind: "status", value: "done", made_at: receivedAt, client_id: null, ...over };
  await env.DB.prepare("INSERT INTO board_log(id,user_id,device,card_id,kind,value,made_at,received_at,client_id) VALUES(?,?,?,?,?,?,?,?,?)")
    .bind(r.id, userId, r.device, r.card_id, r.kind, r.value, r.made_at, receivedAt, r.client_id).run();
  return r;
}

const n = async (sql: string, ...args: unknown[]) => (await env.DB.prepare(sql).bind(...args).first<{ n: number }>())!.n;

describe("database size", () => {
  it("size_is_read_from_d1_and_is_a_positive_number", async () => {
    const s = await dbSizeBytes(env as any);
    expect(typeof s).toBe("number");
    expect(s!).toBeGreaterThan(0);
  });

  it("status_carries_db_size_bytes_as_a_number_only", async () => {
    const u = await newUser("Size");
    const b = await (await call("/v2/status", { key: u.key })).json<any>();
    expect(typeof b.db_size_bytes).toBe("number");
    expect(b.db_size_bytes).toBeGreaterThan(0);
  });

  it("setup_page_shows_the_size_and_warns_above_250_mb", async () => {
    const base = { name: "X", csrf: "c", origin: "https://e", connectLink: null, googleClientId: null, gmail: [], hasClaudeKey: true,
      telegramLinked: false, fathomURL: null };
    const small = dashboardPage({ ...base, dbSizeBytes: 1_400_000 });
    expect(small).toContain("Database: 1.4 MB of 500 MB");
    expect(small).not.toContain("Archive old data to this Mac");
    const big = dashboardPage({ ...base, dbSizeBytes: 260_000_000 });
    expect(big).toContain("Database: 260.0 MB of 500 MB");
    expect(big).toContain("Archive old data to this Mac");
    expect(big).not.toContain("—");
    const unknown = dashboardPage({ ...base, dbSizeBytes: null });
    expect(unknown).toContain("Database: size not available");
    // and the live page shows it
    const u = await newUser("Size page");
    const { page } = await signIn(u.key);
    expect(page).toMatch(/Database: \d+\.\d MB of 500 MB/);
  });
});

describe("archive: canonical form", () => {
  it("canonical_lines_match_the_documented_golden_hash", async () => {
    // Same rows and hash as the Mac check archive_canonical_lines_match_the_engine (FloatBoardChecks).
    const text = canonLine("board_log", { id: "a1", device: "mac", card_id: 7, kind: "add",
      value: "Quote \" back\\ slash / tab\t nl\n ctl\u0001 del\u007f 任务 😀  ", made_at: "2026-01-01T00:00:00.000Z",
      received_at: "2026-01-01T00:00:01.000Z", client_id: null }) + "\n"
      + canonLine("items", { id: "i1", importance: -2, title: "Ünïcode é", link: null, has_time: 0 }) + "\n";
    expect(text.split("\n")[1]).toBe('{"row":{"has_time":0,"id":"i1","importance":-2,"link":null,"title":"Ünïcode é"},"table":"items"}');
    expect(await sha256Hex(text)).toBe("9d19ea473cc84d0959011f59a837c17bd02e9724cf1049f3fc52117870682f80");
    expect(archiveText([{ table: "items", row: { b: 1, a: "x" } }])).toBe('{"row":{"a":"x","b":1},"table":"items"}\n');
  });
});

describe("archive: what is returned", () => {
  it("before_must_be_an_iso_time_at_least_30_days_ago", async () => {
    const u = await newUser("Arch before");
    expect((await call("/v2/archive", { key: u.key })).status).toBe(400);
    expect((await getPage(u.key, "yesterday")).status).toBe(400);
    expect((await getPage(u.key, ago(10))).status).toBe(400);
    expect((await getPage(u.key, ago(31))).status).toBe(200);
    expect((await getPage(u.key, ago(31), "garbage")).status).toBe(400);
    expect((await call("/v2/archive?before=" + ago(40))).status).toBe(401); // user key needed
  });

  it("returns_only_this_users_old_rows_never_another_users", async () => {
    const a = await newUser("Arch A"), b = await newUser("Arch B");
    const oldA = await logRow(a.id, ago(200));
    await logRow(a.id, ago(5)); // too new
    const oldB = await logRow(b.id, ago(200));
    const itemA = await addItem(a.id, { created: ago(200) });
    const itemB = await addItem(b.id, { created: ago(200) });
    const { all } = await collect(a.key, ago(100));
    expect(all.map((x) => x.row.id).sort()).toEqual([oldA.id, itemA.id].sort());
    expect(JSON.stringify(all)).not.toContain(oldB.id);
    expect(JSON.stringify(all)).not.toContain(itemB.id);
    expect(all.every((x) => !("user_id" in x.row))).toBe(true);
  });

  it("items_newer_than_90_days_are_never_returned", async () => {
    const u = await newUser("Arch 90");
    const old = await addItem(u.id, { created: ago(120) });
    const recent = await addItem(u.id, { created: ago(60) });
    const log = await logRow(u.id, ago(60));
    // A cut-off 40 days ago: board log rows older than it, but no items at all (the cut-off is newer than 90 days).
    const r40 = await collect(u.key, ago(40));
    expect(r40.all.map((x) => x.row.id)).toEqual([log.id]);
    // A cut-off 100 days ago: only the 120-day-old item.
    const r100 = await collect(u.key, ago(100));
    expect(r100.all.map((x) => x.row.id)).toEqual([old.id]);
    expect(JSON.stringify(r100.all)).not.toContain(recent.id);
  });

  it("open_tasks_on_the_board_are_kept_and_add_titles_come_back_readable", async () => {
    const u = await newUser("Arch open");
    const open = await addItem(u.id, { created: ago(200), link: "https://mail/open" });
    const doneItem = await addItem(u.id, { created: ago(200), link: "https://mail/done" });
    await call("/v2/board", { method: "PUT", key: u.key, body: JSON.stringify({ cards: [
      { id: 1, title: "Open", group: "Work", color: "#aabbcc", importance: 1, due: null, has_time: false, status: "todo", link: "https://mail/open", done_at: null },
      { id: 2, title: "Done", group: "Work", color: "#aabbcc", importance: 1, due: null, has_time: false, status: "done", link: "https://mail/done", done_at: ago(0) },
    ] }) });
    const add = await logRow(u.id, ago(200), { kind: "add", value: await encrypt(env as any, "Buy milk") });
    const { all } = await collect(u.key, ago(100));
    const ids = all.map((x) => x.row.id);
    expect(ids).toContain(doneItem.id);
    expect(ids).not.toContain(open.id);
    expect(all.find((x) => x.row.id === add.id)!.row.value).toBe("Buy milk");
  });

  it("pages_of_500_in_id_order_board_log_first_capped_per_run", async () => {
    const u = await newUser("Arch pages");
    const stmts = [];
    for (let i = 0; i < 1200; i++) {
      stmts.push(env.DB.prepare("INSERT INTO board_log(id,user_id,device,card_id,kind,value,made_at,received_at) VALUES(?,?,?,?,?,?,?,?)")
        .bind(`log-${String(i).padStart(5, "0")}`, u.id, "mac", i, "status", "done", ago(200), ago(200)));
    }
    for (let i = 0; i < 1000; i++) {
      stmts.push(env.DB.prepare("INSERT INTO items(id,user_id,message_id,kind,title,created) VALUES(?,?,?,?,?,?)")
        .bind(`item-${String(i).padStart(5, "0")}`, u.id, `<p${i}@x>`, "action", "T", ago(200)));
    }
    await env.DB.batch(stmts);
    const first = await (await getPage(u.key, ago(100))).json<any>();
    expect(first.rows.board_log).toHaveLength(500);
    expect(first.rows.items).toHaveLength(0);
    expect(typeof first.cursor).toBe("string");
    const { all, pages } = await collect(u.key, ago(100));
    expect(all).toHaveLength(ARCHIVE_MAX_ROWS);
    expect(pages).toBe(Math.ceil(ARCHIVE_MAX_ROWS / 500));
    const ids = all.map((x) => x.row.id);
    expect(ids.slice(0, 1200)).toEqual([...ids.slice(0, 1200)].sort());
    expect(all.slice(0, 1200).every((x) => x.table === "board_log")).toBe(true);
    expect(all[1200]).toMatchObject({ table: "items", row: { id: "item-00000" } });
    // A cursor from another cut-off is refused.
    expect((await getPage(u.key, ago(150), first.cursor)).status).toBe(400);
    // Confirm deletes this run; the next run returns the rest.
    expect((await confirm(u.key, await proof(ago(100), all))).status).toBe(200);
    const next = await collect(u.key, ago(100));
    expect(next.all).toHaveLength(2200 - ARCHIVE_MAX_ROWS);
  });
});

describe("archive: confirm", () => {
  it("deletes_exactly_the_returned_rows_and_keeps_tombstones", async () => {
    const a = await newUser("Conf A"), b = await newUser("Conf B");
    await logRow(a.id, ago(200)); await logRow(a.id, ago(200));
    const keep = await logRow(a.id, ago(5));
    const item = await addItem(a.id, { created: ago(200) });
    const recent = await addItem(a.id, { created: ago(10) });
    await logRow(b.id, ago(200));
    const itemB = await addItem(b.id, { created: ago(200) });
    const before = ago(100);
    const { all } = await collect(a.key, before);
    expect(all).toHaveLength(3);
    const r = await confirm(a.key, await proof(before, all));
    expect(r.status).toBe(200);
    expect(await r.json()).toMatchObject({ ok: true, deleted: { board_log: 2, items: 1 } });
    expect(await n("SELECT COUNT(*) n FROM board_log WHERE user_id=?", a.id)).toBe(1);
    expect(await n("SELECT COUNT(*) n FROM board_log WHERE id=?", keep.id)).toBe(1);
    expect(await n("SELECT COUNT(*) n FROM items WHERE id=?", item.id)).toBe(0);
    expect(await n("SELECT COUNT(*) n FROM items WHERE id=?", recent.id)).toBe(1);
    expect(await n("SELECT COUNT(*) n FROM archived_items WHERE user_id=? AND message_id=?", a.id, item.message_id)).toBe(1);
    // The other user's rows are untouched.
    expect(await n("SELECT COUNT(*) n FROM board_log WHERE user_id=?", b.id)).toBe(1);
    expect(await n("SELECT COUNT(*) n FROM items WHERE id=?", itemB.id)).toBe(1);
  });

  it("count_or_hash_mismatch_deletes_nothing", async () => {
    const u = await newUser("Conf mismatch");
    await logRow(u.id, ago(200));
    await addItem(u.id, { created: ago(200) });
    const before = ago(100);
    const { all } = await collect(u.key, before);
    const good = await proof(before, all);
    const before0 = { log: await n("SELECT COUNT(*) n FROM board_log WHERE user_id=?", u.id), items: await n("SELECT COUNT(*) n FROM items WHERE user_id=?", u.id) };
    expect((await confirm(u.key, { ...good, counts: { board_log: 2, items: 1 } })).status).toBe(409);
    expect((await confirm(u.key, { ...good, sha256: "0".repeat(64) })).status).toBe(409);
    // A row changed after the Mac read it: the hash no longer matches.
    await env.DB.prepare("UPDATE items SET title='changed' WHERE user_id=?").bind(u.id).run();
    expect((await confirm(u.key, good)).status).toBe(409);
    expect(await n("SELECT COUNT(*) n FROM board_log WHERE user_id=?", u.id)).toBe(before0.log);
    expect(await n("SELECT COUNT(*) n FROM items WHERE user_id=?", u.id)).toBe(before0.items);
    expect(await n("SELECT COUNT(*) n FROM archived_items WHERE user_id=?", u.id)).toBe(0);
    // Malformed confirms are refused.
    expect((await confirm(u.key, { before, counts: { board_log: 1 }, sha256: good.sha256 })).status).toBe(400);
    expect((await confirm(u.key, { ...good, sha256: "XYZ" })).status).toBe(400);
    expect((await confirm(u.key, { ...good, before: ago(1) })).status).toBe(400);
  });

  it("another_users_key_cannot_confirm_this_users_rows", async () => {
    const a = await newUser("Conf owner"), b = await newUser("Conf other");
    await logRow(a.id, ago(200));
    const before = ago(100);
    const { all } = await collect(a.key, before);
    // B sends A's proof: B's own set is empty, so it does not match and nothing of A's is touched.
    expect((await confirm(b.key, await proof(before, all))).status).toBe(409);
    expect(await n("SELECT COUNT(*) n FROM board_log WHERE user_id=?", a.id)).toBe(1);
  });
});

describe("archive: the same email never becomes a task twice", () => {
  it("an_archived_email_read_again_creates_no_new_task", async () => {
    const { runUser } = await import("../src/run");
    const { HAIKU } = await import("../src/llm");
    const u = await newUser("Arch triage");
    await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env as any, "sk-test"), u.id).run();
    const sid = crypto.randomUUID();
    await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,enabled,created) VALUES(?,?,'gmail','me@gmail.com',1,?)").bind(sid, u.id, iso(Date.now())).run();
    const msg = { messageId: "<old-ask@x>", sourceId: sid, from: "Anna <anna@acme.com>", to: ["me@gmail.com"], cc: [], subject: "Old ask",
      date: "", labels: ["UNREAD"], headers: {}, text: "Please do the thing", link: "https://mail/old" };
    const source = { async fetchBatch() { return { messages: [msg], cursor: "1", done: true }; } };
    let claudeCalls = 0;
    const fetchFn = (async () => {
      claudeCalls++;
      return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
        content: [{ type: "text", text: JSON.stringify({ action_required: true, title: "Handle old ask", why: "asked", due: null,
          has_time: false, importance: 1, group: null, urgent: false }) }], usage: { input_tokens: 1, output_tokens: 1 } });
    }) as typeof fetch;
    await runUser(env as any, u.id, { sourceFor: () => source as any, fetchFn });
    expect(await n("SELECT COUNT(*) n FROM items WHERE user_id=? AND kind='action'", u.id)).toBe(1);
    // The task is old, then archived to the Mac.
    await env.DB.prepare("UPDATE items SET created=? WHERE user_id=?").bind(ago(200), u.id).run();
    const before = ago(100);
    const { all } = await collect(u.key, before);
    expect((await confirm(u.key, await proof(before, all))).status).toBe(200);
    expect(await n("SELECT COUNT(*) n FROM items WHERE user_id=?", u.id)).toBe(0);
    // The engine forgets it read the email (as a Re-check does) and reads it again: no new task, no Claude call.
    await env.DB.prepare("DELETE FROM seen WHERE user_id=?").bind(u.id).run();
    const calls = claudeCalls;
    await runUser(env as any, u.id, { sourceFor: () => source as any, fetchFn });
    expect(await n("SELECT COUNT(*) n FROM items WHERE user_id=?", u.id)).toBe(0);
    expect(claudeCalls).toBe(calls);
  });

  it("an_archived_meeting_recap_is_not_stored_again", async () => {
    const { recapKnown } = await import("../src/recap");
    const u = await newUser("Arch recap");
    await env.DB.prepare("INSERT INTO archived_items(user_id,message_id,archived_at) VALUES(?,?,?)").bind(u.id, "<meet@x>", iso(Date.now())).run();
    expect(await recapKnown(env as any, u.id, ["<meet@x>"])).toBe(true);
    expect(await recapKnown(env as any, u.id, ["<other@x>"])).toBe(false);
  });
});
