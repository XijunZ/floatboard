// The web platform pieces the engine needs, for running it inside the Mac app's JavaScriptCore (Mac only mode,
// docs/architecture.md C2). Everything that touches the outside world goes through the host object `__fb`, which the
// Mac app provides: network (`fetch`), timers, randomness, hashing/encryption, and the local SQLite database.
// Loaded before the engine; plain JavaScript on purpose (the engine's own types describe Cloudflare Workers).
import "core-js/actual/url";
import "core-js/actual/url-search-params";

const host = globalThis.__fb;
const g = globalThis;

// ---- console --------------------------------------------------------------------------------------------------------
const fmt = (args) => args.map((a) => (typeof a === "string" ? a : (() => { try { return JSON.stringify(a); } catch { return String(a); } })())).join(" ");
g.console = { log: (...a) => host.log("info", fmt(a)), info: (...a) => host.log("info", fmt(a)), warn: (...a) => host.log("warning", fmt(a)),
  error: (...a) => host.log("error", fmt(a)), debug: () => {} };

// ---- timers ---------------------------------------------------------------------------------------------------------
g.setTimeout = (fn, ms, ...args) => host.setTimeout(() => fn(...args), Math.max(0, Number(ms) || 0));
g.clearTimeout = (id) => { if (id != null) host.clearTimeout(id); };
g.setInterval = () => { throw new Error("setInterval is not available"); };
g.queueMicrotask ??= (fn) => Promise.resolve().then(fn);

// ---- bytes, text and base64 -----------------------------------------------------------------------------------------
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const B64I = Object.fromEntries([...B64].map((c, i) => [c, i]));
function bytesToB64(u8) {
  let s = "";
  for (let i = 0; i < u8.length; i += 3) {
    const a = u8[i], b = u8[i + 1], c = u8[i + 2];
    s += B64[a >> 2] + B64[((a & 3) << 4) | ((b ?? 0) >> 4)] + (b === undefined ? "=" : B64[((b & 15) << 2) | ((c ?? 0) >> 6)]) + (c === undefined ? "=" : B64[c & 63]);
  }
  return s;
}
function b64ToBytes(s) {
  s = String(s).replace(/[\s=]/g, "");
  const out = new Uint8Array(Math.floor((s.length * 3) / 4));
  let o = 0;
  for (let i = 0; i < s.length; i += 4) {
    const n = (B64I[s[i]] << 18) | (B64I[s[i + 1]] << 12) | ((B64I[s[i + 2]] ?? 0) << 6) | (B64I[s[i + 3]] ?? 0);
    out[o++] = (n >> 16) & 255;
    if (s[i + 2] !== undefined) out[o++] = (n >> 8) & 255;
    if (s[i + 3] !== undefined) out[o++] = n & 255;
  }
  return out.subarray(0, o);
}
g.btoa = (s) => {
  const str = String(s), u8 = new Uint8Array(str.length);
  for (let i = 0; i < str.length; i++) {
    const c = str.charCodeAt(i);
    if (c > 255) throw new Error("btoa: character out of range");
    u8[i] = c;
  }
  return bytesToB64(u8);
};
g.atob = (s) => { const u8 = b64ToBytes(s); let r = ""; for (const b of u8) r += String.fromCharCode(b); return r; };

class TextEncoderImpl {
  get encoding() { return "utf-8"; }
  encode(str = "") {
    const out = [];
    for (const ch of String(str)) {
      let c = ch.codePointAt(0);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
  }
}
class TextDecoderImpl {
  constructor(label = "utf-8") { this.encoding = String(label).toLowerCase(); }
  decode(buf) {
    if (buf == null) return "";
    const u8 = buf instanceof Uint8Array ? buf : ArrayBuffer.isView(buf) ? new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength) : new Uint8Array(buf);
    let s = "", i = 0;
    while (i < u8.length) {
      const b = u8[i++];
      let c;
      if (b < 0x80) c = b;
      else if (b >= 0xf0) c = ((b & 7) << 18) | ((u8[i++] & 63) << 12) | ((u8[i++] & 63) << 6) | (u8[i++] & 63);
      else if (b >= 0xe0) c = ((b & 15) << 12) | ((u8[i++] & 63) << 6) | (u8[i++] & 63);
      else if (b >= 0xc0) c = ((b & 31) << 6) | (u8[i++] & 63);
      else c = 0xfffd;
      s += String.fromCodePoint(c);
    }
    return s;
  }
}
g.TextEncoder = TextEncoderImpl;
g.TextDecoder = TextDecoderImpl;
const enc = new TextEncoderImpl(), dec = new TextDecoderImpl();
const toBytes = (d) => d instanceof Uint8Array ? d : ArrayBuffer.isView(d) ? new Uint8Array(d.buffer, d.byteOffset, d.byteLength)
  : d instanceof ArrayBuffer ? new Uint8Array(d) : enc.encode(String(d));

// ---- crypto ---------------------------------------------------------------------------------------------------------
class CryptoKeyImpl { constructor(raw, algorithm, usages) { this._raw = raw; this.algorithm = algorithm; this.usages = usages; this.type = "secret"; this.extractable = false; } }
const algName = (a) => (typeof a === "string" ? a : a?.name ?? "").toUpperCase();
const hashName = (h) => (typeof h === "string" ? h : h?.name ?? "SHA-256").toUpperCase();
const unsupported = (what) => Promise.reject(new Error(`${what} is not available on this Mac`));
g.crypto = {
  getRandomValues(arr) { const r = b64ToBytes(host.random(arr.byteLength)); new Uint8Array(arr.buffer, arr.byteOffset, arr.byteLength).set(r); return arr; },
  randomUUID() { return host.uuid(); },
  subtle: {
    digest: async (alg, data) => b64ToBytes(host.digest(hashName(alg), bytesToB64(toBytes(data)))).buffer.slice(0),
    importKey: async (format, keyData, alg, _extractable, usages) => {
      if (format !== "raw") return unsupported(`importKey(${format})`);
      const a = algName(alg);
      if (a !== "AES-GCM" && a !== "HMAC") return unsupported(`importKey(${a})`);
      return new CryptoKeyImpl(new Uint8Array(toBytes(keyData)), a === "HMAC" ? { name: "HMAC", hash: { name: hashName(alg.hash) } } : { name: "AES-GCM" }, usages);
    },
    encrypt: async (alg, key, data) => {
      const out = host.aesGcm(true, bytesToB64(key._raw), bytesToB64(toBytes(alg.iv)), bytesToB64(toBytes(data)));
      if (out == null) throw new Error("encrypt failed");
      return b64ToBytes(out).buffer.slice(0);
    },
    decrypt: async (alg, key, data) => {
      const out = host.aesGcm(false, bytesToB64(key._raw), bytesToB64(toBytes(alg.iv)), bytesToB64(toBytes(data)));
      if (out == null) throw new Error("decrypt failed");
      return b64ToBytes(out).buffer.slice(0);
    },
    sign: async (alg, key, data) => {
      if (algName(alg) !== "HMAC") return unsupported(`sign(${algName(alg)})`);
      return b64ToBytes(host.hmac(key.algorithm.hash.name, bytesToB64(key._raw), bytesToB64(toBytes(data)))).buffer.slice(0);
    },
    verify: async (alg, key, sig, data) => {
      const mac = new Uint8Array(await g.crypto.subtle.sign(alg, key, data)), s = toBytes(sig);
      if (mac.length !== s.length) return false;
      let d = 0; for (let i = 0; i < s.length; i++) d |= mac[i] ^ s[i];
      return d === 0;
    },
    generateKey: () => unsupported("generateKey"),
    exportKey: () => unsupported("exportKey"),
    deriveBits: () => unsupported("deriveBits"),
    deriveKey: () => unsupported("deriveKey"),
  },
};

// ---- abort ----------------------------------------------------------------------------------------------------------
class EventTargetImpl {
  constructor() { this._l = {}; }
  addEventListener(t, fn) { (this._l[t] ??= []).push(fn); }
  removeEventListener(t, fn) { this._l[t] = (this._l[t] ?? []).filter((f) => f !== fn); }
  dispatchEvent(e) { for (const fn of this._l[e.type] ?? []) fn.call(this, e); return true; }
}
class AbortSignalImpl extends EventTargetImpl {
  constructor() { super(); this.aborted = false; this.reason = undefined; this.onabort = null; }
  throwIfAborted() { if (this.aborted) throw this.reason; }
  static timeout(ms) { const c = new AbortControllerImpl(); g.setTimeout(() => c.abort(new Error("timeout")), ms); return c.signal; }
  static abort(r) { const c = new AbortControllerImpl(); c.abort(r); return c.signal; }
  static any(signals) { const c = new AbortControllerImpl(); for (const s of signals) s.addEventListener("abort", () => c.abort(s.reason)); return c.signal; }
}
class AbortControllerImpl {
  constructor() { this.signal = new AbortSignalImpl(); }
  abort(reason) {
    if (this.signal.aborted) return;
    this.signal.aborted = true;
    this.signal.reason = reason ?? Object.assign(new Error("The operation was aborted"), { name: "AbortError" });
    const e = { type: "abort", target: this.signal };
    this.signal.onabort?.(e);
    this.signal.dispatchEvent(e);
  }
}
g.EventTarget ??= EventTargetImpl;
g.Event ??= class { constructor(type) { this.type = type; } };
g.AbortController = AbortControllerImpl;
g.AbortSignal = AbortSignalImpl;

// ---- Headers, Request, Response, fetch ------------------------------------------------------------------------------
class HeadersImpl {
  constructor(init) {
    this._m = new Map();
    if (init instanceof HeadersImpl) for (const [k, v] of init) this.append(k, v);
    else if (Array.isArray(init)) for (const [k, v] of init) this.append(k, v);
    else if (init && typeof init === "object") for (const k of Object.keys(init)) if (init[k] !== undefined) this.append(k, init[k]);
  }
  append(k, v) { k = String(k).toLowerCase(); const cur = this._m.get(k); this._m.set(k, cur === undefined ? String(v) : k === "set-cookie" ? cur + "\n" + v : cur + ", " + v); }
  set(k, v) { this._m.set(String(k).toLowerCase(), String(v)); }
  get(k) { const v = this._m.get(String(k).toLowerCase()); return v === undefined ? null : String(k).toLowerCase() === "set-cookie" ? v.split("\n").join(", ") : v; }
  getSetCookie() { const v = this._m.get("set-cookie"); return v === undefined ? [] : v.split("\n"); }
  has(k) { return this._m.has(String(k).toLowerCase()); }
  delete(k) { this._m.delete(String(k).toLowerCase()); }
  forEach(fn, self) { for (const [k, v] of this) fn.call(self, v, k, this); }
  *entries() { for (const [k, v] of [...this._m].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
    if (k === "set-cookie") for (const c of v.split("\n")) yield [k, c]; else yield [k, v]; } }
  *keys() { for (const [k] of this.entries()) yield k; }
  *values() { for (const [, v] of this.entries()) yield v; }
  [Symbol.iterator]() { return this.entries(); }
}

/** A body as bytes: string, bytes, URLSearchParams, or null. */
function bodyBytes(body) {
  if (body == null) return null;
  if (typeof body === "string") return enc.encode(body);
  if (body instanceof URLSearchParams) return enc.encode(body.toString());
  if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) return toBytes(body);
  if (body instanceof BlobImpl) return body._bytes;
  return enc.encode(String(body));
}
class BodyMixin {
  _initBody(body) { this._bytes = bodyBytes(body); this.bodyUsed = false; }
  get body() { return this._bytes == null ? null : { locked: false, getReader: () => { let done = false; return { read: async () => done ? { done: true } : (done = true, { done: false, value: this._bytes }), releaseLock() {}, cancel: async () => {} }; } }; }
  async arrayBuffer() { this.bodyUsed = true; const b = this._bytes ?? new Uint8Array(0); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); }
  async bytes() { return new Uint8Array(await this.arrayBuffer()); }
  async text() { this.bodyUsed = true; return this._bytes == null ? "" : dec.decode(this._bytes); }
  async json() { return JSON.parse(await this.text()); }
  async formData() {
    const p = new URLSearchParams(await this.text()), f = new FormDataImpl();
    for (const [k, v] of p) f.append(k, v);
    return f;
  }
  async blob() { return new BlobImpl([this._bytes ?? new Uint8Array(0)], { type: this.headers.get("content-type") ?? "" }); }
}
class RequestImpl extends BodyMixin {
  constructor(input, init = {}) {
    super();
    const base = input instanceof RequestImpl ? input : null;
    this.url = base ? base.url : String(input);
    this.method = String(init.method ?? base?.method ?? "GET").toUpperCase();
    this.headers = new HeadersImpl(init.headers ?? base?.headers);
    this.signal = init.signal ?? base?.signal ?? new AbortSignalImpl();
    this.redirect = init.redirect ?? base?.redirect ?? "follow";
    this.cf = undefined;
    this._initBody(init.body !== undefined ? init.body : base ? base._bytes : null);
    if (typeof init.body === "string" && !this.headers.has("content-type")) this.headers.set("content-type", "text/plain;charset=UTF-8");
    if (init.body instanceof URLSearchParams && !this.headers.has("content-type")) this.headers.set("content-type", "application/x-www-form-urlencoded;charset=UTF-8");
  }
  clone() { return new RequestImpl(this); }
}
class ResponseImpl extends BodyMixin {
  constructor(body = null, init = {}) {
    super();
    this.status = init.status ?? 200;
    this.statusText = init.statusText ?? "";
    this.headers = new HeadersImpl(init.headers);
    this.ok = this.status >= 200 && this.status < 300;
    this.redirected = false;
    this.type = "default";
    this.url = init.url ?? "";
    this._initBody(body);
    if (typeof body === "string" && !this.headers.has("content-type")) this.headers.set("content-type", "text/plain;charset=UTF-8");
  }
  clone() { return new ResponseImpl(this._bytes, { status: this.status, statusText: this.statusText, headers: this.headers, url: this.url }); }
  static json(data, init = {}) { const h = new HeadersImpl(init.headers); if (!h.has("content-type")) h.set("content-type", "application/json"); return new ResponseImpl(JSON.stringify(data), { ...init, headers: h }); }
  static redirect(url, status = 302) { return new ResponseImpl(null, { status, headers: { Location: String(url) } }); }
  static error() { return new ResponseImpl(null, { status: 0 }); }
}
class BlobImpl {
  constructor(parts = [], opts = {}) { const chunks = parts.map((p) => (p instanceof BlobImpl ? p._bytes : toBytes(p))); const n = chunks.reduce((a, c) => a + c.length, 0);
    this._bytes = new Uint8Array(n); let o = 0; for (const c of chunks) { this._bytes.set(c, o); o += c.length; } this.size = n; this.type = opts.type ?? ""; }
  async arrayBuffer() { return this._bytes.buffer.slice(0); }
  async text() { return dec.decode(this._bytes); }
}
class FormDataImpl {
  constructor() { this._e = []; }
  append(k, v) { this._e.push([String(k), v]); }
  get(k) { return this._e.find((e) => e[0] === k)?.[1] ?? null; }
  getAll(k) { return this._e.filter((e) => e[0] === k).map((e) => e[1]); }
  has(k) { return this._e.some((e) => e[0] === k); }
  *entries() { yield* this._e; }
  [Symbol.iterator]() { return this.entries(); }
}
g.Headers = HeadersImpl;
g.Request = RequestImpl;
g.Response = ResponseImpl;
g.Blob ??= BlobImpl;
g.File ??= class extends BlobImpl { constructor(parts, name, opts) { super(parts, opts); this.name = name; } };
g.FormData ??= FormDataImpl;
g.ReadableStream ??= class { constructor() { throw new Error("ReadableStream is not available on this Mac"); } };

g.fetch = (input, init = {}) => new Promise((resolve, reject) => {
  const req = input instanceof RequestImpl && Object.keys(init).length === 0 ? input : new RequestImpl(input, init);
  if (req.signal?.aborted) return reject(req.signal.reason);
  // redirect: "manual" is honoured by the app (each hop comes back here); publicOnly asks it to refuse private addresses.
  const payload = JSON.stringify({ url: req.url, method: req.method, headers: [...req.headers], body: req._bytes == null ? null : bytesToB64(req._bytes),
    redirect: req.redirect, publicOnly: init.fbPublicOnly === true });
  let settled = false;
  req.signal?.addEventListener?.("abort", () => { if (!settled) { settled = true; reject(req.signal.reason); } });
  host.fetch(payload, (err, res) => {
    if (settled) return;
    settled = true;
    if (err) return reject(new TypeError(String(err)));
    const r = JSON.parse(res);
    resolve(new ResponseImpl(r.body == null ? null : b64ToBytes(r.body), { status: r.status, headers: r.headers, url: req.url }));
  });
});

g.structuredClone ??= (v) => JSON.parse(JSON.stringify(v));
g.navigator ??= { userAgent: "FloatBoard-Mac" };
g.self ??= g;

export { bytesToB64, b64ToBytes };
