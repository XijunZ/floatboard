// Service worker: owns the one queue, sends it to the engine, and keeps the toolbar badge current. Content scripts in
// any number of Outlook tabs only report what they read.
import { OUTLOOK_MATCHES } from "./hosts";
import type { PageReadMessage, ReadRequest, SaveSettingsMessage, Settings } from "./messages";
import {
  badgeFor,
  engineIdentity,
  flush,
  NOT_SET_UP,
  Queue,
  type IngestConfig,
  type PageKind,
  type StorageArea,
} from "./queue";

const local: StorageArea = {
  get: async (key) => (await chrome.storage.local.get(key))[key],
  set: (key, value) => chrome.storage.local.set({ [key]: value }),
  setMany: (items) => chrome.storage.local.set(items),
};
const queue = new Queue(local);
const COLORS = { green: "#2e9d4f", blue: "#1a73e8", grey: "#8e8e93", red: "#d93025" } as const;
const READ_ALARM = "read";
const RETRY_ALARM = "retry";

async function settings(): Promise<IngestConfig | undefined> {
  const s = (await chrome.storage.local.get("settings")).settings as Settings | undefined;
  if (!s?.engine || !s?.token) return undefined;
  const allowed = await chrome.permissions.contains({ origins: [`${new URL(s.engine).origin}/*`] });
  return allowed ? s : undefined;
}

// What each Outlook tab shows, kept in session storage so a restarted worker still knows.
async function pageKinds(): Promise<Record<string, PageKind>> {
  return ((await chrome.storage.session.get("pages")).pages as Record<string, PageKind> | undefined) ?? {};
}

async function setPageKind(tabId: number, kind: PageKind | undefined): Promise<PageKind> {
  const pages = await pageKinds();
  if (kind) pages[tabId] = kind;
  else delete pages[tabId];
  await chrome.storage.session.set({ pages });
  return overallPage(pages);
}

function overallPage(pages: Record<string, PageKind>): PageKind {
  const kinds = Object.values(pages);
  for (const k of ["inbox", "unrecognised", "signedOut", "notInbox"] as const) if (kinds.includes(k)) return k;
  return "none";
}

async function updateBadge(): Promise<void> {
  const [status, cfg, page] = await Promise.all([queue.status(), settings(), pageKinds().then(overallPage)]);
  const badge = badgeFor(cfg ? status : { ...status, problem: status.problem ?? NOT_SET_UP }, page);
  await chrome.action.setBadgeText({ text: badge.text });
  await chrome.action.setBadgeBackgroundColor({ color: COLORS[badge.color] });
  await chrome.action.setTitle({ title: badge.title });
}

/** Sends the queue. `force` ignores the back-off (every page read is also a retry). */
async function send(force: boolean): Promise<void> {
  const cfg = await settings();
  if (cfg && (force || (await queue.canSend(new Date())))) {
    await flush(queue, cfg, (url, init) => fetch(url, init), () => new Date());
    const next = await queue.nextAttempt();
    if (next) await chrome.alarms.create(RETRY_ALARM, { when: Math.max(next.getTime(), Date.now() + 30_000) });
  }
  await updateBadge();
}

async function onPageRead(tabId: number, msg: PageReadMessage): Promise<void> {
  const { read } = msg;
  const overall = await setPageKind(tabId, read.kind);
  await queue.setPageProblem(overall === "unrecognised" && read.kind === "unrecognised" ? read.reason : undefined);
  if (read.kind === "inbox") {
    // Rows go into the queue of the engine saved now (round 41); rows without a mailbox wait until seen with one.
    const cfg = await settings();
    await queue.add(read.rows, new Date(), read.mailbox, cfg ? await engineIdentity(cfg) : undefined);
  }
  await send(true);
}

async function askTabsToRead(): Promise<void> {
  const tabs = await chrome.tabs.query({ url: OUTLOOK_MATCHES });
  const req: ReadRequest = { type: "read" };
  await Promise.all(tabs.map((t) => (t.id === undefined ? undefined : chrome.tabs.sendMessage(t.id, req).catch(() => undefined))));
}

async function ensureAlarm(): Promise<void> {
  if (!(await chrome.alarms.get(READ_ALARM))) await chrome.alarms.create(READ_ALARM, { periodInMinutes: 5 });
}

/** Settings from the options page (round 44), saved with the queue in one write; a content script can't send them. */
async function onSaveSettings(msg: SaveSettingsMessage): Promise<{ ok: boolean; error?: string }> {
  const next = msg.settings;
  if (typeof next?.engine !== "string" || typeof next?.token !== "string" || !next.engine || !next.token) return { ok: false, error: "engine and token needed" };
  const old = (await chrome.storage.local.get("settings")).settings as Settings | undefined;
  const previous = old?.engine && old?.token ? await engineIdentity(old) : undefined;
  await queue.saveSettings({ engine: next.engine, token: next.token }, previous);
  return { ok: true };
}

chrome.runtime.onMessage.addListener((msg: PageReadMessage | SaveSettingsMessage, sender, respond) => {
  if (msg?.type === "pageRead" && sender.tab?.id !== undefined) void onPageRead(sender.tab.id, msg);
  if (msg?.type === "saveSettings") {
    const fromPage = sender.tab !== undefined && !String(sender.tab.url ?? "").startsWith("chrome-extension://");
    if (fromPage) { respond({ ok: false, error: "not allowed" }); return false; }
    void onSaveSettings(msg).then(respond, (e) => respond({ ok: false, error: String(e) }));
    return true;   // answered asynchronously
  }
  return false;
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === READ_ALARM) void askTabsToRead().then(() => send(false));
  else if (alarm.name === RETRY_ALARM) void send(false);
});

chrome.tabs.onRemoved.addListener((tabId) => {
  void setPageKind(tabId, undefined).then(updateBadge);
});

/**
 * The engine a stored queue from an older version belongs to, only where that is certain (round 43): the settings a
 * change replaced (oldValue), or the settings in place when this version is installed over the older one. A worker
 * woken for any other reason never guesses from the settings it finds (they may already be new): a queue still
 * unbound when an engine is bound is parked and never sent. Settings saved from the options page bind it in the same
 * write (onSaveSettings), so the change event's adoption afterwards finds it bound and does nothing.
 */
async function adoptLegacyQueue(cfg: Pick<Settings, "engine" | "token"> | undefined): Promise<void> {
  if (cfg?.engine && cfg?.token) await queue.adoptLegacy(await engineIdentity({ engine: cfg.engine, token: cfg.token }));
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local" || !changes.settings) return;
  // The previous settings first: an older queue is theirs, never the new engine's.
  const before = changes.settings.oldValue as Settings | undefined;
  void adoptLegacyQueue(before).then(() => queue.resetMailbox()).then(() => send(true));
});

chrome.runtime.onInstalled.addListener((details) => {
  const adopt = details?.reason === "update"
    ? chrome.storage.local.get("settings").then((r) => adoptLegacyQueue(r.settings as Settings | undefined)).catch(() => undefined)
    : Promise.resolve();
  void adopt.then(() => ensureAlarm()).then(updateBadge);
});
chrome.runtime.onStartup.addListener(() => void ensureAlarm().then(updateBadge));
void ensureAlarm();
