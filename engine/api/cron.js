// Vercel cron: the engine's 5-minute schedule. Vercel sends "Authorization: Bearer <CRON_SECRET>".
import { scheduled } from "../vercel/dist/engine.mjs";

export default {
  async fetch(req) {
    if (!process.env.CRON_SECRET || req.headers.get("authorization") !== `Bearer ${process.env.CRON_SECRET}`) {
      return new Response("unauthorized", { status: 401 });
    }
    await scheduled();
    return Response.json({ ok: true });
  },
};
