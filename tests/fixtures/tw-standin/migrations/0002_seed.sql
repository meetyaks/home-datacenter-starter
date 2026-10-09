INSERT INTO core.users VALUES ('u1', 'synthetic-1@example.test', 'scrypt$synthetic', '2026-01-01T00:00:00Z'),
                              ('u2', 'synthetic-2@example.test', 'scrypt$synthetic', '2026-01-01T00:00:00Z');
INSERT INTO core.households VALUES ('h1', 'Synthetic household');
INSERT INTO core.household_members VALUES ('m1', 'h1', 'u1'), ('m2', 'h1', 'u2');
