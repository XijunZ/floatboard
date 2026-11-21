import { beforeEach, describe, expect, it } from "vitest";
import { env } from "cloudflare:test";
import worker, { ALERT_AFTER, GLOBAL_PER_DAY, MAX_TEXT, PER_DAY, PER_IP_PER_DAY, issueFor, retry, setFetches } from "../src/index";

const BASE = "https://feedback.test";
let github: { url: string; body: any; auth: string | null }[] = [];
let ntfy: { url: string; title: string | null; body: string }[] = [];
let githubUp = true;

beforeEach(async () => {
  github = []; ntfy = []; githubUp = true;
  await env.DB.batch([env.DB.prepare("DELETE FROM feedback"), env.DB.prepare("DELETE FROM meta"), env.DB.prepare("DELETE FROM allowance")]);
  setFetches(
    (async (url: RequestInfo | URL, init?: RequestInit) => {
      github.push({ url: String(url), body: JSON.parse(String(init?.body)), auth: new Headers(init?.headers).get("Authorization") });
      return githubUp ? Response.json({ html_url: `https://github.com/x/y/issues/${github.length}` }, { status: 201 })
        : new Response("down", { status: 502 });
    }) as typeof fetch,
    (async (url: RequestInfo | URL, init?: RequestInit) => {
      ntfy.push({ url: String(url), title: new Headers(init?.headers).get("Title"), body: String(init?.body) });
      return new Response("ok");
    }) as typeof fetch,
  );
});

const send = (body: unknown, raw?: string, ip = "203.0.113.7") =>
  worker.fetch(new Request(BASE + "/feedback", { method: "POST", headers: { "Content-Type": "application/json", "CF-Connecting-IP": ip },
    body: raw ?? JSON.stringify(body) }), env as any);
const msg = (over: Record<string, unknown> = {}) =>
  ({ install_id: "0f1e2d3c-aaaa-bbbb-cccc-000000000001", text: "The bar hides my dock\nsteps: …", app_version: "0.1.0", os: "macOS 26.1", ...over });
const rows = async () => (await env.DB.prepare("SELECT * FROM feedback ORDER BY received").all<any>()).results;

describe("feedback", () => {
  it("stores_files_a_private_issue_and_alerts", async () => {
    const r = await send(msg());
    expect(r.status).toBe(200);
    const [row] = await rows();
    expect(row.text).toBe("The bar hides my dock\nsteps: …");
    expect(row.issue_url).toBe("https://github.com/x/y/issues/1");
    expect(github[0].url).toBe(`https://api.github.com/repos/${env.GITHUB_REPO}/issues`);
    expect(github[0].auth).toBe("Bearer gh-test-token");
    expect(github[0].body.title).toBe("Feedback: The bar hides my dock");
    expect(github[0].body.labels).toEqual(["feedback"]);
    expect(github[0].body.body).toContain("App 0.1.0 · macOS 26.1");
    expect(ntfy[0].url).toBe("https://ntfy.sh/fb-test-topic");
    expect(ntfy[0].body).toContain("The bar hides my dock");
  });

  it("diagnostics_only_when_sent_and_folded_away", async () => {
    await send(msg());
    expect(github[0].body.body).not.toContain("Diagnostics");
    await send(msg({ diagnostics: '{"cards":3}' }));
    expect(github[1].body.body).toContain("<details><summary>Diagnostics</summary>");
    expect(github[1].body.body).toContain('{"cards":3}');
  });

  it("refuses_bad_or_oversized_messages", async () => {
    expect((await send(null, "not json")).status).toBe(400);
    expect((await send(msg({ text: "   " }))).status).toBe(400);
    expect((await send(msg({ install_id: "x" }))).status).toBe(400);
    expect((await send(msg({ text: "a".repeat(MAX_TEXT + 1) }))).status).toBe(400);
    expect((await send(msg({ diagnostics: "a".repeat(70_000) }))).status).toBe(413);
    expect(await rows()).toHaveLength(0);
    expect((await worker.fetch(new Request(BASE + "/feedback"), env as any)).status).toBe(405);
  });

  it("at_most_five_a_day_per_install", async () => {
    for (let i = 0; i < PER_DAY; i++) expect((await send(msg({ text: `n${i}` }))).status).toBe(200);
    const over = await send(msg({ text: "one more" }));
    expect(over.status).toBe(429);
    // Another install (from another address: round 29 also limits each address) is not affected.
    expect((await send(msg({ install_id: "0f1e2d3c-aaaa-bbbb-cccc-000000000002" }), undefined, "198.51.100.20")).status).toBe(200);
  });

  it("kept_when_github_is_down_retried_hourly_and_alerted_once_after_three", async () => {
    githubUp = false;
    for (let i = 0; i < ALERT_AFTER; i++) expect((await send(msg({ text: `m${i}` }))).status).toBe(200);
    expect((await rows()).every((r) => r.issue_url === null && r.last_error.includes("502"))).toBe(true);
    const alerts = () => ntfy.filter((n) => n.title === "FloatBoard feedback can't reach GitHub");
    expect(alerts()).toHaveLength(1);
    await retry(env as any); // still down: no second alert
    expect(alerts()).toHaveLength(1);
    githubUp = true;
    expect(await retry(env as any)).toBe(ALERT_AFTER);
    expect((await rows()).every((r) => r.issue_url?.startsWith("https://github.com/"))).toBe(true);
    // A new run of failures alerts again.
    githubUp = false;
    for (let i = 0; i < ALERT_AFTER; i++) await send(msg({ install_id: "0f1e2d3c-aaaa-bbbb-cccc-00000000000" + (i + 3), text: `k${i}` }), undefined, `198.51.100.${30 + i}`);
    expect(alerts()).toHaveLength(2);
  });

  it("issue_title_is_the_first_line_shortened", () => {
    const t = issueFor({ id: "i", install_id: "abcdefgh", received: "r", text: "x".repeat(100), app_version: null, os: null, diagnostics: null, attempts: 0 }).title;
    expect(t.length).toBeLessThanOrEqual("Feedback: ".length + 70);
    expect(t.endsWith("…")).toBe(true);
  });
});

describe("retry without a cron", () => {
  it("a_new_message_retries_older_waiting_ones", async () => {
    githubUp = false;
    await send(msg({ text: "first" }));
    githubUp = true;
    const waits: Promise<unknown>[] = [];
    const ctx = { waitUntil: (p: Promise<unknown>) => waits.push(p), passThroughOnException() {} } as unknown as ExecutionContext;
    await worker.fetch(new Request(BASE + "/feedback", { method: "POST", body: JSON.stringify(msg({ text: "second" })) }), env as any, ctx);
    await Promise.all(waits);
    expect((await rows()).every((r) => r.issue_url?.startsWith("https://github.com/"))).toBe(true);
  });
});

// Round 29 (security review M1): the endpoint can't be used to flood the maintainer's repository or phone.
describe("feedback: abuse limits", () => {
  it("one_address_is_limited_whatever_install_id_it_claims", async () => {
    for (let i = 0; i < PER_IP_PER_DAY; i++) expect((await send(msg({ install_id: `aaaaaaaa-0000-0000-0000-00000000000${i}` }))).status).toBe(200);
    expect((await send(msg({ install_id: "bbbbbbbb-0000-0000-0000-000000000099" }))).status).toBe(429);
    expect((await send(msg({ install_id: "bbbbbbbb-0000-0000-0000-000000000099" }), undefined, "198.51.100.1")).status).toBe(200);
  });

  it("a_daily_cap_on_issues_then_messages_are_only_stored", async () => {
    const day = new Date().toISOString().slice(0, 10);
    await env.DB.batch([
      env.DB.prepare("INSERT OR REPLACE INTO allowance(kind,day,n) VALUES('issue',?,?)").bind(day, GLOBAL_PER_DAY),
      env.DB.prepare("INSERT OR REPLACE INTO allowance(kind,day,n) VALUES('ntfy',?,?)").bind(day, GLOBAL_PER_DAY),
    ]);
    const r = await send(msg({ install_id: "dddddddd-0000-0000-0000-000000000001" }), undefined, "192.0.2.9");
    expect(r.status).toBe(200);
    expect(github).toHaveLength(0);
    expect(ntfy).toHaveLength(0);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM feedback WHERE issue_url IS NULL").first<any>()).n).toBe(1);
    expect(await retry(env as any)).toBe(0);   // the hourly run respects the cap too
  });

  it("mentions_never_notify_anyone", async () => {
    await send(msg({ text: "Hi @octocat and @github/team, see also email a@b.c" }));
    const body: string = github[0].body.body, title: string = github[0].body.title;
    expect(body).not.toMatch(/@[A-Za-z0-9]/);
    expect(title).not.toMatch(/@[A-Za-z0-9]/);
    expect(body).toContain("octocat");
  });

  it("a_body_without_length_is_still_capped", async () => {
    const big = new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode('{"text":"' + "x".repeat(200_000) + '"}')); c.close(); } });
    const r = await worker.fetch(new Request(BASE + "/feedback", { method: "POST", body: big, duplex: "half" } as any), env as any);
    expect(r.status).toBe(413);
  });
});

// Round 31 (Codex 21): the allowances are taken before anything happens, in one statement each, so requests arriving
// together (or a retry) can never pass the caps; a notification counts whether or not GitHub took the issue.
describe("feedback: caps hold under concurrency", () => {
  it("concurrent_requests_from_one_address_never_pass_its_cap", async () => {
    const all = await Promise.all(Array.from({ length: 12 }, (_, i) =>
      send(msg({ install_id: `eeeeeeee-0000-0000-0000-0000000000${String(i).padStart(2, "0")}` }), undefined, "203.0.113.50")));
    expect(all.filter((r) => r.status === 200)).toHaveLength(PER_IP_PER_DAY);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM feedback WHERE install_id LIKE 'eeeeeeee%'").first<any>()).n).toBe(PER_IP_PER_DAY);
  });

  it("concurrent_requests_never_pass_the_daily_issue_and_notification_caps", async () => {
    const day = new Date().toISOString().slice(0, 10);
    await env.DB.batch([
      env.DB.prepare("INSERT OR REPLACE INTO allowance(kind,day,n) VALUES('issue',?,?)").bind(day, GLOBAL_PER_DAY - 2),
      env.DB.prepare("INSERT OR REPLACE INTO allowance(kind,day,n) VALUES('ntfy',?,?)").bind(day, GLOBAL_PER_DAY - 2),
    ]);
    await Promise.all(Array.from({ length: 8 }, (_, i) =>
      send(msg({ install_id: `ffffffff-0000-0000-0000-0000000000${i}0` }), undefined, `198.51.100.${100 + i}`)));
    expect(github).toHaveLength(2);
    expect(ntfy).toHaveLength(2);
    await retry(env as any);
    expect(github).toHaveLength(2);
  });

  it("a_github_failure_still_uses_up_a_notification", async () => {
    githubUp = false;
    const day = new Date().toISOString().slice(0, 10);
    await env.DB.prepare("INSERT OR REPLACE INTO allowance(kind,day,n) VALUES('ntfy',?,?)").bind(day, GLOBAL_PER_DAY - 1).run();
    await send(msg({ install_id: "abababab-0000-0000-0000-000000000001" }), undefined, "192.0.2.77");
    await send(msg({ install_id: "abababab-0000-0000-0000-000000000002" }), undefined, "192.0.2.78");
    expect(ntfy.filter((n) => n.title === "FloatBoard feedback")).toHaveLength(1);
  });
});

