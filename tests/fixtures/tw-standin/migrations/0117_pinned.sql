-- An additive migration after the floor.
ALTER TABLE wealth.notes ADD COLUMN pinned boolean NOT NULL DEFAULT false;
