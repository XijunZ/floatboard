declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
    GITHUB_REPO: string;
    GITHUB_TOKEN: string;
    NTFY_TOPIC?: string;
    TEST_MIGRATIONS: import("@cloudflare/vitest-plugin").D1Migration[];
  }
}
