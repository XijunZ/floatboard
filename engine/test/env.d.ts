declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
    ENC_KEY: string;
    ADMIN_KEY: string;
    DATA_MODEL_DOC: string;
    TEST_MIGRATIONS: import("@cloudflare/vitest-plugin").D1Migration[];
  }
}
