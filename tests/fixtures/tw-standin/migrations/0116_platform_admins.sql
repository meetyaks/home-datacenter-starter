-- Stand-in for TrueWealth 0116_platform_admins.sql, the rollback floor.
CREATE SCHEMA IF NOT EXISTS security;
CREATE TABLE security.platform_admin_grants (user_id text PRIMARY KEY, granted_at text NOT NULL);
