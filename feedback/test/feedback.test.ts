import { beforeEach, describe, expect, it } from "vitest";
import { env } from "cloudflare:test";
import worker, { ALERT_AFTER, MAX_TEXT, PER_DAY, issueFor, retry, setFetches } from "../src/index";

const BASE = "https://feedback.test";
let github: { url: string; body: any; auth: string | null }[] = [];
let ntfy: { url: string; title: string | null; body: string }[] = [];
let githubUp = true;

beforeEach(async () => {
  github = []; ntfy = []; githubUp = true;
  await env.DB.batch([env.DB.prepare("DELETE FROM feedback"), env.DB.prepare("DELETE FROM meta")]);
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

const send = (body: unknown, raw?: string) =>
  worker.fetch(new Request(BASE + "/feedback", { method: "POST", headers: { "Content-Type": "application/json" }, body: raw ?? JSON.stringify(body) }), env as any);
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
    // Another install is not affected.
    expect((await send(msg({ install_id: "0f1e2d3c-aaaa-bbbb-cccc-000000000002" }))).status).toBe(200);
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
    for (let i = 0; i < ALERT_AFTER; i++) await send(msg({ install_id: "0f1e2d3c-aaaa-bbbb-cccc-00000000000" + (i + 3), text: `k${i}` }));
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
