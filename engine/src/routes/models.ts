/**
 * "Compare with Haiku" (Settings › Rules & learning › AI model, Mac only mode; docs/architecture.md C7): judges your most
 * recent chats twice, with Haiku and with Apple's model on this Mac, and reports how often they agree on "needs you".
 * Costs one Haiku call per chat (shown before it runs). Nothing is stored except the usual usage count.
 */
import { json } from "../env";
import { decrypt } from "../lib/crypto";
import { readJSON } from "../lib/http";
import { HAIKU, ON_DEVICE, makeClient, onDeviceAllowed } from "../lib/llm";
import { route } from "../lib/router";
import { chatMessage } from "../sources/chat";
import { classify } from "../triage/classify";

route("POST", "/v2/models/compare", async (req, env, user) => {
  if (!onDeviceAllowed(env, "judge")) return json({ error: "Apple's on-device model is only available in Mac only mode" }, 400);
  const b = await readJSON(req);
  if (!b.ok) return b.res;
  const limit = Math.min(20, Math.max(1, Number((b.body as any)?.limit) || 10));
  const u = await env.DB.prepare("SELECT anthropic_key_enc, name FROM users WHERE id=?").bind(user.id).first<{ anthropic_key_enc: string | null; name: string | null }>();
  if (!u?.anthropic_key_enc) return json({ error: "Add your Claude key first" }, 400);
  const { results } = await env.DB.prepare(`SELECT row_key, app, chat_name, is_group, muted, senders, transcript, link, received, source_id
      FROM chat_rows WHERE user_id=? ORDER BY received DESC LIMIT ?`).bind(user.id, limit).all<any>();
  if (!results.length) return json({ n: 0, agree: 0, pairs: [], note: "No chats to compare yet: turn on WhatsApp screening first." });
  const key = await decrypt(env, u.anthropic_key_enc);
  const s = await env.DB.prepare("SELECT groups, chat_rules FROM settings WHERE user_id=?").bind(user.id).first<{ groups: string | null; chat_rules: string | null }>();
  const groups: string[] = JSON.parse(s?.groups ?? "[]");
  const ctx = { chatRules: s?.chat_rules ?? "", userName: u.name ?? "" };
  const haiku = makeClient(key, undefined, { env, userId: user.id, job: "compare", model: HAIKU });
  const device = makeClient(key, undefined, { env, userId: user.id, job: "compare", model: ON_DEVICE });
  const pairs: { chat: string; haiku: boolean | null; device: boolean | null }[] = [];
  for (const r of results) {
    const m = chatMessage(r, r.source_id);
    const [a, d] = [await classify(m, [], [], haiku, groups, ctx), await classify(m, [], [], device, groups, ctx)];
    pairs.push({ chat: r.chat_name, haiku: a.ok ? !!a.action : null, device: d.ok ? !!d.action : null });
  }
  const judged = pairs.filter((p) => p.haiku !== null);
  return json({ n: judged.length, agree: judged.filter((p) => p.device === p.haiku).length,
    unusable: pairs.filter((p) => p.device === null).length, pairs });
});
