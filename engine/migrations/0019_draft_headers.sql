-- Reply drafts: also keep the recipients and subject FloatBoard wrote, so a second press updates FloatBoard's draft only
-- while the whole draft (To, Cc, Subject, body, no attachments) is still exactly as FloatBoard wrote it.
ALTER TABLE drafts ADD COLUMN to_addr TEXT;
ALTER TABLE drafts ADD COLUMN cc_addrs TEXT;  -- JSON list
ALTER TABLE drafts ADD COLUMN subject TEXT;
