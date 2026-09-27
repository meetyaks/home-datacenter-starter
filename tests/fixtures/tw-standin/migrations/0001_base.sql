CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS wealth;
CREATE TABLE core.users (id text PRIMARY KEY, email text NOT NULL, password_hash text, created_at text NOT NULL);
CREATE TABLE core.households (id text PRIMARY KEY, name text NOT NULL);
CREATE TABLE core.household_members (id text PRIMARY KEY, household_id text NOT NULL, user_id text NOT NULL);
