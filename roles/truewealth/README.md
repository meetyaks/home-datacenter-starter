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
  -e truewealth_commit=<sha> -e truewealth_transfer_dir=<dir>
ansible-playbook playbooks/truewealth.yml --ask-become-pass \
  -e truewealth_commit=<sha> -e truewealth_transfer_dir=<dir>
```

What a run does, in order (`tasks/main.yml`):

1. **Controller** (runs in check mode too): `transfer.json` is for this commit,
   `linux/amd64`, exactly the four roles; every archive re-hashes to its
   record; the compose file from the commit is the dc1 runtime definition.
2. **Preflight**: `roles/caddy` ran in this play; x86-64; `/srv/data` is a
   mount; Compose ≥ 2.24; port 3100 free or ours; GID 1001 free or ours.
3. Directories, the runtime group, secrets as files (`env` 0600 root,
   `redis_password` 0440 root:1001), all `no_log`.
4. **Images**: copy only what is missing, re-hash on the host, `docker load`,
   and accept only the identities `transfer.json` lists (config digest, or
   manifest digest with the containerd store) with this commit's labels.
5. **Compose**: `config` renders the whole configuration first; it must be
   exactly the six services, no builds, only web published and only on
   127.0.0.1, no Docker socket, no Redis password in the rendered text.
6. **Migrations**: `run --rm migrate` (one-shot, advisory-locked); a failure
   stops the deployment; then `--status` must report 0 pending.
7. **Deploy**: `up -d --pull never --remove-orphans --wait`; never `down`;
   the running web/worker/compute containers must be the loaded images;
   `DEPLOYMENT_MANIFEST.json` and `ROLLBACK_PREVIOUS.json` are written.
8. **Caddy**: one drop-in, validated alone, then `roles/caddy`'s
   reload-and-verify validates the **whole** configuration before reloading;
   the hostname must be in the configuration Caddy has loaded.
9. **Verify**: `/api/readyz` ready; port bound to loopback only; the name
   resolves; `https://tw.dc1.lan/api/healthz` 200 with certificate
   verification on (internal CA); the running web container's revision label
   is the commit.
10. The backup timer (below).

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

`truewealth-backup.timer` runs `/usr/local/sbin/truewealth-backup` daily:

- `pg_dump -Fc` in one transaction (consistent), checked with
  `pg_restore --list`, into `backups/<stamp>/db.dump` (root, 0600/0700).
- `manifest.json` — secret-free: commit and image identities (from
  `DEPLOYMENT_MANIFEST.json`), applied migrations and the last one, user and
  household counts, dump digest and size, PostgreSQL version, the
  **fingerprint** of `TW_KEY_SECRET` (`sha256('tw-key:'+secret)[0:16]`), and
  the Redis policy.
- PostgreSQL is the only authoritative store (the compose file mounts no other
  persistent data). **Redis is not backed up or restored**: it holds queues and
  schedules; the worker re-registers schedules at start; replaying a stale
  queue onto restored rows could run jobs twice. Jobs in flight are lost.
- Off-host: set `truewealth_backup_age_recipients` (age public keys) and
  `truewealth_backup_offhost_target` + `truewealth_backup_offhost_ssh_key`.
  Only `db.dump.age` and the manifest leave the host; plaintext never does.
  **No destination or credential is configured by default** — these are
  operator decisions.
- A failure makes the unit fail (`systemctl status truewealth-backup`); a
  partial backup is removed, never left looking complete.

The in-app "Data export" page is not a backup and says so.

## Restore

**Verify first, always in isolation:**

```
sudo /usr/local/sbin/truewealth-restore-verify /srv/data/services/truewealth/backups/<stamp>
```

It checks the dump digest against the manifest, restores into a throwaway
PostgreSQL container (no network, same image as production, removed on exit)
and checks: migration count and user/household counts equal the manifest; no
orphaned members, accounts, balances, assets, valuations, positions or
snapshot items; sign-in material present. It never touches production.

**Replacing production data** is a separate, approved act, never automatic:
it needs an exact target (the backup directory and its manifest digest), the
vault `TW_KEY_SECRET` whose fingerprint equals the manifest's, and explicit
approval that newer production data may be discarded. Procedure: take a fresh
backup of the current state first; stop `web` and `worker`; restore into a
**new** database; point the stack at it only after `restore-verify`-equivalent
checks pass; keep the old database until the owner confirms.

## Rollback — code and schema are different things

- **Code rollback** (a bad release, schema unchanged): redeploy the previous
  verified commit with its own transfer bundle (`ROLLBACK_PREVIOUS.json`
  records what ran before). Migrations are forward-only; rolling code back
  across a migration is only safe if that release's migrations were additive
  and the old code tolerates them — check before doing it.
- **Schema/data recovery** (corruption, a destructive migration): a restore
  as above. Never restore an older backup over newer production data as a
  "rollback".

## What only the live host can prove

Local tests (`tests/run-truewealth-role.sh`) prove the templates, the
controller and compose checks, the composed Caddy configuration and the
backup/restore scripts against a disposable stack. Still to be shown on
dc1-x86: host capacity, image load and identity under its Docker image store,
migrations and `up --wait` on the real volumes, the Caddy reload and
**trusted HTTPS** at `tw.dc1.lan`, DNS, second-run idempotence, and the first
timer-driven backup plus an off-host copy once a destination exists.
