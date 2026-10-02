# The Keel DEV environment, and how it gets its releases

DEV is the Keel environment on `dc1-x86`. It runs **immutable, digest-pinned artifacts** built by CI from validated commits on `main`, and it reconciles to them automatically.

> ⚠️ **Not "attested artifacts".** An earlier draft of this document said that, and today it would be false. GitHub cannot persist artifact attestations for `meetyaks/keel` — see [Provenance, and what DEV actually gets](#provenance-and-what-dev-actually-gets). DEV deploys releases that declare `attestation.status: unavailable`, under an explicit policy that says so. Every other environment refuses them.

> **Nothing in this document deploys anything by being read.** The identity change and the launchd daemon are applied deliberately, in the order given under [Turning it on](#turning-it-on). **Neither credential the controller needs exists yet** — see [Authentication](#authentication-what-the-controller-needs-and-does-not-have).

## The two halves, and why they are separate

| | decides | does not |
|---|---|---|
| **CI** (`meetyaks/keel`, `.github/workflows/dev-release.yml`) | what is **eligible**: builds, gates, pushes by digest, **declares what provenance it could and could not produce**, publishes a release manifest and advances the channel | reach into any site |
| **The site controller** (`playbooks/keel-reconcile.yml`, here) | **when** to run an eligible release, and whether to refuse | build anything |

Collapsing these two turns *"CI is green"* into *"CI can deploy into the datacenter"*. A CI runner would also need DEV's vault passphrase, its SSH key, and a route to its database and durable storage.

**Neither CI VM is a deployment target.** `dc1-ci-1` (Keel CI) and `dc1-ci-tw-1` (Truewealth CI) are absent from this inventory entirely, and `tests/dev-environment-identity.yml` fails if either appears.

**The controller runs on `dc1-arm-1`**, the administration console and Ansible control node — not on `dc1-x86`. A host that decided what to run could decide wrongly, and would need its own credentials to fetch releases. See [The controller, and what it runs on](#the-controller-and-what-it-runs-on); the machine is named there rather than left as "wherever Ansible happens to run", which is how this document once ended up describing a laptop.

## The identity

| | |
|---|---|
| environment | `dev` |
| site | `dc1` |
| hostname | `keel-dev.dc1.lan` |
| channel | `dev` |
| automatic deployment | yes, for eligible releases only |

`keel.dc1.lan` is **reserved for a future PROD on separate hardware**. It is not recycled: leaving DEV on it would mean the eventual PROD cutover has to take a name away from a running environment.

All of it lives in [`inventory/group_vars/keel_dev/environment.yml`](../inventory/group_vars/keel_dev/environment.yml).

## What happens on each tick

```
release/dev : channels/dev.json
        │
        ▼
  read the channel ──▶ decide ──▶ converged?          stop, quietly
        │                     ├─▶ moved backwards?    REFUSE, escalate
        │                     ├─▶ out of retries?     REFUSE, escalate
        │                     └─▶ deploy
        ▼
  take the lock ──▶ record the attempt ──▶ roles/keel in release mode ──▶ record the outcome
        │                                          │
        └────────────── always released ───────────┴─▶ on failure: keep evidence, stop
```

`roles/keel` is the only thing that deploys. In **release mode** it takes the commit and the exact image digests from the manifest, **reads the release's provenance statement and applies this environment's policy to it**, proves the transferred compose bundle is byte-identical to the one CI gated, pulls the digests, and skips the host build entirely. Everything else — preflight, secrets, migrations through the compose `migrate` service, health verification — is unchanged.

### What the site refuses, and why

| refusal | reason |
|---|---|
| unknown channel or release schema | a field this reader does not know is exactly where a security-relevant instruction would be |
| an image with a tag, or a digest in the `repository` field | a tag is a mutable pointer; the same tag can be repushed to mean a different image |
| a release missing an image the bundle resolves | compose would fail *after* stopping the running stack |
| an incomplete provenance statement — no `attestation.status`, no `sbom.format`, a `sbom.sha256` that is not 64 hex | not "probably fine": a statement a site cannot reason about |
| `attestation.status` that is neither `persisted` nor `unavailable` | refusing beats guessing which way an unknown status should be read |
| `mechanism` and `attestation.status` that contradict each other | a document that looks signed to whichever field a reader happens to trust |
| `status: unavailable` with no `reason` | an operator accepting reduced assurance must be told what was unavailable and why |
| `status: unavailable` under the `require_persisted` policy | the default, and what a future PROD inherits by saying nothing |
| failed attestation verification on a `persisted` release | shape cannot detect substitution — only an attestation ties the bytes to a real build |
| `keel_release_require_provenance` set anywhere | retired; it no longer controls anything, and silently ignoring it would leave somebody believing they had configured something |
| a bundle whose hash differs from the manifest's | the bundle that would run is not the bundle that was gated |
| a release requiring a newer controller | a site older than the release must refuse, not guess |
| a channel naming an **older** release with no `advanced.rollback` | the channel moved backwards by accident, or is not the document CI wrote |
| a release that already used its retry allowance | a timer plus an unconditional retry is an infinite retry |
| a held deployment lock | two deployers interleaving `compose up` with a migration is how a schema ends up half-applied |
| `keel_deployment_mode: production` with password-only sign-in | Keel has no valid configuration for it: the validator requires OIDC, and the dev-login escape hatch that would satisfy it is itself forbidden in production. The stack migrates and then crash-loops |
| a `keel_deployment_mode` this role does not know | Keel reads an unrecognised `KEEL_ENV` as "no mode declared", satisfying neither the production checks nor the development affordances, so a typo must not fall through to permissive |

The last two are **preflight** refusals rather than release ones: they are decided from inventory before an image is pulled. They exist because on 2026-10-01 that combination was not refused — the deployment pulled, verified the bundle, applied **migrations**, and left a migrated database behind a gateway that never served. See [the role's README](../roles/keel/README.md#keel_deployment_mode--and-why-password-only-forces-it) for what `development` keeps and gives up.

### Failure is not rolled back automatically

Keel's migrations are **forward-only**; there is no down-migration runner. Redeploying the previous image does **not** restore the previous schema, so a site that rolled back would report a recovery that did not happen. Each release states this itself, in `migrations.requiresManualRecoveryOnFailure`.

On failure the controller keeps evidence under `/srv/data/services/keel/releases/evidence/<timestamp>-<releaseId>/` — the attempt, container state, recent logs per service, and which images the host actually holds — and escalates. It retries once more (`keel_reconcile_max_attempts: 2`) for a genuinely transient failure, then stops and waits for a person.

## Provenance, and what DEV actually gets

A `keel.release/v1` release makes a provenance **statement**, and the site asks two separate questions about it. Conflating them is how *"we could not attest it"* quietly becomes *"we did not check"*.

1. **Is the statement complete and coherent?** Asked of every release, under every policy. A release with no `attestation.status`, no SBOM identity, or a `mechanism` that contradicts its status is refused everywhere.
2. **Is it a statement this environment is willing to deploy?** Asked of the policy, and only environments differ here.

### The policy

`keel_release_provenance_policy` (`roles/keel/defaults/main.yml`) takes exactly two values. There is no third, no boolean, and no default at the point of use — an unset or misspelled value is refused rather than falling through to the permissive branch.

| value | accepts | where |
|---|---|---|
| `require_persisted` | only `attestation.status: persisted`, and verifies it with `gh attestation verify` | **the shipped default.** Every environment that says nothing — including a future PROD |
| `allow_unavailable` | also `status: unavailable`, provided the release says why | **`inventory/group_vars/keel_dev/` only.** `tests/dev-environment-identity.yml` fails if any other inventory file contains the string |

`allow_unavailable` **widens what is accepted; it does not weaken what is checked.** A `persisted` release is verified under either policy, and the SBOM identity, digest pinning, bundle hash and controller-version checks are identical.

> This replaced a boolean, `keel_release_require_provenance`, which conflated three different things: a fact about a release, an action the site takes, and a concession a test needed. It is **removed, not deprecated** — the role refuses to run if it is still set anywhere, because an operator who sets it believes they configured something they did not.

### Why DEV needs the exception

GitHub does not persist artifact attestations for **user-owned private repositories**, which is what `meetyaks/keel` is. This is an account-level limitation, not a workflow defect and not something a retry fixes. The producer therefore declares it, in the release itself:

```json
"provenance": {
  "mechanism": "none",
  "attestation": {
    "status": "unavailable",
    "reason": "GitHub artifact attestations are not available for user-owned private repositories (observed on run 36689645463); this release carries immutable image digests and an SBOM identity but no persisted provenance."
  },
  "sbom": { "format": "spdx-json", "sha256": "d3dfdb1b…" }
}
```

**What DEV still has:** immutable image digests, an SBOM identity, a byte-checked compose bundle, a release id that embeds its commit, and a channel that only advances along ancestry.

**What DEV does not have:** anything cryptographically tying those bytes to a build that happened in `meetyaks/keel`. A manifest someone edited to point at their own image would pass every structural check. The deployment says so, out loud, on every run:

```
⚠️ NOT ATTESTED — explicitly permitted by DEV policy
```

and `current.json` records it afterwards, so *"was what this host is running ever attested?"* is answerable from the host months later rather than only from a workflow log that expires.

**To remove the exception**, make attestations available — an organisation-owned repository, or a public one — and let the producer emit `status: persisted`. Then delete the line from `inventory/group_vars/keel_dev/environment.yml`; DEV inherits `require_persisted` by saying nothing, exactly as every other environment does. Nothing else changes.

### Controller version

The published release declares `minimumControllerVersion: 1.0.0`, and this controller is `1.0.0`. **Reading the provenance statement did not raise that number**, deliberately:

- `minimumControllerVersion` is the producer saying *"a site that cannot understand my document must refuse me"*. It is about **contract comprehension**, not about local posture. Two sites on the same controller version may legitimately set opposite policies.
- No field was added to `keel.release/v1`. `provenance.attestation` and `provenance.sbom` are already in the contract and already in the published release; this controller started *enforcing* them, which makes it stricter, not newer — and `minimumControllerVersion` cannot express a stricter consumer, only a newer one.
- **`1.0.0` has never shipped.** `roles/keel/tasks/release.yml` and `keel_controller_version` do not exist on `main`; the whole reader arrives with this PR. There is no deployed `1.0.0` for a floor to protect, and bumping to `1.1.0` would assert a predecessor that never existed — leaving the first producer floor naming a reader nobody ever ran.

Raise it when the role gains the ability to honour a **new required field** that an older reader would silently ignore. That is the only case where a producer needs to be able to say "older sites must refuse me" and be believed.

## Where the state is

On the host, beside the deployer's own directories, because "what is this host running" is a fact about the host:

```
/srv/data/services/keel/releases/
├── current.json                 the release this host is running, when, and
│                                under what assurance
├── attempts/<releaseId>.json    failed attempts, which bound the retries
├── evidence/<run>/              what went wrong, kept for the last 20
└── reconcile.lock/              held only during a deployment
```

`current.json`, `attempts/` and the failure evidence all carry `provenancePolicy`, `attestation`, `sbom` and `assurance`. That is the point of recording them: the DEV exception has to stay visible somewhere a person would look, long after the run that made it has scrolled away.

```json
{
  "releaseId": "keel-20261001T010103Z-5bb120c97b56",
  "provenancePolicy": "allow_unavailable",
  "attestation": { "status": "unavailable", "reason": "…" },
  "sbom": { "format": "spdx-json", "sha256": "d3dfdb1b…" },
  "assurance": "NOT ATTESTED — explicitly permitted by DEV policy"
}
```

The reconciler **records** the policy and can never **set** it: choosing this site's posture belongs in inventory, where an operator reads it. `tests/reconcile-boundaries.yml` holds both halves — no assignment, and all four fields present.

A lock is **never broken automatically**, however old it is — "probably stale" is doing too much work when being wrong means two deployers at once. The refusal prints the `rmdir` to clear it once you have confirmed no deployment is running.

## The controller, and what it runs on

> **The console is `dc1-arm-1`** — the Ansible control node, named in [`roles/keel/README.md`](../roles/keel/README.md): *"Run from `~/Projects/home-datacenter-starter` on dc1-arm-1"*. It is a Mac (the "arm" is Apple Silicon): `tests/controller-delegation.yml` records its own Ansible temp path as `/Users/…`, which only a macOS control node produces.

It is deliberately **not** `dc1-x86` — a host that decided what to run could decide wrongly — and deliberately **not** `dc1-ci-1` or `dc1-ci-tw-1`, because CI decides what is *eligible* and a site decides *when*.

> ⚠️ **Nor is it whichever laptop happens to have the repository cloned.** An earlier version of this document said the console was "already the Ansible control node" without naming a machine, which is how it came to be pointed at a developer's workstation — a corporate-managed Mac that sleeps every night, roams, and can be reimaged. A 15-minute reconciler on a machine that is asleep mostly does not run, and when the machine is wiped DEV stops reconciling with nothing to say why. The console is a datacenter machine, and it is named.

Because the console is macOS, the DEV path uses **launchd**. `tests/controller-scheduler.yml` asks the machine rather than assuming — that check exists because this repository first shipped **systemd units** for the console and told you to `systemctl enable --now keel-reconcile-dev.timer`, a command that cannot run there at all.

| | |
|---|---|
| live scheduler | [`…/files/launchd/com.meetyaks.keel-reconcile-dev.plist.template`](../roles/keel_reconcile/files/launchd/com.meetyaks.keel-reconcile-dev.plist.template), rendered by the bootstrap into `/etc/keel/` and copied to `/Library/LaunchDaemons/` by a person |
| retained, **unused** | [`roles/keel_reconcile/files/systemd/`](../roles/keel_reconcile/files/systemd/) — the variant for a future Linux controller. Installed nowhere. Kept because a Linux console is a plausible next step and the hardening is worth not re-deriving |

**The plist is a template because launchd has no variables.** Every path in it is absolute, and the checkout path is a fact about the machine. An earlier version was a constant naming `/opt/home-datacenter-starter` — invented rather than observed, and absent on the real console, whose checkout is in an operator's home. The daemon would have failed at load with status 127 and nothing would have explained why. The bootstrap renders `@@CHECKOUT@@`, `@@SERVICE_USER@@` and `@@LOG_DIR@@` from what is actually there, and refuses if any placeholder survives.

### One entrypoint, and the scheduler's whole job is *when*

Both schedulers invoke [`bin/keel-reconcile-dev`](../bin/keel-reconcile-dev) and nothing else. The inventory, the vault password path, the execution ceiling and the concurrency rule live in that one script. A plist that called `ansible-playbook` directly would be a second place those decisions live, and the copies drift — so `tests/controller-scheduler.yml` fails if any scheduler file mentions `ansible-playbook`.

| the wrapper | |
|---|---|
| configuration | `/etc/keel/reconcile.conf` — **paths only, never values** |
| noninteractive | no `--ask-vault-pass`, no `--ask-become-pass`; a scheduler cannot answer a prompt, and a run that waits for one hangs until its timeout |
| bounded | 3000s, below the 15-minute schedule's own patience and well under launchd's 3600s backstop |
| concurrency | an atomic `mkdir` lock on the controller, **in addition to** the deployment lock on the host — everything before the host lock (the clone, the decision, the registry login) would otherwise happen twice |
| exit status | Ansible's, unchanged. Plus `100` already running, `101` misconfigured, `102` timed out — each distinct, because "the vault file is missing" and "the deployment failed" need different responses from whoever reads the log |
| retries | none. The role's attempt ledger bounds them with state that survives a reboot; a loop here would defeat that bound without replacing it |

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/com.meetyaks.keel-reconcile-dev.plist
sudo launchctl print     system/com.meetyaks.keel-reconcile-dev
sudo launchctl kickstart -p system/com.meetyaks.keel-reconcile-dev   # run one tick now
sudo launchctl bootout   system/com.meetyaks.keel-reconcile-dev
```

**No `KeepAlive`.** It restarts a job the moment it exits, so a failed reconciliation would be restarted immediately and forever — defeating the role's two-attempt ledger and burying the one informative failure under a thousand identical ones. **No `RunAtLoad`** either: bootstrapping the daemon must not itself start a deployment.

## Authentication: what the controller needs, and does not have

Two private things stand between a correct controller and a working one. **Both are modelled in code and neither credential exists.** Nothing in this repository creates them.

### 1. The release channel and source — one SSH deploy key

`meetyaks/keel` is private, so `release/dev` is private too. Over HTTPS, git resolves that through the **credential helper** — a keychain, a personal token, a login session. That works when a person runs the playbook and fails the moment the scheduler does, as a different account, unattended.

> **An interactive developer credential is not proof that an unattended controller can read anything.** A green manual run proves a person was logged in.

So the channel remote is the SSH form and the controller authenticates with a **dedicated, repository-scoped, read-only deploy key**:

| | |
|---|---|
| key | `/etc/keel/keel-deploy-key`, mode **`0400`**, owned by the service account |
| host keys | `/etc/keel/known_hosts`, built from GitHub's **published** keys (`https://api.github.com/meta`, `ssh_keys`) — not from `ssh-keyscan`, which pins whatever answers |
| ssh | `-o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=yes` |

**One key covers both reads**, because `release/dev` and the release's source commit are in the *same* repository. The channel clone and the `git fetch` that makes the commit present on the controller use the same key and the same URL.

`roles/keel_reconcile/tasks/credentials.yml` refuses to go further if the key is absent, group- or world-readable, or owned by somebody else — and then **asks GitHub directly**, with `GIT_TERMINAL_PROMPT=0`, the `GIT_CONFIG_*` trio neutralised and `IdentityAgent=none`, so the operator's own credentials cannot answer on the service account's behalf. `IdentityAgent=none` is the one people leave out: on a developer's Mac an agent is usually loaded with a key that *can* read the repository, and without it this check would pass and prove nothing.

**`StrictHostKeyChecking` is not negotiable.** With `BatchMode=yes` there is nobody to answer the authenticity prompt, so the alternative to pinning is not *ask* — it is *accept whatever answered on port 22*, which is the path by which a site deploys a manifest handed to it by the wrong server. `accept_hostkey` on the git clone is the same thing wearing a friendlier name, and is explicitly `false`.

**Operator steps, when you are ready** (this repository does not do them):

1. `ssh-keygen -t ed25519 -N '' -f /etc/keel/keel-deploy-key -C keel-dev-controller` on the console, as the service account.
2. Add the **public** half to `meetyaks/keel` → Settings → Deploy keys. **Leave "Allow write access" unchecked.**
3. `chmod 0400 /etc/keel/keel-deploy-key && chown keeladmin /etc/keel/keel-deploy-key`.
4. Write `/etc/keel/known_hosts` from `https://api.github.com/meta`.
5. `ansible-playbook playbooks/keel-reconcile.yml --check` — the preflight will say whether it worked.

### 2. The images — one read-only GHCR token, from the vault

`ghcr.io/meetyaks/keel` and `…/keel-web` are **private packages**, and `docker pull` runs **on `dc1-x86`**, which has no `docker login`. An anonymous pull of a digest in a private package is refused with `denied`, and release mode does not build, so there is no fallback.

| | |
|---|---|
| vault keys | `keel_vault_registry_username`, `keel_vault_registry_token` in `inventory/group_vars/linux_servers/vault.yml` |
| scope | a classic PAT with **`read:packages` and nothing else**, or a fine-grained token scoped to those two packages. Not a personal token, not one that can write, not the one CI publishes with |
| where | the encrypted vault only. Never a command line, never a `.env`, never this document |

The handling, in [`roles/keel/tasks/registry.yml`](../roles/keel/tasks/registry.yml) and [`registry-logout.yml`](../roles/keel/tasks/registry-logout.yml):

- **Both halves are required before any mutation** — and emptiness counts as missing, because a vault key present with an empty value is the ordinary mistake. Discovering this after `compose up` has stopped the stack means the site is down and cannot come back.
- **The token goes over `--password-stdin`**, never `--password <token>`, which would put it in the host's process table for the life of the command and in the shell history of anyone reproducing the step.
- **Every task that touches it is `no_log: true`.** Not tidiness: a failed task prints its own arguments, and `-vvv` prints them on success too.
- **The registry is derived from the release and then checked** against `keel_release_expected_registry` (`ghcr.io`). `docker login` with no registry argument authenticates to *Docker Hub* — that is the accident this prevents.
- **Only the accepted manifest's digests are pulled**, and the host is asked afterwards what it actually holds under each one.
- **Logout runs in an `always` block**, so it happens whether the deployment succeeded or failed — and the host is then asked whether anything was left behind. `docker login` writes a base64 of `username:token` into `~/.docker/config.json`; not encrypted, just encoded. A logout that only ran on success would leave it there in exactly the case where somebody is about to go poking around.

> **Authenticating to a registry is not provenance.** It proves who you are to the registry and says nothing about who built the image. The digest and the [provenance policy](#provenance-and-what-dev-actually-gets) do that.

**Why `ansible.builtin.command` and not `community.docker.docker_login`:** the module talks to the daemon through the `docker` Python library, which `dc1-x86` does not have, and this repository declares only `community.general`. Every other docker interaction in `roles/keel` is the CLI through `command`, needing nothing on the host but docker itself. `--password-stdin` is the mechanism Docker documents precisely because it keeps the secret off the command line, which is the property that actually matters.

### 3. SSH, sudo and the vault password — prerequisites, not yet provisioned

Everything below is **documented, not created.** No file is written by this repository, and none of these exist yet.

> **Run the bootstrap; do not work down this table by hand.** It exists so you can check what the script did, and so a second console comes out the same as the first. Step-by-step: [runbook-provision-dev-controller.md](runbook-provision-dev-controller.md).
>
> ```bash
> # On dc1-arm-1, from the checkout:
> scripts/bootstrap-dev-controller.sh --check     # no sudo, changes nothing
> sudo scripts/bootstrap-dev-controller.sh
> ```

`$CHECKOUT` below is **derived, never configured**: the bootstrap script lives at `<checkout>/scripts/`, and `bin/keel-reconcile-dev` lives at `<checkout>/bin/`, so both work it out from their own location. On `dc1-arm-1` that is `~/Projects/home-datacenter-starter`.

| what | path | owner | mode | why |
|---|---|---|---|---|
| account the daemon runs as | **the owner of `$CHECKOUT`** by default | — | — | the account a manual run already happens as, so the credentials are usable immediately |
| …or a dedicated one | `KEEL_SERVICE_USER=keeladmin KEEL_CREATE_SERVICE_USER=1` | — | — | **opt-in.** A deployment should not depend on a person's login session or keychain — but adding a hidden account is a change to how that machine works, so the script never does it unasked |
| wrapper config | `/etc/keel/reconcile.conf` | `root` | `0644` | **paths only**; no value belongs here |
| vault password | `/etc/keel/vault-pass` | service account | **`0400`** | readable by that account and nobody else. Generated, never typed |
| GitHub deploy key | `/etc/keel/keel-deploy-key` | service account | **`0400`** | §1 above |
| pinned GitHub host keys | `/etc/keel/known_hosts` | `root` | `0444` | §1 above |
| rendered launchd job | `/etc/keel/com.meetyaks.keel-reconcile-dev.plist` | `root` | `0644` | **rendered, not loaded.** Copying it to `/Library/LaunchDaemons/` is a separate, deliberate step |
| SSH key for dc1-x86 | `~/.ssh/home_datacenter_admin` of the service account | service account | **`0400`** | the inventory's `ansible_ssh_private_key_file`. **Not created by the bootstrap** — it is a different credential with a different blast radius |
| pinned dc1-x86 host key | that account's `~/.ssh/known_hosts` | service account | `0600` | `host_key_checking = True` is already set in `ansible.cfg` and stays on |
| log directory | `/var/log/keel/` | service account | `0750` | where the plist sends stdout and stderr |

**The sudo rule on `dc1-x86`** is scoped to what the playbook actually needs, not blanket `NOPASSWD`. An unattended run cannot answer `--ask-become-pass`, and the fix for that is a narrow rule rather than a wide one:

```sudoers
# /etc/sudoers.d/keel-reconcile on dc1-x86 — NOT created by this repository.
# Scope it to the commands the playbook runs, then tighten it against a real
# run's output rather than guessing wider than necessary.
labadmin ALL=(root) NOPASSWD: /usr/bin/docker, /usr/bin/systemctl, /bin/mkdir, /bin/chown, /bin/chmod
```

**And none of it goes in the plist.** A file in `/Library/LaunchDaemons` is world-readable and `launchctl print` shows its environment to anyone who asks. `tests/controller-scheduler.yml` fails if anything credential-shaped appears in a scheduler file, a unit file or the wrapper.

## Operating it

**By hand**, as a person at a terminal — this is how the first deployment is done:

```bash
# What would it do right now? Changes nothing.
ansible-playbook playbooks/keel-reconcile.yml --check --diff --ask-vault-pass --ask-become-pass

# Reconcile now.
ansible-playbook playbooks/keel-reconcile.yml --ask-vault-pass --ask-become-pass

# Report drift without deploying, whatever the channel says.
ansible-playbook playbooks/keel-reconcile.yml -e keel_reconcile_auto_deploy=false --ask-vault-pass --ask-become-pass

# Allow another attempt at a release that used up its allowance, once the
# cause is understood.
ssh dc1-x86 'sudo rm /srv/data/services/keel/releases/attempts/<releaseId>.json'
```

**Unattended**, through the wrapper — this is what launchd runs, and what you run to reproduce what launchd did:

```bash
# One tick, exactly as the daemon would do it. No prompts.
# On dc1-arm-1, from the checkout. Works out its own paths.
bin/keel-reconcile-dev
bin/keel-reconcile-dev --check

# Or as the service account, if you provisioned a dedicated one:
sudo -u keeladmin bin/keel-reconcile-dev

# Or ask launchd to run one now.
sudo launchctl kickstart -p system/com.meetyaks.keel-reconcile-dev

tail -f /var/log/keel/reconcile-dev.log
```

> ⚠️ **`--ask-vault-pass` is not a smaller version of the unattended path; it is a different one.** A manual run succeeds with the operator's git credentials, their ssh-agent and their keychain — none of which the service account has. Use the wrapper, as `keeladmin`, to find out what the scheduler will actually do.

A **rollback** is published by CI, not decided here: re-run `dev-release.yml` with `rollback: true` against the older commit. The channel entry then records `advanced.rollback: true`, which is what makes the site accept a backwards move — and what distinguishes it from the straggler the guard exists to stop.

## Delivery sequence

Both halves must land, in order, and the order matters: a site that can consume releases before any release exists is harmless, but a channel publishing into a site that cannot read its provenance statement is not.

| # | where | step | stop if |
|---|---|---|---|
| 1 | keel | merge the DEV release channel PR to `main` | the eligibility gate is not green on the PR itself |
| 2 | keel | let `dev-release.yml` run on `main` and publish the **first** release | the gate fails on `main` — that is the gate doing its job, not a reason to bypass it |
| 3 | keel | read `channels/dev.json` on `release/dev` by hand and check it names two digest-pinned images, a bundle hash, and a `platformVersion` | anything is tagged rather than digested |
| 4 | keel | read `provenance.attestation.status` and **check it against what you expect of this repository**. `persisted` → verify it: `gh attestation verify oci://…@<digest> --repo meetyaks/keel`, for both images and the manifest file. `unavailable` → read the `reason` and decide whether it is one you accept | the status and the `mechanism` disagree, or an `unavailable` reason is missing or is not a real limitation |
| 5 | infra | merge `deploy/keel-lab` (PR #1), then this PR | — |
| 6 | **dc1-arm-1** | clone the repository, then `sudo scripts/bootstrap-dev-controller.sh` — it creates `/etc/keel/*`, `/var/log/keel/`, the deploy key, the host-key pin and the vault password, and renders the plist | it reports a refusal; read it rather than forcing past it |
| 7 | github | create the **read-only deploy key** ([§1](#1-the-release-channel-and-source--one-ssh-deploy-key)) and the **read-only GHCR token** ([§2](#2-the-images--one-read-only-ghcr-token-from-the-vault)); put the token in the vault | either can write. **This is where the sequence currently stops** |
| 8 | dc1-x86 | add the scoped sudo rule | it is blanket `NOPASSWD` |
| 9 | dns | create `keel-dev.dc1.lan` → dc1-x86 | — |
| 10 | infra | apply the identity. **This invalidates live sessions** — the JWT issuer appears in already-issued tokens | outside an acceptable window |
| 11 | infra | `ansible-playbook playbooks/keel-reconcile.yml --check --diff` and read the decision | the credential preflight refuses, or it does not name the release you read at step 3 |
| 12 | infra | run it for real, **watching**, and confirm `/srv/data/services/keel/releases/current.json` names that release **and the assurance you expected** | health verification fails — evidence is kept, and recovery is manual |
| 13 | **dc1-arm-1** | copy the rendered plist into `/Library/LaunchDaemons/` and `sudo launchctl bootstrap system …` | steps 11 and 12 have not both been done by hand at least once |

Steps 1–4 are the producing side and change nothing on any host. **Steps 1–4 are done**: `release/dev` exists and carries `keel-20261001T010103Z-5bb120c97b56`, whose attestation status is `unavailable` for the reason above. Steps 6–8 are the prerequisites, and nothing in this repository creates them. Steps 9–12 are one deliberate, watched deployment.

**Step 13 is last on purpose, and the ordering is not a formality.** Automatic scheduling is enabled only after the manual deployment has succeeded and been watched by a person. A mechanism nobody has seen work should not first run unattended at 3am — and the first run is the one that will discover whether the two credentials actually work, because nothing before it can.

## Blockers, before the first deployment

| # | blocker | status |
|---|---|---|
| 1 | **No GitHub deploy key.** The controller cannot read the private channel or fetch the release's commit without one | **modelled, not provisioned.** The contract, the preflight and the refusals are in code and tested; §1 above has the operator steps |
| 2 | **No GHCR read-only token.** `dc1-x86` cannot pull the two private digests | **modelled, not provisioned.** The vault keys are named and the handling is in code and tested; §2 above has the scope |
| 3 | **No service account, vault-pass file, SSH key, known_hosts, log directory or sudo rule on the console or the host** | **documented, not created.** §3 above |

> **Private channel access and GHCR pull have never been exercised with real credentials, and cannot be until they exist.** Every test in this repository proves the code refuses correctly, handles the secret safely, and gives it back — none of them proves authentication succeeds. That is the one thing the first manual deployment will establish.

**Not a blocker**, recorded so it is not rediscovered: `release/dev` carries **6,031 files** in its tree, where the channel needs two JSON documents. That costs a slower clone on every tick and nothing else. It is producer-side shape and belongs in the Keel repository, not here.

## Turning it on

Steps 6 onwards, in detail. **None of this is done, and none of it is done by this repository.**

1. **Run the bootstrap on `dc1-arm-1`**: `scripts/bootstrap-dev-controller.sh --check`, read it, then `sudo scripts/bootstrap-dev-controller.sh`. It provisions everything in [§3](#3-ssh-sudo-and-the-vault-password--prerequisites-not-yet-provisioned) and is idempotent — a second run reports "already present" and regenerates no secret.
2. **Create the deploy key** ([§1](#1-the-release-channel-and-source--one-ssh-deploy-key)) and pin GitHub's host keys. Read-only; leave "Allow write access" unchecked.
3. **Create the GHCR token** ([§2](#2-the-images--one-read-only-ghcr-token-from-the-vault)) with `read:packages` and nothing else, and put it in the vault.
4. **Add the scoped sudo rule** on `dc1-x86`. An unattended run cannot answer `--ask-become-pass`, and blanket `NOPASSWD` is not the way to fix that.
5. **Create the DNS record** `keel-dev.dc1.lan` → `dc1-x86`. Nothing in this repository creates DNS.
6. **Apply the identity.** `keel_hostname` changes the Caddy route, the CORS origin, and the JWT and OIDC issuers. **The issuer appears in already-issued tokens, so applying it invalidates live sessions** — do it when that is acceptable, and expect to sign in again.
7. **Deploy by hand, watching.** `ansible-playbook playbooks/keel-reconcile.yml --check` first, then a real run. Then **run it once through the wrapper as `keeladmin`**, because that is the only thing that proves the service account's own credentials work. Read `current.json` afterwards and confirm the `assurance` line says what you expect — on DEV today that is `NOT ATTESTED — explicitly permitted by DEV policy`.
8. **Only then** install the daemon:
   ```bash
   sudo cp /etc/keel/com.meetyaks.keel-reconcile-dev.plist /Library/LaunchDaemons/
   sudo launchctl bootstrap system /Library/LaunchDaemons/com.meetyaks.keel-reconcile-dev.plist
   sudo launchctl print system/com.meetyaks.keel-reconcile-dev
   ```

Until step 8, DEV reconciles when somebody runs the playbook — which is a reasonable place to stop and watch it for a while. **Step 8 is deliberately after step 7**: scheduling is enabled only once a manual deployment has succeeded and been watched.

## Tests

```bash
tests/run-all.sh                        # everything, including the twelve suites below
KEEL_SKIP_MUTATIONS=1 tests/run-all.sh  # the quick loop; leaves the guards UNPROVEN
```

| suite | what it establishes |
|---|---|
| `controller-scheduler.yml` | **asks the machine which OS it is** and requires the scheduler that OS can run; every scheduler — live and retained — invokes only the wrapper, never restarts into a loop, and carries no credential |
| `run-wrapper-behaviour.sh` | the wrapper **executed**: Ansible's exit status survives unchanged (0, 1, 2, 4, 99), a second concurrent run is refused with its own status, the lock is released after success *and* failure, a missing prerequisite is refused before anything runs |
| `credential-contract.yml` | the deploy-key preflight **exercised** against absent, world-readable, group-readable, mis-owned and unpinned fixtures, plus an HTTPS remote; and the registry token's handling — stdin not argv, `no_log`, `ghcr.io` only, digests only, logout in `always`, nothing in the records, no value committed |
| `run-auth-mutations.sh` | **breaks all of that seventeen ways** and proves the suites notice, each for its own reason. One mutation needs `plutil` and is skipped — loudly — off a Mac |
| `dev-environment-identity.yml` | the names, read from inventory; no CI VM is a deployment target; DEV declares `allow_unavailable` and **no other inventory file may** |
| `release-contract.yml` | 28 cases against the role's own reader: schema, digest-only, identity, role coverage, controller version, and every provenance state under both policies |
| `reconcile-decisions.yml` | 8 decision cases, plus that the shipped defaults are the safe ones |
| `reconcile-lock.yml` | acquire, contend, release-and-retake — exercised, not grepped |
| `reconcile-boundaries.yml` | one deployer, one migration owner, no verification bypass, no retry loop; the reconciler records the policy and cannot set it |
| `run-reconcile-check-mode.sh` | a real `--check` run against a real channel repository, changing nothing |
| `published-release-proof.yml` + `run-published-release-check-mode.sh` | the reader and the reconciler against a byte-for-byte copy of the **actually published** `release/dev` document — refused under the default, resolved under DEV's policy, verified never, deployed never |
| `run-provenance-mutations.sh` | **breaks the policy eleven ways and proves the suites notice** — each one for its own reason, because a rejection for the wrong reason is not a pass |

Two things those suites do that are worth knowing about:

- **The contract cases run the role's own `tasks/release.yml`.** They restate no assertion. A harness carrying its own copy of the contract would pass against a contract the role does not have.
- **`gh` is replaced by a stub that records every call.** That is evidence, not a workaround: a `persisted` fixture's digests were never published, so the real `gh attestation verify` could not succeed offline — and the log is what proves that a `persisted` release *does* reach verification and an `unavailable` one *never* does.

The producing side's contract tests live in the Keel repository: `node --test scripts/release/release.test.mjs`. **Both readers exist on purpose**: a contract only one side can check is not a contract, and if they ever disagree the release is refused here, which is the safe direction.
