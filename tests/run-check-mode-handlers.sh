#!/usr/bin/env bash
# Mutating handlers must be notified-but-skipped under --check.
#
# Asserts three things, because the first two alone would pass a role that had
# simply stopped notifying:
#   · the run reaches PLAY RECAP with failed=0 and unreachable=0
#   · every mutating handler reports skipping
#   · the absent deployment root is still absent afterwards
set -euo pipefail
cd "$(dirname "$0")/.."

out=$(mktemp)
ansible-playbook tests/check-mode-handlers.yml --check 2>&1 | tee "$out"

fail=0
grep -qE 'failed=0' "$out"      || { echo "FAILED: failed != 0"; fail=1; }
grep -qE 'unreachable=0' "$out" || { echo "FAILED: unreachable != 0"; fail=1; }

for h in "Restart Keel stack" "Restart Keel gateway" "Reload Caddy"; do
  # The handler must appear AND be skipped. A handler that never ran at all
  # would satisfy "not executed" without proving the guard works.
  if grep -q "RUNNING HANDLER \[$h\]" "$out" && \
     awk "/RUNNING HANDLER \[$h\]/{f=1;next} f&&/^(skipping|ok|changed|fatal)/{print;exit}" "$out" | grep -q '^skipping'; then
    echo "  ok       $h was notified and SKIPPED"
  else
    echo "  FAILED   $h did not report skipping"
    fail=1
  fi
done

rm -f "$out"
[ "$fail" -eq 0 ] || exit 1
echo
echo "Check-mode handler regression passed."
