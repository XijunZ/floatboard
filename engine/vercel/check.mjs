// Runs the Vercel build of the engine locally against a libSQL file (no Vercel or Turso account needed):
// a user, keys, a WhatsApp chat judged by a fake Claude, the schedule, and the task coming back as a proposal.
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "fb-vercel-"));
process.env.TURSO_DATABASE_URL = `file:${join(dir, "engine.db")}`;
process.env.ENC_KEY = "a long test encryption key for the vercel check";
process.env.ADMIN_KEY = "adm-vercel";
const claudeCalls = [];
const realFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  if (url.startsWith("https://api.anthropic.com/")) {
    claudeCalls.push(JSON.parse(String(init?.body ?? "{}")));
    return Response.json({ id: "m", type: "message", role: "assistant", model: "claude-haiku-5-5", stop_reason: "end_turn", stop_sequence: null,
      content: [{ type: "text", text: JSON.stringify({ action_required: true, title: "Send Anna the contract", why: "She asked", due: null, has_time: false, importance: 2, group: null, urgent: false }) }],
      usage: { input_tokens: 10, output_tokens: 5 } });
  }
  return realFetch(input, init);
};
const { handle, scheduled } = await import("./dist/engine.mjs");
const BASE = "https://engine.vercel.test";
let failures = 0;
const check = (ok, name) => { console.log(`${ok ? "PASS" : "FAIL"} ${name}`); if (!ok) failures++; };
const call = (path, init = {}) => handle(new Request(BASE + path, init));
try {
  const made = await (await call("/admin/users", { method: "POST", headers: { "X-Admin-Key": "adm-vercel", "Content-Type": "application/json" }, body: JSON.stringify({ name: "V" }) })).json();
  check(typeof made.key === "string", "vercel_engine_migrates_and_creates_a_user");
  const auth = { Authorization: `Bearer ${made.key}`, "Content-Type": "application/json" };
  const keys = await (await call("/v2/keys", { method: "PUT", headers: auth, body: JSON.stringify({ claude_key: "sk-test" }) })).json();
  check(keys.keys?.claude === true, "vercel_engine_takes_keys");
  const chat = { key: "wa:447700900123@s.whatsapp.net:V1", name: "Anna", group: false, senders: ["Anna"], transcript: "[2026-11-13 09:12] Anna: Can you send me the contract?", link: "", received: "2026-11-13T09:12:00Z" };
  const stored = await (await call("/v2/chats", { method: "POST", headers: auth, body: JSON.stringify({ app: "whatsapp", chats: [chat] }) })).json();
  check(stored.stored === 1, "vercel_engine_stores_chats");
  await scheduled();
  const page = await (await call("/v2/proposals", { headers: auth })).json();
  check(page.items?.some((i) => i.title === "Send Anna the contract") && claudeCalls.length >= 1, "vercel_engine_turns_a_chat_into_a_task");
  const st = await (await call("/v2/status", { headers: auth })).json();
  check(st.ai_cost?.judge?.calls >= 1, "vercel_engine_counts_claude_use");
  check((await call("/setup")).status === 200, "vercel_engine_serves_the_setup_page");
} catch (e) {
  console.log("FAIL vercel_engine:", e?.stack ?? e);
  failures++;
} finally {
  rmSync(dir, { recursive: true, force: true });
}
console.log(failures ? `VERCEL CHECKS FAILED (${failures})` : "VERCEL CHECKS OK");
process.exit(failures ? 1 : 0);
