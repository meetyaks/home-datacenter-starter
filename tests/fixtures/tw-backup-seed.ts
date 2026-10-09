/**
 * SYNTHETIC encrypted application data for the backup/restore exercise
 * (tests/run-truewealth-role.sh section 4). Run with the TrueWealth
 * checkout's tsx and tsconfig AFTER `db/seed-demo.ts`, so the values are
 * written by the application's own code:
 *   - the demo user gets MFA enabled with an encrypted TOTP secret
 *     (TW_KEY_SECRET),
 *   - the demo household gets an encrypted provider credential
 *     (TW_KEY_SECRET),
 *   - an LLM provider row gets an encrypted API key (TW_SECRET_KEY).
 * DB via TW_DB_*; keys via TW_KEY_SECRET / TW_SECRET_KEY in this process's
 * environment (test process only). Prints counts, never values.
 */
import { Pool } from 'pg';
import { encryptSecret } from '@/lib/secretBox';
import { encryptSecret as encryptLlm } from '@/lib/llm/secrets';

async function main() {
  const pool = new Pool({
    host: process.env.TW_DB_HOST, port: Number(process.env.TW_DB_PORT), user: process.env.TW_DB_USER,
    password: process.env.TW_DB_PASSWORD, database: process.env.TW_DB_NAME, max: 1
  });
  const now = new Date().toISOString();
  const demo = await pool.query<{ id: string; hh: string }>(
    `SELECT u.id, m.household_id AS hh FROM core.users u JOIN core.household_members m ON m.user_id = u.id
     WHERE u.email = 'demo@truewealth.local' LIMIT 1`
  );
  if (demo.rows.length !== 1) throw new Error('demo user not found; run db/seed-demo.ts first');
  const { id, hh } = demo.rows[0];
  await pool.query(`UPDATE core.users SET mfa_enabled = true, mfa_secret = $1 WHERE id = $2`, [encryptSecret('JBSWY3DPEHPK3PXP'), id]);
  await pool.query(
    `INSERT INTO wealth.provider_credentials (id, household_id, provider, encrypted_value, created_at, updated_at)
     VALUES ('pc_backup_exercise', $1, 'synthetic-exercise', $2, $3, $3) ON CONFLICT (id) DO NOTHING`,
    [hh, encryptSecret('{"apiKey":"synthetic-exercise-provider-key"}'), now]
  );
  await pool.query(
    `INSERT INTO ai.providers (id, name, display_name, kind, api_key_encrypted, created_at, updated_at)
     VALUES ('ap_backup_exercise', 'synthetic-exercise-llm', 'Synthetic', 'openai', $1, $2, $2) ON CONFLICT (id) DO NOTHING`,
    [encryptLlm('sk-synthetic-exercise-llm-key'), now]
  );
  const c = await pool.query(
    `SELECT (SELECT count(*) FROM core.users WHERE mfa_secret IS NOT NULL)::int AS mfa,
            (SELECT count(*) FROM wealth.provider_credentials WHERE encrypted_value IS NOT NULL)::int AS creds,
            (SELECT count(*) FROM ai.providers WHERE api_key_encrypted IS NOT NULL)::int AS llm`
  );
  console.log(`seeded encrypted fields: ${JSON.stringify(c.rows[0])}`);
  await pool.end();
}
main().catch((e) => {
  console.error(`tw-backup-seed: FAILED — ${(e as Error).message}`);
  process.exit(1);
});
