# roles/keel

Deploys Keel to `dc1-x86` from an exact Git commit, building `linux/amd64` images
natively on that host. No registry. No release tag. The commit SHA is the only
version identity.

Paired with **meetyaks/keel** PR #10, which adds `infra/lab/compose.lab.yml` —
the stack definition this role installs. The role deliberately does **not** carry
its own copy of that file: two hand-maintained copies of one stack drift, and the
drift is silent until a deploy behaves unlike the tree it claims to be.

## The vault file you must create

`inventory/group_vars/vault.yml` — already covered by `.gitignore`, and it must
stay that way. It is not in this repository and never will be.

```bash
ansible-vault create inventory/group_vars/vault.yml
```

Define exactly these nine names. The role asserts all nine are present **before it
writes anything**, so a missing one stops the run rather than rendering a blank
credential into a live stack:

| variable | what it is |
|---|---|
| `keel_vault_admin_db_password` | `keel_admin` — owns DDL, used by the one-shot migration only |
| `keel_vault_app_db_password` | `keel_app_login` — NOBYPASSRLS, the request path |
| `keel_vault_blob_access_key` | object-store access key (also MinIO's root user) |
| `keel_vault_blob_secret_key` | object-store secret key (also MinIO's root password) |
| `keel_vault_oidc_client_secret` | OIDC client secret |
| `keel_vault_master_key` | credential-vault master key |
| `keel_vault_mfa_master_key` | MFA secret-encryption master key |
| `keel_vault_jwt_private_key` | RS256 private key, full PEM including headers |
| `keel_vault_jwt_public_key` | RS256 public key, full PEM including headers |

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
ansible-playbook playbooks/keel.yml --tags rollback
```

⚠️ Moves the **code**, not the **schema**. Migrations are forward-only, so if the
forward deploy applied one, an older image meets a newer database. The task
prints what ran so the call is made on evidence; when a schema changed, restore
the matching backup instead.

With no registry, rollback also requires the previous image to still be in the
host's daemon. If it was pruned, redeploy that commit from source instead.
