/**
 * Server-rendered HTML for the engine's setup page (/setup). Plain HTML and a little inline CSS: no scripts, no inline
 * event handlers, no external resources. Every dynamic value goes through `esc`.
 */

import { RULES, PRE_RULES } from "../classify";

const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
/** HTML-escape text for element content and (double- or single-quoted) attribute values. */
export const esc = (s: unknown): string => String(s ?? "").replace(/[&<>"']/g, (c) => ESCAPES[c]);

export const SECURITY_HEADERS: Record<string, string> = {
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Cache-Control": "no-store",
};

export function htmlResponse(body: string, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/html; charset=utf-8", ...SECURITY_HEADERS, ...extra } });
}

/** A redirect with the same strict headers (and optionally a cookie). */
export function redirect(location: string, extra: Record<string, string> = {}): Response {
  return new Response(null, { status: 303, headers: { Location: location, ...SECURITY_HEADERS, ...extra } });
}

const CSS = `
body{font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;max-width:720px;margin:0 auto;padding:24px 16px;color:#1d1d1f;background:#fbfbfd}
h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:0 0 8px}
section{background:#fff;border:1px solid #e3e3e8;border-radius:10px;padding:16px;margin:16px 0}
label{display:block;margin:8px 0 2px;font-weight:600}
input[type=text],input[type=password]{width:100%;box-sizing:border-box;padding:8px;border:1px solid #c7c7cc;border-radius:6px;font:inherit}
button,.button{display:inline-block;margin-top:10px;padding:7px 14px;border-radius:6px;border:1px solid #0a64d8;background:#0a64d8;color:#fff;font:inherit;text-decoration:none;cursor:pointer}
button.secondary,.button.secondary{background:#fff;color:#0a64d8}
button.danger{background:#fff;color:#c4271b;border-color:#c4271b}
code{background:#f2f2f5;padding:2px 5px;border-radius:4px;word-break:break-all}
.muted{color:#6e6e73}.ok{color:#1a7f37;font-weight:600}.bad{color:#c4271b;font-weight:600}
.notice{background:#eaf6ec;border:1px solid #b7dfc0;padding:10px;border-radius:8px}
.error{background:#fdecea;border:1px solid #f3b8b2;padding:10px;border-radius:8px}
ul{padding-left:0;list-style:none}li{padding:8px 0;border-top:1px solid #eee}li:first-child{border-top:0}
form.inline{display:inline}
.connect{font-size:17px;padding:10px 20px}
`;

function layout(title: string, inner: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><title>${esc(title)}</title><style>${CSS}</style></head><body>${inner}</body></html>`;
}

const banner = (notice?: string | null, error?: string | null) =>
  (notice ? `<p class="notice">${esc(notice)}</p>` : "") + (error ? `<p class="error">${esc(error)}</p>` : "");

const csrfField = (csrf: string) => `<input type="hidden" name="csrf" value="${esc(csrf)}">`;

export function signInPage(opts: { admin?: boolean; error?: string | null } = {}): string {
  const action = opts.admin ? "/setup/admin/signin" : "/setup/signin";
  const what = opts.admin ? "the engine's admin key" : "your FloatBoard user key";
  return layout(opts.admin ? "FloatBoard engine admin" : "FloatBoard engine setup", `
<h1>${opts.admin ? "FloatBoard engine admin" : "FloatBoard engine setup"}</h1>
<p class="muted">Sign in with ${what}. You stay signed in for one hour on this browser.</p>
${banner(null, opts.error)}
<section><form method="post" action="${action}">
<label for="key">${opts.admin ? "Admin key" : "User key"}</label>
<input type="password" id="key" name="key" autocomplete="current-password" required>
<button type="submit">Sign in</button></form></section>`);
}

export function messagePage(title: string, message: string, opts: { ok?: boolean; back?: string } = {}): string {
  return layout(title, `<h1>${esc(title)}</h1><p class="${opts.ok ? "notice" : "error"}">${esc(message)}</p>
<p><a class="button secondary" href="${esc(opts.back ?? "/setup")}">Back to setup</a></p>`);
}

export type GmailRow = { id: string; address: string; enabled: number; last_error: string | null; last_run: string | null };

/** The user's Outlook (Chrome extension) source, if made. */
export type OutlookStatus = { address: string; enabled: number; last_error: string | null; last_run: string | null };

export type Dashboard = {
  name: string;
  csrf: string;
  origin: string;
  /** floatboard://connect?... (null when the key can't be recovered from the session). */
  connectLink: string | null;
  googleClientId: string | null;
  gmail: GmailRow[];
  hasClaudeKey: boolean;
  telegramLinked: boolean;
  telegramURL?: string | null;
  /** The user's ntfy topic when phone alerts with the ntfy app are on. */
  ntfyTopic?: string | null;
  /** The @username (without @) of the user's own bot, when they saved one. */
  telegramBot?: string | null;
  fathomURL: string | null;
  fathomSecretSaved?: boolean;
  fathomKeySaved?: boolean;
  outlook?: OutlookStatus | null;
  /** Paired phones (the phone app), oldest first. */
  phones?: { id: string; name: string; created: string; last_seen: string | null }[];
  /** The new ingest token, right after it was made (shown this once only). */
  outlookToken?: string | null;
  notice?: string | null;
  error?: string | null;
};

function gmailStatus(g: GmailRow): string {
  if (!g.enabled) return `<span class="muted">paused</span>`;
  if (g.last_error) return `<span class="bad">needs attention</span> <span class="muted">${esc(g.last_error)}</span>`;
  return `<span class="ok">connected</span>${g.last_run ? ` <span class="muted">last checked ${esc(g.last_run.replace("T", " ").slice(0, 16))} UTC</span>` : ""}`;
}

const utc = (iso: string) => `${iso.replace("T", " ").slice(0, 16)} UTC`;

function phonesSection(d: Dashboard): string {
  const phones = d.phones ?? [];
  const list = phones.length
    ? `<ul>${phones.map((p) => `<li><strong>${esc(p.name)}</strong> <span class="muted">added ${esc(utc(p.created))}${p.last_seen ? `, last used ${esc(utc(p.last_seen))}` : ""}</span>
<form class="inline" method="post" action="/setup/phones/remove">${csrfField(d.csrf)}<input type="hidden" name="device_id" value="${esc(p.id)}">
<button class="danger" type="submit">Remove</button></form></li>`).join("")}</ul>`
    : `<p class="muted">No phones paired yet.</p>`;
  return `${list}
<p class="muted">To add a phone, open the FloatBoard app on your Mac, go to the Connectors tab and choose Pair a phone. Remove signs that phone out and deletes its passkey here.</p>`;
}

export function dashboardPage(d: Dashboard): string {
  const redirectURI = `${d.origin}/setup/google/callback`;
  const startHref = (hint?: string) => `/setup/google/start?csrf=${encodeURIComponent(d.csrf)}${hint ? `&hint=${encodeURIComponent(hint)}` : ""}`;
  const gmailList = d.gmail.length
    ? `<ul>${d.gmail.map((g) => `<li><strong>${esc(g.address)}</strong> — ${gmailStatus(g)}<br>
<a class="button secondary" href="${esc(startHref(g.address))}">Reconnect</a>
<form class="inline" method="post" action="/setup/gmail/remove">${csrfField(d.csrf)}<input type="hidden" name="source_id" value="${esc(g.id)}">
<button class="danger" type="submit">Remove</button></form></li>`).join("")}</ul>`
    : `<p class="muted">No Gmail accounts connected yet.</p>`;
  return layout("FloatBoard engine setup", `
<h1>FloatBoard engine setup</h1>
<p class="muted">Signed in as ${esc(d.name)}. This page holds only secrets and connections; rules, groups and lists live in the FloatBoard app.</p>
<form method="post" action="/setup/signout">${csrfField(d.csrf)}<button class="secondary" type="submit">Sign out</button></form>
${banner(d.notice, d.error)}

<section><h2>1. Google Cloud client</h2>
<p>Create an OAuth client of type <strong>Web application</strong> in your own Google Cloud project, enable the Gmail API,
and add this exact <strong>Authorized redirect URI</strong>:</p>
<p><code>${esc(redirectURI)}</code></p>
<p>Then, in Google Auth Platform, open <strong>Audience</strong> and press <strong>Publish app</strong> so its status is
<strong>In production</strong>. While it stays in Testing, Google expires Gmail sign-ins every 7 days and you would have to reconnect.
When you connect, Google warns that the app is unverified; that is expected for your own app: choose <strong>Advanced</strong>
and continue.</p>
<p>Status: ${d.googleClientId ? `<span class="ok">saved ✓</span> <span class="muted">client ID ${esc(d.googleClientId)}</span>` : `<span class="muted">not set</span>`}</p>
<form method="post" action="/setup/google/client">${csrfField(d.csrf)}
<label for="client_id">Client ID</label><input type="text" id="client_id" name="client_id" value="${esc(d.googleClientId ?? "")}" required autocomplete="off">
<label for="client_secret">Client secret${d.googleClientId ? " (leave blank to keep the saved one)" : ""}</label>
<input type="password" id="client_secret" name="client_secret" autocomplete="off"${d.googleClientId ? "" : " required"}>
<button type="submit">Save client</button></form></section>

<section><h2>2. Gmail accounts</h2>
${gmailList}
${d.googleClientId ? `<a class="button" href="${esc(startHref())}">Connect a Gmail account</a>` : `<p class="muted">Save the Google Cloud client first.</p>`}
</section>

<section><h2>3. Claude API key</h2>
<p>Status: ${d.hasClaudeKey ? `<span class="ok">saved ✓</span>` : `<span class="muted">not set</span>`}</p>
<form method="post" action="/setup/claude">${csrfField(d.csrf)}
<label for="anthropic_key">${d.hasClaudeKey ? "Replace key" : "Key"}</label>
<input type="password" id="anthropic_key" name="anthropic_key" autocomplete="off" required>
<button type="submit">Save key</button></form></section>

<section><h2>4. Telegram alerts</h2>
<p>Status: ${d.telegramLinked ? `<span class="ok">linked ✓</span>` : `<span class="muted">not linked</span>`}</p>
${d.telegramURL ? `<p><a class="button" href="${esc(d.telegramURL)}">Open Telegram and press Start</a></p><p class="muted">This link works once.</p>` : ""}
<form method="post" action="/setup/telegram">${csrfField(d.csrf)}<button class="secondary" type="submit">${d.telegramLinked ? "Link a different chat" : "Get Telegram link"}</button></form>
${d.telegramLinked ? `<form method="post" action="/setup/telegram/unlink">${csrfField(d.csrf)}<button class="secondary" type="submit">Unlink</button></form>` : ""}
<p class="muted">Create a bot with @BotFather (/newbot) and paste its token here; alerts then come from your bot instead of the shared one.</p>
${d.telegramBot ? `<p>Your bot: <strong>@${esc(d.telegramBot)}</strong> <span class="ok">saved ✓</span></p>
<form method="post" action="/setup/telegram/bot/remove">${csrfField(d.csrf)}<button class="danger" type="submit">Remove my bot</button></form>` : ""}
<form method="post" action="/setup/telegram/bot">${csrfField(d.csrf)}
<label for="bot_token">${d.telegramBot ? "Replace with another bot token" : "Your own bot token (optional)"}</label>
<input type="password" id="bot_token" name="bot_token" autocomplete="off" required>
<button type="submit">Save</button></form>
</section>

<section><h2>Phone alerts (ntfy app)</h2>
<p>Status: ${d.ntfyTopic ? `<span class="ok">on ✓</span>` : `<span class="muted">off</span>`}</p>
${d.ntfyTopic ? `<p>Subscribe address: <code>https://ntfy.sh/${esc(d.ntfyTopic)}</code></p>
<ol><li>Install the ntfy app on your Android phone or iPhone.</li><li>Tap +, then paste the topic name <code>${esc(d.ntfyTopic)}</code>.</li><li>On iPhone, allow notifications when asked.</li></ol>
<p class="muted">Anyone who knows the topic name can read the alerts, so keep it private. Press New topic if it leaks.</p>
<form method="post" action="/setup/ntfy/test">${csrfField(d.csrf)}<button type="submit">Send a test alert</button></form>
<form method="post" action="/setup/ntfy/new">${csrfField(d.csrf)}<button class="secondary" type="submit">New topic</button></form>
<form method="post" action="/setup/ntfy/off">${csrfField(d.csrf)}<button class="danger" type="submit">Turn off</button></form>`
: `<p class="muted">Urgent emails can also reach your phone through the free ntfy app. Alerts carry the task title, due date and sender, never the email text.</p>
<form method="post" action="/setup/ntfy/on">${csrfField(d.csrf)}<button type="submit">Turn on</button></form>`}
</section>

<section><h2>Phones</h2>
${phonesSection(d)}
</section>

<section><h2>5. Fathom meeting recaps</h2>
${d.fathomURL ? `<p>Paste this private webhook address into Fathom's settings:</p><p><code>${esc(d.fathomURL)}</code></p>
<p>Signing secret: ${d.fathomSecretSaved ? `<span class="ok">saved ✓</span> <span class="muted">only deliveries signed by Fathom are accepted</span>` : `<span class="muted">not set (any delivery to the address above is accepted)</span>`}</p>
<form method="post" action="/setup/fathom/secret">${csrfField(d.csrf)}<label for="fathom_secret">Fathom webhook secret (starts with whsec_)</label>
<input id="fathom_secret" name="fathom_secret" type="password" autocomplete="off" required>
<button type="submit">${d.fathomSecretSaved ? "Replace secret" : "Save secret"}</button></form>
<p>API key: ${d.fathomKeySaved ? `<span class="ok">saved ✓</span> <span class="muted">every hour the engine asks Fathom for meetings the webhook missed</span>` : `<span class="muted">not set (no hourly catch-up if a delivery is missed)</span>`}</p>
<form method="post" action="/setup/fathom/key">${csrfField(d.csrf)}<label for="fathom_key">Fathom API key</label>
<input id="fathom_key" name="fathom_key" type="password" autocomplete="off" required>
<button type="submit">${d.fathomKeySaved ? "Replace key" : "Save key"}</button></form>`
    : `<form method="post" action="/setup/fathom">${csrfField(d.csrf)}<button class="secondary" type="submit">Create webhook address</button></form>`}
</section>

<section><h2>6. Outlook (Chrome extension)</h2>
${outlookSection(d)}
</section>

<section><h2>How emails are judged</h2>
<p class="muted">Read-only. These are the shared rules Claude follows for everyone, plus the free checks done first. Your own rules in the FloatBoard app take priority.</p>
<h3>Rules Claude follows</h3>
<ul>${RULES.map((r) => `<li>${esc(r)}</li>`).join("")}</ul>
<h3>Free checks before Claude sees an email</h3>
<ul>${PRE_RULES.map((r) => `<li>${esc(r)}</li>`).join("")}</ul>
</section>

<section><h2>Connect to FloatBoard</h2>
${d.connectLink ? `<p>Opens the FloatBoard app on this Mac and adds this engine as the Email connector.</p>
<p><a class="button connect" href="${esc(d.connectLink)}">Connect to FloatBoard</a></p>`
    : `<p class="muted">Sign out and sign in again to get the Connect to FloatBoard link.</p>`}
</section>`);
}

function outlookSection(d: Dashboard): string {
  const o = d.outlook;
  const intro = `<p>For Outlook on the web when your organisation doesn't allow mail access for apps. The FloatBoard Chrome
extension reads the unread emails your signed-in Outlook tab shows and sends them here; they are judged like Gmail. It never
changes anything in Outlook.</p>
<p class="muted">It reads only what Outlook shows without scrolling, usually the newest 20 to 50 emails. On its first run it
picks up the unread emails from the last 7 days that are on screen; after that, new ones. Keep an Outlook tab open in Chrome:
if it hasn't reported for 2 working days, FloatBoard tells you.</p>`;
  if (!o) return `${intro}<form method="post" action="/setup/outlook">${csrfField(d.csrf)}<button class="secondary" type="submit">Set up Outlook</button></form>`;
  const status = !o.enabled ? `<span class="muted">paused</span>`
    : o.last_error ? `<span class="bad">needs attention</span> <span class="muted">${esc(o.last_error)}</span>`
    : o.last_run ? `<span class="ok">connected</span> <span class="muted">last report ${esc(o.last_run.replace("T", " ").slice(0, 16))} UTC</span>`
    : `<span class="muted">waiting for the extension's first report</span>`;
  const token = d.outlookToken ? `<p class="notice">Copy this token now. It is shown only once; only a fingerprint of it is kept.</p>
<label for="outlook_token">Ingest token</label><input type="text" id="outlook_token" readonly value="${esc(d.outlookToken)}" autocomplete="off">` : "";
  return `${intro}
<p>Mailbox: ${o.address ? `<strong>${esc(o.address)}</strong>` : `<span class="muted">set by the extension's first send</span>`}</p>
<p>Status: ${status}</p>
${token}
<p>To install it: build the extension (<code>npm install</code> and <code>node build.mjs</code> in
<code>connectors/outlook-web</code>), then in Chrome open Extensions, turn on Developer mode, choose Load unpacked and pick its
<code>dist</code> folder. In the extension's options paste this engine address and the token, then press Test connection.</p>
<p>Engine address: <code>${esc(d.origin)}</code></p>
<form method="post" action="/setup/outlook/rotate">${csrfField(d.csrf)}<button class="secondary" type="submit">New token</button></form>
<p class="muted">A new token stops the old one at once. Use it if the token was lost or shared.</p>`;
}

export function adminPage(d: { csrf: string; invite?: { name: string; link: string } | null; notice?: string | null; error?: string | null }): string {
  const invite = d.invite ? `<section><h2>Invite for ${esc(d.invite.name)}</h2>
<p>Send this link to ${esc(d.invite.name)}. Opening it on their Mac connects FloatBoard to this engine. It is shown only once.</p>
<p><a class="button connect" href="${esc(d.invite.link)}">Connect to FloatBoard</a></p>
<p><code>${esc(d.invite.link)}</code></p>
<p class="muted">The <code>key=</code> part is also how they sign in to this engine's setup page at /setup.</p></section>` : "";
  return layout("FloatBoard engine admin", `
<h1>FloatBoard engine admin</h1>
<form method="post" action="/setup/admin/signout">${csrfField(d.csrf)}<button class="secondary" type="submit">Sign out</button></form>
${banner(d.notice, d.error)}${invite}
<section><h2>Invite someone</h2>
<form method="post" action="/setup/admin/users">${csrfField(d.csrf)}
<label for="name">Name</label><input type="text" id="name" name="name" required maxlength="100" autocomplete="off">
<button type="submit">Create invite</button></form></section>`);
}

export const notFoundPage = () => messagePage("Not found", "There's nothing at this address.");
