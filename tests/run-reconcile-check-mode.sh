#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# A REAL --check RUN OF THE RECONCILE PLAYBOOK, AGAINST A REAL CHANNEL.
#
# ⚠️ WHY LOCAL GIT REPOSITORIES AND NOT MOCKS. The role fetches the channel with
# `ansible.builtin.git`, and it fetches the Keel source checkout with `git
# fetch` to make sure the release's commit is present. A fixture that handed it
# files on disk would skip the two steps most likely to be wrong — the branch,
# the path inside the repository, whether a shallow clone of a non-default
# branch works, and whether the commit check actually rejects a missing commit.
# `git` does not care that a remote is a local directory, so this exercises the
# real tasks against real repositories AND NEEDS NO NETWORK.
#
# ⚠️ AND NOT AGAINST THE DEVELOPER'S OWN KEEL CHECKOUT. An earlier version left
# `keel_source_repo` at its default, so the suite ran `git fetch origin` against
# the real repository over the network, and its "commit is present" case passed
# only because the fixture SHA happened to exist there. A test that needs the
# outside world to be in a particular state is not a test.
#
# What it proves:
#   1. the run reaches a decision, and SAYS what that decision is
#   2. --check takes no lock, writes no attempt record, deploys nothing
#   3. a release whose commit is absent from the controller is REFUSED — and
#      refused under --check, so a dry run does not promise a deployment that
#      the real run would decline
#   4. a channel document of the wrong schema is refused, not interpreted
#
# Controller-only. Everything it creates is under /tmp, named exactly, and
# removed at the end.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURE=/tmp/keel-reconcile-channel-fixture
SRCFIX=/tmp/keel-reconcile-source-fixture
WORKDIR=/tmp/keel-reconcile-checkmode-workdir
STATE=/tmp/keel-reconcile-checkmode-state
OUT=$(mktemp)

cleanup() {
  rm -rf "$FIXTURE" "$SRCFIX" "$WORKDIR" "$STATE" "$OUT"
}
trap cleanup EXIT
rm -rf "$FIXTURE" "$SRCFIX" "$WORKDIR" "$STATE"

# ── A stand-in for the controller's Keel checkout ───────────────────────────
# One commit, and `origin` pointing at itself so the role's `git fetch origin`
# succeeds without reaching anything.
mkdir -p "$SRCFIX"
git -C "$SRCFIX" init --quiet --initial-branch=main
git -C "$SRCFIX" config user.email fixture@example.invalid
git -C "$SRCFIX" config user.name "source fixture"
echo "stand-in for the Keel source tree" > "$SRCFIX/README"
git -C "$SRCFIX" add -A
git -C "$SRCFIX" commit --quiet -m "fixture commit"
git -C "$SRCFIX" remote add origin "$SRCFIX"
REAL_SHA=$(git -C "$SRCFIX" rev-parse HEAD)
ABSENT_SHA=$(printf 'f%.0s' $(seq 1 40))

# ── A channel repository, built here ────────────────────────────────────────
mkdir -p "$FIXTURE/channels"
git -C "$FIXTURE" init --quiet --initial-branch=release/dev
git -C "$FIXTURE" config user.email fixture@example.invalid
git -C "$FIXTURE" config user.name "reconcile fixture"

write_channel() { # write_channel <channel-schema> <gitSha>
  cat > "$FIXTURE/channels/dev.json" <<JSON
{
  "schemaVersion": "$1",
  "channel": "dev",
  "release": {
    "schemaVersion": "keel.release/v1",
    "releaseId": "keel-20260929T000000Z-$(printf '%s' "$2" | cut -c1-12)",
    "gitSha": "$2",
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
  git -C "$FIXTURE" commit --quiet -m "channel: $1 $2"
}

run_check() {
  ansible-playbook playbooks/keel-reconcile.yml --check \
    -i tests/inventory-reconcile-fixture.yml \
    -e keel_reconcile_hosts=keel_reconcile_fixture \
    -e "keel_reconcile_channel_repo=$FIXTURE" \
    -e "keel_reconcile_workdir=$WORKDIR" \
    -e "keel_reconcile_state_dir=$STATE" \
    -e "keel_source_repo=$SRCFIX" \
    > "$OUT" 2>&1
}

fail=0
check() { # check <description> <status>
  if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=$((fail + 1)); fi
}

# ⚠️ `grep … ; check $?` DOES NOT WORK UNDER `set -e`. A bare failing grep is
# not in a condition context, so the shell exits on the first failed check and
# the run reports two passes and silence instead of a failure. Every text check
# goes through here.
want() { # want <description> <pattern>
  if grep -q -e "$2" "$OUT"; then check "$1" 0; else check "$1" 1; fi
}
want_not() { # want_not <description> <pattern>
  if grep -q -E -e "$2" "$OUT"; then check "$1" 1; else check "$1" 0; fi
}

# ── 1. A WELL-FORMED CHANNEL: the run decides, and says so ──────────────────
echo "── a well-formed channel reaches a stated decision ─────────────────"
write_channel "keel.channel/v1" "$REAL_SHA"

if run_check; then
  echo "  ok    the check-mode run completed"
else
  echo "  FAIL  the check-mode run did not complete; output follows"
  cat "$OUT"
  exit 1
fi

want "it decided to deploy, and said so" "DECISION deploy"
want "it names the commit it would deploy" "${REAL_SHA:0:12}"

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

# ── 3. A COMMIT THE CONTROLLER DOES NOT HAVE ────────────────────────────────
#
# Release mode reads the compose bundle out of the release's own commit, so a
# controller without that object cannot deploy it. Caught under --check, so a
# dry run does not promise a deployment the real run would refuse.
echo
echo "── a release whose commit is absent is refused, under --check ──────"
write_channel "keel.channel/v1" "$ABSENT_SHA"

if run_check; then
  echo "  FAIL  a release with an unavailable commit was accepted"
  fail=$((fail + 1))
else
  check "the run refused it" 0
  want "it named the checkout and the missing commit" "is not in $SRCFIX on this controller"

fi

# ── 4. A CHANNEL OF THE WRONG SCHEMA IS REFUSED ─────────────────────────────
#
# Not best-effort parsed. A field this reader does not know about is exactly
# where a security-relevant instruction would be.
echo
echo "── an unknown channel schema is refused, not interpreted ───────────"
write_channel "keel.channel/v2" "$REAL_SHA"

if run_check; then
  echo "  FAIL  a keel.channel/v2 document was accepted"
  fail=$((fail + 1))
else
  check "the run refused it" 0
  want "and said why" "Refusing to interpret it"
  if grep -q "DECISION" "$OUT"; then
    echo "  FAIL  it reached a decision anyway"; fail=$((fail + 1))
  else
    check "it stopped before deciding anything" 0
  fi
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: ${fail} check(s)."
  echo "── playbook output ─────────────────────────────────────────────────"
  cat "$OUT"
  exit 1
fi
echo "Reconcile check-mode regression passed."
