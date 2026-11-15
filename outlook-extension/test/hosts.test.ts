import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { OUTLOOK_MATCHES } from "../src/hosts";
import { readPage } from "../src/parse";
import { docFrom, NOW, sampleHtml } from "./helpers";

describe("hosts", () => {
  it("outlook_cloud_microsoft_is_read", () => {
    expect(OUTLOOK_MATCHES).toContain("https://outlook.cloud.microsoft/*");
    const read = readPage(docFrom(sampleHtml(), "https://outlook.cloud.microsoft/mail/"), NOW);
    expect(read.kind).toBe("inbox");
  });

  it("manifest_matches_hosts_ts", () => {
    const m = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url), "utf8"));
    expect([...m.host_permissions].sort()).toEqual([...OUTLOOK_MATCHES].sort());
    expect([...m.content_scripts[0].matches].sort()).toEqual([...OUTLOOK_MATCHES].sort());
  });
});
