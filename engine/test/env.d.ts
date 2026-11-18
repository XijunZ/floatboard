declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
    ENC_KEY: string;
    ADMIN_KEY: string;
    DATA_MODEL_DOC: string;
    TEST_MIGRATIONS: import("@cloudflare/vitest-plugin").D1Migration[];
  }
}

// Vite's `?raw` imports (a file's text), used to read the Mac's Swift source in a cross-check.
declare module "*?raw" {
  const text: string;
  export default text;
}
