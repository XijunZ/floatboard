import type { PageRead } from "./parse";

/** Content script to service worker: what the Outlook page shows now. */
export type PageReadMessage = { type: "pageRead"; read: PageRead };
/** Options page to service worker (round 44): new settings, saved by the worker together with the queue. */
export type SaveSettingsMessage = { type: "saveSettings"; settings: Settings };
/** Service worker or options page to content script. */
export type ReadRequest = { type: "read" };
export type ScrubRequest = { type: "scrubSample" };
export type ScrubResponse = { html: string };
/** Saved in chrome.storage.local (never synced). */
export type Settings = { engine: string; token: string };
