# roles/keel

Deploys Keel to `dc1-x86` from an exact Git commit, building `linux/amd64` images
natively on that host. No registry. No release tag. The commit SHA is the only
version identity.

Paired with **meetyaks/keel** PR #10, which adds `infra/lab/compose.lab.yml` —
the stack definition this role installs. The role deliberately does **not** carry
its own copy of that file: two hand-maintained copies of one stack drift, and the
drift is silent until a deploy behaves unlike the tree it claims to be.

## The vault file you must create

**`inventory/group_vars/linux_servers/vault.yml`** — gitignored, and it must stay
that way. It is not in this repository and never will be.

```bash
ansible-vault create inventory/group_vars/linux_servers/vault.yml
```

⚠️ **The directory name is the group name, and that is the whole point.** Ansible
loads `group_vars/<group>/` for every host in `<group>`; `dc1-x86` is in
`linux_servers`, so everything in that directory — including the encrypted vault —
is loaded for it automatically. No `vars_files`, no `-e @…`, no path on the
command line.

An earlier version of these instructions said `inventory/group_vars/vault.yml`.
That binds to a group named `vault`, which does not exist, so the file was
**decrypted and then never loaded** — `--ask-vault-pass` succeeded and every
`keel_vault_*` variable was undefined. If you created a vault at the old path,
move it:

```bash
git mv 2>/dev/null; mkdir -p inventory/group_vars/linux_servers
mv inventory/group_vars/vault.yml inventory/group_vars/linux_servers/vault.yml
```

The old path stays in `.gitignore` until everyone has moved, so a stale file of
real credentials cannot become committable in the meantime.

The role proves the loading path on every run: a committed, non-secret canary
(`loading-canary.yml`) sits beside the vault and is asserted **before** the
secrets are checked, so "you forgot the vault" and "Ansible never loaded it" stop
looking like the same failure.

Define exactly these ten names. The role asserts all ten are present **before it
writes anything**, so a missing one stops the run rather than rendering a blank
value into a live stack:

| variable | what it is |
|---|---|
| `keel_vault_admin_db_password` | `keel_admin` — owns DDL, used by the one-shot bootstrap only |
| `keel_vault_app_db_password` | `keel_app_login` — NOBYPASSRLS, the request path. Bootstrap rotates the role onto this value |
| `keel_vault_blob_access_key` | object-store access key (also MinIO's root user) |
| `keel_vault_blob_secret_key` | object-store secret key (also MinIO's root password) |
| `keel_vault_oidc_client_secret` | OIDC client secret |
| `keel_vault_master_key` | credential-vault master key |
| `keel_vault_mfa_master_key` | MFA secret-encryption master key |
| `keel_vault_jwt_private_key` | RS256 private key, full PEM including headers |
| `keel_vault_jwt_public_key` | RS256 public key, full PEM including headers |
| `keel_vault_default_tenant_id` | **permanent installation identity** — see below. Not a credential |

### `keel_vault_default_tenant_id` is not configuration

Bootstrap seeds this installation's initial tenant at this id, and every row that
tenant ever owns is keyed to it. That makes it **immutable for the life of the
installation**:

- **upgrades reuse it**; a rerun must never regenerate it
- **a rebuilt machine restores it** from the vault — it is recovery material
- **a database restore must use the value that produced the dump.** Restore a
  dump into an installation carrying a different id and the data is present but
  unreachable as that tenant: no error, just an empty-looking tenant

There is **no default for it anywhere** — not in `defaults/main.yml`, not in the
Compose file, not in `env.example`. A committed constant would be *reusable*, so
two installations deployed from this repository would collide on one tenant
identity; and a default of any kind lets a stack start having quietly invented
its own permanent identity, which is the one decision a deployment must never
make by omission.

Generate one per installation **on the admin console, never on the managed
host**, and never by the playbook:

```bash
uuidgen | tr 'A-Z' 'a-z'
```

Preflight validates it in both modes — defined, non-empty, canonical lowercase
UUID, and not an all-zero or sentinel value — and **fails before anything is
written or started**. It is rendered into `env/keel.env` under `no_log`, so the
value never reaches a deployment log; the failure messages say what is wrong
without quoting it.

Generate the keypair (on the admin console, never on the host):

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out jwt_private.pem
openssl rsa -in jwt_private.pem -pubout -out jwt_public.pem
```

Paste both as YAML block scalars so the PEM newlines survive:

```yaml
keel_vault_jwt_private_key: |
  -----BEGIN PRIVATE KEY-----
  …
  -----END PRIVATE KEY-----
```

Then delete the local `.pem` files — `.gitignore` excludes `*.pem`, but the safest
copy is the one that does not exist.

Rotating `keel_vault_master_key` or `keel_vault_mfa_master_key` invalidates
everything they protect. Neither is a routine change.

## Commands

Run from `~/Projects/home-datacenter-starter` on dc1-arm-1:

```bash
# check (read-only)
ansible-playbook playbooks/keel.yml --check --diff --ask-vault-pass --ask-become-pass

# deploy
ansible-playbook playbooks/keel.yml --ask-vault-pass --ask-become-pass
```

No `ANSIBLE_REMOTE_TMP=` prefix is needed. The play sets
`ansible_remote_tmp: /tmp/ansible-keel` itself, which is what the environment
variable was working around.

<details>
<summary>Why that setting exists, and why it is on the <em>play</em></summary>

Ansible stages a module in a temporary directory **before** it executes a task,
so anything set in a task's own `vars:` is resolved too late to influence it. The
default `~/.ansible/tmp` is expanded against the *connection* user — and for a
task delegated to the controller, that user was still the **remote** one:

```
fatal: [dc1-x86 -> localhost]: UNREACHABLE
Attempted controller temp directory: /Users/labadmin/.ansible/tmp
```

A per-task `ansible_user` override looks like it should fix this. It does not,
and was removed. An absolute path is never expanded against anyone's home, which
is what actually settles it — and `/tmp` is valid on both ends: the controller
under whatever account runs `ansible-playbook`, and dc1-x86 under `labadmin` and
under root after `become`.

</details>

Nothing names the vault file. It is loaded automatically because it sits in
`group_vars/<group>/` for a group the target belongs to.

### `--check` is a PREFLIGHT, not a simulated deployment

It answers *"could this deploy start, and is the commit it names actually
deployable"* — and it exits **successfully** on a completely fresh host.

**What it validates**, all without changing anything:

- the target's architecture, that `/srv/data` is a separate filesystem, that
  Docker and Compose v2 are reachable by this connection
- that all ten `keel_vault_*` variables are present, and that
  `group_vars/linux_servers/` is genuinely being loaded
- that `keel_vault_default_tenant_id` is a canonical lowercase UUID and not an
  all-zero or sentinel value — checked **before** anything is written, because it
  is permanent installation identity and cannot be corrected by redeploying
- every path the deployment will use, and that the image tag derives from the
  commit
- **from the controller's git objects** — that `keel_commit` exists, is a commit,
  and that its tree contains `infra/lab/compose.lab.yml`,
  `packages/gateway/Dockerfile`, `apps/web/Dockerfile`, `packs/` and `profiles/`
- the secret files and directories it *would* write, predicted without exposing
  any content

It then prints what a real run would perform, and stops.

**On an existing secret, `--check` distinguishes two things** that an exact-mode
comparison alone would conflate:

| state | check mode | why |
|---|---|---|
| reachable by `other`, or group-readable by an *unexpected* group | **fails** | a real exposure, and it is real whether or not this run changes anything |
| merely not yet converged — too narrow, or the right bits under the wrong owner | **reports** | that is the state this play exists to correct; failing on it would stop the dry run before it could tell you what else is wrong |

A normal run asserts the exact mode and ownership in full, as it always did.

> **The runtime group is applied by GID, not by name.** Under `--check` the
> `group` module correctly creates nothing, so `keel-runtime` does not resolve
> for the rest of the play. A dry run against dc1-x86 died on exactly that —
> `chgrp failed: failed to look up group keel-runtime` — collapsing on a group
> it had itself declined to create. The GID is also the identifier that matters:
> a bind mount matches numbers, and the name exists so `ls -l` reads sensibly.
> (enforced: `tests/check-mode-runtime-group.yml`)

**What it deliberately does not do:** create an archive, transfer or unpack
source, build an image, run migrations or Compose, or touch Caddy. It also never
*requires* any of those to exist — on a fresh host none of them can.

> An existing secret file with unsafe permissions still **fails** in check mode,
> as does an already-installed stack that publishes a non-loopback port. Those
> are live exposures; "I was only looking" does not make them safe.

### Regression suites

```bash
tests/run-all.sh
```

Controller-only: no SSH, no vault, no secrets, no Docker, nothing written outside
`/tmp` fixtures.

| suite | covers |
|---|---|
| `run-secret-verification.sh` | check/absent (no crash), check/existing-unsafe (fails), normal/absent (fails), normal/correct-0600 (passes) |
| `controller-delegation.yml` | delegated tasks keep the **controller's** identity when the remote is `labadmin` with `become: true` |
| `check-mode-fresh-host.yml` | absent stat, absent slurp and skipped-command registers all dereference safely |
| `run-check-mode-preflight.sh` | every mutating phase is guarded; a real `--check` run creates no archive and no source tree |
| `run-check-mode-handlers.sh` | all three mutating handlers are notified and SKIPPED under `--check`, and create nothing |
| `platform-version.yml` | empty, malformed and undefined versions are refused; a valid one is accepted; the commit-blob derivation yields an accepted value |

Two details that are load-bearing rather than incidental:

- The secret suite runs **twice**, with and without `--check`, because
  `ansible_check_mode` is true only when the *play* was started with `--check`. A
  task- or block-level `check_mode: true` behaves as a dry run *without flipping
  that fact*, so a single invocation exercises a different path from the one
  `--check` takes and proves nothing.
- The delegation fixture points at `192.0.2.1` (RFC 5737, never routable) with
  `ansible_user: labadmin`. Every task is delegated, so nothing is ever sent
  there — the host exists only to supply the remote identity that used to leak.
  The suite asserts the controller account *differs* from `labadmin`, so it
  cannot pass vacuously.

### How check mode behaves, by design

| | |
|---|---|
| read-only validation | runs in **every** mode (`check_mode: false`) — source repo, commit existence, Caddy directory, existing image inspection |
| predicted-but-absent | skipped with an explicit note (`when: not ansible_check_mode`) |
| existing unsafe state | **fails in every mode** — an installed stack publishing a LAN port, or an existing secret at 0644 |
| normal-mode verification | unchanged and strict |

### Verifying the loading path without deploying

```bash
ansible-inventory --host dc1-x86 --ask-vault-pass
```

`keel_group_vars_source: inventory/group_vars/linux_servers` in the output means
the directory is loaded for that host; any variable you placed beside the canary,
encrypted or not, is loaded with it.

## What it does

1. **Asserts** the commit is a full 40-char SHA, every secret is present, the host
   is `x86_64`, and `/srv/data` is a separate filesystem.
2. **Creates** `/srv/data/services/keel/{builds,data,secrets,env}` — secrets and
   env at `0700`, their contents `0600 root:root`.
3. **Renders** the environment file and PEM keys from Vault, then *verifies* their
   mode and owner rather than assuming the write took.
4. **Transfers** `git archive <sha>` from the control node — the commit's tree and
   nothing else: no `.git`, no `node_modules`, no working-tree edits, no build
   output. Writes `DEPLOYMENT_MANIFEST` and refuses to build unless it names the
   requested SHA.
5. **Builds** `keel-gateway:sha-<short>` and `keel-web:sha-<short>` on the host,
   **skipping** when the tag already resolves to an image. Records the previous
   tags to `ROLLBACK_PREVIOUS` and the new image IDs to `IMAGE_DIGESTS`.
6. **Deploys** Compose, after asserting the rendered config publishes nothing on a
   non-loopback address.
7. **Migrates** once; the gateway waits on it completing successfully, and a
   non-zero exit fails the play.
8. **Configures** one Caddy drop-in, `caddy validate`-checked before install and
   applied with a *reload*, never a restart — Caddy is shared infrastructure.
9. **Verifies** `/healthz`, `/readyz`, the console, container state, and that the
   running image actually contains its baked packs.

## Idempotence

A second run against an unchanged commit creates no directory, transfers no
archive, builds no image and recreates no container. Re-running after a partial
failure is safe, which is the state a deployment is most often actually in.

## Filesystem

```
/srv/data/services/keel/
├── builds/<short>/          source from the commit
│   ├── DEPLOYMENT_MANIFEST  full SHA — verified before any build
│   └── IMAGE_DIGESTS        image IDs as built
├── data/{postgres,nats,minio}/   ALL persistent state
├── secrets/                 0700; jwt_private.pem, jwt_public.pem at 0600
├── env/keel.env             0600 root:root
├── compose.lab.yml          installed from the built commit
└── ROLLBACK_PREVIOUS        the images running before this deploy
```

Build inputs and runtime state are separate on purpose: removing a build
directory must never be able to reach data.

## Ingress

Caddy only. The gateway publishes `127.0.0.1:3000` and the console
`127.0.0.1:8080` so Caddy — on the same host — can reach them; Postgres, NATS,
Temporal and MinIO publish nothing at all. The role *asserts* this from the
rendered Compose config on every run, because a `3000:3000` slipping in is the
most likely way this stack would accidentally become reachable.

## Rollback

```bash
ansible-playbook playbooks/keel.yml --tags rollback --ask-vault-pass --ask-become-pass
```

⚠️ Moves the **code**, not the **schema**. Migrations are forward-only, so if the
forward deploy applied one, an older image meets a newer database. The task
prints what ran so the call is made on evidence; when a schema changed, restore
the matching backup instead.

With no registry, rollback also requires the previous image to still be in the
host's daemon. If it was pruned, redeploy that commit from source instead.
