import { describe, it, expect } from "vitest";
import { z } from "zod";
import { askStructured, makeClient, HAIKU } from "../src/llm";

describe("llm client", () => {
  it("default_fetch_is_called_unbound_safely", async () => {
    const real = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (function (this: unknown) {
      calls++;
      if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
      return Promise.resolve(Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn",
        stop_sequence: null, content: [{ type: "text", text: JSON.stringify({ ok: true }) }], usage: { input_tokens: 1, output_tokens: 1 } }));
    }) as typeof fetch;
    try {
      const r = await askStructured(makeClient("sk-test"), { system: "s", user: "u", schema: z.object({ ok: z.boolean() }) });
      expect(r).toEqual({ ok: true, value: { ok: true } });
      expect(calls).toBe(1);
    } finally { globalThis.fetch = real; }
  });
});
