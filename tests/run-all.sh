#!/usr/bin/env bash
# Every regression suite for roles/keel. Controller-only: no SSH, no vault, no
# secrets, no Docker, nothing written outside /tmp fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "══ secret verification (4 cases, both modes) ═══════════════════════"
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
echo "All regression suites passed."
