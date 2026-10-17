-- Atomic allocation of sequential identifiers (lead / client numbers).
--
-- A row per "PREFIX-YEAR" key.  Allocation is a single
-- INSERT ... ON CONFLICT DO UPDATE ... RETURNING statement, so two concurrent
-- requests can never compute the same next number (the previous
-- SELECT MAX(...)+1 approach could).

CREATE TABLE IF NOT EXISTS counters (
    name TEXT PRIMARY KEY,
    n    INTEGER NOT NULL DEFAULT 0
);
