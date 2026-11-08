import { OUTLOOK_MATCHES } from "./hosts";
import type { ScrubRequest, ScrubResponse, Settings } from "./messages";
import { postIngest } from "./queue";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const engineInput = $<HTMLInputElement>("engine");
const tokenInput = $<HTMLInputElement>("token");
const status = $("status");

/** The engine origin, or undefined when the address isn't usable. */
function engineOrigin(value: string): string | undefined {
  try {
    const u = new URL(value.trim());
    const local = u.hostname === "localhost" || u.hostname === "127.0.0.1";
    if (u.protocol === "https:" || (u.protocol === "http:" && local)) return u.origin;
  } catch {
    // fall through
  }
  return undefined;
}

async function load(): Promise<void> {
  const s = (await chrome.storage.local.get("settings")).settings as Settings | undefined;
  if (s) {
    engineInput.value = s.engine;
    tokenInput.value = s.token;
  }
}

function save(): void {
  const origin = engineOrigin(engineInput.value);
  const token = tokenInput.value.trim();
  if (!origin) {
    status.textContent = "Enter the engine address, starting with https://";
    return;
  }
  if (!token) {
    status.textContent = "Enter the ingest token.";
    return;
  }
  // Ask for access to exactly this engine. This must run straight from the click.
  chrome.permissions.request({ origins: [`${origin}/*`] }, (granted) => {
    if (!granted) {
      status.textContent = "Chrome needs permission to reach the engine. Press Save again and allow it.";
      return;
    }
    void (async () => {
      const old = (await chrome.storage.local.get("settings")).settings as Settings | undefined;
      const oldOrigin = old && engineOrigin(old.engine);
      if (oldOrigin && oldOrigin !== origin) await chrome.permissions.remove({ origins: [`${oldOrigin}/*`] });
      const settings: Settings = { engine: origin, token };
      await chrome.storage.local.set({ settings });
      status.textContent = "Saved.";
    })();
  });
}

async function testConnection(): Promise<void> {
  const origin = engineOrigin(engineInput.value);
  const token = tokenInput.value.trim();
  if (!origin || !token) {
    status.textContent = "Enter the engine address and token first.";
    return;
  }
  if (!(await chrome.permissions.contains({ origins: [`${origin}/*`] }))) {
    status.textContent = "Press Save first so Chrome can reach the engine.";
    return;
  }
  status.textContent = "Testing...";
  const result = await postIngest({ engine: origin, token }, { items: [] }, (url, init) => fetch(url, init));
  status.textContent =
    result === "ok" ? "OK" : result === "rejected" ? "Key rejected" : result === "wrongMailbox" ? "OK" : "Engine unreachable";
}

async function outlookTab(): Promise<chrome.tabs.Tab | undefined> {
  const tabs = await chrome.tabs.query({ url: OUTLOOK_MATCHES });
  return tabs.find((t) => t.active) ?? tabs.sort((a, b) => (b.lastAccessed ?? 0) - (a.lastAccessed ?? 0))[0];
}

function download(name: string, html: string): void {
  const url = URL.createObjectURL(new Blob([html], { type: "text/html" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

async function saveSample(): Promise<void> {
  const sampleStatus = $("sampleStatus");
  const tab = await outlookTab();
  if (tab?.id === undefined) {
    sampleStatus.textContent = "Open Outlook in a tab first.";
    return;
  }
  try {
    const req: ScrubRequest = { type: "scrubSample" };
    const res = (await chrome.tabs.sendMessage(tab.id, req)) as ScrubResponse | undefined;
    if (!res?.html) throw new Error("no sample");
    download(`outlook-sample-${new Date().toISOString().slice(0, 10)}.html`, res.html);
    sampleStatus.textContent = "Saved.";
  } catch {
    sampleStatus.textContent = "Couldn't read the Outlook tab. Reload it and try again.";
  }
}

$("save").addEventListener("click", save);
$("test").addEventListener("click", () => void testConnection());
$("sample").addEventListener("click", () => void saveSample());
void load();
