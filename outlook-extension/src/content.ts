// Runs in the Outlook tab. Only reads the page and reports what it saw; it never clicks, scrolls, opens a message or
// changes read state, and it never talks to the engine (the service worker owns the one queue).
import type { PageReadMessage, ReadRequest, ScrubRequest, ScrubResponse } from "./messages";
import { readPage } from "./parse";
import { scrubSample } from "./scrub";

const QUIET_MS = 30_000;
let timer: ReturnType<typeof setTimeout> | undefined;

function report(): void {
  const msg: PageReadMessage = { type: "pageRead", read: readPage(document, new Date()) };
  chrome.runtime.sendMessage(msg).catch(() => {
    // The service worker is starting up or the extension was reloaded; the next read or alarm catches up.
  });
}

// Outlook re-renders often; read at most once per 30 seconds after the page changes.
new MutationObserver(() => {
  if (timer !== undefined) return;
  timer = setTimeout(() => {
    timer = undefined;
    report();
  }, QUIET_MS);
}).observe(document.documentElement, { childList: true, subtree: true, characterData: true });

chrome.runtime.onMessage.addListener((msg: ReadRequest | ScrubRequest, _sender, sendResponse) => {
  if (msg?.type === "read") {
    report();
    sendResponse({ ok: true });
  } else if (msg?.type === "scrubSample") {
    const res: ScrubResponse = { html: scrubSample(document) };
    sendResponse(res);
  }
  return false;
});

report();
