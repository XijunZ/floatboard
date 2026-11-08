import type { Env, User } from "./env";

export type Handler = (req: Request, env: Env, user: User, params: Record<string, string>, ctx: ExecutionContext) => Promise<Response>;
export const routes: { method: string; pattern: RegExp; keys: string[]; handler: Handler }[] = [];

/** Register an authenticated /v2 route, e.g. route("GET", "/v2/thing/:id", h). */
export function route(method: string, path: string, handler: Handler) {
  const keys: string[] = [];
  const pattern = new RegExp("^" + path.replace(/:(\w+)/g, (_, k) => (keys.push(k), "([^/]+)")) + "$");
  routes.push({ method, pattern, keys, handler });
}
