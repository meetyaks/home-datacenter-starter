# The Keel DEV environment, and how it gets its releases

DEV is the Keel environment on `dc1-x86`. It runs **immutable, attested artifacts** built by CI from validated commits on `main`, and it reconciles to them automatically.

> **Nothing in this document deploys anything by being read.** The identity change and the scheduling units are applied deliberately, in the order given under [Turning it on](#turning-it-on).

## The two halves, and why they are separate

| | decides | does not |
|---|---|---|
| **CI** (`meetyaks/keel`, `.github/workflows/dev-release.yml`) | what is **eligible**: builds, gates, pushes by digest, attests, publishes a release manifest and advances the channel | reach into any site |
| **The site controller** (`playbooks/keel-reconcile.yml`, here) | **when** to run an eligible release, and whether to refuse | build anything |

Collapsing these two turns *"CI is green"* into *"CI can deploy into the datacenter"*. A CI runner would also need DEV's vault passphrase, its SSH key, and a route to its database and durable storage.

**Neither CI VM is a deployment target.** `dc1-ci-1` (Keel CI) and `dc1-ci-tw-1` (Truewealth CI) are absent from this inventory entirely, and `tests/dev-environment-identity.yml` fails if either appears.

**The controller runs on the administration console**, which is already the Ansible control node — not on `dc1-x86`. A host that decided what to run could decide wrongly, and would need its own credentials to fetch releases.

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

`roles/keel` is the only thing that deploys. In **release mode** it takes the commit and the exact image digests from the manifest, verifies provenance, proves the transferred compose bundle is byte-identical to the one CI gated, pulls the digests, and skips the host build entirely. Everything else — preflight, secrets, migrations through the compose `migrate` service, health verification — is unchanged.

### What the site refuses, and why

| refusal | reason |
|---|---|
| unknown channel or release schema | a field this reader does not know is exactly where a security-relevant instruction would be |
| an image with a tag, or a digest in the `repository` field | a tag is a mutable pointer; the same tag can be repushed to mean a different image |
| a release missing an image the bundle resolves | compose would fail *after* stopping the running stack |
| failed provenance verification | shape cannot detect substitution — only an attestation ties the bytes to a real build |
| a bundle whose hash differs from the manifest's | the bundle that would run is not the bundle that was gated |
| a release requiring a newer controller | a site older than the release must refuse, not guess |
| a channel naming an **older** release with no `advanced.rollback` | the channel moved backwards by accident, or is not the document CI wrote |
| a release that already used its retry allowance | a timer plus an unconditional retry is an infinite retry |
| a held deployment lock | two deployers interleaving `compose up` with a migration is how a schema ends up half-applied |

### Failure is not rolled back automatically

Keel's migrations are **forward-only**; there is no down-migration runner. Redeploying the previous image does **not** restore the previous schema, so a site that rolled back would report a recovery that did not happen. Each release states this itself, in `migrations.requiresManualRecoveryOnFailure`.

On failure the controller keeps evidence under `/srv/data/services/keel/releases/evidence/<timestamp>-<releaseId>/` — the attempt, container state, recent logs per service, and which images the host actually holds — and escalates. It retries once more (`keel_reconcile_max_attempts: 2`) for a genuinely transient failure, then stops and waits for a person.

## Where the state is

On the host, beside the deployer's own directories, because "what is this host running" is a fact about the host:

```
/srv/data/services/keel/releases/
├── current.json                 the release this host is running, and when
├── attempts/<releaseId>.json    failed attempts, which bound the retries
├── evidence/<run>/              what went wrong, kept for the last 20
└── reconcile.lock/              held only during a deployment
```

A lock is **never broken automatically**, however old it is — "probably stale" is doing too much work when being wrong means two deployers at once. The refusal prints the `rmdir` to clear it once you have confirmed no deployment is running.

## Operating it

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

A **rollback** is published by CI, not decided here: re-run `dev-release.yml` with `rollback: true` against the older commit. The channel entry then records `advanced.rollback: true`, which is what makes the site accept a backwards move — and what distinguishes it from the straggler the guard exists to stop.

## Delivery sequence

Both halves must land, in order, and the order matters: a site that can consume releases before any release exists is harmless, but a channel that publishes into a site that cannot verify provenance is not.

| # | where | step | stop if |
|---|---|---|---|
| 1 | keel | merge the DEV release channel PR to `main` | the eligibility gate is not green on the PR itself |
| 2 | keel | let `dev-release.yml` run on `main` and publish the **first** release | the gate fails on `main` — that is the gate doing its job, not a reason to bypass it |
| 3 | keel | read `channels/dev.json` on `release/dev` by hand and check it names two digest-pinned images, a bundle hash, and a `platformVersion` | anything is tagged rather than digested |
| 4 | keel | `gh attestation verify oci://…@<digest> --repo meetyaks/keel` for both images, and for the manifest file | verification fails — the site would refuse anyway, and better to learn it here |
| 5 | infra | merge `deploy/keel-lab` (PR #1), then this PR | — |
| 6 | dns | create `keel-dev.dc1.lan` → dc1-x86 | — |
| 7 | infra | apply the identity. **This invalidates live sessions** — the JWT issuer appears in already-issued tokens | outside an acceptable window |
| 8 | infra | `ansible-playbook playbooks/keel-reconcile.yml --check --diff` and read the decision | it does not name the release you verified at step 3 |
| 9 | infra | run it for real, watching, and confirm `/srv/data/services/keel/releases/current.json` names that release | health verification fails — evidence is kept, and recovery is manual |
| 10 | console | provision `/etc/keel/vault-pass` (`0400`) and the scoped sudo rule | — |
| 11 | console | install the units and `systemctl enable --now keel-reconcile-dev.timer` | steps 8 and 9 have not both been done by hand at least once |

Steps 1–4 are the producing side and change nothing on any host. Steps 5–9 are one deliberate, watched deployment. Steps 10–11 are what makes it unattended, and are deliberately last: a mechanism nobody has watched work should not first run at 3am.

## Turning it on

Steps 6 onwards, in detail. Not yet done:

1. **Create the DNS record** `keel-dev.dc1.lan` → `dc1-x86`. Nothing in this repository creates DNS.
2. **Apply the identity.** `keel_hostname` changes the Caddy route, the CORS origin, and the JWT and OIDC issuers. **The issuer appears in already-issued tokens, so applying it invalidates live sessions** — do it when that is acceptable, and expect to sign in again.
3. **Verify by hand** once: `ansible-playbook playbooks/keel-reconcile.yml --check` then a real run, watching it through.
4. **Provision the two files the timer needs**, neither of which is in git:
   - `/etc/keel/vault-pass`, mode `0400`, owned by the operator account
   - a sudo rule for that account scoped to this playbook's needs on `dc1-x86` — an unattended run cannot answer a `--ask-become-pass` prompt, and blanket `NOPASSWD` is not the way to fix that
5. **Install the units** from [`roles/keel_reconcile/files/`](../roles/keel_reconcile/files/) and `systemctl enable --now keel-reconcile-dev.timer`.

Until step 5, DEV reconciles when somebody runs the playbook — which is a reasonable place to stop and watch it for a while.

## Tests

```bash
tests/run-all.sh          # everything, including the six suites below
```

| suite | what it establishes |
|---|---|
| `dev-environment-identity.yml` | the names, read from inventory; no CI VM is a deployment target |
| `release-contract.yml` | 14 cases against the role's own reader: schema, digest-only, identity, role coverage, controller version |
| `reconcile-decisions.yml` | 8 decision cases, plus that the shipped defaults are the safe ones |
| `reconcile-lock.yml` | acquire, contend, release-and-retake — exercised, not grepped |
| `reconcile-boundaries.yml` | one deployer, one migration owner, no verification bypass, no retry loop |
| `run-reconcile-check-mode.sh` | a real `--check` run against a real channel repository, changing nothing |

The producing side's contract tests live in the Keel repository: `node --test scripts/release/release.test.mjs`.
