export interface Env {
  DB: D1Database;
  ENC_KEY: string;
  ADMIN_KEY: string;
  TELEGRAM_BOT_TOKEN?: string;
  TELEGRAM_BOT_NAME?: string;
  TELEGRAM_WEBHOOK_SECRET?: string;
}

export type User = { id: string; name: string };

export const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });

export const nowISO = () => new Date().toISOString();
