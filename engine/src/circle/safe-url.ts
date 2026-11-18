/**
 * Circle fetches addresses the owner typed (a person's blog or news feed). They may only reach the public internet:
 * http(s) only, no user:password, and no loopback, private, link-local, shared (CGNAT), multicast or unspecified hosts,
 * whether named (localhost, *.localhost, *.local, *.internal) or written as an IP (any IPv4 form the URL parser accepts,
 * IPv6 including IPv4-mapped). Redirects are followed by hand, each hop checked again, at most 3.
 *
 * Names: Workers can't resolve a name before fetching (and Cloudflare's network doesn't reach the owner's home network). On
 * the Mac (Mac only mode) the same code runs behind the app's fetch bridge, which can: `fbPublicOnly` makes the bridge resolve
 * the name and refuse private, loopback and link-local answers, and `redirect: "manual"` makes it hand back each redirect
 * (mac/Sources/FloatBoardConnectors/Local/LocalNetwork.swift).
 */

const MAX_HOPS = 3;

function ipv4Private(a: number[]): boolean {
  const [x, y] = a;
  return x === 0 || x === 10 || x === 127 || (x === 169 && y === 254) || (x === 172 && y >= 16 && y <= 31) || (x === 192 && y === 168)
    || (x === 100 && y >= 64 && y <= 127) || (x === 192 && y === 0 && a[2] === 0) || (x === 198 && (y === 18 || y === 19)) || x >= 224;
}

function ipv6Private(h: string): boolean {
  const s = h.toLowerCase();
  if (s === "::" || s === "::1") return true;
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(s);
  if (mapped) return ipv4Private(mapped[1].split(".").map(Number));
  const hex = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(s);
  if (hex) { const a = parseInt(hex[1], 16), b = parseInt(hex[2], 16); return ipv4Private([a >> 8, a & 255, b >> 8, b & 255]); }
  // NAT64 (64:ff9b::/96) carries an IPv4 address in its last 32 bits.
  const nat = /^64:ff9b::(?:([0-9a-f]{1,4}):([0-9a-f]{1,4})|(\d+\.\d+\.\d+\.\d+))$/.exec(s);
  if (nat) {
    if (nat[3]) return ipv4Private(nat[3].split(".").map(Number));
    const a = parseInt(nat[1], 16), b = parseInt(nat[2], 16);
    return ipv4Private([a >> 8, a & 255, b >> 8, b & 255]);
  }
  // Anything else under ::/80 (the old IPv4-compatible form, e.g. ::127.0.0.1 written as ::7f00:1) is not a public address.
  if (s.startsWith("::")) return true;
  const first = parseInt(s.split(":")[0] || "0", 16);
  return (first & 0xfe00) === 0xfc00 || (first & 0xffc0) === 0xfe80 || (first & 0xff00) === 0xff00;
}

/** The URL when it may be fetched, else null. */
export function publicHttpUrl(raw: string, base?: string): URL | null {
  let u: URL;
  try { u = base ? new URL(raw, base) : new URL(raw); } catch { return null; }
  if (u.protocol !== "https:" && u.protocol !== "http:") return null;
  if (u.username || u.password) return null;
  const host = u.hostname.toLowerCase().replace(/\.$/, "");
  if (!host) return null;
  if (host.startsWith("[")) return ipv6Private(host.slice(1, -1)) ? null : u;
  if (/^\d+\.\d+\.\d+\.\d+$/.test(host)) return ipv4Private(host.split(".").map(Number)) ? null : u;
  if (host === "localhost" || /\.(localhost|local|internal|lan|home\.arpa)$/.test(host) || !host.includes(".")) return null;
  return u;
}

/** Fetches a public URL, following at most 3 redirects by hand and checking each address. Throws on anything else. */
export async function fetchPublic(f: typeof fetch, raw: string): Promise<Response> {
  let url = publicHttpUrl(raw);
  for (let hop = 0; ; hop++) {
    if (!url) throw new Error("not a public web address");
    // fbPublicOnly: on the Mac (Mac only mode) the app's fetch bridge also resolves the name and refuses private answers;
    // Workers ignore the field.
    const r = await f(url.href, { redirect: "manual", fbPublicOnly: true } as RequestInit);
    if (r.status < 300 || r.status >= 400 || !r.headers.get("Location")) return r;
    if (hop >= MAX_HOPS) throw new Error("too many redirects");
    url = publicHttpUrl(r.headers.get("Location")!, url.href);
  }
}
