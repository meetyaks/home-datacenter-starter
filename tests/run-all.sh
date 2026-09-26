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
echo "══ ingress ownership (25 static checks) ═══════════════════════════"
# One owner for Caddy, provisioned before Keel, and a route that does not try
# to split ~80 gateway prefixes from the SPA's router by path.
tests/run-ingress-ownership.sh

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

echo
echo "All regression suites passed."
