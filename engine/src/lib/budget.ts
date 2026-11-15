/** Outgoing calls allowed in one Worker invocation (Cloudflare free plan: 50; we keep a safety margin). */
export const CALLS_PER_INVOCATION = 45;

export class BudgetExhausted extends Error {
  constructor() { super("Call budget for this run is used up"); }
}

/** Counts outgoing network calls so a run can stop cleanly before the platform limit. */
export class Budget {
  used = 0;
  constructor(readonly limit: number = CALLS_PER_INVOCATION) {}
  get remaining() { return Math.max(0, this.limit - this.used); }
  take(n = 1) {
    if (this.used + n > this.limit) throw new BudgetExhausted();
    this.used += n;
  }
  /** A fetch that charges one call per request. */
  wrap(f: typeof fetch = (i, init) => fetch(i, init)): typeof fetch {
    return ((i: RequestInfo | URL, init?: RequestInit) => { this.take(1); return f(i, init); }) as typeof fetch;
  }
}
