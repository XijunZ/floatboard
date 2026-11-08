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
