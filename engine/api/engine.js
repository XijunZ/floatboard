// Vercel function: every request to the engine (vercel.json sends all paths here).
import { waitUntil } from "@vercel/functions";
import { handle } from "../vercel/dist/engine.mjs";

export default { fetch: (req) => handle(req, waitUntil) };
