/**
 * Keeping two engines of the same person in step (docs/architecture.md, Edition 2, C1): the one that screens (online or
 * on the Mac) hands its state to the one on standby every few minutes, and again at the moment of switching, so a switch
 * starts exactly where the other left off and nothing set up is lost:
 * - inputs: Gmail sign-ins (with their own Google client), the Fathom API key, and how far each was read (cursor);
 * - what was already judged (`seen`, last 30 days), so nothing is judged twice, and the meetings already judged
 *   (`recap_keys`, every alias, last 30 days: Fathom catch-up checks these), round 40;
 * - the person's own name (`owner_name`): judging uses it to know which asks and meeting actions are theirs (the engine
 *   on the Mac is labelled "This Mac", which is never a person), round 40;
 * - the Claude key, when the receiving engine has none.
 * The Mac app moves it between its two engines over HTTPS with the person's user key (the same key that already reads
 * all of their data). Rules, groups and what was learned are owned by the Mac and sent as settings, not here.
 */
import { json, nowISO } from "../env";
import { decrypt, encrypt } from "../lib/crypto";
import { readCappedJSON } from "../lib/http";
import { logEvent } from "../lib/runlog";
import { route } from "../lib/router";

const KINDS = ["gmail", "fathom"];
/** The label the Mac's own engine was once created with: never a person's name. */
const MACHINE_LABEL = "This Mac";
const ownerName = (n: string | null | undefined) => (n && n.trim() && n.trim() !== MACHINE_LABEL ? n.trim().slice(0, 200) : null);
const SEEN_DAYS = 30;
const MAX_BODY = 2_000_000;

type Handed = { kind: string; address: string; enabled: boolean; cursor: string | null; refresh_token: string | null;
  client_id: string | null; client_secret: string | null; fathom_key: string | null };

route("GET", "/v2/handover", async (_req, env, user) => {
  const { results } = await env.DB.prepare(`SELECT kind, address, enabled, cursor, refresh_enc, client_id, client_secret_enc, fathom_key_enc
      FROM sources WHERE user_id=? AND kind IN (SELECT value FROM json_each(?))`).bind(user.id, JSON.stringify(KINDS)).all<any>();
  const open = async (v: string | null) => (v ? await decrypt(env, v) : null);
  const sources: Handed[] = [];
  for (const r of results) {
    sources.push({ kind: r.kind, address: r.address, enabled: !!r.enabled, cursor: r.cursor ?? null, refresh_token: await open(r.refresh_enc),
      client_id: r.client_id ?? null, client_secret: await open(r.client_secret_enc), fathom_key: await open(r.fathom_key_enc) });
  }
  const since = new Date(Date.now() - SEEN_DAYS * 86400e3).toISOString();
  const seen = (await env.DB.prepare("SELECT message_id FROM seen WHERE user_id=? AND at > ?").bind(user.id, since).all<{ message_id: string }>())
    .results.map((r) => r.message_id);
  const recapKeys = (await env.DB.prepare("SELECT key FROM recap_keys WHERE user_id=? AND claim IS NULL AND created > ?").bind(user.id, since)
    .all<{ key: string }>()).results.map((r) => r.key);
  const u = await env.DB.prepare("SELECT anthropic_key_enc, name FROM users WHERE id=?").bind(user.id).first<{ anthropic_key_enc: string | null; name: string | null }>();
  await logEvent(env, { run_id: "handover", user_id: user.id, decision: "handover sent", detail: `${sources.length} input(s), ${seen.length} seen` }).run();
  return json({ version: 1, at: nowISO(), sources, seen, recap_keys: recapKeys, owner_name: ownerName(u?.name),
    claude_key: await open(u?.anthropic_key_enc ?? null) });
});

/**
 * Body: what GET /v2/handover returned, plus `apply_enabled`: true at a switch (each input is on or off here as it was
 * there), false while on standby (new inputs arrive switched off, existing ones keep their switch: a standby engine never
 * reads). Cursors are taken from the sender: it is the one that has been reading.
 */
route("POST", "/v2/handover", async (req, env, user) => {
  const b = await readCappedJSON(req, MAX_BODY);
  if (!b.ok) return json({ error: b.tooLarge ? "too large" : "Invalid JSON" }, b.tooLarge ? 413 : 400);
  const body = b.body as { sources?: Handed[]; seen?: string[]; recap_keys?: string[]; owner_name?: string | null; claude_key?: string | null; apply_enabled?: boolean };
  if (!Array.isArray(body.sources) || !Array.isArray(body.seen)) return json({ error: "sources and seen are required" }, 400);
  const apply = body.apply_enabled === true;
  const now = nowISO();
  const stmts: D1PreparedStatement[] = [];
  let inputs = 0;
  for (const s of body.sources.slice(0, 50)) {
    if (!s || !KINDS.includes(s.kind) || typeof s.address !== "string" || !s.address || s.address.length > 200) continue;
    const enc = async (v: string | null | undefined) => (typeof v === "string" && v ? await encrypt(env, v) : null);
    const existing = await env.DB.prepare("SELECT id FROM sources WHERE user_id=? AND kind=? AND address=?").bind(user.id, s.kind, s.address)
      .first<{ id: string }>();
    const cursor = typeof s.cursor === "string" ? s.cursor.slice(0, 4000) : null;
    if (existing) {
      stmts.push(env.DB.prepare(`UPDATE sources SET refresh_enc=COALESCE(?,refresh_enc), client_id=COALESCE(?,client_id),
          client_secret_enc=COALESCE(?,client_secret_enc), fathom_key_enc=COALESCE(?,fathom_key_enc), cursor=?,
          enabled=CASE WHEN ? THEN ? ELSE enabled END, last_error=NULL WHERE id=?`)
        .bind(await enc(s.refresh_token), s.client_id ?? null, await enc(s.client_secret), await enc(s.fathom_key), cursor,
          apply ? 1 : 0, s.enabled ? 1 : 0, existing.id));
    } else {
      stmts.push(env.DB.prepare(`INSERT INTO sources(id,user_id,kind,address,refresh_enc,client_id,client_secret_enc,fathom_key_enc,hook_id,enabled,cursor,created)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`)
        .bind(crypto.randomUUID(), user.id, s.kind, s.address, await enc(s.refresh_token), s.client_id ?? null, await enc(s.client_secret),
          await enc(s.fathom_key), s.kind === "fathom" ? crypto.randomUUID().replace(/-/g, "") : null, apply && s.enabled ? 1 : 0, cursor, now));
    }
    inputs++;
  }
  for (const id of body.seen.slice(0, 50_000)) {
    if (typeof id === "string" && id && id.length <= 500) stmts.push(env.DB.prepare("INSERT OR IGNORE INTO seen(user_id,message_id,at) VALUES(?,?,?)").bind(user.id, id, now));
  }
  for (const k of (Array.isArray(body.recap_keys) ? body.recap_keys : []).slice(0, 50_000)) {
    if (typeof k === "string" && k && k.length <= 500) stmts.push(env.DB.prepare("INSERT OR IGNORE INTO recap_keys(user_id,key,created) VALUES(?,?,?)").bind(user.id, k, now));
  }
  // The person's name: taken at a switch (the sender is the one in use); on standby only where this engine has none.
  const name = ownerName(body.owner_name);
  if (name) {
    stmts.push(apply ? env.DB.prepare("UPDATE users SET name=? WHERE id=?").bind(name, user.id)
      : env.DB.prepare("UPDATE users SET name=? WHERE id=? AND (name IS NULL OR trim(name)='' OR name=?)").bind(name, user.id, MACHINE_LABEL));
  }
  if (typeof body.claude_key === "string" && body.claude_key) {
    stmts.push(env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=? AND anthropic_key_enc IS NULL").bind(await encrypt(env, body.claude_key), user.id));
  }
  stmts.push(logEvent(env, { run_id: "handover", user_id: user.id, decision: "handover received",
    detail: `${inputs} input(s), ${body.seen.length} seen${apply ? ", switched here" : ", on standby"}` }));
  for (let i = 0; i < stmts.length; i += 90) await env.DB.batch(stmts.slice(i, i + 90));
  return json({ ok: true, inputs, seen: body.seen.length });
});
