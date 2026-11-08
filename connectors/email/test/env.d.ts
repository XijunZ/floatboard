declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
    ENC_KEY: string;
    ADMIN_KEY: string;
    TELEGRAM_BOT_TOKEN: string;
    TELEGRAM_BOT_NAME: string;
    TELEGRAM_WEBHOOK_SECRET: string;
    DATA_MODEL_DOC: string;
    TEST_MIGRATIONS: import("@cloudflare/vitest-plugin").D1Migration[];
  }
}
