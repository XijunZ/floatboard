-- Round 40: a meeting's aliases are claimed together before its notes are judged (`claim` = the delivery judging it; NULL
-- once its result is stored), so a webhook and the recap email arriving together are judged once.
ALTER TABLE recap_keys ADD COLUMN claim TEXT;
