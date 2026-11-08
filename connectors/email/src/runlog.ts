import { type Env, nowISO } from "./env";

export type RunLogEntry = {
  run_id: string; user_id: string; decision: string; at?: string;
  source?: string | null; sender?: string | null; subject?: string | null; detail?: string | null; trace?: string | null;
};

/** A run_events row as a prepared statement: `.run()` it, or put several in one `env.DB.batch`. */
export function logEvent(env: Env, e: RunLogEntry): D1PreparedStatement {
  return env.DB.prepare("INSERT INTO run_events(run_id,user_id,at,source,sender,subject,decision,detail,trace) VALUES(?,?,?,?,?,?,?,?,?)")
    .bind(e.run_id, e.user_id, e.at ?? nowISO(), e.source ?? null, e.sender ?? null, e.subject ? e.subject.slice(0, 80) : null,
      e.decision, e.detail ?? null, e.trace ?? null);
}
