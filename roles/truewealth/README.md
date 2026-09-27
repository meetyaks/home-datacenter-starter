# roles/truewealth — TrueWealth on dc1-x86

Deploys TrueWealth to `https://tw.dc1.lan` from **verified images**: built once
and tested natively on the TrueWealth CI runner, published behind a separate
gate, and verified on the admin plane (dc1-arm-1). The production host never
builds, never pulls TrueWealth images and never holds a registry credential.

Sibling of `roles/keel`, sharing nothing with it but the Docker daemon and the
canonical Caddy (`roles/caddy`):

| | Keel | TrueWealth |
|---|---|---|
| compose project | `keel` | `truewealth` |
| root | `/srv/data/services/keel` | `/srv/data/services/truewealth` |
| loopback ports | 3000, 8080 | 3100 |
| Caddy drop-in | `conf.d/keel.caddy` | `conf.d/truewealth.caddy` |
| runtime GID | 10001 `keel-runtime` | 1001 `truewealth-runtime` |
| vault vars | `keel_vault_*` | `truewealth_vault_*` |

## Inputs

- `truewealth_commit` — the approved full commit (required, no default).
- `truewealth_transfer_dir` — on the admin plane, the output of
  `scripts/release/fetch-verify.mjs` (TrueWealth repository): `<role>.tar` for
  web, worker, compute, migrator, and `transfer.json`.
- `truewealth_source_repo` — a TrueWealth clone on the admin plane containing
  that commit; the compose file is read with `git show <commit>:infra/dc1/compose.dc1.yml`.
- Vault (`inventory/group_vars/linux_servers/vault.yml`, see the example):
  `truewealth_vault_db_password`, `truewealth_vault_key_secret`,
  `truewealth_vault_compute_token`, `truewealth_vault_redis_password`
  (`openssl rand -hex 32` each). **Back up `truewealth_vault_key_secret`
  separately**: a restored database is unreadable without it.

## Deploy

```
ansible-playbook playbooks/truewealth.yml --check --diff --ask-become-pass \
  -e truewealth_commit=<sha> -e truewealth_transfer_dir=<dir> \
  -e truewealth_run_id=<approved run id> -e truewealth_run_attempt=<n>
ansible-playbook playbooks/truewealth.yml --ask-become-pass \
  -e truewealth_commit=<sha> -e truewealth_transfer_dir=<dir> \
  -e truewealth_run_id=<approved run id> -e truewealth_run_attempt=<n>
```

None of these values is a secret. Secrets come only from the vault; the
administrator password only from a hidden prompt (never `-e`, which the role
refuses).

What a run does, in order (`tasks/main.yml`):

1. **Controller** (runs in check mode too): `transfer.json` (schema 2) is for
   this commit and for the **approved run and attempt** you name
   (`-e truewealth_run_id= -e truewealth_run_attempt=`); its evidence class is
   `ci`, which fetch-verify only writes after checking the run against the
   GitHub API (release workflow, success, head = commit, default branch) and
   the artifact digest GitHub computed; the platform is `linux/amd64`; the
   evidence file still hashes to the verified value; exactly the four roles;
   every archive re-hashes to its record; the compose file from the commit is
   the dc1 runtime definition. Dev-local (arm64) or stand-in evidence is
   refused (`truewealth_accept_evidence_classes: [ci]`).
2. **Preflight**: `roles/caddy` ran in this play; x86-64; `/srv/data` is a
   mount; Compose ≥ 2.24; port 3100 free or ours; GID 1001 free or ours.
3. Directories, the runtime group, secrets as files (`env` 0600 root,
   `redis_password` 0440 root:1001), `no_log` **and** `diff: false`.
4. **Images**: copy only what is missing, re-hash on the host, `docker load`,
   and accept only the identities `transfer.json` lists (config digest, or
   manifest digest with the containerd store) with this commit's labels.
5. **Compose**: `config` renders the whole configuration first; it must be
   exactly the six services, no builds, only web published and only on
   127.0.0.1, no Docker socket, no Redis password in the rendered text.
6. **Scripts**: backup, restore-verify and diagnostics are installed before
   anything runs (the deployment uses them).
7. **State**: compare with the last **verified** deployment
   (`DEPLOYMENT_MANIFEST.json`) and ask the new migrator what is pending.
   **Unchanged** (same commit and image identities, nothing pending, no input
   changed, every service running the verified image): converge (a no-op),
   Caddy, verify — and **write nothing**. A re-run reports `changed=0`.
8. **Changed** deployment:
   1. `DEPLOYMENT_ATTEMPT.json` opens (`started`; commit, run, images, the
      previous success, pending migrations).
   2. If migrations are pending **and the database already holds data**: a
      **pre-migration recovery point** (`truewealth-backup --reason
      pre-migration`, kept outside retention) and the **worker stopped**.
      Without a recovery point the deployment stops before migrating (turning
      it off needs `truewealth_allow_migration_without_recovery_point`).
   3. `run --rm migrate`; then `--status` must report 0 pending.
   4. `up -d --pull never --wait` — **no `--remove-orphans`, never `down`**.
      The running containers must be the loaded images. A container of this
      project that the compose file does not define is **reported, never
      removed**.
   5. Caddy: one drop-in, validated alone, then `roles/caddy`'s
      reload-and-verify validates the whole configuration first.
   6. Verify: `/api/readyz` ready; loopback-only; the name resolves;
      `https://tw.dc1.lan/api/healthz` with certificate verification on;
      the running revision label is the commit.
   7. Only now: `ROLLBACK_PREVIOUS.json` ← the previous success **if it is a
      different release** (a redeploy of the same release, e.g. after a
      secret rotation, never replaces the rollback target with itself);
      `DEPLOYMENT_MANIFEST.json` ← this release, `verifiedAt`, what was
      verified; the attempt closes `succeeded`.

   Any failure: the attempt closes `failed` with its stage; the success record
   and the rollback target are **untouched**; nothing is rolled back or
   restored automatically; the message names the last verified release, the
   recovery point, whether the worker is stopped, and the options (below).
   Failure diagnostics are **bounded**: container state, health, exit codes,
   restart counts and log-line counts — no log content (an opt-in,
   redacted excerpt: `truewealth_diagnostics_log_excerpt`). Read full logs
   on the host deliberately.
9. The backup timer (below).

### Migrations and the running release

Migrations run while the **previous** web container keeps serving (it
checked the schema when it started; it is not restarted until `up`). They
must therefore be **backward-compatible with the release that is running**:
add tables/columns/indexes and backfill in one release; remove or rename only
in a later one (expand → contract). The worker — scheduled jobs, broker sync,
anything that could trade — is **stopped** before migrating existing data and
only starts again with the new release after verification. The migrator is
advisory-locked and applies each migration in its own transaction, so after a
failure the earlier migrations of the batch **stay applied** and the report
lists what is applied and what is pending.

The role never rolls a schema back and never restores data by itself.

`site.yml` does not include this, and it never runs `docker`, `common` or
`storage`: a TrueWealth deploy cannot restart Docker or touch Keel.

### Client IP

The drop-in is a plain `reverse_proxy` with no `trusted_proxies`, so Caddy
replaces any client `X-Forwarded-For` with the real peer; the app
(`TW_TRUSTED_PROXY_HOPS=1`) trusts only that last entry. Anything that can
reach `127.0.0.1:3100` directly (processes on this host, containers on the
`truewealth_default` network) can claim any address; that is the stated trust
boundary. Do not add `header_up X-Forwarded-For`, `X-Real-IP` or
`trusted_proxies`.

## First administrator

```
ansible-playbook playbooks/truewealth-enroll-admin.yml --ask-become-pass \
  -e truewealth_admin_email=you@example.com
```

Runs the application's own CLI (`dist/ops/platform-admin.mjs enroll`) in the
migrator image; the password is prompted without echo and passed on stdin
only. Registration is invite-only after that.

## Backups (disaster recovery — infrastructure-owned)

`truewealth-backup.timer` runs `/usr/local/sbin/truewealth-backup` daily; the
deployment also runs it (`--reason pre-migration`) before migrating existing
data.

- **One snapshot.** A read-only repeatable-read transaction exports its
  snapshot; `pg_dump -Fc --snapshot` dumps exactly that snapshot, and the
  manifest's schema state and counts (migrations, users, households and
  representative wealth tables) are read **in the same transaction**. The
  manifest therefore describes the dump's own content even while the
  application writes (tested with ~400 concurrent inserts).
- The dump must parse (`pg_restore --list`). Files are root-only (0600/0700).
- `manifest.json` is secret-free: reason, commit and image identities (from
  `DEPLOYMENT_MANIFEST.json`), the snapshot metadata, dump digest and size,
  the encrypted copy's digest and recipients, **fingerprints** of every
  at-rest key (`TW_KEY_SECRET`; `TW_SECRET_KEY` and
  `TW_AUDIT_SIGNING_SECRET` when configured), and the Redis policy.
- **One at a time**: a lock; a second backup waits
  (`truewealth_backup_lock_wait_seconds`) and then fails with exit 75 rather
  than overlapping. A stamp is never reused.
- **Failure reporting**: any failure exits non-zero (the unit shows failed),
  the partial directory is removed, and `backups/LAST_STATUS.json` records the
  result and the failing stage (for monitoring).
- **Off-host**: set `truewealth_backup_age_recipients` (age public keys) and
  `truewealth_backup_offhost_target` + `truewealth_backup_offhost_ssh_key`
  (root-owned, 0600). Only `db.dump.age` and the manifest leave the host;
  rsync writes into a partial directory and renames at the end, and a
  `COMPLETE` marker (digests of both files) is written **last** — a copy
  without it is incomplete and restore-verify refuses it. **No destination,
  key or credential is configured by default**; they are operator decisions.
- **Retention is disabled**: nothing is deleted until
  `truewealth_backup_retention_approved` is set with `truewealth_backup_keep`
  (the play refuses a keep count without the approval). Even then only
  scheduled local backups are pruned — never pre-migration recovery points,
  never off-host copies.

### Key custody (what a restore needs besides the dump)

| Secret | Protects | Without it |
|---|---|---|
| `truewealth_vault_key_secret` (`TW_KEY_SECRET`) | MFA secrets, provider credentials | those fields are unreadable; MFA users cannot sign in |
| `truewealth_vault_secret_key` (`TW_SECRET_KEY`, optional) | stored LLM provider API keys | they must be re-entered |
| `truewealth_vault_audit_signing_secret` (optional) | audit-log signatures | signatures cannot be verified |
| the age **identity** (private key) | the off-host ciphertext | the off-host copy is useless |

Keep the vault and the age identity **separately** from the backups and from
each other's storage. The manifest records fingerprints so a restore can
check it holds the right values before relying on them. The age identity
never belongs on the production host (except for a supervised drill).

The in-app "Data export" page is not a backup and says so.

## Restore

**Verify first, always in isolation:**

```
sudo /usr/local/sbin/truewealth-restore-verify /srv/data/services/truewealth/backups/<stamp>
# an off-host (encrypted) copy, with separately held keys:
sudo /usr/local/sbin/truewealth-restore-verify --identity <age identity> \
  --key-file <file with TW_KEY_SECRET=… [TW_SECRET_KEY=…]> <copy dir>
```

It checks the COMPLETE marker and digests of an encrypted copy, decrypts
with the identity, checks the dump digest against the manifest, and restores
into a throwaway PostgreSQL container (no network, same image as
production, its password passed by `--env-file`, never an argument; removed
on exit). Then: migrations, users, households and the representative tables
equal the manifest (same snapshot); no orphaned members, accounts, balances,
assets, valuations, positions or snapshot items; the key fingerprint matches
the manifest; and the **application's own code** (`dist/ops/verify-restore.mjs`
in the deployed migrator image, keys on stdin) decrypts every encrypted
field. `--check-email` (password from a root-only file or a hidden prompt)
additionally verifies one KNOWN account's password against its restored hash.
Password hashes are otherwise reported as **presence only — not proof that
anyone can sign in**. Exit codes: 0 pass; 1 data mismatch; 2 input problem;
3 wrong/missing key or identity; 4 incomplete or tampered copy; 5 partly
decryptable; 6 password check failed; 7 unproven (key check skipped or
nothing encrypted to test). It never touches production.

**Replacing production data** is a separate, approved act, never automatic:
an exact target (the backup directory and its manifest digest), the vault
keys whose fingerprints equal the manifest's, restore-verify PASSED on that
target, and explicit approval that newer production data may be discarded.
Procedure:

1. Take a fresh backup of the current state (`--reason manual`), even if
   it is damaged: it is evidence and a way back.
2. Stop `worker` and `web`.
3. Restore into a **new** database; run the restore-verify checks against it.
4. Point the stack at it and start with the **worker held**
   (`-e truewealth_hold_worker=true`): web and compute run, no job runs.
5. Reconcile (next section), then deploy again without the hold.
6. Keep the old database until the owner confirms.

### Redis loss and job reconciliation

Redis holds BullMQ queues, schedules and transient state only; it is **not**
backed up or restored. After a restore (or a Redis loss):

- **Lost**: jobs queued or running at backup time, delayed jobs, and
  retry/attempt counters. Schedules are re-registered by the worker at start.
- **Not replayed on purpose**: a stale queue applied to restored rows could
  run jobs twice — duplicate notifications, double-applied imports, or broker
  actions.
- **Before starting the worker** (it stays held until then):
  - check at the broker(s) directly for orders, positions and fills since
    the backup's `snapshot.readAt`, and reconcile them with the restored
    data; live trading stays off unless explicitly enabled per broker
    (`TW_LIVE_TRADING_ENABLED` and the broker flags default to 0);
  - identify scheduled work whose last successful run is later than the
    snapshot (provider syncs, snapshots, imports) and decide whether to
    re-run it;
  - expect provider syncs to fetch again from the restored cursors
    (idempotent upserts; verify for any provider that is not).
- Then deploy without `truewealth_hold_worker`; the worker starts with an
  empty queue and freshly registered schedules.

## Rollback — code and schema are different things

`ROLLBACK_PREVIOUS.json` is the last **distinct** verified release before the
current one (commit, run, image identities). `DEPLOYMENT_ATTEMPT.json` is the
last attempt, succeeded or failed; it is never a rollback target.

- **Code rollback** (a bad release): redeploy the commit in
  `ROLLBACK_PREVIOUS.json` with its own verified transfer bundle and run id.
  It does not touch the schema: migrations are forward-only, and the older
  code must work with the schema as it now is. That is true when the
  release being rolled back only EXPANDED the schema (the contract in
  "Migrations and the running release"); check its migrations before doing it.
  The role will report nothing pending (the database is ahead) and deploy.
- **Database restore** (corruption, a destructive or wrong migration): the
  Restore procedure above, from the pre-migration recovery point or another
  verified backup, as a separate approved act. Never restore an older backup
  over newer production data as a "rollback", and never automatically.

## What only the live host can prove

Local tests (`tests/run-truewealth-role.sh`, this Mac: arm64 engine) prove the
templates, the controller's run/evidence binding, the compose checks, the
composed Caddy configuration, the backup/restore scripts with the real
migrator image and synthetic data, and — with stand-in application images —
the whole deploy flow (unchanged re-runs, migrations behind a recovery point,
failures, records). Still to be shown on dc1-x86: host capacity, image load
and identity of the REAL amd64 images under its Docker image store,
migrations and `up --wait` on the real volumes, the Caddy reload and
**trusted HTTPS** at `tw.dc1.lan`, DNS, second-run idempotence there, and the
first timer-driven backup plus an off-host copy once a destination exists.
