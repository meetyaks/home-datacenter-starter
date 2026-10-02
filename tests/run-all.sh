#!/usr/bin/env bash
# Every regression suite for roles/keel. Controller-only — no SSH, no vault, no
# secrets, nothing written outside /tmp fixtures — with ONE exception, noted at
# the runtime-group scenarios, which need a disposable Linux container.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "══ secret verification (7 cases, both modes) ══════════════════════"
tests/run-secret-verification.sh

echo
echo "══ controller delegation ═══════════════════════════════════════════"
ansible-playbook -i tests/inventory-fixture.yml tests/controller-delegation.yml

echo
echo "══ fresh-host check mode ═══════════════════════════════════════════"
ansible-playbook tests/check-mode-fresh-host.yml --check

echo
echo "══ check-mode preflight (no archive, no source tree) ═══════════════"
tests/run-check-mode-preflight.sh

echo
echo "══ check-mode handlers (notified, never executed) ══════════════════"
tests/run-check-mode-handlers.sh

echo
echo "══ check-mode runtime group (chgrp by GID, not name) ═══════════════"
tests/run-check-mode-runtime-group.sh

echo
echo "══ remote image check (runs on the managed host, list as data) ════"
# Covers the module AND how preflight calls it. Both have gone wrong: once by
# interpolating the image list into shell text, and once by delegating the
# check to the controller — which removed the host-specific protection it
# exists to provide.
#
# Network-dependent in part: "can this be fetched right now, with no
# credentials and no cache" is only answerable by asking a registry.
tests/run-remote-image-check.sh

echo
echo "══ ingress ownership (33 static checks) ═══════════════════════════"
# One owner for Caddy, provisioned before Keel, and a route that does not try
# to split ~80 gateway prefixes from the SPA's router by path.
tests/run-ingress-ownership.sh

echo
echo "══ caddy handler ordering + resume drift (57 checks, disposable) ══"
# The defect: the route was written, the reload notified, and verification ran
# before Ansible flushed handlers — so it tested the config Caddy loaded BEFORE
# the drop-in existed. Reproduces the incident, and fails against the old code.
tests/run-caddy-handler-order.sh

echo
echo "══ caddy check mode & real install (34 checks, disposable host) ══"
# The defect: `--check` on a fresh host ran `caddy version` against a binary
# the apt task above had only PREDICTED. Plus the handover to roles/keel, where
# a predicted /etc/caddy/conf.d used to abort the dry run.
tests/run-caddy-check-mode.sh

echo
echo "══ caddy role (16 checks, on a disposable systemd host) ═══════════"
# Installing a package, enabling a unit and reloading a service need root on a
# throwaway Linux machine. Skips loudly when Docker is absent.
tests/run-caddy-role.sh

echo
echo "══ runtime group scenarios (7, on a disposable Linux host) ═════════"
# The only suite here that is NOT controller-only: creating and colliding system
# groups, and proving a real run is idempotent, need root on a throwaway Linux
# machine. It skips loudly when Docker is absent rather than passing silently.
tests/run-runtime-group-scenarios.sh

echo
echo "══ compose auth profile (22 checks, rendered + container) ═════════"
# THE ACCEPTANCE FAILURE. `${VAR:-}` in a compose `environment:` mapping always
# emits the key, so an unset KEEL_OIDC_ISSUER became `KEEL_OIDC_ISSUER=` and the
# gateway crash-looped on an invalid URL while everything around it was healthy.
# Reads the RENDERED config and a container Compose actually started — absent and
# empty are different states, and only one of them used to be tested.
tests/run-compose-auth-profile.sh

echo
echo "══ rendered auth posture (password-only, registration closed) ═════"
# Renders roles/keel/templates/keel.env.j2 with the role's OWN defaults and
# asserts the posture it produces. Grepping the template would prove the lines
# exist; only rendering proves which survive the `{% if %}`.
ansible-playbook tests/env-render.yml

echo
echo "══ deployment mode vs sign-in methods (9 checks) ══════════════════"
# ⚠️ THE 2026-10-01 OUTAGE, AS A TEST. `production` + password-only has NO
# valid configuration in Keel: the validator requires OIDC, and the dev-login
# escape hatch it would otherwise accept is itself forbidden in production. The
# deployment did not notice — it pulled, verified the bundle and APPLIED
# MIGRATIONS, and only then did the gateway crash-loop, leaving a migrated
# database behind a gateway that never served.
#
# Runs roles/keel/tasks/assert-deployment-mode.yml itself, in both directions:
# the impossible combination must be refused in preflight, the three workable
# ones must not be, and a typo must fail closed rather than fall through to
# permissive. No mutation runner needed — the refusal cases ARE the proof that
# the guard fires, since a guard that stopped firing would fail them.
ansible-playbook tests/deployment-mode.yml

echo
echo "══ enrollment operator path (19 checks, executes the play) ═════════"
# ⚠️ EXECUTES the play against a local stand-in host — never dc1-x86. The email
# validator shipped rejecting EVERY valid address and passed --syntax-check,
# because a syntax check does not evaluate a template.
tests/run-enroll-admin-path.sh

echo
echo "══ platform version gate ═══════════════════════════════════════════"
# ⚠️ READ THE PIN, DO NOT RESTATE IT. This used to carry its own copy of the
# 40-character SHA, which meant the deployment pin lived in two hand-maintained
# places — and the copy here is the one nobody remembers to change. A suite that
# derives the version from a DIFFERENT commit than the role deploys is worse
# than no suite: it passes while proving something about the wrong tree.
# roles/keel/defaults/main.yml is the single authority; this reads it.
KEEL_TEST_COMMIT=$(awk '/^keel_commit:/{print $2; exit}' roles/keel/defaults/main.yml)

if ! printf '%s' "$KEEL_TEST_COMMIT" | grep -qE '^[0-9a-f]{40}$'; then
  echo "FAILED: could not read a 40-character commit SHA from roles/keel/defaults/main.yml" >&2
  echo "        got: '${KEEL_TEST_COMMIT}'" >&2
  exit 1
fi
echo "   deployment pin: ${KEEL_TEST_COMMIT}"

ansible-playbook tests/platform-version.yml -e keel_test_commit="$KEEL_TEST_COMMIT"

echo
echo "══ installation identity (7 cases + no committed value) ════════════"
ansible-playbook tests/installation-identity.yml

# ═══ DEV RELEASE DELIVERY ═══════════════════════════════════════════════════
#
# The site half of the DEV channel: read a published release, verify it, and
# deploy it through roles/keel rather than building on the host.

echo
echo "══ DEV environment identity (12 checks, read from inventory) ══════"
# The names are read out of inventory/hosts.yml and
# inventory/group_vars/keel_dev/ — never restated here. Also asserts that
# neither CI VM is a deployment target, which is the boundary the whole
# delivery design rests on.
ansible-playbook tests/dev-environment-identity.yml

echo
echo "══ release contract (14 cases, the site's own reader) ═════════════"
# roles/keel/tasks/release.yml is this repository's reader for
# keel.release/v1; the producing side has its own. A contract only one side
# can check is not a contract, and this is what makes the second reader real.
# Runs the ROLE'S tasks against fixtures — it restates no assertion.
ansible-playbook tests/release-contract.yml

echo
echo "══ reconcile decisions (8 cases + 3 shipped-posture checks) ═══════"
# Every state a DEV site can be in: converged, behind, moved backwards,
# rolled back explicitly, out of retries, previously failed.
ansible-playbook tests/reconcile-decisions.yml

echo
echo "══ deployment lock (3 scenarios, real directory) ══════════════════"
# ⚠️ EXERCISED, NOT GREPPED. That a second acquisition FAILS is the only
# property that matters, and it is exactly the one `file: state=directory`
# would silently lose.
ansible-playbook tests/reconcile-lock.yml

echo
echo "══ reconcile boundaries (9 structural checks) ═════════════════════"
# One deployer, one migration owner, no path that weakens provenance
# verification, no systemd restart loop — and the reconciler records which
# policy and what assurance it deployed under, which is the half of that rule
# a prohibition alone cannot express.
ansible-playbook tests/reconcile-boundaries.yml

echo
echo "══ reconcile check mode (13 checks, real channel repository) ══════"
# ⚠️ A REAL --check RUN. The role takes a lock and writes an attempt record
# BEFORE it reaches roles/keel, and neither is a dry run of anything. Builds a
# local git repository so the real `git` task is exercised without a network.
tests/run-reconcile-check-mode.sh

echo
echo "══ the controller's scheduler (25 checks) ════════════════════════"
# ⚠️ IT ASKS THE MACHINE WHICH OS IT IS. The repository shipped systemd units
# for a console that runs macOS and has no systemctl at all; nothing said so
# until somebody tried. The live scheduler is a launchd plist, the systemd
# units are a retained Linux variant, and both are held to the same rules:
# invoke the wrapper, never restart into a loop, carry no credential.
ansible-playbook tests/controller-scheduler.yml

echo
echo "══ the wrapper, executed (20 checks) ═════════════════════════════"
# ⚠️ EXERCISED, NOT GREPPED. That a SECOND concurrent run is refused, and
# that Ansible's exit status survives unchanged, are exactly the properties a
# careless rewrite loses and a structural check cannot see.
tests/run-wrapper-behaviour.sh

echo
echo "══ unpullable vs unobtainable (15 checks) ════════════════════════"
# ⚠️ IT GUARDS A NARROWING OF A DEPLOYMENT GATE. The preflight used to refuse
# whenever an image could not be pulled anonymously; it now refuses only when
# the host can obtain it NEITHER anonymously NOR from its own store. These
# cases keep the second half honest — an image that is genuinely gone must
# still stop the deployment, and an entry nobody could check counts as gone.
ansible-playbook tests/anon-pull-classify.yml

echo
echo "══ the github host-key pin (9 checks) ════════════════════════════"
# ⚠️ THE GUARD THAT MATTERS MOST ON THIS PATH. The controller decides what DEV
# runs, from a document it fetches over SSH. `ssh-keyscan` — the usual way to
# fill known_hosts — pins whatever answers on port 22 and authenticates
# nothing. This proves the replacement actually REJECTS a tampered document
# rather than merely fetching a good one.
tests/run-known-hosts-pin.sh

echo
echo "══ the credential contract (99 checks) ═══════════════════════════"
# ⚠️ NEITHER CREDENTIAL EXISTS YET. Nothing here proves authentication works
# — only that the code refuses without it, cannot leak it, and gives it back.
# Those must be right BEFORE a real credential is created, because afterwards
# a mistake is a disclosed secret rather than a failing test.
ansible-playbook tests/credential-contract.yml

echo
echo "══ the published release, read by this reader ════════════════════"
# ⚠️ THE ONE SUITE WHOSE INPUT THIS REPOSITORY DID NOT WRITE. Every fixture
# above agrees with the reader because the same hand wrote both. This runs the
# reader against a byte-for-byte copy of the document meetyaks/keel actually
# published to release/dev: refused under the shipped default, resolved under
# DEV's policy, and never verified — because it declares there is nothing to
# verify. Read-only; deploys nothing.
ansible-playbook tests/published-release-proof.yml
tests/run-published-release-check-mode.sh

echo
echo "══ provenance mutations (14 checks) ══════════════════════════════"
# ⚠️ A GUARD THAT HAS NEVER FAILED IS NOT A GUARD. Breaks the policy eleven
# ways in turn and proves the suites above go red FOR THAT REASON — a
# rejection for the wrong reason is not a pass. Restores every file it edits.
#
# Slow: it runs three suites twelve times. Set KEEL_SKIP_MUTATIONS=1 to leave
# it out of a quick loop, and never out of a release check.
if [ "${KEEL_SKIP_MUTATIONS:-0}" = "1" ]; then
  echo "SKIPPED by KEEL_SKIP_MUTATIONS=1 — the policy guards are UNPROVEN in this run."
else
  tests/run-provenance-mutations.sh
fi

echo
echo "══ scheduler and credential mutations (20 checks) ════════════════"
# ⚠️ THE SAME DISCIPLINE, APPLIED TO THE GUARDS THAT PROTECT SECRETS. These
# decide whether a read-only token reaches a process table, whether a failed
# deployment leaves a credential on the host, and whether an unattended
# controller accepts a release document from whatever answered on port 22.
if [ "${KEEL_SKIP_MUTATIONS:-0}" = "1" ]; then
  echo "SKIPPED by KEEL_SKIP_MUTATIONS=1 — the credential guards are UNPROVEN in this run."
else
  tests/run-auth-mutations.sh
fi

echo
echo "All regression suites passed."
