#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# A REAL --check RUN OF THE RECONCILE PLAYBOOK, AGAINST A REAL CHANNEL.
#
# ⚠️ WHY A LOCAL GIT REPOSITORY AND NOT A MOCK. The role fetches the channel
# with `ansible.builtin.git`; a fixture that handed it a file on disk would
# skip the one step most likely to be wrong — the branch, the path inside the
# repository, and whether a shallow clone of a non-default branch even works.
# `git` does not care that the remote is a local directory, so this exercises
# the real task against a real repository and still needs no network.
#
# What it proves:
#   1. the run reaches a decision, and SAYS what that decision is
#   2. --check takes no lock, writes no attempt record, deploys nothing
#   3. a channel document of the wrong schema is refused, not interpreted
#
# Controller-only. Everything it creates is under /tmp and named exactly, and
# it is all removed at the end.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURE=/tmp/keel-reconcile-channel-fixture
WORKDIR=/tmp/keel-reconcile-checkmode-workdir
STATE=/tmp/keel-reconcile-checkmode-state
OUT=$(mktemp)

cleanup() {
  rm -rf "$FIXTURE" "$WORKDIR" "$STATE" "$OUT"
}
trap cleanup EXIT

# ── A channel repository, built here ────────────────────────────────────────
rm -rf "$FIXTURE" "$WORKDIR" "$STATE"
mkdir -p "$FIXTURE/channels"
git -C "$FIXTURE" init --quiet --initial-branch=release/dev
git -C "$FIXTURE" config user.email fixture@example.invalid
git -C "$FIXTURE" config user.name "reconcile fixture"

write_channel() {
  cat > "$FIXTURE/channels/dev.json" <<JSON
{
  "schemaVersion": "$1",
  "channel": "dev",
  "release": {
    "schemaVersion": "keel.release/v1",
    "releaseId": "keel-20260929T000000Z-938f25ac6474",
    "gitSha": "938f25ac6474b7408d425be600220ce9c52de87e",
    "createdAt": "2026-09-29T00:00:00Z",
    "platformVersion": "0.1.2",
    "images": [],
    "bundle": {"composePath": "infra/lab/compose.lab.yml", "sha256": "00"},
    "migrations": {"headId": "304_skills.sql", "count": 296, "requiresManualRecoveryOnFailure": true},
    "minimumControllerVersion": "1.0.0",
    "provenance": {"repository": "meetyaks/keel"}
  },
  "advanced": {"at": "2026-09-29T00:00:00Z", "by": "fixture", "reason": "seed", "rollback": false}
}
JSON
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit --quiet -m "channel: $1"
}

run_check() {
  ansible-playbook playbooks/keel-reconcile.yml --check \
    -i tests/inventory-reconcile-fixture.yml \
    -e keel_reconcile_hosts=keel_reconcile_fixture \
    -e "keel_reconcile_channel_repo=$FIXTURE" \
    -e "keel_reconcile_workdir=$WORKDIR" \
    -e "keel_reconcile_state_dir=$STATE" \
    > "$OUT" 2>&1
}

fail=0
check() { # check <description> <condition-already-evaluated:0|1>
  if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=$((fail + 1)); fi
}

# ── 1. A WELL-FORMED CHANNEL: the run decides, and says so ──────────────────
echo "── a well-formed channel reaches a stated decision ─────────────────"
write_channel "keel.channel/v1"

if run_check; then
  echo "  ok    the check-mode run completed"
else
  echo "  FAIL  the check-mode run did not complete; output follows"
  cat "$OUT"
  exit 1
fi

grep -q "DECISION deploy" "$OUT"; check "it decided to deploy, and said so" $?
grep -q "keel-20260929T000000Z-938f25ac6474" "$OUT"; check "it names the release it would deploy" $?

# ── 2. --check CHANGED NOTHING ──────────────────────────────────────────────
#
# ⚠️ THE ONE THAT MATTERS. roles/keel guards each mutating phase, but this role
# takes a lock and writes an attempt record BEFORE it ever reaches that role,
# and neither of those is a dry run of anything.
echo
echo "── --check took no lock, wrote no record, deployed nothing ─────────"

[ ! -e "$STATE/reconcile.lock" ]; check "no deployment lock was taken" $?
[ ! -e "$STATE/attempts" ];      check "no attempt record was written" $?
[ ! -e "$STATE/current.json" ];  check "no deployment record was written" $?
[ ! -e "$STATE/evidence" ];      check "no evidence directory was created" $?

# The deployer must never have been entered at all.
if grep -qE "docker (build|pull|compose)" "$OUT"; then
  check "no docker command was run" 1
else
  check "no docker command was run" 0
fi

recap=$(grep -E "^reconcile-fixture-host" "$OUT" | tail -1 || true)
case "$recap" in
  *failed=0*) check "PLAY RECAP reports failed=0" 0 ;;
  *)          echo "  FAIL  PLAY RECAP: ${recap:-(absent)}"; fail=$((fail + 1)) ;;
esac

# ── 3. A CHANNEL OF THE WRONG SCHEMA IS REFUSED ─────────────────────────────
#
# Not best-effort parsed. A field this reader does not know about is exactly
# where a security-relevant instruction would be.
echo
echo "── an unknown channel schema is refused, not interpreted ───────────"
write_channel "keel.channel/v2"

if run_check; then
  echo "  FAIL  a keel.channel/v2 document was accepted"
  fail=$((fail + 1))
else
  check "the run refused it" 0
  grep -q "Refusing to interpret it" "$OUT"; check "and said why" $?
  grep -q "DECISION" "$OUT" && { echo "  FAIL  it reached a decision anyway"; fail=$((fail + 1)); } || \
    check "it stopped before deciding anything" 0
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: ${fail} check(s)."
  echo "── playbook output ─────────────────────────────────────────────────"
  cat "$OUT"
  exit 1
fi
echo "Reconcile check-mode regression passed."
