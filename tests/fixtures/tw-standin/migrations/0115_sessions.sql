-- Stand-in for the release the rollback floor protects (TrueWealth 0115).
CREATE TABLE core.sessions (id text PRIMARY KEY, user_id text NOT NULL, created_at text NOT NULL);
