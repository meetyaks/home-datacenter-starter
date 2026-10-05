# Semaphore UI on dc1-arm-1

The operator interface for the home datacenter's control plane.

> **Not deployed yet.** At the time of writing this describes a reviewed,
> tested change that has not been applied to dc1-arm-1. Nothing in this
> document should be read as a statement about a running service. The
> watched deployment is the step that changes that.

## What Semaphore is, and is not, allowed to do

Git is the source of truth. Semaphore is an operator UI and a controlled job
runner in front of it.

| it may | it may not |
|---|---|
| show projects, inventories and templates | hold the canonical inventory in its own database |
| fetch reviewed Git branches | create host configuration outside Git |
| run existing playbooks from this repository | build images, or replace GitHub Actions |
| show logs and task history | act as a CI runner, or run product workloads |
| later: run approved schedules | manipulate Docker outside reviewed Ansible roles |
| later: hold its own SSH and vault credentials | use the operator's private SSH keys |

Infrastructure changes remain reviewed Git changes. If the UI and the
repository ever disagree, the repository wins — and
`tests/semaphore-config.yml` fails the build if the project is pointed
anywhere other than this repository's `main`.

## Architecture

A native macOS binary under launchd, with SQLite.

**Why not Docker.** Docker Desktop is not the datacenter's control authority
and should not become a dependency of it: it introduces a login/session
requirement, complicates access to Ansible, Python, SSH and `known_hosts`,
and would mean mounting controller credentials into a container. A native
binary is officially supported on Darwin ARM64.

**Why SQLite.** One controller, one operator, low job concurrency, trivial
backup. Introducing a database service before the UI itself has been
validated is work without a reason. The choice is meant to stay replaceable:
only `tasks/database.yml` and the config template know which engine is in
use.

## The pinned release

Everything below was verified on 2026-10-04 by downloading the artifacts,
comparing them against the official checksum file published in the same
release, extracting them and running them — not copied from documentation.

| | |
|---|---|
| release | <https://github.com/semaphoreui/semaphore/releases/tag/v2.19.12> |
| published | 2026-08-30, `prerelease: false`, `draft: false` |
| edition | **community** |
| artifact (controller) | `semaphore_community_2.19.12_darwin_arm64.tar.gz` |
| SHA-256 | `f99cd2829722c9f4a7074cafa07a43ad7f027055b0b0eb48931059d38c62261e` |
| artifact (CI) | `semaphore_community_2.19.12_linux_amd64.tar.gz` |
| SHA-256 | `2576f8a473c5e91bd0d7833976111c56f0ad43720210f9ca437037d10acd97cc` |
| checksum file | `semaphore_community_2.19.12_checksums.txt` (same release) |
| `semaphore version` | `2.19.12-012ed06-1788086239` |

**The community edition, deliberately.** This release publishes two artifact
families: `semaphore_<ver>_…` (97 MB on darwin_arm64) and
`semaphore_community_<ver>_…` (48 MB). Both ship an MIT licence and report
the same commit, but the larger one bundles the licensed Pro feature set.
This installation has no Pro licence, so it installs the open edition rather
than shipping code it cannot enable.

The two are distinguishable at runtime: the standard build reports
`…-1788086244`, the community build `…-1788086239`. `verify.yml` asserts the
exact string, so installing the wrong edition from a correct-looking URL is
caught.

No `latest`, no prerelease, no Docker Hub image, no Homebrew formula. An
upgrade is a reviewed change to three lines in `defaults/main.yml` plus a
watched deployment.

## Service identity

A dedicated, hidden, non-login account: **`_semaphore`**.

Not root, and not the human `dc1-arm-1` account. Semaphore executes
playbooks, so its identity is the blast radius of every job it runs: as the
operator it would hold the operator's SSH keys and keychain; as root it
would hold everything.

- created by `ansible.builtin.user` with `system: yes`, which drives `dscl`,
  sets `IsHidden` and allocates a free UID below 500 by scanning the
  existing ones — no hardcoded number, so no silent collision
- shell `/usr/bin/false`, no password, no administrative group membership
  (asserted, not assumed)
- the role **refuses** rather than adopting an account of that name whose
  home is not the Semaphore state directory
- it is asserted that the account cannot read `/Users/dc1-arm-1/.ssh`

**Removal.** `sudo dscl . -delete /Users/_semaphore` and
`sudo dseditgroup -o delete _semaphore`, after booting out the daemon. Do
this only when removing Semaphore entirely; the state directory is owned by
that account and will be orphaned.

## Filesystem

| what | where |
|---|---|
| versioned binary | `/usr/local/libexec/semaphore/2.19.12/semaphore` |
| stable link | `/usr/local/sbin/semaphore` |
| configuration | `/usr/local/etc/semaphore/config.json` (0600, `_semaphore`) |
| database | `/usr/local/var/lib/semaphore/semaphore.db` (0600) |
| repo/task cache | `/usr/local/var/lib/semaphore/tmp` |
| backups | `/usr/local/var/lib/semaphore/backups` |
| logs | `/var/log/semaphore/semaphore.{log,err}` |
| launchd job | `/Library/LaunchDaemons/org.dc1.semaphore.plist` |

The binary is immutable per version and the stable link is replaced
atomically, so an upgrade is a new directory plus a moved link and a
rollback is moving the link back. Nothing durable lives in a user home or in
`/tmp`, which macOS prunes.

## Network exposure

**Loopback only: `127.0.0.1:3000`.** No LAN listener, no
`semaphore.dc1.lan` record, no reverse proxy, no certificate. `verify.yml`
reads the socket table and fails if anything is bound to `0.0.0.0`.

Access is an SSH tunnel:

```bash
ssh -L 3000:127.0.0.1:3000 dc1-arm-1@10.0.0.22
# then open http://127.0.0.1:3000
```

`https://semaphore.dc1.lan` is a later, separate decision that depends on
Orbi DNS activation and a TLS choice. Being loopback-only is not a reason to
weaken authentication.

## Secrets

Four, all vaulted, none with a usable default:

| variable | what it is |
|---|---|
| `vault_semaphore_cookie_hash` | session cookie HMAC key |
| `vault_semaphore_cookie_encryption` | session cookie encryption key |
| `vault_semaphore_access_key_encryption` | **AES key for every stored credential** |
| `vault_semaphore_admin_password` | the administrator's password |

The two AES keys must be base64 decoding to exactly 16, 24 or 32 bytes —
upstream validates this and refuses at server start. Generate with:

```bash
openssl rand -base64 32
```

The role checks all four for presence and shape **before it creates
anything**, so a run without the vault stops while the host is untouched
rather than leaving a half-built service.

### ⚠️ Losing `access_key_encryption` loses every stored credential

The database holds only ciphertext. That key is the only thing that decrypts
it, it is not recoverable from a backup, and nothing will warn you until you
try to use a stored SSH key. It must survive upgrades, reinstalls and
restores. Keep it in the vault, and keep the vault backed up somewhere other
than the controller.

### The first administrator is created by hand, once

v2.19.12 creates users two ways and only one of them is safe:

| mechanism | password goes | verdict |
|---|---|---|
| `semaphore users add --password …` | **argv**, readable by any local account via `ps` | rejected |
| `semaphore setup` | **stdin** | used |

`no_log` hides a password from Ansible's log and from nothing else, so the
automated path was **removed entirely** rather than left as an opt-in flag —
a capability that exists can be switched on.

`setup` is not something a converging role can run either: it calls
`GenerateSecrets()` and rewrites `config.json` on every invocation. Verified
on 2026-10-04: a second run rotated `access_key_encryption` from `HMF98JFG…`
to `eab6YytE…`. With any Key Store credential present that would make all of
them permanently undecryptable.

So the role installs an interactive helper and stops:

```bash
sudo /usr/local/sbin/semaphore-bootstrap-admin
```

It refuses unless it is on the controller, run as root, attached to a real
terminal, the service is stopped, the database has **0 users and 0 stored
credentials**, and it has never run before. It prompts with echo off, asks
twice, and hands the password to `setup` on stdin — never argv, never the
environment, never a file. It then discards setup's temporary configuration
(which setup writes **0644**, with key material in it) and leaves a
non-secret marker.

**The administrator survives the key swap**, which is what makes this work.
Verified against the real binary: an administrator created under setup's
temporary key authenticated successfully (HTTP 204) against a server
configured with a completely different `access_key_encryption`, while a wrong
password returned 401. The password is bcrypt in the `user` table and does
not involve the encryption key.

### The role converges in two stages

**Stage 1** installs the binary, creates the account and directories, writes
the configuration, migrates the database — then **stops**, because no
administrator exists. The service is never defined or started: an empty
Semaphore left listening is an unauthenticated initialisation surface.

**Operator** runs the helper above.

**Stage 2** re-runs the role. It finds the administrator, starts the service
and verifies it.

## First login and mandatory TOTP

v2.19.12 has **no setting that centrally forces TOTP enrolment**. This is
therefore an operator acceptance control, not an automated enforcement
claim, and the deployment is not complete until the sequence below has been
performed and the second factor observed.

1. Open the tunnel — there is no LAN listener:
   `ssh -L 3000:127.0.0.1:3000 dc1-arm-1@10.0.0.22`
2. Confirm the listener is still loopback only:
   `sudo lsof -nP -iTCP:3000 -sTCP:LISTEN` shows `127.0.0.1:3000` and
   nothing on `0.0.0.0`.
3. Log in as `dc1admin` with the password set during bootstrap.
4. Enrol TOTP in user settings.
5. Capture the recovery codes if any are offered.
6. Store that recovery material **outside Git and outside the controller** —
   a password manager or a printed copy. On the controller it would be
   protected by exactly the thing it is meant to recover.
7. Log out.
8. Log in again.
9. **Prove the second factor is requested.** A password-only login must not
   succeed.
10. Only then is the deployment complete.

## The first project, created by hand

⚠️ **Semaphore's project objects are database state, configured manually,
and are NOT declaratively managed.** Creating them through the API would
require an administrative token handled in automation, which is the same
class of exposure the argv bootstrap was rejected for. A later milestone may
manage them through a scoped token once that security model has been
designed; until then, what is in the UI is not described by Git, and that
is a known, accepted gap rather than an oversight.

After deployment, first login and TOTP enrolment, create exactly:

| | |
|---|---|
| Project | `DC1 Control Plane` |
| Repository | `https://github.com/meetyaks/home-datacenter-starter.git` |
| Branch | `main` |
| Inventory | the repository-backed `inventory/hosts.yml` |

The inventory must be the **repository-backed file**, never an independently
edited static copy pasted into the UI. A host list maintained in Semaphore's
database is a second source of truth that drifts silently from Git.

The first task template is a controller-local, read-only validation — a
syntax or inventory check that mutates nothing:

```
ansible-playbook --syntax-check playbooks/semaphore.yml
```

With all of the following **absent**:

- no SSH credential
- no vault credential
- no sudo / become credential
- no schedule
- no webhook
- no arbitrary shell command
- no branch override
- no unrestricted extra-vars or survey variables
- no mutating playbook, no deployment
- no DNS reconciliation task
- no Keel reconciliation task

Semaphore has no deployment authority in this milestone. Changing
infrastructure remains a reviewed Git change.

## Backup and restore

```bash
sudo -u _semaphore /usr/local/sbin/semaphore-backup [destination]
```

**SQLite runs in WAL mode** — verified; `semaphore.db-wal` and
`semaphore.db-shm` sit beside the database. Copying `semaphore.db` alone, the
obvious thing to do, silently produces a backup missing everything still in
the WAL. The script uses `VACUUM INTO`, which asks SQLite for a consistent
single-file snapshot and is safe while the service is running, then runs
`PRAGMA integrity_check` on the result and refuses to report success if it
fails.

Backups are 0600 and are **not** a complete restore on their own:

```
restore = backup file + vault_semaphore_access_key_encryption
```

That separation is deliberate — a stolen backup is not a stolen credential
store. The Linux harness proves it by searching a real backup for the
encryption key and requiring its absence.

**To restore:** stop the daemon, put the backup at the database path, make
sure the vault still holds the original `access_key_encryption`, and start
it. Restoring with a *different* key leaves stored credentials unreadable
while everything else appears to work.

No backup schedule is installed. Scheduling is a separate milestone.

## Upgrading

1. Find the new release and its official checksum file.
2. Download the artifact, verify its SHA-256 against that file, run it to
   read the version string back.
3. Update `semaphore_version`, the two checksums and
   `semaphore_expected_version` in `roles/semaphore/defaults/main.yml`.
4. Open a PR; CI runs the role end to end against the new pin.
5. Deploy, watched.

The previous version stays in `/usr/local/libexec/semaphore/<old>/`, so a
rollback is re-pointing the stable link and restarting — no re-download.

## Logs and troubleshooting

```bash
sudo tail -n 100 /var/log/semaphore/semaphore.log
sudo tail -n 100 /var/log/semaphore/semaphore.err
sudo launchctl print system/org.dc1.semaphore
curl -sS http://127.0.0.1:3000/api/ping      # expects exactly: pong
```

`/api/ping` is the health endpoint, found by probing the real binary. Note
that `/ping` **also** returns 200 — it is the single-page-app catch-all — so
check the body, not just the status. `verify.yml` does.

**Jobs fail with "executable not found".** launchd sources no shell profile,
so the interactive Homebrew PATH does not exist for this process. The
daemon's PATH is set explicitly in the plist, and `platform.yml` resolves
`ansible-playbook`, `ansible-galaxy`, `python3`, `git` and `ssh` against that
same list and refuses to proceed if one is missing.

**The service will not start after a config change.** `configure.yml` parses
the rendered JSON before anything restarts, so this is more likely a bad
value than bad syntax. Check `semaphore.err`.

## Testing

| suite | what it covers |
|---|---|
| `tests/semaphore-config.yml` | the pin, exposure, identity, secret contract, Git's authority |
| `tests/semaphore-task-shape.yml` | conditional shapes, `no_log` coverage, flush and preflight ordering |
| `tests/semaphore-harness-integrity.yml` | the harnesses' own safety properties |
| `tests/run-semaphore-linux.sh` | **executes the role** on a disposable systemd container |
| `tests/run-semaphore-linux.sh --red` | removes the flush and requires the run to fail |
| `tests/run-semaphore-launchd.sh` | **executes the role** on disposable launchd, operator-run |
| `tests/run-semaphore-mutations.sh` | breaks each guard and requires the matching failure |

### What the macOS harness does not cover

It sets `semaphore_manage_account: false` and overrides `semaphore_user` to the invoking account, so it **creates no service account** — creating and deleting a real hidden `dscl` account on a workstation is exactly the permanent change a disposable test must not make. The default is `true` and `tests/semaphore-config.yml` fails if that changes, so the override cannot become the shipped behaviour.

So the `dscl` account path is exercised on Linux (where the container is
discarded) and on the real controller during the watched deployment — never
on a workstation. That is a genuine gap, and it is the thing to watch first
when the deployment runs.

## Later, and deliberately not now

- `semaphore.dc1.lan` with TLS, after Orbi DNS activation
- dedicated SSH and vault credentials in Semaphore's encrypted key store —
  this milestone copies no key and the role asserts the service account
  cannot read the operator's `~/.ssh`
- a mapping from `release/dev` to approved reconciliation
- any scheduled or mutating template
