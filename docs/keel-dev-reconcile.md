# The Keel DEV environment, and how it gets its releases

DEV is the Keel environment on `dc1-x86`. It runs **immutable, digest-pinned artifacts** built by CI from validated commits on `main`, and it reconciles to them automatically.

> ⚠️ **Not "attested artifacts".** An earlier draft of this document said that, and today it would be false. GitHub cannot persist artifact attestations for `meetyaks/keel` — see [Provenance, and what DEV actually gets](#provenance-and-what-dev-actually-gets). DEV deploys releases that declare `attestation.status: unavailable`, under an explicit policy that says so. Every other environment refuses them.

> **Nothing in this document deploys anything by being read.** The identity change and the scheduling units are applied deliberately, in the order given under [Turning it on](#turning-it-on).

## The two halves, and why they are separate

| | decides | does not |
|---|---|---|
| **CI** (`meetyaks/keel`, `.github/workflows/dev-release.yml`) | what is **eligible**: builds, gates, pushes by digest, **declares what provenance it could and could not produce**, publishes a release manifest and advances the channel | reach into any site |
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

### Failure is not rolled back automatically

Keel's migrations are **forward-only**; there is no down-migration runner. Redeploying the previous image does **not** restore the previous schema, so a site that rolled back would report a recovery that did not happen. Each release states this itself, in `migrations.requiresManualRecoveryOnFailure`.

On failure the controller keeps evidence under `/srv/data/services/keel/releases/evidence/<timestamp>-<releaseId>/` — the attempt, container state, recent logs per service, and which images the host actually holds — and escalates. It retries once more (`keel_reconcile_max_attempts: 2`) for a genuinely transient failure, then stops and waits for a person.

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

Both halves must land, in order, and the order matters: a site that can consume releases before any release exists is harmless, but a channel publishing into a site that cannot read its provenance statement is not.

| # | where | step | stop if |
|---|---|---|---|
| 1 | keel | merge the DEV release channel PR to `main` | the eligibility gate is not green on the PR itself |
| 2 | keel | let `dev-release.yml` run on `main` and publish the **first** release | the gate fails on `main` — that is the gate doing its job, not a reason to bypass it |
| 3 | keel | read `channels/dev.json` on `release/dev` by hand and check it names two digest-pinned images, a bundle hash, and a `platformVersion` | anything is tagged rather than digested |
| 4 | keel | read `provenance.attestation.status` and **check it against what you expect of this repository**. `persisted` → verify it: `gh attestation verify oci://…@<digest> --repo meetyaks/keel`, for both images and the manifest file. `unavailable` → read the `reason` and decide whether it is one you accept | the status and the `mechanism` disagree, or an `unavailable` reason is missing or is not a real limitation |
| 5 | infra | merge `deploy/keel-lab` (PR #1), then this PR | — |
| 6 | infra | **resolve the registry and channel credentials** — see [Blockers](#blockers-before-this-can-run-unattended). Nothing below works without them | they do not exist yet; this is where the sequence currently stops |
| 7 | dns | create `keel-dev.dc1.lan` → dc1-x86 | — |
| 8 | infra | apply the identity. **This invalidates live sessions** — the JWT issuer appears in already-issued tokens | outside an acceptable window |
| 9 | infra | `ansible-playbook playbooks/keel-reconcile.yml --check --diff` and read the decision | it does not name the release you read at step 3 |
| 10 | infra | run it for real, watching, and confirm `/srv/data/services/keel/releases/current.json` names that release **and the assurance you expected** | health verification fails — evidence is kept, and recovery is manual |
| 11 | console | provision `/etc/keel/vault-pass` (`0400`) and the scoped sudo rule | — |
| 12 | console | install the units and `systemctl enable --now keel-reconcile-dev.timer` | steps 9 and 10 have not both been done by hand at least once |

Steps 1–4 are the producing side and change nothing on any host. **Steps 1–4 are done**: `release/dev` exists and carries `keel-20261001T010103Z-5bb120c97b56`, whose attestation status is `unavailable` for the reason above. Steps 5–10 are one deliberate, watched deployment. Steps 11–12 are what makes it unattended, and are deliberately last: a mechanism nobody has watched work should not first run at 3am.

## Blockers, before this can run unattended

Found while tracing the consumer against the real release. **Neither is fixed here** — both need a credential, and creating one is not something this repository does on its own initiative.

| # | blocker | why it stops the run |
|---|---|---|
| 1 | **Private GHCR.** `ghcr.io/meetyaks/keel` and `…/keel-web` are private packages. `roles/keel/tasks/release-bundle.yml` runs `docker pull` **on `dc1-x86`**, which has no `docker login` for GHCR — and no `keel_vault_*` variable holds a registry credential | the pull fails with `denied`. Release mode does not build, so there is no fallback. It fails *before* `compose up`, which is deliberate — the running site stays up — but the release cannot be deployed at all |
| 2 | **Private release channel.** `meetyaks/keel` is private, so `release/dev` is too. The controller clones it with `ansible.builtin.git` (`delegate_to: localhost`) and this repository supplies no credential for it | an operator's own console may happen to have a working git credential, which is exactly the trap: the **unattended timer** runs as a service account that does not, and would fail at the first task on every tick |

Both are **least-privilege, read-only** needs: a token that can pull those two packages, and one that can read that one branch. They belong in the existing vault (`inventory/group_vars/linux_servers/`) — not in this document, not on a command line, and not in a `.env`. Until they exist the sequence above stops at step 6: the controller is correct and cannot run.

A third item is **not** a blocker, and is recorded so it is not rediscovered: `release/dev` carries **6,031 files** in its tree, where the channel needs two JSON documents. That costs a slower clone on every tick and nothing else. It is producer-side shape and belongs in the Keel repository, not here.

## Turning it on

Steps 6 onwards, in detail. Not yet done:

1. **Resolve the two credentials** in [Blockers](#blockers-before-this-can-run-unattended), through the vault. Everything below assumes the host can pull the images and the controller can read the channel.
2. **Create the DNS record** `keel-dev.dc1.lan` → `dc1-x86`. Nothing in this repository creates DNS.
3. **Apply the identity.** `keel_hostname` changes the Caddy route, the CORS origin, and the JWT and OIDC issuers. **The issuer appears in already-issued tokens, so applying it invalidates live sessions** — do it when that is acceptable, and expect to sign in again.
4. **Verify by hand** once: `ansible-playbook playbooks/keel-reconcile.yml --check` then a real run, watching it through. Read `current.json` afterwards and confirm the `assurance` line says what you expect — on DEV today that is `NOT ATTESTED — explicitly permitted by DEV policy`.
5. **Provision the two files the timer needs**, neither of which is in git:
   - `/etc/keel/vault-pass`, mode `0400`, owned by the operator account
   - a sudo rule for that account scoped to this playbook's needs on `dc1-x86` — an unattended run cannot answer a `--ask-become-pass` prompt, and blanket `NOPASSWD` is not the way to fix that
6. **Install the units** from [`roles/keel_reconcile/files/`](../roles/keel_reconcile/files/) and `systemctl enable --now keel-reconcile-dev.timer`.

Until step 6, DEV reconciles when somebody runs the playbook — which is a reasonable place to stop and watch it for a while.

## Tests

```bash
tests/run-all.sh                        # everything, including the eight suites below
KEEL_SKIP_MUTATIONS=1 tests/run-all.sh  # the quick loop; leaves the guards UNPROVEN
```

| suite | what it establishes |
|---|---|
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
