-- Round 29 (security review M1): who sent a message (a hash of the sending address, for the per-address limit; never the
-- address itself) and when it was filed (for the daily cap on issues).
ALTER TABLE feedback ADD COLUMN ip_hash TEXT;
ALTER TABLE feedback ADD COLUMN filed_at TEXT;
CREATE INDEX feedback_ip ON feedback(ip_hash, received);
CREATE INDEX feedback_filed ON feedback(filed_at);
