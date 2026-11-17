/**
 * Circle's outgoing calls (Gmail metadata, Companies House, news and blog feeds, Claude) go through one fetch, so tests
 * can stand in for every outside service at once. Never a live call in tests.
 */
const live: typeof fetch = (i, init) => fetch(i, init);
let current: typeof fetch = live;

/** Tests replace the outside world; null puts the real fetch back. */
export function setCircleFetch(f: typeof fetch | null) { current = f ?? live; }

/** The fetch Circle uses now (wrap it with a Budget to count calls). */
export function circleFetch(): typeof fetch { return current; }
