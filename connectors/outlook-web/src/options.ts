import { OUTLOOK_MATCHES } from "./hosts";
import type { ScrubRequest, ScrubResponse } from "./messages";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

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
  const status = $("sampleStatus");
  const tab = await outlookTab();
  if (tab?.id === undefined) {
    status.textContent = "Open Outlook in a tab first.";
    return;
  }
  try {
    const req: ScrubRequest = { type: "scrubSample" };
    const res = (await chrome.tabs.sendMessage(tab.id, req)) as ScrubResponse | undefined;
    if (!res?.html) throw new Error("no sample");
    download(`outlook-sample-${new Date().toISOString().slice(0, 10)}.html`, res.html);
    status.textContent = "Saved.";
  } catch {
    status.textContent = "Couldn't read the Outlook tab. Reload it and try again.";
  }
}

$("sample").addEventListener("click", () => void saveSample());
