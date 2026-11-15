export interface Env {
  DB: D1Database;
  ENC_KEY: string;
  ADMIN_KEY: string;
  /** "1" when the engine runs inside the Mac app and Apple's on-device model is available there. */
  ON_DEVICE?: string;
}

export type User = { id: string; name: string };

export const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });

export const nowISO = () => new Date().toISOString();
