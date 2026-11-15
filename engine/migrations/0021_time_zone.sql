-- Per person: IANA time zone the app reports (e.g. "Europe/Berlin"). Due dates and "now" are read in it; NULL = UTC.
ALTER TABLE settings ADD COLUMN time_zone TEXT;
