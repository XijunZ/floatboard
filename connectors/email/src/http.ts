import { json } from "./env";

/** Parse a JSON request body: empty is `{}`, malformed or non-object JSON is a 400 `{error:"Invalid JSON"}`. */
export async function readJSON(req: Request): Promise<{ ok: true; body: any } | { ok: false; res: Response }> {
  const text = await req.text();
  if (!text.trim()) return { ok: true, body: {} };
  try {
    const body = JSON.parse(text);
    if (body !== null && typeof body === "object") return { ok: true, body };
  } catch { /* fall through */ }
  return { ok: false, res: json({ error: "Invalid JSON" }, 400) };
}

/**
 * Read a request body of at most `limit` bytes. A Content-Length over the limit is refused before anything is read; without
 * one, the stream is read only until it passes the limit, then cancelled. Returns the text, or null when too large.
 */
export async function readCapped(req: Request, limit: number): Promise<string | null> {
  const declared = req.headers.get("Content-Length");
  if (declared !== null && !(Number(declared) <= limit)) {
    try { await req.body?.cancel(); } catch { /* already closed */ }
    return null;
  }
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      try { await reader.cancel(); } catch { /* already closed */ }
      return null;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let o = 0;
  for (const c of chunks) { all.set(c, o); o += c.byteLength; }
  return new TextDecoder().decode(all);
}

/** `readJSON` with a byte cap: too large is `{ tooLarge: true }`, so each caller answers 413 in its own response format. */
export async function readCappedJSON(req: Request, limit: number): Promise<{ ok: true; body: any } | { ok: false; tooLarge: boolean }> {
  const text = await readCapped(req, limit);
  if (text === null) return { ok: false, tooLarge: true };
  if (!text.trim()) return { ok: true, body: {} };
  try {
    const body = JSON.parse(text);
    if (body !== null && typeof body === "object") return { ok: true, body };
  } catch { /* fall through */ }
  return { ok: false, tooLarge: false };
}
