-- Which Claude model each job uses (Settings › Rules & learning › AI model), and what each model was used for, per
-- day, so the app can estimate the monthly cost of each choice (docs/architecture.md, Edition 2, C7).
ALTER TABLE settings ADD COLUMN model_judge TEXT;
ALTER TABLE settings ADD COLUMN model_recap TEXT;
ALTER TABLE settings ADD COLUMN model_reply TEXT;
CREATE TABLE llm_usage (
  user_id TEXT NOT NULL,
  day TEXT NOT NULL,              -- YYYY-MM-DD (UTC)
  job TEXT NOT NULL,              -- judge, recap, learn, reply
  model TEXT NOT NULL,
  calls INTEGER NOT NULL DEFAULT 0,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, day, job, model)
);
