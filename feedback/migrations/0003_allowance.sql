-- Round 31: the day's allowances (issues filed, ntfy pushes), each taken by one conditional statement before the work is
-- done, so requests arriving together or a retry can never pass the caps.
CREATE TABLE allowance (kind TEXT NOT NULL, day TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY (kind, day));
