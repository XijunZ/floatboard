import type { Env } from "./env";

let cached: { raw: string; key: CryptoKey } | null = null;

async function key(env: Env): Promise<CryptoKey> {
  if (cached?.raw === env.ENC_KEY) return cached.key;
  // ENC_KEY: base64 secret; derive a 256-bit AES key from it.
  const raw = await crypto.subtle.digest("SHA-256", Uint8Array.from(atob(env.ENC_KEY), (c) => c.charCodeAt(0)));
  const k = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
  cached = { raw: env.ENC_KEY, key: k };
  return k;
}

const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

/** AES-GCM; output is base64(iv) + "." + base64(ciphertext). */
export async function encrypt(env: Env, plain: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await key(env), new TextEncoder().encode(plain));
  return `${b64(iv)}.${b64(new Uint8Array(ct))}`;
}

export async function decrypt(env: Env, enc: string): Promise<string> {
  const [iv, ct] = enc.split(".");
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(iv) }, await key(env), unb64(ct));
  return new TextDecoder().decode(pt);
}
