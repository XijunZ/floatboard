// Runs the whole phone app script (APP_JS) against a permissive fake browser, so tab handover and account switches can be
// tested as they run rather than by reading the source. Every element is a forgiving stand-in: unknown properties read as
// further stand-ins, calls do nothing, and listeners are kept so a test can fire them.
import { APP_JS } from "../../src/phone/client";

type Listener = (e: any) => any;

export function fakeElement(tag = "div", onSet?: (k: string | symbol, v: any) => void): any {
  const props: Record<string | symbol, any> = { tagName: tag.toUpperCase(), hidden: false, disabled: false, value: "", textContent: "", innerHTML: "", className: "", id: "", style: {}, dataset: {}, children: [] as any[] };
  const listeners: Record<string, Listener[]> = {};
  const classes = new Set<string>();
  const self: any = new Proxy(function () {}, {
    get(_t, k) {
      if (k in props) return props[k];
      if (k === "then" || k === Symbol.iterator || k === Symbol.toPrimitive) return undefined;
      if (k === "listeners") return listeners;
      if (k === "addEventListener") return (type: string, fn: Listener) => { (listeners[type] ??= []).push(fn); };
      if (k === "removeEventListener") return (type: string, fn: Listener) => { listeners[type] = (listeners[type] ?? []).filter((f) => f !== fn); };
      if (k === "fire") return (type: string, e: any = {}) => (listeners[type] ?? []).map((f) => f({ preventDefault() {}, stopPropagation() {}, target: self, ...e }));
      if (k === "appendChild" || k === "append" || k === "prepend" || k === "insertBefore") return (...c: any[]) => { props.children.push(...c); return c[0]; };
      if (k === "replaceChildren") return (...c: any[]) => { props.children = c; };
      if (k === "querySelectorAll" || k === "getElementsByTagName") return () => [];
      if (k === "querySelector" || k === "closest") return () => null;
      if (k === "classList") return { add: (...c: string[]) => c.forEach((x) => classes.add(x)), remove: (...c: string[]) => c.forEach((x) => classes.delete(x)), toggle: (c: string, on?: boolean) => { if (on ?? !classes.has(c)) classes.add(c); else classes.delete(c); }, contains: (c: string) => classes.has(c) };
      if (k === "getAttribute") return (a: string) => props["attr:" + a] ?? null;
      if (k === "setAttribute") return (a: string, v: any) => { props["attr:" + a] = String(v); };
      if (k === "firstElementChild" || k === "parentNode" || k === "parentElement" || k === "lastElementChild") return fakeElement();
      if (k === "isConnected") return true;
      if (k === "getBoundingClientRect") return () => ({ top: 0, left: 0, width: 0, height: 0, bottom: 0, right: 0 });
      if (typeof k === "string" && /^(offset|client|scroll)/.test(k)) return 0;
      return () => undefined;   // any other method: does nothing
    },
    set(_t, k, v) { props[k] = v; if (onSet) onSet(k, v); return true; },
    apply() { return undefined; },
  });
  return self;
}

export function fakeLocks() {
  const held: Record<string, boolean> = {}, waiting: Record<string, (() => void)[]> = {};
  return {
    request(name: string, opts: any, fn: (l: any) => any) {
      const run = () => { held[name] = true; return Promise.resolve(fn({ name })).finally(() => { held[name] = false; const next = (waiting[name] ?? []).shift(); if (next) next(); }); };
      if (!held[name]) return run();
      if (opts && opts.ifAvailable) return Promise.resolve(fn(null));
      return new Promise((resolve, reject) => {
        const go = () => resolve(run());
        (waiting[name] ??= []).push(go);
        opts?.signal?.addEventListener("abort", () => { waiting[name] = waiting[name].filter((g) => g !== go); reject(new Error("AbortError")); });
      });
    },
  };
}

// BroadcastChannels of one browser: a message reaches every other channel of the same name.
export function fakeChannels() {
  const all: any[] = [];
  return class {
    name: string; onmessage: Listener | null = null;
    constructor(name: string) { this.name = name; all.push(this); }
    postMessage(data: any) { all.filter((c) => c !== this && c.name === this.name).forEach((c) => c.onmessage && c.onmessage({ data })); }
    close() {}
  };
}

export type Reply = { status: number; body: any } | Promise<{ status: number; body: any }>;

// One tab of the app. `storage` is the browser's localStorage, shared by the tabs of one test; `reply(path, init)` answers
// fetch (a Promise held back by the test is a slow answer).
export function runApp(o: { storage: Map<string, string>; locks: any; Channel: any; reply: (path: string, init: any) => Reply; storageFails?: () => boolean; push?: { ready: Promise<any> } }) {
  const els: Record<string, any> = {};
  const created: any[] = [];
  const byId = (id: string) => (els[id] ??= fakeElement());
  const selected: Record<string, any> = {};
  const toasts: string[] = [];
  els.toast = fakeElement("div", (k, v) => { if (k === "textContent" && v) toasts.push(v); });
  els["sync-note"] = fakeElement("div", (k, v) => { if (k === "textContent" && v) toasts.push(v); });
  const document: any = {
    getElementById: byId,
    querySelector: (s: string) => (selected[s] ??= fakeElement()),
    querySelectorAll: () => [],
    createElement: (t: string) => { const e = fakeElement(t); created.push(e); return e; },
    createTextNode: (t: string) => ({ textContent: t }),
    addEventListener: () => {}, removeEventListener: () => {},
    visibilityState: "visible", body: fakeElement("body"), documentElement: fakeElement("html"), activeElement: null,
  };
  const localStorage = {
    getItem: (k: string) => (o.storage.has(k) ? o.storage.get(k)! : null),
    setItem: (k: string, v: string) => { if (o.storageFails && o.storageFails()) throw new Error("QuotaExceededError"); o.storage.set(k, String(v)); },
    removeItem: (k: string) => { o.storage.delete(k); },
  };
  const session = new Map<string, string>();
  const sessionStorage = { getItem: (k: string) => session.get(k) ?? null, setItem: (k: string, v: string) => { session.set(k, v); }, removeItem: (k: string) => { session.delete(k); } };
  const location = { hash: "", search: "", pathname: "/app/", href: "https://example.test/app/", origin: "https://example.test", reload: () => { (location as any).reloaded = true; } };
  const fetch = async (path: string, init: any) => {
    const r = await o.reply(path, init);
    return { status: r.status, ok: r.status >= 200 && r.status < 300, json: async () => r.body };
  };
  const navigator: any = { userAgent: "test", platform: "test", maxTouchPoints: 0, locks: o.locks, onLine: true, vibrate: () => true };
  const window: any = { addEventListener: () => {}, scrollTo: () => {}, matchMedia: () => ({ matches: false }), innerHeight: 800, innerWidth: 400 };
  if (o.push) {   // a browser with push: the service worker's registration comes when the test lets it
    navigator.serviceWorker = { ready: o.push.ready, controller: null, addEventListener: () => {}, register: () => Promise.resolve() };
    window.PushManager = function () {};
    window.Notification = { permission: "granted" };
  }
  const timers: any[] = [];
  const g: Record<string, any> = {
    window, document, navigator, localStorage, sessionStorage, location, fetch,
    history: { replaceState: () => {} }, BroadcastChannel: o.Channel, crypto: (globalThis as any).crypto,
    setInterval: () => 0, clearInterval: () => {},
    // Short waits run at once; a wait of a second or more (retries, give-ups, undo windows) never comes during a test.
    setTimeout: (f: () => void, ms: number) => { if ((ms ?? 0) >= 1000) return 0; const t = setTimeout(f, Math.min(ms ?? 0, 5)); timers.push(t); return t; },
    clearTimeout: (t: any) => clearTimeout(t),
    matchMedia: window.matchMedia, PublicKeyCredential: undefined, Notification: window.Notification, requestAnimationFrame: (f: () => void) => setTimeout(f, 0),
    getComputedStyle: () => ({}), performance: (globalThis as any).performance, alert: () => {}, confirm: () => true,
  };
  const names = Object.keys(g);
  // eslint-disable-next-line no-new-func
  new Function(...names, APP_JS)(...names.map((n) => g[n]));
  return { els, byId, toasts, location, created, find: (id: string) => [...created].reverse().find((e) => e.id === id), stop: () => timers.forEach((t) => clearTimeout(t)) };
}
