/**
 * What's new for the people the Mac lists (features §3 P11, §9): Companies House, news, blog posts. Hourly, at most weekly
 * per person and kind, within the call budget; results are encrypted and taken in by the Mac (`GET /v2/circle/updates`).
 *
 * - Companies House (needs the user's API key): without a confirmed officer id, a name search gives **candidates** (with
 *   birth month/year) that the owner confirms on the Mac; never linked here. With one, its appointments: the first read
 *   records current directorships; later reads add new appointments and resignations, as separate kinds.
 * - News (Google News RSS): the person (`"Name"` with their firm or company) and the firm (`"Firm"`) as separate searches and
 *   kinds; duplicates merged by title (person news wins). ⚑ `news_match` (Haiku, one batch per run) answers per headline
 *   whether it is about them; a "no" is set aside (`match: "unlikely"`), never dropped. Everything stays "possible" until
 *   the owner marks it on the Mac. Without a Claude key all news is "possible".
 * - Posts: the person's feed (RSS or Atom).
 */
import { z } from "zod";
import type { Env } from "../env";
import { nowISO } from "../env";
import type { Budget } from "../lib/budget";
import { decrypt } from "../lib/crypto";
import { askStructured } from "../lib/llm";
import { circleFetch } from "./net";
import { circleOn, haikuFor, line, seal, unseal } from "./common";

const DAY = 86400_000;
export const RECHECK_MS = 7 * DAY;
const CH = "https://api.company-information.service.gov.uk";
const NEWS_PER_SEARCH = 8;
const NEWS_MAX_AGE = 30 * DAY;
const MATCH_BATCH = 40;

export type WatchPerson = { person: string; name: string; firm: string; company: string; officer_id: string; born: string; feed_url: string; news: boolean; ch: boolean };
export type Update = { kind: string; title: string; detail: string; url: string; at: string | null; match: string; born?: string; officer?: string };

// ---------------------------------------------------------------- feeds

const decode = (s: string) => s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1").replace(/<[^>]+>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
  .replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&#(\d+);/g, (_m, n) => String.fromCharCode(Number(n))).replace(/&amp;/g, "&").trim();
const tag = (xml: string, name: string) => { const m = new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`, "i").exec(xml); return m ? decode(m[1]) : ""; };

/** RSS items or Atom entries: title, link, when, and the source's name (Google News). */
export function parseFeed(xml: string): { title: string; link: string; at: string | null; source: string }[] {
  const out: { title: string; link: string; at: string | null; source: string }[] = [];
  for (const m of xml.matchAll(/<(item|entry)(?:\s[^>]*)?>([\s\S]*?)<\/\1>/gi)) {
    const body = m[2];
    let link = tag(body, "link");
    if (!link) link = /<link[^>]*href="([^"]+)"/i.exec(body)?.[1] ?? "";
    const when = tag(body, "pubDate") || tag(body, "updated") || tag(body, "published");
    const t = Date.parse(when);
    const title = tag(body, "title");
    if (!title || !/^https?:\/\//.test(link)) continue;
    out.push({ title: title.slice(0, 300), link: link.slice(0, 2000), at: Number.isFinite(t) ? new Date(t).toISOString() : null, source: tag(body, "source").slice(0, 100) });
  }
  return out;
}

/** A headline without Google News' " - Source" ending. */
export function cleanTitle(t: string): string { return t.replace(/\s+[-–—]\s+[^-–—]{1,60}$/, "").trim(); }

/** Same story, same key: the headline without its source, in lower case, letters and digits only. */
export function newsTitleKey(t: string): string {
  return cleanTitle(t).toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

const titleCase = (s: string) => s.toLowerCase().replace(/\b\p{L}/gu, (c) => c.toUpperCase());

// ---------------------------------------------------------------- the run

type Pending = { person: WatchPerson; key: string; u: Update; needsMatch: boolean };

/** One pass over the watch list. Never throws; returns how many people were looked at and how many new things found. */
export async function runCircleUpdates(env: Env, userId: string, budget: Budget, opts: { now?: number; fetchFn?: typeof fetch } = {}): Promise<{ checked: number; found: number }> {
  try {
    if (!(await circleOn(env, userId))) return { checked: 0, found: 0 };
    const w = await env.DB.prepare("SELECT data_enc FROM circle_watch WHERE user_id=?").bind(userId).first<{ data_enc: string }>();
    if (!w) return { checked: 0, found: 0 };
    const people = await unseal<WatchPerson[]>(env, w.data_enc);
    const now = opts.now ?? Date.now();
    const f = budget.wrap(opts.fetchFn ?? circleFetch());
    const u = await env.DB.prepare("SELECT companies_house_key_enc FROM users WHERE id=?").bind(userId).first<{ companies_house_key_enc: string | null }>();
    const chKey = u?.companies_house_key_enc ? await decrypt(env, u.companies_house_key_enc) : null;
    const pending: Pending[] = [];
    let checked = 0;
    const due = async (person: string, kind: string) => {
      const r = await env.DB.prepare("SELECT checked_at FROM circle_checked WHERE user_id=? AND person=? AND kind=?").bind(userId, person, kind).first<{ checked_at: string }>();
      return !r || now - Date.parse(r.checked_at) >= RECHECK_MS;
    };
    const mark = (person: string, kind: string) => env.DB.prepare(`INSERT INTO circle_checked(user_id,person,kind,checked_at) VALUES(?,?,?,?)
        ON CONFLICT(user_id,person,kind) DO UPDATE SET checked_at=excluded.checked_at`).bind(userId, person, kind, new Date(now).toISOString()).run();
    for (const p of people) {
      if (budget.remaining < 4) break;
      let looked = false;
      try {
        if (p.news && await due(p.person, "news")) {
          looked = true;
          const seen = new Set<string>();
          const firm = p.firm || p.company;
          const searches: [string, string][] = [["news_person", `"${p.name}"${firm ? ` "${firm}"` : ""}`]];
          if (firm) searches.push(["news_firm", `"${firm}"`]);
          for (const [kind, q] of searches) {
            const r = await f(`https://news.google.com/rss/search?${new URLSearchParams({ q, hl: "en-GB", gl: "GB", ceid: "GB:en" })}`);
            if (!r.ok) continue;
            const items = parseFeed(await r.text()).filter((i) => !i.at || now - Date.parse(i.at) <= NEWS_MAX_AGE).slice(0, NEWS_PER_SEARCH);
            for (const i of items) {
              const k = newsTitleKey(i.title);
              if (!k || seen.has(k)) continue;
              seen.add(k);
              pending.push({ person: p, key: `news:${p.person}:${k}`, needsMatch: kind === "news_person",
                u: { kind, title: cleanTitle(i.title), detail: i.source, url: i.link, at: i.at, match: "possible" } });
            }
          }
          await mark(p.person, "news");
        }
        if (p.ch && chKey && await due(p.person, "ch")) {
          looked = true;
          await companiesHouse(env, userId, p, chKey, f, pending);
          await mark(p.person, "ch");
        }
        if (p.feed_url && /^https?:\/\//.test(p.feed_url) && await due(p.person, "feed")) {
          looked = true;
          const r = await f(p.feed_url);
          if (r.ok) for (const i of parseFeed(await r.text()).slice(0, 5)) {
            pending.push({ person: p, key: `post:${p.person}:${i.link}`, needsMatch: false, u: { kind: "post", title: i.title, detail: "", url: i.link, at: i.at, match: "possible" } });
          }
          await mark(p.person, "feed");
        }
      } catch (e) {
        if ((e as Error)?.name === "BudgetExhausted" || /budget/i.test(String((e as Error)?.message))) break;
        console.warn(JSON.stringify({ event: "circle_update_failed", person: p.person, error: String((e as Error)?.message ?? e).slice(0, 200) }));
      }
      if (looked) checked++;
    }
    // Only new items are judged (each once), in one batch.
    const fresh: Pending[] = [];
    for (const x of pending) {
      const known = await env.DB.prepare("SELECT 1 AS x FROM circle_updates WHERE user_id=? AND key=?").bind(userId, x.key).first();
      if (!known) fresh.push(x);
    }
    await matchNews(env, userId, fresh.filter((x) => x.needsMatch).slice(0, MATCH_BATCH), f);
    const stmts: D1PreparedStatement[] = [];
    for (const x of fresh) {
      stmts.push(env.DB.prepare("INSERT OR IGNORE INTO circle_updates(user_id,key,person,data_enc,created) VALUES(?,?,?,?,?)")
        .bind(userId, x.key, x.person.person, await seal(env, x.u), nowISO()));
    }
    const res = stmts.length ? await env.DB.batch(stmts) : [];
    return { checked, found: res.filter((r) => r.meta.changes > 0).length };
  } catch (e) {
    console.warn(JSON.stringify({ event: "circle_updates_failed", error: String((e as Error)?.message ?? e).slice(0, 300) }));
    return { checked: 0, found: 0 };
  }
}

/** ⚑ news_match: "is this headline about this person?" One Haiku call for the batch; "no" = set aside (kept). */
async function matchNews(env: Env, userId: string, items: Pending[], f: typeof fetch) {
  if (!items.length) return;
  const client = await haikuFor(env, userId, "news_match", f);
  if (!client) return;
  const Answer = z.object({ items: z.array(z.object({ n: z.number(), about_them: z.boolean() })) });
  const list = items.map((x, n) => ({ n: n + 1, person: x.person.name, firm: x.person.firm || x.person.company, headline: x.u.title, source: x.u.detail }));
  const r = await askStructured(client, {
    system: "You check news headlines for a personal contacts app. Same-name confusion is common: a headline can be about someone " +
      "else with the same name. For each item, answer about_them=false only when the headline is clearly about a different person " +
      "(another job, field, place or age than the person and firm given). When unsure, answer true. Judge only from the headline, " +
      "the source, the name and the firm.",
    user: JSON.stringify(list), schema: Answer, maxTokens: 1000,
  });
  if (!r.ok) return;   // couldn't read the answer: everything stays "possible"
  for (const a of r.value.items) {
    const x = items[a.n - 1];
    if (x && !a.about_them) x.u.match = "unlikely";
  }
}

/** Companies House: candidates by name, or a confirmed officer's appointments (first read = current directorships). */
async function companiesHouse(env: Env, userId: string, p: WatchPerson, key: string, f: typeof fetch, out: Pending[]) {
  const auth = { Authorization: "Basic " + btoa(`${key}:`) };
  if (!p.officer_id) {
    const r = await f(`${CH}/search/officers?${new URLSearchParams({ q: p.name, items_per_page: "10" })}`, { headers: auth });
    if (!r.ok) return;
    const j = await r.json<{ items?: any[] }>();
    for (const it of (j.items ?? []).slice(0, 5)) {
      const id = /\/officers\/([^/]+)\/appointments/.exec(String(it?.links?.self ?? ""))?.[1];
      if (!id) continue;
      const dob = it.date_of_birth;
      const born = dob?.year && dob?.month ? `${dob.year}-${String(dob.month).padStart(2, "0")}` : "";
      out.push({ person: p, key: `ch:cand:${p.person}:${id}`, needsMatch: false, u: { kind: "officer_candidate", title: line(it.title, 200),
        detail: [line(it.address_snippet, 120), it.appointment_count ? `${it.appointment_count} appointments` : ""].filter(Boolean).join(" · "),
        url: `https://find-and-update.company-information.service.gov.uk/officers/${id}/appointments`, at: null, match: "", born, officer: id } });
    }
    return;
  }
  const off = p.officer_id;
  const r = await f(`${CH}/officers/${encodeURIComponent(off)}/appointments?items_per_page=50`, { headers: auth });
  if (!r.ok) return;
  const items = (await r.json<{ items?: any[] }>()).items ?? [];
  const reader = `ch:${p.person}:${off}`;
  const st = await env.DB.prepare("SELECT cursor FROM circle_readers WHERE user_id=? AND reader=?").bind(userId, reader).first<{ cursor: string }>();
  const first = !st;
  const known = new Set<string>(st ? (JSON.parse(st.cursor || "[]") as string[]) : []);
  const view = items.map((it) => {
    const num = line(it?.appointed_to?.company_number, 20), name = titleCase(line(it?.appointed_to?.company_name, 160));
    const role = titleCase(line(it?.officer_role, 60).replace(/-/g, " "));
    return { base: `ch:${off}:${num}:${line(it?.appointed_on, 10)}`, title: `${role}, ${name}`, appointed: line(it?.appointed_on, 10),
      resigned: line(it?.resigned_on, 10), url: num ? `https://find-and-update.company-information.service.gov.uk/company/${num}` : "" };
  }).filter((a) => a.base.split(":")[2]);
  const push = (key: string, kind: string, a: typeof view[number], detail: string, at: string) =>
    out.push({ person: p, key, needsMatch: false, u: { kind, title: a.title, detail, url: a.url, at: at ? new Date(at).toISOString() : null, match: "" } });
  for (const a of view) {
    if (first) { if (!a.resigned) push(`${a.base}:d`, "directorship", a, a.appointed ? `Since ${a.appointed}` : "", a.appointed); }
    else if (!known.has(a.base) && !a.resigned) push(`${a.base}:a`, "appointment", a, `Appointed ${a.appointed}`, a.appointed);
  }
  for (const a of view) if (!first && known.has(a.base) && a.resigned) push(`${a.base}:r`, "resignation", a, `Resigned ${a.resigned}`, a.resigned);
  for (const a of view) known.add(a.base);
  await env.DB.prepare(`INSERT INTO circle_readers(user_id,reader,as_of,cursor,note) VALUES(?,?,?,?,'')
      ON CONFLICT(user_id,reader) DO UPDATE SET as_of=excluded.as_of, cursor=excluded.cursor`).bind(userId, reader, nowISO(), JSON.stringify([...known])).run();
}
