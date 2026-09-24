#!/usr/bin/env bash
# Two checks, one script.
#
#   1. STATIC — every mutating phase in main.yml carries `when: not ansible_check_mode`.
#      A phase that loses its guard is the defect returning, and grep sees it
#      without needing a host to run against.
#   2. RUNTIME — a real --check run performs no source transfer and leaves no
#      archive or build tree behind, and reaches PLAY RECAP with failed=0.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "── static: every mutating phase is guarded ─────────────────────────"
missing=0
guards=$(awk -f tests/lib/guard-check.awk roles/keel/tasks/main.yml)
for phase in source build deploy caddy verify; do
  if echo "$guards" | grep -qx "$phase guarded"; then
    echo "  ok         $phase.yml is guarded"
  else
    echo "  UNGUARDED  $phase.yml would run under --check"
    missing=$((missing + 1))
  fi
done
# preflight and secrets MUST NOT be guarded: they are the preflight.
for phase in preflight secrets; do
  if echo "$guards" | grep -qx "$phase UNGUARDED"; then
    echo "  ok         $phase.yml runs in both modes, as it must"
  else
    echo "  WRONG      $phase.yml is guarded; check mode would validate nothing"
    missing=$((missing + 1))
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "FAILED: ${missing} mutating phase(s) would run under --check."
  exit 1
fi

echo
echo "── runtime: --check creates no archive and no source tree ──────────"
recap=$(mktemp)
ansible-playbook tests/check-mode-preflight.yml --check 2>&1 | tee "$recap"

if ! grep -qE 'failed=0' "$recap"; then
  echo "FAILED: the check-mode run did not reach PLAY RECAP with failed=0."
  rm -f "$recap"
  exit 1
fi
rm -f "$recap"

echo
echo "Check-mode preflight regression passed."
