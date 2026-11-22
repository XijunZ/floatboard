// Saving the engine and key (the options page). Round 43: a queue left by an older version records no engine, so before
// new settings are written it is bound to the settings in use until now, in the same write: it can never be read as
// the new engine's, whatever the service worker is doing.
import type { Settings } from "./messages";
import { bindLegacyState, engineIdentity } from "./queue";

/** chrome.storage.local, as far as saving settings needs it. */
export interface SettingsArea {
  get(keys: string[]): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
}

export async function saveSettings(area: SettingsArea, next: Settings): Promise<void> {
  const cur = await area.get(["settings", "queue"]);
  const old = cur.settings as Settings | undefined;
  const queue = old?.engine && old?.token ? bindLegacyState(cur.queue, await engineIdentity(old)) : undefined;
  await area.set(queue ? { settings: next, queue } : { settings: next });
}
